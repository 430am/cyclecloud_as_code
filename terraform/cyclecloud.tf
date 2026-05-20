# The bootstrap script is rendered separately so the resulting bash file can
# use ${var}-style references freely without colliding with Terraform's own
# template syntax. The rendered content is then embedded into cloud-config via
# write_files.
locals {
  cc_bootstrap_script = templatefile("${path.module}/../scripts/cc-bootstrap.sh.tftpl", {
    admin_user         = var.vm_admin_username
    key_vault_name     = azurerm_key_vault.cyclecloud.name
    pwd_secret_name    = azurerm_key_vault_secret.cyclecloud_admin_password.name
    pubkey_secret_name = azurerm_key_vault_secret.public_key.name
  })
}

data "cloudinit_config" "cyclecloud" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    filename     = "cloud-config.yaml"
    content = templatefile("${path.module}/../scripts/cloud-config.yaml.tftpl", {
      admin_user             = var.vm_admin_username
      resource_group_name    = azurerm_resource_group.testing.name
      subscription_id        = data.azurerm_subscription.current.subscription_id
      location               = var.location
      storage_account_name   = azurerm_storage_account.locker.name
      storage_container_name = azurerm_storage_container.cyclecloud_locker.name
      locker_identity_id     = azurerm_user_assigned_identity.cyclecloud.id
      bootstrap_script       = local.cc_bootstrap_script
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

# Inbound 22/8080/8443 from caller IPs is enforced by the server-subnet NSG
# (azurerm_network_security_group.server in network.tf), which applies to
# every NIC placed on the subnet. No NIC-level NSG is needed.

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
  type_handler_version       = "1.41"
  virtual_machine_id         = azurerm_linux_virtual_machine.cyclecloud.id
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
}

# Block `terraform apply` until the in-VM bootstrap script declares success
# (touches /var/lib/cc-bootstrap.done) or failure (/var/lib/cc-bootstrap.failed).
# Uses `az vm run-command invoke`, which goes via the Azure control plane and
# therefore works in bastion-only deployments with no SSH path from the
# operator workstation.
#
# Operator must already have `az login` context (the same context Terraform
# uses to authenticate). Polls every 20s for up to ~30 minutes.
resource "null_resource" "cyclecloud_ready" {
  triggers = {
    vm_id            = azurerm_linux_virtual_machine.cyclecloud.id
    bootstrap_sha256 = sha256(local.cc_bootstrap_script)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      RG="${azurerm_resource_group.testing.name}"
      VM="${azurerm_linux_virtual_machine.cyclecloud.name}"
      echo "[cyclecloud_ready] polling $VM for /var/lib/cc-bootstrap.done ..."
      for i in $(seq 1 90); do
        out=$(az vm run-command invoke -g "$RG" -n "$VM" \
                --command-id RunShellScript \
                --scripts "if [ -f /var/lib/cc-bootstrap.failed ]; then echo FAILED; tail -n 40 /var/log/cc-bootstrap.log 2>/dev/null || true; elif [ -f /var/lib/cc-bootstrap.done ]; then echo READY; else echo PENDING; fi" \
                --query 'value[0].message' -o tsv 2>/dev/null || echo PENDING)
        if echo "$out" | grep -q READY; then
          echo "[cyclecloud_ready] CycleCloud bootstrap complete after $((i * 20))s."
          exit 0
        fi
        if echo "$out" | grep -q FAILED; then
          echo "[cyclecloud_ready] CycleCloud bootstrap FAILED. Last log lines:" >&2
          echo "$out" >&2
          exit 1
        fi
        echo "[cyclecloud_ready] still pending ($i/90); sleeping 20s ..."
        sleep 20
      done
      echo "[cyclecloud_ready] timeout: sentinel not found after 30 minutes." >&2
      exit 1
    EOT
  }

  depends_on = [
    azurerm_virtual_machine_extension.ama,
  ]
}