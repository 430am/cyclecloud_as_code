resource "azurerm_virtual_network" "cyclecloud" {
  address_space       = var.vnet_address_space
  location            = var.location
  name                = "${local.naming_token}-vnet"
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

# Server-subnet NSG. Default deny-all-inbound from Internet (implicit). Allows
# CycleCloud server reachability from inside the VNet (covers Bastion in
# `bastion` mode), and -- in `public_ip` mode -- adds matching caller-IP
# allow rules so the NIC NSG's Internet-facing rules aren't blackholed at
# the subnet level (both NSGs are evaluated; either deny wins).
#
# All rules are declared via a single `dynamic "security_rule"` block.
# Mixing inline `security_rule` blocks with standalone
# `azurerm_network_security_rule` resources targeting the same NSG is
# unsupported by the azurerm provider: the inline set acts as the source of
# truth and silently deletes any standalone rules on every reconciliation
# (see https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_rule).
resource "azurerm_network_security_group" "server" {
  location            = var.location
  name                = "${local.naming_token}-nsg-server"
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags

  dynamic "security_rule" {
    for_each = local.server_nsg_rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = security_rule.value.port
      source_address_prefix      = security_rule.value.source
      destination_address_prefix = security_rule.value.destination
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "server" {
  network_security_group_id = azurerm_network_security_group.server.id
  subnet_id                 = azurerm_subnet.cyclecloud["server"].id
}

# Azure Bastion service requires a specific NSG ruleset on AzureBastionSubnet.
# See: https://learn.microsoft.com/azure/bastion/bastion-nsg
resource "azurerm_network_security_group" "bastion" {
  count               = local.use_bastion ? 1 : 0
  location            = var.location
  name                = "${local.naming_token}-nsg-bastion"
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags

  security_rule {
    name                       = "AllowHttpsInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowGatewayManagerInbound"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 140
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowBastionHostCommunicationInbound"
    priority                   = 150
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowSshRdpOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureCloudOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureCloud"
  }

  security_rule {
    name                       = "AllowBastionHostCommunicationOutbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowGetSessionInformationOutbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "bastion" {
  count                     = local.use_bastion ? 1 : 0
  network_security_group_id = azurerm_network_security_group.bastion[0].id
  subnet_id                 = azurerm_subnet.cyclecloud["AzureBastionSubnet"].id
}