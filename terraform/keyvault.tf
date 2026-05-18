resource "azurerm_key_vault" "cyclecloud" {
    location = var.location
    name = substr("kv${random_pet.naming.id}", 0, 24)
    resource_group_name = azurerm_resource_group.testing.name
    sku_name = "standard"
    tenant_id = data.azurerm_client_config.current.tenant_id
    tags = local.common_tags
    soft_delete_retention_days = 7
    rbac_authorization_enabled = true
    
    network_acls {
      default_action = "Deny"
      bypass = "AzureServices"
      ip_rules = [ var.CURRENT_IP_ADDRESS ]
    }
}

resource "azurerm_key_vault_secret" "private_key" {
    key_vault_id = azurerm_key_vault.cyclecloud.id
    name = "cc-${random_pet.naming.id}-private-key"
    value_wo = ephemeral.tls_private_key.cyclecloud_ephemeral.private_key_openssh
    value_wo_version = 1
}

resource "azurerm_key_vault_secret" "public_key" {
    key_vault_id     = azurerm_key_vault.cyclecloud.id
    name             = "cc-${random_pet.naming.id}-public-key"
    value_wo         = ephemeral.tls_public_key.cyclecloud_ephemeral.public_key_openssh
    value_wo_version = 1
}

# Read the public key back from Key Vault so it can be used as a non-ephemeral
# input to the VM's admin_ssh_key block (the secret resource above is
# write-only, so its `value` attribute is null).
data "azurerm_key_vault_secret" "public_key" {
    key_vault_id = azurerm_key_vault.cyclecloud.id
    name         = azurerm_key_vault_secret.public_key.name

    depends_on = [ azurerm_key_vault_secret.public_key ]
}