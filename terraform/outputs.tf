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

# Outputs below exist primarily so the locals they expose are assertable
# from `terraform test` (see terraform/tests/). They're cheap to expose
# and equally useful for operator inspection via `terraform output`.

output "subnet_cidrs" {
  description = "Computed CIDR for each subnet keyed by subnet name (AzureBastionSubnet only present when access_mode = \"bastion\")."
  value       = local.subnets
}

output "effective_access_flags" {
  description = "Resolved access-mode booleans derived from var.access_mode."
  value = {
    use_bastion   = local.use_bastion
    use_public_ip = local.use_public_ip
  }
}

output "naming_tokens" {
  description = "Resolved naming tokens (kebab and compact) used as the leading segment of every resource name."
  value = {
    naming_token         = local.naming_token
    naming_token_compact = local.naming_token_compact
  }
}

# ---------------------------------------------------------------------------
# Entra ID outputs. All null when entra_auth_enabled = false. Used by the
# operator to copy values into the CycleCloud UI's Auth Settings (or into
# the follow-up server-side bootstrap automation).
# ---------------------------------------------------------------------------

output "entra_auth_enabled" {
  description = "Whether the Entra ID app registration was created."
  value       = var.entra_auth_enabled
}

output "entra_tenant_id" {
  description = "Tenant ID of the directory hosting the CycleCloud app registration. Null when entra_auth_enabled = false."
  value       = var.entra_auth_enabled ? data.azurerm_client_config.current.tenant_id : null
}

output "entra_client_id" {
  description = "Application (client) ID of the CycleCloud Entra app registration. Null when entra_auth_enabled = false."
  value       = var.entra_auth_enabled ? azuread_application.cyclecloud[0].client_id : null
}

output "entra_application_object_id" {
  description = "Directory object ID of the CycleCloud Entra app registration. Null when entra_auth_enabled = false."
  value       = var.entra_auth_enabled ? azuread_application.cyclecloud[0].object_id : null
}

output "entra_service_principal_object_id" {
  description = "Object ID of the CycleCloud Entra service principal (use this when assigning additional app roles via Graph / az ad). Null when entra_auth_enabled = false."
  value       = var.entra_auth_enabled ? azuread_service_principal.cyclecloud[0].object_id : null
}

output "entra_app_role_ids" {
  description = "Map of app-role value -> role GUID for the CycleCloud Entra app registration. Empty when entra_auth_enabled = false."
  value = var.entra_auth_enabled ? {
    Administrator     = local.entra_role_ids.Administrator
    SuperUser         = local.entra_role_ids.SuperUser
    User              = local.entra_role_ids.User
    Global_Node_User  = local.entra_role_ids.Global_Node_User
    Global_Node_Admin = local.entra_role_ids.Global_Node_Admin
  } : {}
}

output "entra_redirect_uris" {
  description = "Effective redirect URIs configured on the Entra app registration (public client + single-page application)."
  value = var.entra_auth_enabled ? {
    public_client           = ["http://localhost", "https://localhost"]
    single_page_application = local.entra_spa_redirect_uris
  } : null
}

# Convenience: operator-facing next-steps after a successful apply with
# entra_auth_enabled = true. Renders nothing when disabled.
output "entra_next_steps" {
  description = "Manual server-side configuration steps to wire CycleCloud to the new app registration. See docs/entra-auth.md."
  value = var.entra_auth_enabled ? join("\n", [
    "1. SSH (or `az vm run-command invoke`) to the CycleCloud VM.",
    "2. Edit /opt/cycle_server/config/cycle_server.properties and set:",
    "     webServerEnableTenancy=true",
    "     webServerEnableAzureAuth=true",
    "     webServerAzureAuthTenantId=${data.azurerm_client_config.current.tenant_id}",
    "     webServerAzureAuthClientId=${azuread_application.cyclecloud[0].client_id}",
    "3. Restart cycle_server:  sudo systemctl restart cycle_server",
    "4. (Optional) Assign additional Entra users/groups to the desired app role:",
    "     az ad app-role assignment create --app-role-id <role_id> \\",
    "       --principal-id <user_or_group_object_id> \\",
    "       --resource-id ${azuread_service_principal.cyclecloud[0].object_id}",
  ]) : null
}
