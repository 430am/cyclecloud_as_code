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

# Server-subnet NSG. Default deny-all-inbound from Internet (implicit). Two
# allow rules cover every scenario:
#   1. VirtualNetwork -> VirtualNetwork on local.server_inbound_ports. Covers
#      Bastion (bastion mode), future Slurm scheduler / cluster nodes, and
#      private endpoints reaching back to the server.
#   2. local.allowed_source_ips -> * on the same port set. Only meaningful in
#      public_ip mode (the VM has no public IP otherwise), and only created
#      when the list is non-empty.
#
# The NIC-level NSG that used to live in cyclecloud.tf is gone -- the subnet
# NSG enforces the same traffic for every NIC placed on the subnet (today the
# CycleCloud server, tomorrow the Slurm scheduler / login nodes).
resource "azurerm_network_security_group" "server" {
  location            = var.location
  name                = "${local.naming_token}-nsg-server"
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags

  security_rule {
    name                       = "allow-server-ports-from-vnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = local.server_inbound_ports
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  dynamic "security_rule" {
    # Only meaningful in public_ip mode -- the VM has no public IP otherwise.
    # In bastion / private_ip mode the VirtualNetwork->VirtualNetwork rule
    # above covers all legitimate sources.
    for_each = local.use_public_ip && length(local.allowed_source_ips) > 0 ? [1] : []
    content {
      name                       = "allow-server-ports-from-allowed-ips"
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_ranges    = local.server_inbound_ports
      source_address_prefixes    = local.allowed_source_ips
      destination_address_prefix = "*"
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