output "resource_group_name" {
  description = "Name of the resource group containing all resources."
  value       = azurerm_resource_group.testing.name
}

output "virtual_network_name" {
  description = "Name of the CycleCloud virtual network."
  value       = azurerm_virtual_network.cyclecloud.name
}

output "cyclecloud_vm_name" {
  description = "Name of the CycleCloud server VM."
  value       = azurerm_linux_virtual_machine.cyclecloud.name
}

output "cyclecloud_vm_private_ip" {
  description = "Private IP address of the CycleCloud server VM (reachable via Bastion)."
  value       = azurerm_network_interface.cyclecloud.private_ip_address
}

output "cyclecloud_vm_public_ip" {
  description = "Public IP of the CycleCloud server VM (null when access_mode = \"bastion\")."
  value       = local.use_public_ip ? azurerm_public_ip.cyclecloud[0].ip_address : null
}

output "cyclecloud_vm_admin_username" {
  description = "Admin username for SSH into the CycleCloud server VM."
  value       = var.vm_admin_username
}

output "access_mode" {
  description = "Active connectivity mode for the CycleCloud server (\"bastion\" or \"public_ip\")."
  value       = var.access_mode
}

output "bastion_host_name" {
  description = "Name of the Azure Bastion host (null when access_mode = \"public_ip\")."
  value       = local.use_bastion ? azurerm_bastion_host.bastion[0].name : null
}

output "key_vault_name" {
  description = "Name of the Key Vault holding the generated SSH key pair."
  value       = azurerm_key_vault.cyclecloud.name
}

output "key_vault_uri" {
  description = "URI of the Key Vault holding the generated SSH key pair."
  value       = azurerm_key_vault.cyclecloud.vault_uri
}

output "ssh_private_key_secret_name" {
  description = "Name of the Key Vault secret holding the ephemeral OpenSSH private key."
  value       = azurerm_key_vault_secret.private_key.name
}

output "cyclecloud_admin_password_secret_name" {
  description = "Name of the Key Vault secret holding the auto-generated CycleCloud web-UI admin password."
  value       = azurerm_key_vault_secret.cyclecloud_admin_password.name
}

output "cyclecloud_locker_storage_account" {
  description = "Dedicated storage account used by CycleCloud as its project / template locker (separate from the monitoring SA)."
  value       = azurerm_storage_account.locker.name
}

output "cyclecloud_locker_container" {
  description = "Blob container inside the locker storage account."
  value       = azurerm_storage_container.cyclecloud_locker.name
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.monitoring.id
}

output "cyclecloud_orchestrator_role_name" {
  description = "Custom role granted to the CycleCloud VM system-assigned identity at subscription scope."
  value       = azurerm_role_definition.cyclecloud.name
}

output "nfs_storage_account" {
  description = "Premium FileStorage account hosting the NFSv4.1 shares for Slurm scheduler state and cluster-wide shared data."
  value       = azurerm_storage_account.files.name
}

output "nfs_shares" {
  description = "NFSv4.1 share names on nfs_storage_account, and the FQDN used to mount them (resolved via private DNS to the file PE)."
  value = {
    sched = {
      name        = azurerm_storage_share.sched.name
      quota_gib   = azurerm_storage_share.sched.quota
      mount_fqdn  = "${azurerm_storage_account.files.name}.file.core.windows.net"
      mount_point = "/${azurerm_storage_account.files.name}/${azurerm_storage_share.sched.name}"
    }
    shared = {
      name        = azurerm_storage_share.shared.name
      quota_gib   = azurerm_storage_share.shared.quota
      mount_fqdn  = "${azurerm_storage_account.files.name}.file.core.windows.net"
      mount_point = "/${azurerm_storage_account.files.name}/${azurerm_storage_share.shared.name}"
    }
  }
}
