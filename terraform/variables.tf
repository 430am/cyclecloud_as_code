variable "vm_admin_username" {
  description = "The username for the admin user on the virtual machines."
  type        = string
  default     = "cyclecloudadmin"
}

variable "application_name" {
  description = <<-EOT
    Product / application name used as the leading token in every resource
    name (`<application_name>-<abbrev>...`). Lowercase letters, numbers and
    hyphens only; 2-20 chars to keep within Azure resource length limits
    (Key Vault and storage account cap at 24 chars).

    Leave empty (the default) to fall back to a generated `random_pet` value,
    which is convenient for throwaway lab deployments where collisions across
    parallel runs would otherwise cause naming conflicts.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.application_name == "" || can(regex("^[a-z][a-z0-9-]{1,19}$", var.application_name))
    error_message = "application_name must be empty or 2-20 chars of lowercase letters/numbers/hyphens, starting with a letter."
  }
}

variable "location" {
  description = "The Azure region to deploy resources in."
  type        = string
  default     = "southcentralus"
}

variable "allowed_ip_addresses" {
  description = <<-EOT
    Additional caller IPv4 addresses / CIDRs allowed on the Key Vault firewall
    and the server-subnet NSG (ports 22/8080/8443 inbound when
    `access_mode = "public_ip"`). The live public IP of the host running
    Terraform is auto-detected via ipify and merged into this list at plan
    time, so this variable only needs entries for teammates, CI runners,
    jump hosts, etc. Bare IPs are normalized to `/32` automatically.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for ip in var.allowed_ip_addresses :
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$", ip))
    ])
    error_message = "Each entry must be an IPv4 address or CIDR (e.g. 1.2.3.4 or 1.2.3.0/24)."
  }
}

variable "tags" {
  description = "A map of tags to apply to all resources."
  type        = map(string)
  default = {
    managed_by = "terraform"
    project    = "cyclecloud testing"
    workload   = "Azure CycleCloud"
  }
}

variable "vnet_address_space" {
  description = "The address space for the virtual network."
  type        = list(string)
  default     = ["10.150.0.0/16"]
}

variable "access_mode" {
  description = <<-EOT
    How to reach the CycleCloud server VM:
      - "bastion"   : deploy Azure Bastion (Standard, tunneling enabled); VM has no public IP.
      - "public_ip" : attach a Standard public IP to the VM NIC. The server-subnet
                      NSG allows SSH (22), HTTP (8080) and HTTPS (8443) inbound from
                      every entry in var.allowed_ip_addresses (plus the auto-detected
                      operator IP). Note: CycleCloud only binds 8443 once a TLS
                      keystore is configured -- see docs/known-gaps.md.
                      No Bastion / AzureBastionSubnet is deployed.
  EOT
  type        = string
  default     = "bastion"

  validation {
    condition     = contains(["bastion", "public_ip"], var.access_mode)
    error_message = "access_mode must be either \"bastion\" or \"public_ip\"."
  }
}

# ---------------------------------------------------------------------------
# Microsoft Entra ID app registration for CycleCloud SSO. Opt-in; the
# default keeps the deployment provider-only (no AAD writes). When enabled,
# this module creates the app registration + service principal needed by
# the CycleCloud web UI to authenticate users via Entra. Server-side
# enablement of Entra auth on the VM is handled in a follow-up change.
# See docs/entra-auth.md for the full flow and the open hostname gap.
# ---------------------------------------------------------------------------

variable "entra_auth_enabled" {
  description = <<-EOT
    Create the Microsoft Entra ID application registration, service principal,
    app roles, and (optionally) Open OnDemand federated identity credential
    needed for CycleCloud SSO. When false (the default), no AAD resources are
    created and the deployment is unchanged.
  EOT
  type        = bool
  default     = false
}

variable "entra_app_display_name" {
  description = <<-EOT
    Display name for the Entra application registration when
    entra_auth_enabled = true. Leave empty (default) to fall back to
    "<naming_token>-cyclecloud".
  EOT
  type        = string
  default     = ""
}

variable "entra_cyclecloud_hostnames" {
  description = <<-EOT
    Public hostnames (FQDNs) at which the CycleCloud web UI will be
    reachable, used to populate the SPA redirect URIs on the Entra app
    registration:
      https://<host>/home   (sign-in landing)
      https://<host>/sso    (auth callback)

    Intentionally decoupled from var.access_mode because Entra SPA URIs
    must be https:// FQDNs -- the bastion / public_ip access modes do not
    produce one on their own (HTTPS termination comes from a future
    app_gateway access mode). You can still validate the app registration
    end-to-end via the public_client URIs ("http://localhost",
    "https://localhost") that are always added.

    Ignored when entra_auth_enabled = false.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for h in var.entra_cyclecloud_hostnames :
      can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$", h))
    ])
    error_message = "Each entry must be a bare FQDN (no scheme, no path, no port). Example: \"cc.example.com\"."
  }
}

variable "entra_enable_ondemand" {
  description = <<-EOT
    Add the Global.Node.User / Global.Node.Admin app roles required for
    Open OnDemand and create a federated identity credential trusting
    var.entra_ondemand_mi_principal_id. Ignored when entra_auth_enabled
    is false.
  EOT
  type        = bool
  default     = false
}

variable "entra_ondemand_mi_principal_id" {
  description = <<-EOT
    Object (principal) ID of the user-assigned managed identity attached
    to the Open OnDemand VM. Used as the federated-credential subject so
    OOD can exchange its MI token for an app-scoped token without storing
    a client secret. Required iff entra_enable_ondemand = true.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.entra_ondemand_mi_principal_id == "" || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.entra_ondemand_mi_principal_id))
    error_message = "entra_ondemand_mi_principal_id must be empty or a valid UUID (object ID of the OOD UAI)."
  }
}

variable "entra_extra_admin_object_ids" {
  description = <<-EOT
    Additional Entra ID user or group object IDs to grant the
    "Administrator" app role on the new application registration in
    addition to the deploying user (who is auto-assigned "SuperUser").
    Ignored when entra_auth_enabled = false.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for id in var.entra_extra_admin_object_ids :
      can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))
    ])
    error_message = "Each entry must be a valid UUID (Entra user or group object ID)."
  }
}
