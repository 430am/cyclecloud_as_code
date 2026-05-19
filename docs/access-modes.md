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

CycleCloud 8 listens on **HTTP 8080** out of the box. **HTTPS 8443 is
NOT open** until a TLS keystore is configured on the VM (the Ubuntu
package install ships without a self-signed cert -- see
[known-gaps.md](known-gaps.md#https-on-8443-is-not-configured-out-of-the-box)).
SSH is on 22 as usual. Both NSGs allow 22/8080/8443 (8443 is pre-opened
for when you do enable TLS).

## Option A: Bastion (`access_mode = "bastion"`)

Use Bastion + Azure CLI tunneling (Standard SKU, `tunneling_enabled = true`):

```bash
cd terraform

RG=$(terraform output -raw resource_group_name)
VM_ID=$(az vm show -g "$RG" -n "$(terraform output -raw cyclecloud_vm_name)" --query id -o tsv)
BAS=$(terraform output -raw bastion_host_name)

# Forward localhost:8080 -> VM:8080 (CycleCloud HTTP)
az network bastion tunnel \
  --name "$BAS" --resource-group "$RG" \
  --target-resource-id "$VM_ID" \
  --resource-port 8080 --port 8080
```

Then browse to <http://localhost:8080> and sign in (see
[post-deploy.md](post-deploy.md#logging-into-the-web-ui) for the credentials).
The browser-to-Bastion hop is HTTPS (Bastion's own TLS); only the
Bastion-to-VM hop inside the tunnel is plaintext HTTP.

For SSH over Bastion, see [ssh-key.md](ssh-key.md#2c-ssh-over-azure-bastion-tunneling).

## Option B: Public IP (`access_mode = "public_ip"`)

The VM gets a Standard public IP; the NIC NSG and subnet NSG restrict
inbound on 22/8080/8443 to `var.current_ip_address`:

```bash
cd terraform

IP=$(terraform output -raw cyclecloud_vm_public_ip)

# Web UI (HTTP only by default -- traffic is unencrypted on the wire).
# Configure TLS on the VM if this matters; see known-gaps.md.
open http://$IP:8080/

# SSH using the key from Key Vault (see ssh-key.md)
ssh -i ~/.ssh/cyclecloud.pem "$(terraform output -raw cyclecloud_vm_admin_username)@$IP"
```
