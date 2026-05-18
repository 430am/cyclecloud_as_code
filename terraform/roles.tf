resource "azurerm_role_definition" "cyclecloud" {
  name        = "CycleCloud Orchestrator Role"
  scope       = data.azurerm_subscription.current.id
  description = "Role for managing CycleCloud orchestrator resources."

  assignable_scopes = [data.azurerm_subscription.current.id]

  permissions {
    actions = [
      "Microsoft.Authorization/*/read",
      "Microsoft.Authorization/roleAssignments/*",
      "Microsoft.Authorization/roleDefinitions/*",
      "Microsoft.Commerce/RateCard/read",
      "Microsoft.Compute/*/read",
      "Microsoft.Compute/availabilitySets/*",
      "Microsoft.Compute/disks/*",
      "Microsoft.Compute/images/read",
      "Microsoft.Compute/locations/usages/read",
      "Microsoft.Compute/register/action",
      "Microsoft.Compute/skus/read",
      "Microsoft.Compute/virtualMachines/*",
      "Microsoft.Compute/virtualMachineScaleSets/*",
      "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/*",
      "Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action",
      "Microsoft.ManagedIdentity/userAssignedIdentities/*/read",
      "Microsoft.MarketplaceOrdering/offertypes/publishers/offers/plans/agreements/read",
      "Microsoft.MarketplaceOrdering/offertypes/publishers/offers/plans/agreements/write",
      "Microsoft.Network/*/read",
      "Microsoft.Network/locations/*/read",
      "Microsoft.Network/networkInterfaces/delete",
      "Microsoft.Network/networkInterfaces/join/action",
      "Microsoft.Network/networkInterfaces/read",
      "Microsoft.Network/networkInterfaces/write",
      "Microsoft.Network/networkSecurityGroups/delete",
      "Microsoft.Network/networkSecurityGroups/join/action",
      "Microsoft.Network/networkSecurityGroups/read",
      "Microsoft.Network/networkSecurityGroups/write",
      "Microsoft.Network/publicIPAddresses/delete",
      "Microsoft.Network/publicIPAddresses/join/action",
      "Microsoft.Network/publicIPAddresses/read",
      "Microsoft.Network/publicIPAddresses/write",
      "Microsoft.Network/register/action",
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/subnets/join/action",
      "Microsoft.Network/virtualNetworks/subnets/read",
      "Microsoft.Resources/deployments/read",
      "Microsoft.Resources/subscriptions/operationresults/read",
      "Microsoft.Resources/subscriptions/resourceGroups/delete",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      "Microsoft.Resources/subscriptions/resourceGroups/resources/read",
      "Microsoft.Resources/subscriptions/resourceGroups/write",
      "Microsoft.Storage/*/read",
      "Microsoft.Storage/checknameavailability/read",
      "Microsoft.Storage/register/action",
      "Microsoft.Storage/storageAccounts/blobServices/containers/delete",
      "Microsoft.Storage/storageAccounts/blobServices/containers/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/write",
      "Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action",
      "Microsoft.Storage/storageAccounts/listKeys/action",
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/write",
    ]
    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/move/action",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
    ]
    not_actions      = []
    not_data_actions = []
  }
}

resource "azurerm_user_assigned_identity" "cyclecloud" {
  location            = var.location
  name                = "uaid-${random_pet.naming.id}"
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "cyclecloud" {
  principal_id         = azurerm_linux_virtual_machine.cyclecloud.identity[0].principal_id
  scope                = data.azurerm_subscription.current.id
  role_definition_name = azurerm_role_definition.cyclecloud.name
  depends_on           = [azurerm_role_definition.cyclecloud]
}

resource "azurerm_role_assignment" "key_vault" {
  depends_on = [azurerm_key_vault.cyclecloud]

  principal_id         = data.azurerm_client_config.current.object_id
  scope                = azurerm_key_vault.cyclecloud.id
  role_definition_name = "Key Vault Administrator"
}

resource "azurerm_role_assignment" "monitoring" {
  for_each = toset(["Storage Blob Data Contributor", "Storage Table Data Contributor"])

  principal_id         = azurerm_log_analytics_workspace.monitoring.identity[0].principal_id
  role_definition_name = each.key
  scope                = azurerm_storage_account.monitoring.id

  depends_on = [azurerm_log_analytics_workspace.monitoring, azurerm_storage_account.monitoring]
}