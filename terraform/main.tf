data "azuread_user" "current_user" {
  object_id = data.azurerm_client_config.current.object_id
}

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

# Live public IP of the machine running Terraform. Merged into
# local.allowed_source_ips so the Key Vault firewall and the server-subnet
# NSG always include the operator's current egress IP -- without this, the
# data-plane Read/Write/Delete calls the azurerm provider makes for
# azurerm_key_vault_secret resources can fail with HTTP 403
# ForbiddenByConnection (notably on `terraform destroy`).
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

# Cross-variable invariants Terraform can't express in a single variable's
# `validation` block.
check "spoke_requires_hub" {
  assert {
    condition     = !local.is_spoke || var.hub != null
    error_message = "deployment_mode = \"spoke\" requires var.hub to be set."
  }
}

check "private_ip_needs_external_connectivity" {
  assert {
    condition     = !local.use_private_ip || local.is_spoke
    error_message = "access_mode = \"private_ip\" is only supported when deployment_mode = \"spoke\" (no bastion / public IP is created, so reachability must come from a peered hub VNet)."
  }
}

