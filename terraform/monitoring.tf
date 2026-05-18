resource "azurerm_log_analytics_workspace" "monitoring" {
  location            = var.location
  name                = substr("logs${random_pet.naming.id}", 0, 24)
  resource_group_name = azurerm_resource_group.testing.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_storage_account" "monitoring" {
  account_replication_type        = "LRS"
  account_tier                    = "Standard"
  location                        = var.location
  name                            = substr("st${random_pet.naming.id}", 0, 24)
  resource_group_name             = azurerm_resource_group.testing.name
  tags                            = local.common_tags
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false

  # Access is via the private endpoints in private_endpoints.tf; with public
  # network access disabled, network_rules is ignored, so it's omitted.
}

resource "azurerm_log_analytics_linked_storage_account" "monitoring" {
  data_source_type    = "Ingestion"
  resource_group_name = azurerm_resource_group.testing.name
  storage_account_ids = [azurerm_storage_account.monitoring.id]
  workspace_id        = azurerm_log_analytics_workspace.monitoring.id

  depends_on = [azurerm_role_assignment.monitoring, time_sleep.linked_storage_wait]
}

resource "time_sleep" "linked_storage_wait" {
  create_duration = "60s"

  depends_on = [azurerm_role_assignment.monitoring]
}