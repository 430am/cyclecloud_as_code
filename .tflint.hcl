plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.28.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# Enforce that every variable and output carries a description -- catches
# undocumented additions in PR review.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Required version is pinned in providers.tf (~> 1.15). Don't re-pin.
rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# Naming convention: snake_case for resources, variables, outputs, locals.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}
