data "azuread_user" "current_user" {
  object_id = data.azurerm_client_config.current.objectid
}

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "workload" {
    provider = azurerm.workload_subscription
}

data "azurerm_subscription" "hub" {
    provider = azurerm.hub_subscription
}

resource "random_pet" "naming" {
    length = 2
    separator = ""
}

resource "azurerm_resource_group" "testing" {
    provider = azurerm.workload_subscription
    name     = "rg-${random_pet.naming.id}"
    location = var.location
}