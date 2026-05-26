# VNet peering between this spoke and the hub VNet referenced in var.hub.
# Only created when deployment_mode = "spoke".
#
# Forward (spoke -> hub) is always created when peering at all; reverse
# (hub -> spoke) is created via the aliased `azurerm.hub` provider unless
# var.hub.virtual_network.create_reverse_peering = false (e.g. when the hub
# team manages their side out-of-band).
#
# Permissions required on the deploying principal:
#   - Network Contributor on this spoke VNet                (forward side)
#   - Network Contributor on the hub VNet                   (reverse side)
# If create_reverse_peering = false, only the spoke-side permission is needed.

locals {
  hub_vnet_id   = try(var.hub.virtual_network.id, null)
  hub_vnet_name = local.is_spoke ? element(split("/", local.hub_vnet_id), length(split("/", local.hub_vnet_id)) - 1) : null
  hub_vnet_rg   = local.is_spoke ? element(split("/", local.hub_vnet_id), 4) : null

  create_reverse_peering = local.is_spoke && try(var.hub.virtual_network.create_reverse_peering, true)
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  count = local.is_spoke ? 1 : 0

  name                         = "${local.naming_token}-peer-to-hub"
  resource_group_name          = azurerm_resource_group.testing.name
  virtual_network_name         = azurerm_virtual_network.cyclecloud.name
  remote_virtual_network_id    = local.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = try(var.hub.virtual_network.allow_forwarded_traffic, true)
  allow_gateway_transit        = false
  use_remote_gateways          = try(var.hub.virtual_network.use_remote_gateways, false)
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  provider = azurerm.hub
  count    = local.create_reverse_peering ? 1 : 0

  name                         = "peer-from-${local.naming_token}"
  resource_group_name          = local.hub_vnet_rg
  virtual_network_name         = local.hub_vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.cyclecloud.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = try(var.hub.virtual_network.allow_forwarded_traffic, true)
  # Mirror use_remote_gateways: if the spoke wants to use hub gateways,
  # the hub side must allow gateway transit.
  allow_gateway_transit = try(var.hub.virtual_network.use_remote_gateways, false)
  use_remote_gateways   = false
}
