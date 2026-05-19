locals {
  configured_current_ip_address = trimspace(var.current_ip_address)

  use_bastion   = var.access_mode == "bastion"
  use_public_ip = var.access_mode == "public_ip"

  # Naming token used as the leading `<product>` segment in every resource
  # name. Falls back to `random_pet.naming.id` when `var.application_name` is
  # left empty (default).
  naming_token         = coalesce(var.application_name, random_pet.naming.id)
  naming_token_compact = replace(local.naming_token, "-", "")

  common_tags = merge(var.tags, {
    deployed_by = data.azuread_user.current_user.display_name
  })

  private_dns_names = [
    "privatelink.blob.core.windows.net",
    "privatelink.file.core.windows.net",
    "privatelink.table.core.windows.net",
    "privatelink.vaultcore.azure.net",
    "privatelink.dfs.core.windows.net",
    "privatelink.monitor.azure.com",
    "privatelink.ods.opinsights.azure.com",
    "privatelink.oms.opinsights.azure.com",
    "privatelink.agentsvc.azure-automation.net"
  ]
  ampls_private_dns_zones = [
    "privatelink.monitor.azure.com",
    "privatelink.ods.opinsights.azure.com",
    "privatelink.oms.opinsights.azure.com",
    "privatelink.agentsvc.azure-automation.net",
    "privatelink.blob.core.windows.net",
    "privatelink.table.core.windows.net"
  ]

  base_cidr               = var.vnet_address_space[0]
  cluster_subnet          = cidrsubnet(local.base_cidr, 7, 0)   # /23 - 10.150.0.0/23
  private_endpoint_subnet = cidrsubnet(local.base_cidr, 10, 8)  # /26 - 10.150.2.0/26
  server_subnet           = cidrsubnet(local.base_cidr, 10, 9)  # /26 - 10.150.2.64/26
  bastion_subnet          = cidrsubnet(local.base_cidr, 10, 10) # /26 - 10.150.2.128/26

  subnets = merge(
    {
      cluster          = local.cluster_subnet
      private_endpoint = local.private_endpoint_subnet
      server           = local.server_subnet
    },
    local.use_bastion ? { AzureBastionSubnet = local.bastion_subnet } : {}
  )
}