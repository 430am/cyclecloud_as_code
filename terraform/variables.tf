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
      - "public_ip" (default): attach a Standard public IP to the VM NIC.
                      The server-subnet NSG allows SSH (22), HTTP (8080) and
                      HTTPS (8443) inbound from every entry in
                      var.allowed_ip_addresses (plus the auto-detected
                      operator IP). Note: CycleCloud only binds 8443 once a
                      TLS keystore is configured -- see docs/known-gaps.md.
                      No Bastion / AzureBastionSubnet is deployed.
      - "bastion"   : deploy Azure Bastion (Standard, tunneling enabled);
                      VM has no public IP.
      - "private_ip": no public IP, no Bastion. The VM is reachable only on
                      its private IP from the VNet (or anything peered to
                      it, e.g. a hub jumpbox / ExpressRoute / VPN). The
                      operator-IP NSG rule and the KV firewall caller-IP
                      entries are NOT created in this mode; Key Vault
                      public network access is disabled. Intended for
                      hub-and-spoke landing-zone deployments where access
                      flows in over peering. See docs/hub-spoke.md.
  EOT
  type        = string
  default     = "public_ip"

  validation {
    condition     = contains(["bastion", "public_ip", "private_ip"], var.access_mode)
    error_message = "access_mode must be one of \"bastion\", \"public_ip\", or \"private_ip\"."
  }
}

variable "deployment_mode" {
  description = <<-EOT
    Topology this stack is being deployed into:
      - "standalone" (default): self-contained deployment. Creates its own
                       Log Analytics workspace, AMPLS, private DNS zones,
                       monitoring storage account, etc. No peering.
      - "spoke"      : deploy as a spoke in an existing hub-and-spoke
                       landing zone. Skips creating local Log Analytics /
                       AMPLS / monitoring storage / private DNS zones;
                       reuses the hub workspace for diagnostics and
                       creates VNet peering to the hub. Private endpoints
                       are still created but their DNS A-records are
                       expected to be registered by hub-managed Azure
                       Policy (the "DNS zone group for private endpoint"
                       policy). Requires var.hub to be set. See
                       docs/hub-spoke.md.
  EOT
  type        = string
  default     = "standalone"

  validation {
    condition     = contains(["standalone", "spoke"], var.deployment_mode)
    error_message = "deployment_mode must be either \"standalone\" or \"spoke\"."
  }
}

variable "hub" {
  description = <<-EOT
    Reference to the hub landing-zone resources this spoke consumes. Required
    when deployment_mode = "spoke"; ignored otherwise.

    Fields:
      subscription_id        - Azure subscription ID hosting the hub VNet /
                               Log Analytics workspace. Used to configure
                               the aliased `azurerm.hub` provider.
      tenant_id              - (optional) Hub tenant ID. Only required if
                               the hub lives in a different tenant.
      virtual_network.id     - Full resource ID of the hub VNet to peer with.
      virtual_network.allow_forwarded_traffic
                             - (default true) Sets allow_forwarded_traffic
                               on both peering sides. Required when a hub
                               firewall forwards spoke-originated traffic.
      virtual_network.use_remote_gateways
                             - (default false) Set true if the hub has an
                               ExpressRoute / VPN gateway you want the
                               spoke to use for on-prem connectivity. Hub
                               peering side automatically sets
                               allow_gateway_transit = true in that case.
      virtual_network.create_reverse_peering
                             - (default true) When true, the hub->spoke
                               peering is created via the aliased
                               `azurerm.hub` provider. Set false if the
                               hub team manages their side out-of-band
                               (you only need Network Contributor on the
                               spoke VNet in that case).
      monitoring.log_analytics_workspace_id
                             - Full resource ID of the hub Log Analytics
                               workspace. All spoke diagnostic settings
                               target this workspace.
  EOT
  type = object({
    subscription_id = string
    tenant_id       = optional(string)
    virtual_network = object({
      id                      = string
      allow_forwarded_traffic = optional(bool, true)
      use_remote_gateways     = optional(bool, false)
      create_reverse_peering  = optional(bool, true)
    })
    monitoring = object({
      log_analytics_workspace_id = string
    })
  })
  default = null

  validation {
    condition = var.hub == null || (
      can(regex("^[0-9a-fA-F-]{36}$", var.hub.subscription_id)) &&
      can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+$", var.hub.virtual_network.id)) &&
      can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+$", var.hub.monitoring.log_analytics_workspace_id))
    )
    error_message = "hub.subscription_id must be a GUID; hub.virtual_network.id must be a full Microsoft.Network/virtualNetworks resource ID; hub.monitoring.log_analytics_workspace_id must be a full Microsoft.OperationalInsights/workspaces resource ID."
  }
}