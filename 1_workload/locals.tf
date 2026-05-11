locals {
  configured_current_ip_address = trimspace(var.CURRENT_IP_ADDRESS)

  common_tags = merge(var.tags, {
    deployed_by = data.azuread_user.current_user.display_name
  })
}