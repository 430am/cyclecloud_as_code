data "cloudinit_config" "cyclecloud" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    filename     = "cloud-config.yaml"
    content      = file("${path.module}/../scripts/cloud-config.yaml")
  }
}

# Latest versioned ID for the Ubuntu 24.04 LTS marketplace image. Required for
# azurerm_managed_disk.create_option = "FromImage".
data "azurerm_platform_image" "ubuntu" {
  location  = var.location
  publisher = "Canonical"
  offer     = "ubuntu-24_04-lts"
  sku       = "server"
}

resource "azurerm_network_interface" "cyclecloud" {
  location            = var.location
  name                = "nic-cc-${random_pet.naming.id}"
  resource_group_name = azurerm_resource_group.testing.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "ipconfig-cc-${random_pet.naming.id}"
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.cyclecloud["server"].id
  }
}

resource "azurerm_managed_disk" "cyclecloud" {
  create_option        = "FromImage"
  image_reference_id   = data.azurerm_platform_image.ubuntu.id
  location             = var.location
  name                 = "osdisk-${random_pet.naming.id}-cc"
  resource_group_name  = azurerm_resource_group.testing.name
  storage_account_type = "Premium_LRS"
  disk_size_gb         = 256
  os_type              = "Linux"
  tags                 = local.common_tags
}

resource "azurerm_linux_virtual_machine" "cyclecloud" {
  location              = var.location
  name                  = "vm-${random_pet.naming.id}-cyclecloud"
  network_interface_ids = [azurerm_network_interface.cyclecloud.id]
  resource_group_name   = azurerm_resource_group.testing.name
  size                  = "Standard_D4alds_v6"
  admin_username        = var.vm_admin_username
  tags                  = local.common_tags

  os_managed_disk_id = azurerm_managed_disk.cyclecloud.id

  os_disk {
    caching = "ReadWrite"
  }

  custom_data = data.cloudinit_config.cyclecloud.rendered

  admin_ssh_key {
    public_key = trimspace(data.azurerm_key_vault_secret.public_key.value)
    username   = var.vm_admin_username
  }

  # SystemAssigned provides the principal we grant the orchestrator role to.
  # The UAI is also attached so it's available for future cluster nodes /
  # CycleCloud account configuration.
  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cyclecloud.id]
  }
}