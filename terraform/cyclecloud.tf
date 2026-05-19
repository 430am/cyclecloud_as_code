data "cloudinit_config" "cyclecloud" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    filename     = "cloud-config.yaml"
    content = templatefile("${path.module}/../scripts/cloud-config.yaml.tftpl", {
      admin_user             = var.vm_admin_username
      key_vault_name         = azurerm_key_vault.cyclecloud.name
      pwd_secret_name        = azurerm_key_vault_secret.cyclecloud_admin_password.name
      pubkey_secret_name     = azurerm_key_vault_secret.public_key.name
      resource_group_name    = azurerm_resource_group.testing.name
      subscription_id        = data.azurerm_subscription.current.subscription_id
      tenant_id              = data.azurerm_client_config.current.tenant_id
      location               = var.location
      storage_account_name   = azurerm_storage_account.locker.name
      storage_container_name = azurerm_storage_container.cyclecloud_locker.name
    })
  }
}

resource "azurerm_public_ip" "cyclecloud" {
  count               = local.use_public_ip ? 1 : 0
  allocation_method   = "Static"
  location            = var.location
  name                = "${local.naming_token}-pip-cc"
  resource_group_name = azurerm_resource_group.testing.name
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_network_security_group" "cyclecloud" {
  count               = local.use_public_ip ? 1 : 0
  location            = var.location
  name                = "${local.naming_token}-nsg-cc"
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags

  security_rule {
    name                       = "allow-ssh-from-caller"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.configured_current_ip_address
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https-from-caller"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = local.configured_current_ip_address
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-8080-from-caller"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = local.configured_current_ip_address
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "cyclecloud" {
  count                     = local.use_public_ip ? 1 : 0
  network_interface_id      = azurerm_network_interface.cyclecloud.id
  network_security_group_id = azurerm_network_security_group.cyclecloud[0].id
}

# In public_ip mode the VM is reached over the Internet, but the `server`
# subnet NSG (network.tf) only allows 22/443/8080 from `VirtualNetwork`.
# Both the subnet NSG and the NIC NSG must Allow the flow — either deny wins
# — so without these rules the NIC NSG's caller-IP rules are effectively
# blackholed by the subnet NSG. Add matching subnet-level Allow rules so the
# NIC NSG actually takes effect.
resource "azurerm_network_security_rule" "server_allow_caller_ssh" {
  count                       = local.use_public_ip ? 1 : 0
  name                        = "allow-ssh-from-caller"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = local.configured_current_ip_address
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.testing.name
  network_security_group_name = azurerm_network_security_group.server.name
}

resource "azurerm_network_security_rule" "server_allow_caller_https" {
  count                       = local.use_public_ip ? 1 : 0
  name                        = "allow-https-from-caller"
  priority                    = 210
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.configured_current_ip_address
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.testing.name
  network_security_group_name = azurerm_network_security_group.server.name
}

resource "azurerm_network_security_rule" "server_allow_caller_8080" {
  count                       = local.use_public_ip ? 1 : 0
  name                        = "allow-8080-from-caller"
  priority                    = 220
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = local.configured_current_ip_address
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.testing.name
  network_security_group_name = azurerm_network_security_group.server.name
}

resource "azurerm_network_interface" "cyclecloud" {
  location            = var.location
  name                = "${local.naming_token}-nic-cc"
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "${local.naming_token}-ipconfig-cc"
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.cyclecloud["server"].id
    public_ip_address_id          = local.use_public_ip ? azurerm_public_ip.cyclecloud[0].id : null
  }
}

resource "azurerm_linux_virtual_machine" "cyclecloud" {
  location              = var.location
  name                  = "${local.naming_token}-vm-cyclecloud"
  network_interface_ids = [azurerm_network_interface.cyclecloud.id]
  resource_group_name   = azurerm_resource_group.testing.name
  size                  = "Standard_D4alds_v6"
  admin_username        = var.vm_admin_username
  tags                  = local.common_tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    name                 = "${local.naming_token}-disk-os"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = data.cloudinit_config.cyclecloud.rendered

  admin_ssh_key {
    public_key = trimspace(data.azurerm_key_vault_secret.public_key.value)
    username   = var.vm_admin_username
  }

  # Use the Azure-managed boot diagnostics storage account (no
  # storage_account_uri set) so serial console + screenshot are available in
  # the portal without provisioning / paying for a dedicated SA.
  boot_diagnostics {}

  # SystemAssigned provides the principal we grant the orchestrator role to.
  # The UAI is also attached so it's available for future cluster nodes /
  # CycleCloud account configuration.
  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cyclecloud.id]
  }
}

resource "azurerm_virtual_machine_extension" "ama" {
  name                       = "AzureMonitorLinuxAgent"
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  virtual_machine_id         = azurerm_linux_virtual_machine.cyclecloud.id
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
}