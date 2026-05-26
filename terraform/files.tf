# Azure Files Premium NFS shares for downstream Slurm scheduler state and
# cluster-wide shared data. Mounted by the CycleCloud server VM and (later)
# by cluster compute nodes via NFSv4.1 on port 2049.
#
# Why Premium FileStorage:
#   - NFS on Azure Files is only available on the Premium tier
#     (account_kind = "FileStorage", account_tier = "Premium"); Standard
#     accounts do not expose the NFS protocol at all.
#
# Why 100 GiB shares:
#   - Premium file shares have a hard minimum quota of 100 GiB; the
#     control plane rejects anything smaller with InvalidShareQuota.
#     The dev-environment intent is ~10 GiB each but we provision the
#     floor here so terraform apply succeeds.
#
# Access model:
#   - public_network_access_enabled = false closes the storage account to
#     the Internet; both shares are reached exclusively via the file
#     private endpoint defined in private_endpoints.tf (one PE per SA
#     covers all shares on it).
#   - shared_access_key_enabled = false because NFSv4.1 on Azure Files
#     does not use SAS / account keys for auth -- access is gated by
#     network reachability (PE + VNet) and the share's POSIX permissions
#     once mounted. Disabling keys removes an unused credential surface.
#   - https_traffic_only_enabled = false: NFS is not HTTPS; with this
#     flag on, the file service refuses mount attempts. SMB / REST are
#     unaffected on this account (we aren't using them).
resource "azurerm_storage_account" "files" {
  account_kind                    = "FileStorage"
  account_replication_type        = "LRS"
  account_tier                    = "Premium"
  location                        = var.location
  name                            = substr("${local.naming_token_compact}stnfs", 0, 24)
  resource_group_name             = azurerm_resource_group.testing.name
  tags                            = local.common_tags
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false
  https_traffic_only_enabled      = false
}

# Two shares: scheduler state and cluster-wide shared data. Both NFSv4.1.
# The 100 GiB quota is the Premium minimum (see header comment).
resource "azurerm_storage_share" "sched" {
  name               = "sched"
  storage_account_id = azurerm_storage_account.files.id
  quota              = 100
  enabled_protocol   = "NFS"
}

resource "azurerm_storage_share" "shared" {
  name               = "shared"
  storage_account_id = azurerm_storage_account.files.id
  quota              = 100
  enabled_protocol   = "NFS"
}

# Diagnostic logs for the file service flow into the shared workspace,
# mirroring the locker SA pattern so mount / IO activity is observable
# alongside other audit data.
resource "azurerm_monitor_diagnostic_setting" "files" {
  name                       = "${local.naming_token}-diag-files"
  target_resource_id         = "${azurerm_storage_account.files.id}/fileServices/default"
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
