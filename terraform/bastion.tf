resource "azurerm_public_ip" "bastion" {
  count               = local.use_bastion ? 1 : 0
  allocation_method   = "Static"
  location            = var.location
  name                = "pip-${random_pet.naming.id}-bas"
  resource_group_name = azurerm_resource_group.testing.name
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_bastion_host" "bastion" {
  count               = local.use_bastion ? 1 : 0
  location            = var.location
  name                = "bas-${random_pet.naming.id}"
  resource_group_name = azurerm_resource_group.testing.name
  sku                 = "Standard"
  tunneling_enabled   = true
  ip_configuration {
    name                 = "bastion-ip-config"
    subnet_id            = azurerm_subnet.cyclecloud["AzureBastionSubnet"].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
  tags = local.common_tags
}