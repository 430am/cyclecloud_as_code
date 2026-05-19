data "azuread_user" "current_user" {
  object_id = data.azurerm_client_config.current.object_id
}

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

resource "random_pet" "naming" {
  length    = 2
  separator = ""
}

resource "azurerm_resource_group" "testing" {
  name     = "${local.naming_token}-rg"
  location = var.location
}

