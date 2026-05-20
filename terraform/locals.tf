locals {
  # Live public IP of the machine running Terraform (via ipify, see main.tf).
  # Merged into var.allowed_ip_addresses so the Key Vault firewall and the
  # server-subnet NSG always include the operator's current egress IP --
  # without this, `terraform destroy` fails with 403 ForbiddenByConnection
  # when the data-plane refresh of azurerm_key_vault_secret runs from an
  # IP that no longer matches a stale tfvars entry.
  detected_ip = trimspace(data.http.current_ip.response_body)

  # Canonical caller allow-list used by both the KV firewall and the
  # server-subnet NSG. Bare IPs are normalized to /32 so the same list is
  # valid in NSG rules (which require CIDR notation in source_address_prefixes)
  # and in network_acls.ip_rules.
  allowed_source_ips = distinct([
    for ip in concat(var.allowed_ip_addresses, [local.detected_ip]) :
    strcontains(ip, "/") ? ip : "${ip}/32"
    if length(trimspace(ip)) > 0
  ])

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

  # Inbound TCP ports the server-subnet NSG must accept. Add Slurm
  # scheduler ports (e.g. "6817", "6818") here in the future and both NSG
  # rules in network.tf pick them up automatically.
  server_inbound_ports = ["22", "8080", "8443"]
}