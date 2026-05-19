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

variable "current_ip_address" {
  description = "Caller's public IPv4 address (or x.x.x.x/32 CIDR). Used in the Key Vault firewall allow list and, when access_mode = \"public_ip\", as the source for the VM NSG inbound rules."
  type        = string
  default     = ""
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
      - "public_ip" : attach a Standard public IP to the VM NIC and create an NSG that
                      allows SSH (22), HTTP (8080) and HTTPS (8443) inbound from
                      var.current_ip_address only. Note: CycleCloud only binds 8443
                      once a TLS keystore is configured -- see docs/known-gaps.md.
                      No Bastion / AzureBastionSubnet is deployed.
  EOT
  type        = string
  default     = "bastion"

  validation {
    condition     = contains(["bastion", "public_ip"], var.access_mode)
    error_message = "access_mode must be either \"bastion\" or \"public_ip\"."
  }
}