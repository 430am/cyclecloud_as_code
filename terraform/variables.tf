variable "vm_admin_username" {
  description = "The username for the admin user on the virtual machines."
  type        = string
  default     = "cyclecloudadmin"
}

variable "location" {
  description = "The Azure region to deploy resources in."
  type        = string
  default     = "southcentralus"
}

variable "CURRENT_IP_ADDRESS" {
  description = "Compatibility input for credentials tfvars files; if set, this CIDR is used when current_ip_address is empty."
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
                      allows SSH (22) and HTTPS (443) inbound from var.CURRENT_IP_ADDRESS only.
                      No Bastion / AzureBastionSubnet is deployed.
  EOT
  type        = string
  default     = "bastion"

  validation {
    condition     = contains(["bastion", "public_ip"], var.access_mode)
    error_message = "access_mode must be either \"bastion\" or \"public_ip\"."
  }
}