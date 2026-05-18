resource "azurerm_virtual_network" "cyclecloud" {
  address_space       = var.vnet_address_space
  location            = var.location
  name                = "vnet-${random_pet.naming.id}"
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "cyclecloud" {
  for_each = local.subnets

  name                 = each.key
  resource_group_name  = azurerm_resource_group.testing.name
  virtual_network_name = azurerm_virtual_network.cyclecloud.name
  address_prefixes     = [each.value]
}