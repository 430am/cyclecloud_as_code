resource "azurerm_private_dns_zone" "zones" {
  for_each = toset(local.private_dns_names)

  name                = each.key
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "zones" {
  for_each = toset(local.private_dns_names)

  name                  = "${each.key}-link"
  private_dns_zone_name = each.value
  resource_group_name   = azurerm_resource_group.testing.name
  virtual_network_id    = azurerm_virtual_network.cyclecloud.id

  depends_on = [azurerm_private_dns_zone.zones]
}

resource "azurerm_monitor_private_link_scope" "ampls" {
  name                  = "ampls-${random_pet.naming.id}"
  resource_group_name   = azurerm_resource_group.testing.name
  ingestion_access_mode = "PrivateOnly"
}

resource "azurerm_monitor_private_link_scoped_service" "ampls" {
  linked_resource_id  = azurerm_log_analytics_workspace.monitoring.id
  name                = "ampls-${random_pet.naming.id}-svc"
  resource_group_name = azurerm_resource_group.testing.name
  scope_name          = azurerm_monitor_private_link_scope.ampls.name
}

## Sleep is necessary before creating private endpoints to ensure the scope is fully provisioned
resource "time_sleep" "ampls_wait" {
  create_duration = "60s"

  depends_on = [azurerm_monitor_private_link_scope.ampls]
}

resource "azurerm_private_endpoint" "ampls" {
  location            = var.location
  name                = "pe-${random_pet.naming.id}-ampls"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-${random_pet.naming.id}-ampls"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_monitor_private_link_scope.ampls.id
    subresource_names              = ["azuremonitor"]
  }

  private_dns_zone_group {
    name                 = "pdzg-${random_pet.naming.id}-ampls"
    private_dns_zone_ids = [for zone in local.ampls_private_dns_zones : azurerm_private_dns_zone.zones[zone].id]
  }

  depends_on = [time_sleep.ampls_wait]
}

resource "azurerm_private_endpoint" "key_vault" {
  location            = var.location
  name                = "pe-${random_pet.naming.id}-kv"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    is_manual_connection           = false
    name                           = "psc-${random_pet.naming.id}-kv"
    private_connection_resource_id = azurerm_key_vault.cyclecloud.id
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "pdzg-${random_pet.naming.id}-kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["privatelink.vaultcore.azure.net"].id]
  }
}

resource "azurerm_private_endpoint" "linked_storage_blob" {
  location            = var.location
  name                = "pe-${random_pet.naming.id}-linked-storage-blob"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    is_manual_connection           = false
    name                           = "psc-${random_pet.naming.id}-linked-storage-blob"
    private_connection_resource_id = azurerm_storage_account.monitoring.id
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "pdzg-${random_pet.naming.id}-linked-storage-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["privatelink.blob.core.windows.net"].id]
  }
}

resource "azurerm_private_endpoint" "linked_storage_table" {
  location            = var.location
  name                = "pe-${random_pet.naming.id}-linked-storage-table"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    is_manual_connection           = false
    name                           = "psc-${random_pet.naming.id}-linked-storage-table"
    private_connection_resource_id = azurerm_storage_account.monitoring.id
    subresource_names              = ["table"]
  }

  private_dns_zone_group {
    name                 = "pdzg-${random_pet.naming.id}-linked-storage-table"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["privatelink.table.core.windows.net"].id]
  }
} 