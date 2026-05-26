# All resources in this file are local-monitoring infrastructure. In spoke
# mode (deployment_mode = "spoke") these are skipped: diagnostics are routed
# to var.hub.monitoring.log_analytics_workspace_id instead via
# local.effective_log_analytics_workspace_id.

resource "azurerm_log_analytics_linked_storage_account" "monitoring" {
  count      = local.manage_local_monitoring ? 1 : 0
  depends_on = [azurerm_role_assignment.monitoring, time_sleep.linked_storage_wait]

  data_source_type    = "Ingestion"
  resource_group_name = azurerm_resource_group.testing.name
  storage_account_ids = [azurerm_storage_account.monitoring[0].id]
  workspace_id        = azurerm_log_analytics_workspace.monitoring[0].id
}

resource "azurerm_log_analytics_workspace" "monitoring" {
  count               = local.manage_local_monitoring ? 1 : 0
  location            = var.location
  name                = substr("${local.naming_token}-la", 0, 63)
  resource_group_name = azurerm_resource_group.testing.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_storage_account" "monitoring" {
  count                           = local.manage_local_monitoring ? 1 : 0
  account_replication_type        = "LRS"
  account_tier                    = "Standard"
  location                        = var.location
  name                            = substr("${local.naming_token_compact}stmon", 0, 24)
  resource_group_name             = azurerm_resource_group.testing.name
  tags                            = local.common_tags
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false

  # Access is via the private endpoints in private_endpoints.tf; with public
  # network access disabled, network_rules is ignored, so it's omitted.
}

resource "time_sleep" "linked_storage_wait" {
  count      = local.manage_local_monitoring ? 1 : 0
  depends_on = [azurerm_role_assignment.monitoring]

  create_duration = "60s"
}

# Diagnostic settings route audit / metric data to the Log Analytics workspace
# for traceability. The provider's data-plane fetch for log/metric categories
# requires the target resource to exist, hence the implicit dependency via
# `target_resource_id`.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "${local.naming_token}-diag-kv"
  target_resource_id         = azurerm_key_vault.cyclecloud.id
  log_analytics_workspace_id = local.effective_log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "cyclecloud_vm" {
  name                       = "${local.naming_token}-diag-vm"
  target_resource_id         = azurerm_linux_virtual_machine.cyclecloud.id
  log_analytics_workspace_id = local.effective_log_analytics_workspace_id

  enabled_metric {
    category = "AllMetrics"
  }
}

# The local monitoring SA only exists in standalone mode; diag settings on it
# are gated accordingly. Spoke deployments don't create this SA, so no diag
# settings are emitted for it.
resource "azurerm_monitor_diagnostic_setting" "monitoring_blob" {
  count                      = local.manage_local_monitoring ? 1 : 0
  name                       = "${local.naming_token}-diag-blob"
  target_resource_id         = "${azurerm_storage_account.monitoring[0].id}/blobServices/default"
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

resource "azurerm_monitor_diagnostic_setting" "monitoring_table" {
  count                      = local.manage_local_monitoring ? 1 : 0
  name                       = "${local.naming_token}-diag-table"
  target_resource_id         = "${azurerm_storage_account.monitoring[0].id}/tableServices/default"
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

