resource "azurerm_private_dns_zone" "zones" {
  for_each = toset(local.private_dns_names)

  name                = each.key
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "zones" {
  depends_on = [azurerm_private_dns_zone.zones]

  for_each = toset(local.private_dns_names)

  name                  = "${each.key}-link"
  private_dns_zone_name = each.value
  resource_group_name   = azurerm_resource_group.testing.name
  virtual_network_id    = azurerm_virtual_network.cyclecloud.id
}

resource "azurerm_monitor_private_link_scope" "ampls" {
  name                  = "${local.naming_token}-ampls"
  resource_group_name   = azurerm_resource_group.testing.name
  ingestion_access_mode = "PrivateOnly"
}

resource "azurerm_monitor_private_link_scoped_service" "ampls" {
  # Both this resource and azurerm_log_analytics_linked_storage_account.monitoring
  # mutate the same Log Analytics workspace. Running them in parallel produces
  # `ConflictingConcurrentWriteNotAllowed` (409) from the LA control plane, so
  # serialize by waiting for the linked storage account to finish first.
  depends_on = [azurerm_log_analytics_linked_storage_account.monitoring]

  linked_resource_id  = azurerm_log_analytics_workspace.monitoring.id
  name                = "${local.naming_token}-ampls-svc"
  resource_group_name = azurerm_resource_group.testing.name
  scope_name          = azurerm_monitor_private_link_scope.ampls.name
}

## Sleep is necessary before creating private endpoints to ensure the scope is fully provisioned
resource "time_sleep" "ampls_wait" {
  depends_on = [azurerm_monitor_private_link_scope.ampls]

  create_duration = "60s"
}

resource "azurerm_private_endpoint" "ampls" {
  depends_on = [time_sleep.ampls_wait]

  location            = var.location
  name                = "${local.naming_token}-pe-ampls"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    name                           = "${local.naming_token}-psc-ampls"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_monitor_private_link_scope.ampls.id
    subresource_names              = ["azuremonitor"]
  }

  private_dns_zone_group {
    name                 = "${local.naming_token}-pdzg-ampls"
    private_dns_zone_ids = [for zone in local.ampls_private_dns_zones : azurerm_private_dns_zone.zones[zone].id]
  }
}

resource "azurerm_private_endpoint" "key_vault" {
  location            = var.location
  name                = "${local.naming_token}-pe-kv"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    is_manual_connection           = false
    name                           = "${local.naming_token}-psc-kv"
    private_connection_resource_id = azurerm_key_vault.cyclecloud.id
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "${local.naming_token}-pdzg-kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["privatelink.vaultcore.azure.net"].id]
  }
}

resource "azurerm_private_endpoint" "linked_storage_blob" {
  location            = var.location
  name                = "${local.naming_token}-pe-linked-storage-blob"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    is_manual_connection           = false
    name                           = "${local.naming_token}-psc-linked-storage-blob"
    private_connection_resource_id = azurerm_storage_account.monitoring.id
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "${local.naming_token}-pdzg-linked-storage-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["privatelink.blob.core.windows.net"].id]
  }
}

resource "azurerm_private_endpoint" "linked_storage_table" {
  location            = var.location
  name                = "${local.naming_token}-pe-linked-storage-table"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    is_manual_connection           = false
    name                           = "${local.naming_token}-psc-linked-storage-table"
    private_connection_resource_id = azurerm_storage_account.monitoring.id
    subresource_names              = ["table"]
  }

  private_dns_zone_group {
    name                 = "${local.naming_token}-pdzg-linked-storage-table"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["privatelink.table.core.windows.net"].id]
  }
}

# Dedicated blob private endpoint for the CycleCloud locker storage account.
# Keeps locker traffic on its own NIC / DNS entry rather than sharing the
# monitoring SA's PE.
resource "azurerm_private_endpoint" "locker_blob" {
  location            = var.location
  name                = "${local.naming_token}-pe-locker-blob"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    is_manual_connection           = false
    name                           = "${local.naming_token}-psc-locker-blob"
    private_connection_resource_id = azurerm_storage_account.locker.id
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "${local.naming_token}-pdzg-locker-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["privatelink.blob.core.windows.net"].id]
  }
}

# Private endpoint for the Premium FileStorage account hosting the NFSv4.1
# shares (see files.tf). A single PE on the `file` subresource serves every
# share on the storage account, so this one endpoint covers both `sched`
# and `shared`. Reachability:
#   - server subnet: server-NSG inbound rules don't affect outbound; default
#     allow-VNet-outbound lets the CycleCloud VM reach the PE NIC on 2049.
#   - cluster subnet: no NSG attached, default allow.
#   - private_endpoint subnet: no NSG attached.
# So no NSG changes are required for the shares to be mountable from the
# server or cluster subnets.
resource "azurerm_private_endpoint" "files" {
  location            = var.location
  name                = "${local.naming_token}-pe-files"
  resource_group_name = azurerm_resource_group.testing.name
  subnet_id           = azurerm_subnet.cyclecloud["private_endpoint"].id
  tags                = local.common_tags

  private_service_connection {
    is_manual_connection           = false
    name                           = "${local.naming_token}-psc-files"
    private_connection_resource_id = azurerm_storage_account.files.id
    subresource_names              = ["file"]
  }

  private_dns_zone_group {
    name                 = "${local.naming_token}-pdzg-files"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["privatelink.file.core.windows.net"].id]
  }
}
