# cyclecloud_testing

Terraform that stands up an isolated **Azure CycleCloud** test bench: a hardened
single-VM CycleCloud server (Ubuntu 24.04) with a supporting VNet, Bastion,
Key Vault, Log Analytics + AMPLS, private storage, and the IAM plumbing needed
for CycleCloud to manage compute resources in the same subscription.

> Scope: developer / lab environment. Not production-hardened (no NSGs, single
> region, no HA). See [Known gaps](#known-gaps--todo).

## What it deploys

| File | Resources |
|------|-----------|
| [terraform/main.tf](terraform/main.tf) | Resource group, naming pet, `azuread_user` / `azurerm_subscription` data |
| [terraform/network.tf](terraform/network.tf) | VNet `10.150.0.0/16`, four subnets via `for_each` over `local.subnets` |
| [terraform/natgateway.tf](terraform/natgateway.tf) | NAT Gateway + public IP, attached to the `cluster` and `server` subnets |
| [terraform/bastion.tf](terraform/bastion.tf) | Standard SKU Bastion with tunneling enabled (only when `access_mode = "bastion"`) |
| [terraform/keyvault.tf](terraform/keyvault.tf) | RBAC-mode Key Vault holding an ephemeral ED25519 SSH key pair (write-only secrets) |
| [terraform/ssh.tf](terraform/ssh.tf) | `ephemeral.tls_private_key` / `tls_public_key` providers |
| [terraform/monitoring.tf](terraform/monitoring.tf) | Log Analytics workspace, linked storage account (private-only), `azurerm_log_analytics_linked_storage_account` |
| [terraform/private_endpoints.tf](terraform/private_endpoints.tf) | Private DNS zones, VNet links, AMPLS scope + scoped service, PEs for Key Vault, storage (blob + table), AMPLS |
| [terraform/cyclecloud.tf](terraform/cyclecloud.tf) | Ubuntu 24.04 managed OS disk built `FromImage`, NIC in `server` subnet, VM with `SystemAssigned + UserAssigned` identity, cloud-init from `scripts/cloud-config.yaml`; optional public IP + NSG on the NIC when `access_mode = "public_ip"` |
| [terraform/roles.tf](terraform/roles.tf) | Custom **CycleCloud Orchestrator Role**, role assignment to the VM's system identity at subscription scope, Key Vault Administrator for caller, monitoring data-plane roles for the LA workspace |
| [terraform/locals.tf](terraform/locals.tf) | Subnet CIDR math via `cidrsubnet`, tag merging, DNS zone catalogs |
| [terraform/outputs.tf](terraform/outputs.tf) | Resource group, VM name/IP, Bastion name, Key Vault URI, etc. |
| [scripts/cloud-config.yaml](scripts/cloud-config.yaml) | cloud-init: installs OpenJDK 8, Azure CLI, and `cyclecloud8` from Microsoft's apt repos |

### Subnet layout

`var.vnet_address_space` defaults to `["10.150.0.0/16"]`. From [terraform/locals.tf](terraform/locals.tf):

| Key (and subnet name) | CIDR | Used for |
|---|---|---|
| `cluster` | `10.150.0.0/23` | CycleCloud-managed compute nodes |
| `private_endpoint` | `10.150.2.0/26` | All `azurerm_private_endpoint` NICs |
| `server` | `10.150.2.64/26` | CycleCloud server VM NIC |
| `AzureBastionSubnet` | `10.150.2.128/26` | Bastion (name is required by Azure; only created when `access_mode = "bastion"`) |

## Prerequisites

- Terraform `~> 1` (uses `ephemeral` resources, so 1.10+)
- Azure CLI logged in (`az login`) and the target subscription set as default
- The caller has rights to create custom role definitions and role assignments
  at the subscription scope (typically Owner or User Access Administrator +
  Contributor)
- Your current public IPv4 — used to permit the Terraform runner through the
  Key Vault firewall while it writes the SSH secrets

## Usage

```bash
cd terraform

# 1. Author your tfvars (do not commit)
cp ../environments/example.tfvars.hcl ../environments/local.tfvars.hcl
# edit CURRENT_IP_ADDRESS (must be a valid IPv4, e.g. "203.0.113.10")

# 2. Auth + plan
export ARM_SUBSCRIPTION_ID=<your-sub-id>
az login
terraform init
terraform plan  -var-file=../environments/local.tfvars.hcl
terraform apply -var-file=../environments/local.tfvars.hcl
```

Outputs (see [terraform/outputs.tf](terraform/outputs.tf)) include the
CycleCloud VM private IP, Bastion host name, and Key Vault URI — everything you
need to reach the server.

### Connecting to the CycleCloud server

The connectivity model is controlled by `var.access_mode`:

- `bastion` (default) — VM has no public IP; reach it via Azure Bastion tunneling.
- `public_ip` — VM gets a Standard public IP and an NSG allowing 22/443 inbound
  from `var.CURRENT_IP_ADDRESS` only. Bastion is not deployed.

#### Option A: Bastion (`access_mode = "bastion"`)

Use Bastion + Azure CLI tunneling (Standard SKU, `tunneling_enabled = true`):

```bash
RG=$(terraform output -raw resource_group_name)
VM_ID=$(az vm show -g "$RG" -n "$(terraform output -raw cyclecloud_vm_name)" --query id -o tsv)
BAS=$(terraform output -raw bastion_host_name)

# Open the CycleCloud web UI (http://localhost:8443 → server :8080)
az network bastion tunnel \
  --name "$BAS" --resource-group "$RG" \
  --target-resource-id "$VM_ID" \
  --resource-port 8080 --port 8443
```

Then browse to <http://localhost:8443> and complete the CycleCloud setup
wizard (site name, admin account, SSH public key).

#### Option B: Public IP (`access_mode = "public_ip"`)

The VM gets a Standard public IP; NSG rules restrict inbound to your
`CURRENT_IP_ADDRESS`:

```bash
IP=$(terraform output -raw cyclecloud_vm_public_ip)

# Web UI (CycleCloud serves HTTPS on 443 after setup)
open https://$IP/

# SSH using the key from Key Vault (see below)
ssh -i ~/.ssh/cyclecloud.pem "$(terraform output -raw cyclecloud_vm_admin_username)@$IP"
```

#### SSH private key (both modes)

The generated SSH private key is in Key Vault under the secret name from
`terraform output ssh_private_key_secret_name`:

```bash
az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name "$(terraform output -raw ssh_private_key_secret_name)" \
  --query value -o tsv > ~/.ssh/cyclecloud.pem
chmod 600 ~/.ssh/cyclecloud.pem
```

## Variables

Declared in [terraform/variables.tf](terraform/variables.tf):

| Name | Type | Default | Notes |
|---|---|---|---|
| `location` | string | `southcentralus` | Azure region for all resources |
| `vm_admin_username` | string | `cyclecloudadmin` | Admin user on the CycleCloud VM |
| `vnet_address_space` | list(string) | `["10.150.0.0/16"]` | VNet space; `locals.tf` carves subnets from `[0]` |
| `access_mode` | string | `bastion` | `bastion` deploys Azure Bastion (no public IP on VM). `public_ip` attaches a Standard public IP + NSG to the VM NIC, allowing 22/443 inbound from `CURRENT_IP_ADDRESS` only; no Bastion or `AzureBastionSubnet` is deployed |
| `tags` | map(string) | see file | Merged with a `deployed_by` tag |
| `CURRENT_IP_ADDRESS` | string | `""` | Caller's public IPv4 (or `x.x.x.x/32`). Used in the Key Vault firewall allow list and, when `access_mode = "public_ip"`, as the source for the VM NSG inbound rules. Must be a real value at apply time |

`ARM_SUBSCRIPTION_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`
in `environments/example.tfvars.hcl` are read by the `azurerm` provider as
environment-style inputs; copy and rename the file when running locally.

## Post-deploy: configure CycleCloud

cloud-init installs the `cyclecloud8` package but **does not configure** it.
After the VM finishes provisioning (≈3–5 min), open the web UI via Bastion
tunnel (above) and complete:

1. Site name + license acceptance
2. Local admin account (CycleCloud-only, not an OS account)
3. Paste your SSH public key under *My Profile → Edit Profile*
4. Add the subscription (CycleCloud uses the VM's managed identity — the
   custom **CycleCloud Orchestrator Role** is already assigned at subscription
   scope by [terraform/roles.tf](terraform/roles.tf))

## Known gaps / TODO

These are real but were intentionally left out of this round of changes — pick
them up as needed:

- **No NSGs (bastion mode).** The Bastion subnet and server subnet have no
  NSGs in `bastion` mode. The `public_ip` mode does attach an NSG to the VM
  NIC, but only with allow rules for the caller IP — no deny-all baseline.
- **`azurerm_user_assigned_identity.cyclecloud`** is attached to the VM but
  has no role assignments of its own. It's reserved for future cluster nodes
  / CycleCloud account configuration.
- **Custom role name uniqueness.** `CycleCloud Orchestrator Role` is tenant-
  unique; parallel deployments in the same tenant collide. Consider appending
  `${random_pet.naming.id}`.
- **Key Vault firewall** allows a single `CURRENT_IP_ADDRESS`. Empty string
  default will fail apply; set it explicitly.
- **`local.configured_current_ip_address`** in `locals.tf` is computed but
  never referenced.
- **CycleCloud Insiders / version pinning.** The cloud-init pulls
  `cyclecloud stable main`; no version pin.
- **No automation of the web setup wizard.** Could be replaced with
  `cyclecloud initialize` + `cyclecloud account create` in cloud-init once the
  VM identity is reachable from the server CLI.
- **Single subscription.** Earlier scaffolding referenced aliased
  `workload_subscription` / `hub_subscription` providers; the current config is
  single-subscription. If a hub/spoke split is needed, re-introduce those
  aliases in `providers.tf` and corresponding `var.*_subscription_id` inputs.
- **No backend configured.** State is local; configure an `azurerm` backend
  for team use.
