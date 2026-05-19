# Access modes

How to reach the CycleCloud server VM. Controlled by `var.access_mode`.

| Mode | VM has public IP? | Bastion deployed? | Inbound source |
|---|---|---|---|
| `bastion` (default) | no | yes (Standard SKU, tunneling enabled) | `VirtualNetwork` only (via Bastion) |
| `public_ip` | yes (Standard) | no | `var.current_ip_address` only (NIC NSG **and** matching `server` subnet NSG rules) |

In `public_ip` mode, both the NIC NSG and the subnet NSG must Allow the
flow — either deny wins. The subnet-level rules are added by
`azurerm_network_security_rule.server_allow_caller_*` in
[terraform/cyclecloud.tf](../terraform/cyclecloud.tf).

CycleCloud 8 listens on **8080 (HTTP)** and **8443 (HTTPS)**, not the
standard 80/443. SSH is on 22 as usual. Both NSGs allow only 22/8080/8443.

## Option A: Bastion (`access_mode = "bastion"`)

Use Bastion + Azure CLI tunneling (Standard SKU, `tunneling_enabled = true`):

```bash
cd terraform

RG=$(terraform output -raw resource_group_name)
VM_ID=$(az vm show -g "$RG" -n "$(terraform output -raw cyclecloud_vm_name)" --query id -o tsv)
BAS=$(terraform output -raw bastion_host_name)

# Forward localhost:8443 -> VM:8443 (CycleCloud HTTPS)
az network bastion tunnel \
  --name "$BAS" --resource-group "$RG" \
  --target-resource-id "$VM_ID" \
  --resource-port 8443 --port 8443
```

Then browse to <https://localhost:8443> (the cert is self-signed, so the
browser will warn) and sign in (see
[post-deploy.md](post-deploy.md#logging-into-the-web-ui) for the credentials).

For SSH over Bastion, see [ssh-key.md](ssh-key.md#2c-ssh-over-azure-bastion-tunneling).

## Option B: Public IP (`access_mode = "public_ip"`)

The VM gets a Standard public IP; the NIC NSG and subnet NSG restrict
inbound on 22/8080/8443 to `var.current_ip_address`:

```bash
cd terraform

IP=$(terraform output -raw cyclecloud_vm_public_ip)

# Web UI (CycleCloud serves HTTPS on 8443; cert is self-signed)
open https://$IP:8443/

# SSH using the key from Key Vault (see ssh-key.md)
ssh -i ~/.ssh/cyclecloud.pem "$(terraform output -raw cyclecloud_vm_admin_username)@$IP"
```
