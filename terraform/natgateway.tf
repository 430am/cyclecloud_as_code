resource "azurerm_public_ip" "nat_gateway" {
    allocation_method = "Static"
    location = var.location
    name = "pip-${random_pet.naming.id}-nat"
    resource_group_name = azurerm_resource_group.testing.name
    sku = "Standard"
    tags = local.common_tags
}

resource "azurerm_nat_gateway" "nat_gateway" {
    location = var.location
    name = "nat-${random_pet.naming.id}"
    resource_group_name = azurerm_resource_group.testing.name
    sku_name = "Standard"
    tags = local.common_tags
}

resource "azurerm_nat_gateway_public_ip_association" "nat_gateway" {
    nat_gateway_id = azurerm_nat_gateway.nat_gateway.id
    public_ip_address_id = azurerm_public_ip.nat_gateway.id    
}

resource "azurerm_subnet_nat_gateway_association" "cluster" {
    nat_gateway_id = azurerm_nat_gateway.nat_gateway.id
    subnet_id = azurerm_subnet.cyclecloud["cluster"].id    
}

resource "azurerm_subnet_nat_gateway_association" "server" {
    nat_gateway_id = azurerm_nat_gateway.nat_gateway.id
    subnet_id = azurerm_subnet.cyclecloud["server"].id    
}