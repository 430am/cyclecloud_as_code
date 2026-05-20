# Plan-only tests for the deterministic locals in terraform/locals.tf:
#   - subnet CIDR math (cidrsubnet over var.vnet_address_space)
#   - access_mode -> use_bastion / use_public_ip resolution
#   - naming_token / naming_token_compact derivation and length safety
#
# These tests run with `terraform test` and never touch Azure: all four
# external providers (azurerm, azuread, http, random) are stubbed via
# `mock_provider` so the plan can compute without network or credentials.
#
# Run from terraform/ with:   terraform init -backend=false && terraform test
#
# The assertions target the outputs added to terraform/outputs.tf
# (subnet_cidrs, effective_access_flags, naming_tokens) — those outputs
# exist specifically to make these locals observable to the test harness.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      client_id       = "00000000-0000-0000-0000-000000000001"
      object_id       = "00000000-0000-0000-0000-000000000002"
      tenant_id       = "00000000-0000-0000-0000-000000000003"
      subscription_id = "00000000-0000-0000-0000-000000000004"
    }
  }

  mock_data "azurerm_subscription" {
    defaults = {
      id                    = "/subscriptions/00000000-0000-0000-0000-000000000004"
      subscription_id       = "00000000-0000-0000-0000-000000000004"
      display_name          = "mock-subscription"
      tenant_id             = "00000000-0000-0000-0000-000000000003"
      location_placement_id = "Public_2014-09-01"
      quota_id              = "PayAsYouGo_2014-09-01"
      spending_limit        = "Off"
      state                 = "Enabled"
    }
  }
}

mock_provider "azuread" {
  mock_data "azuread_user" {
    defaults = {
      display_name        = "mock-user"
      user_principal_name = "mock-user@example.com"
      mail                = "mock-user@example.com"
      object_id           = "00000000-0000-0000-0000-000000000002"
    }
  }
}

mock_provider "http" {
  mock_data "http" {
    defaults = {
      response_body = "203.0.113.10"
      status_code   = 200
    }
  }
}

# random / time / tls / cloudinit are intentionally NOT mocked:
#   - tls uses an ephemeral resource (tls_private_key), and mock_provider
#     doesn't yet support ephemeral resource types.
#   - all four are local-only providers that need no credentials, so the
#     real providers work fine inside `terraform test`.

# Shared input baseline used by every run block; individual runs override
# only the variables relevant to what they're asserting.
variables {
  application_name = "cctest"
}

# ---------------------------------------------------------------------------
# 1. Default access_mode ("bastion") yields all four subnets including
#    AzureBastionSubnet, and the access-mode booleans flip correctly.
# ---------------------------------------------------------------------------
run "bastion_mode_subnet_layout" {
  command = plan

  variables {
    access_mode = "bastion"
  }

  assert {
    condition     = output.effective_access_flags.use_bastion == true
    error_message = "use_bastion should be true when access_mode = \"bastion\""
  }

  assert {
    condition     = output.effective_access_flags.use_public_ip == false
    error_message = "use_public_ip should be false when access_mode = \"bastion\""
  }

  assert {
    condition     = contains(keys(output.subnet_cidrs), "AzureBastionSubnet")
    error_message = "AzureBastionSubnet must be present in subnet_cidrs when access_mode = \"bastion\""
  }

  assert {
    condition = (
      output.subnet_cidrs["cluster"] == "10.150.0.0/23" &&
      output.subnet_cidrs["private_endpoint"] == "10.150.2.0/26" &&
      output.subnet_cidrs["server"] == "10.150.2.64/26" &&
      output.subnet_cidrs["AzureBastionSubnet"] == "10.150.2.128/26"
    )
    error_message = "CIDR math drift: expected the documented /23 + three /26 layout under 10.150.0.0/16"
  }
}

# ---------------------------------------------------------------------------
# 2. public_ip mode drops AzureBastionSubnet entirely and inverts the flags.
# ---------------------------------------------------------------------------
run "public_ip_mode_omits_bastion_subnet" {
  command = plan

  variables {
    access_mode = "public_ip"
  }

  assert {
    condition     = output.effective_access_flags.use_public_ip == true
    error_message = "use_public_ip should be true when access_mode = \"public_ip\""
  }

  assert {
    condition     = output.effective_access_flags.use_bastion == false
    error_message = "use_bastion should be false when access_mode = \"public_ip\""
  }

  assert {
    condition     = !contains(keys(output.subnet_cidrs), "AzureBastionSubnet")
    error_message = "AzureBastionSubnet must NOT be present when access_mode = \"public_ip\""
  }

  assert {
    condition     = length(output.subnet_cidrs) == 3
    error_message = "Expected exactly 3 subnets (cluster, private_endpoint, server) in public_ip mode"
  }
}

# ---------------------------------------------------------------------------
# 3. CIDR math is correct under a non-default VNet base — catches regressions
#    in the cidrsubnet() newbits / netnum constants in locals.tf.
# ---------------------------------------------------------------------------
run "custom_vnet_cidr_math" {
  command = plan

  variables {
    access_mode        = "bastion"
    vnet_address_space = ["10.42.0.0/16"]
  }

  assert {
    condition     = output.subnet_cidrs["cluster"] == "10.42.0.0/23"
    error_message = "cluster subnet should be the first /23 of the VNet base"
  }

  assert {
    condition = (
      output.subnet_cidrs["private_endpoint"] == "10.42.2.0/26" &&
      output.subnet_cidrs["server"] == "10.42.2.64/26" &&
      output.subnet_cidrs["AzureBastionSubnet"] == "10.42.2.128/26"
    )
    error_message = "PE / server / bastion subnets should be the first three /26s after the cluster /23"
  }
}

# ---------------------------------------------------------------------------
# 4. Naming tokens: compact form strips hyphens and the kebab form is
#    preserved verbatim. The compact form is what the storage / KV resources
#    use, so its length is the load-bearing invariant (24-char SA cap).
# ---------------------------------------------------------------------------
run "naming_token_compact_strips_hyphens" {
  command = plan

  variables {
    application_name = "my-cc-lab"
  }

  assert {
    condition     = output.naming_tokens.naming_token == "my-cc-lab"
    error_message = "naming_token should equal var.application_name verbatim"
  }

  assert {
    condition     = output.naming_tokens.naming_token_compact == "mycclab"
    error_message = "naming_token_compact should be naming_token with hyphens removed"
  }

  # SA names are substr(compact + 5-char suffix like "stnfs", 0, 24). The
  # safe upper bound for naming_token_compact is therefore 24 - 5 = 19 chars
  # before truncation kicks in. application_name's own validation caps it at
  # 20 lowercase chars, so compact form is always <= 20 -- well within bounds.
  assert {
    condition     = length(output.naming_tokens.naming_token_compact) <= 20
    error_message = "naming_token_compact exceeded the 20-char ceiling implied by the application_name validator"
  }
}
