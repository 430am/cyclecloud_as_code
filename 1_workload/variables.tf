variable "vm_admin_username" {
  description = "The username for the admin user on the virtual machines."
  type        = string
  default     = "cyclecloudadmin"
}

variable "hub_subscription_id" {
  description = "The subscription ID of the hub subscription."
  type        = string
}

variable "location" {
  description = "The Azure region to deploy resources in."
  type        = string
  default     = "southcentralus"
}

variable "workload_subscription_id" {
  description = "The subscription ID of the workload subscription."
  type        = string
}

variable "CURRENT_IP_ADDRESS" {
  description = "Compatibility input for credentials tfvars files; if set, this CIDR is used when current_ip_address is empty."
  type        = string
  default     = ""
}

variable "subnets" {
  description = "A map of subnets to create in the virtual network."
  type        = map(object({
    address_prefix = list(string)
    name = string
  }))
  default     = {
    "bastion" = {
      address_prefix = ["10.150.2.0/26"]
      name = "bastion"
    }
    "cluster" = {
      address_prefix = ["10.150.0.0/23"]
      name = "cluster"
    }
    "private_endpoints" = {
      address_prefix = ["10.150.2.64/26"]
      name = "private_endpoints"
    }
    "infrastructure" = {
      address_prefix = ["10.150.2.128/25"]
      name = "infrastructure"
    }
  }
}

variable "tags" {
  description = "A map of tags to apply to all resources."
  type        = map(string)
  default     = {
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