# Dedicated storage account used exclusively as the CycleCloud "locker" - it
# holds cluster templates and CycleCloud Projects that the orchestrator
# uploads and that cluster nodes pull back via managed-identity auth.
#
# Kept separate from the monitoring storage account so that:
#   - locker churn (frequent template uploads, project syncs) doesn't pollute
#     monitoring diagnostic logs,
#   - the monitoring SA's lifecycle / retention can differ from the locker's,
#   - RBAC blast radius is scoped: the CycleCloud VM identity only needs blob
#     access to this SA, not to the workspace's linked storage,
#   - the locker reaches the VM via its own private endpoint in the
#     `private_endpoint` subnet (see private_endpoints.tf).
resource "azurerm_storage_account" "locker" {
  account_replication_type        = "LRS"
  account_tier                    = "Standard"
  location                        = var.location
  name                            = substr("${local.naming_token_compact}stcc", 0, 24)
  resource_group_name             = azurerm_resource_group.testing.name
  tags                            = local.common_tags
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false

  # Access is exclusively via the private endpoint in private_endpoints.tf;
  # with public network access disabled, network_rules is ignored.
}

resource "azurerm_storage_container" "cyclecloud_locker" {
  name                  = "cyclecloud"
  storage_account_id    = azurerm_storage_account.locker.id
  container_access_type = "private"
}

# Diagnostic logs for the locker SA still flow into the shared workspace so
# template upload / pull activity is observable alongside other audit data.
resource "azurerm_monitor_diagnostic_setting" "locker_blob" {
  name                       = "${local.naming_token}-diag-locker-blob"
  target_resource_id         = "${azurerm_storage_account.locker.id}/blobServices/default"
  log_analytics_workspace_id = local.effective_log_analytics_workspace_id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  enabled_metric {
    category = "Transaction"
  }
}
