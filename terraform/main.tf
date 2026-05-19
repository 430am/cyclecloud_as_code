data "azuread_user" "current_user" {
  object_id = data.azurerm_client_config.current.object_id
}

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

# Live public IP of the machine running Terraform. Used (alongside
# var.current_ip_address) to populate the Key Vault firewall allow list,
# so the data-plane Read/Write/Delete calls that the azurerm provider
# makes for azurerm_key_vault_secret resources are never blocked by a
# stale IP entry — in particular, `terraform destroy` would otherwise
# fail with HTTP 403 ForbiddenByConnection.
data "http" "current_ip" {
  url = "https://api.ipify.org"

  retry {
    attempts     = 3
    min_delay_ms = 500
    max_delay_ms = 2000
  }
}

resource "random_pet" "naming" {
  length    = 2
  separator = ""
}

resource "azurerm_resource_group" "testing" {
  name     = "${local.naming_token}-rg"
  location = var.location
}

