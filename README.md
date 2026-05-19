# cyclecloud_as_code

Terraform that stands up an isolated **Azure CycleCloud** test bench: a hardened
single-VM CycleCloud server (Ubuntu 24.04) with a supporting VNet, Bastion,
Key Vault, Log Analytics + AMPLS, private storage, and the IAM plumbing needed
for CycleCloud to manage compute resources in the same subscription.

> Scope: developer / lab environment. Not production-hardened (single region,
> no HA, minimal NSG coverage — only the `server` and `AzureBastionSubnet`
> subnets carry NSGs). See [Known gaps](#known-gaps--todo).

## What it deploys

| File | Resources |
|------|-----------|
| [terraform/main.tf](terraform/main.tf) | Resource group, naming pet (`random_pet.naming`, used when `application_name` is empty), `azuread_user` / `azurerm_subscription` data |
| [terraform/network.tf](terraform/network.tf) | VNet `10.150.0.0/16`, four subnets via `for_each` over `local.subnets`, NSG on the `server` subnet, NSG on `AzureBastionSubnet` (bastion mode only) |
| [terraform/natgateway.tf](terraform/natgateway.tf) | NAT Gateway + public IP, attached to the `cluster` and `server` subnets |
| [terraform/bastion.tf](terraform/bastion.tf) | Standard SKU Bastion with tunneling enabled (only when `access_mode = "bastion"`) |
| [terraform/keyvault.tf](terraform/keyvault.tf) | RBAC-mode Key Vault holding an ephemeral ED25519 SSH key pair (write-only secrets), plus a `time_sleep` to wait for the caller's KV Administrator RBAC assignment to propagate before secrets are written |
| [terraform/ssh.tf](terraform/ssh.tf) | `ephemeral.tls_private_key` (ED25519) + `ephemeral.tls_public_key` — in-memory key pair that is never written to state; only the Key Vault secrets persist |
| [terraform/monitoring.tf](terraform/monitoring.tf) | Log Analytics workspace, linked storage account (private-only), `azurerm_log_analytics_linked_storage_account`, diagnostic settings for Key Vault / VM / storage blob+table services |
| [terraform/private_endpoints.tf](terraform/private_endpoints.tf) | Private DNS zones, VNet links, AMPLS scope + scoped service, PEs for Key Vault, storage (blob + table), AMPLS |
| [terraform/cyclecloud.tf](terraform/cyclecloud.tf) | Ubuntu 24.04 managed OS disk built `FromImage`, NIC in `server` subnet, VM with `SystemAssigned + UserAssigned` identity, cloud-init from `scripts/cloud-config.yaml`, Azure Monitor Linux Agent (`AzureMonitorLinuxAgent`) VM extension; optional public IP + NSG on the NIC when `access_mode = "public_ip"` |
| [terraform/roles.tf](terraform/roles.tf) | Custom **CycleCloud Orchestrator Role `<naming_token>`** (tenant-unique via the naming token), role assignment to the VM's system identity at subscription scope, Key Vault Administrator for caller, Storage Blob + Table Data Contributor for the LA workspace identity on the linked storage account |
| [terraform/locals.tf](terraform/locals.tf) | Subnet CIDR math via `cidrsubnet`, tag merging, DNS zone catalogs, `naming_token` / `naming_token_compact` (drive every resource name) |
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

- Terraform `~> 1.15` (uses `ephemeral` resources and write-only KV secret
  attributes, both introduced in 1.10/1.11; the pin in
  [terraform/providers.tf](terraform/providers.tf) is `~> 1.15`)
- Azure CLI logged in (`az login`) and the target subscription set as default
- The caller has rights to create custom role definitions and role assignments
  at the subscription scope (typically Owner or User Access Administrator +
  Contributor)
- Your current public IPv4 — used to permit the Terraform runner through the
  Key Vault firewall while it writes the SSH secrets, and (in `public_ip`
  mode) as the only source allowed inbound to the VM NIC NSG

## Usage

### Getting the code

Clone the repository (or your fork) the first time:

```bash
# Clone via SSH (preferred — matches the existing remote in this repo)
git clone git@github.com:430am/cyclecloud_testing.git
cd cyclecloud_testing

# ...or via HTTPS
git clone https://github.com/430am/cyclecloud_testing.git
cd cyclecloud_testing
```

Pull upstream changes on subsequent updates:

```bash
# Fast-forward your local main with whatever is on the remote
git checkout main
git pull --ff-only origin main
```

If you are working on a fork and `origin` points at your fork, add the
upstream once and sync from it:

```bash
git remote add upstream git@github.com:430am/cyclecloud_testing.git   # one-time
git fetch upstream
git checkout main
git merge --ff-only upstream/main
git push origin main                                                  # optional
```

After pulling, re-run `terraform init -upgrade` inside `terraform/` if
provider versions in [terraform/providers.tf](terraform/providers.tf) changed,
then `terraform plan` to see whether anything needs to be applied.

### Deploying

```bash
cd terraform

# 1. Author your tfvars (do not commit)
cp ../environments/example.tfvars.hcl ../environments/local.tfvars.hcl
# edit current_ip_address (must be a valid IPv4, e.g. "203.0.113.10")

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

- `bastion` (default) — VM has no public IP; reach it via Azure Bastion
  tunneling. The `server` subnet NSG allows SSH (22), HTTPS (443) and the
  CycleCloud setup port (8080) inbound from `VirtualNetwork` only.
- `public_ip` — VM gets a Standard public IP. A NIC-level NSG allows SSH (22),
  HTTPS (443) and the CycleCloud setup port (8080) inbound from
  `var.current_ip_address` only. Bastion is not deployed.

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

The VM gets a Standard public IP; the NIC NSG restricts inbound on 22/443/8080
to `var.current_ip_address`:

```bash
IP=$(terraform output -raw cyclecloud_vm_public_ip)

# Web UI (CycleCloud serves HTTPS on 8080 after setup)
open https://$IP:8080/

# SSH using the key from Key Vault (see below)
ssh -i ~/.ssh/cyclecloud.pem "$(terraform output -raw cyclecloud_vm_admin_username)@$IP"
```

#### SSH private key (both modes)

The generated SSH private key is stored in Key Vault as a write-only secret.
Pull it out and load it into your local SSH session with the helpers below.

**1. Download the key from Key Vault**

```bash
cd terraform   # so terraform output works

KEY_FILE=~/.ssh/cyclecloud.pem

az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name      "$(terraform output -raw ssh_private_key_secret_name)" \
  --query value -o tsv > "$KEY_FILE"

chmod 600 "$KEY_FILE"
```

> Note: the Key Vault firewall only permits `var.current_ip_address`, so run
> these commands from the same network you deployed from (or temporarily add
> your current IP to the vault's allow list).

**2a. Use the key for a single SSH command**

```bash
ADMIN=$(terraform output -raw cyclecloud_vm_admin_username)
IP=$(terraform output -raw cyclecloud_vm_public_ip)   # public_ip mode only

ssh -i "$KEY_FILE" "$ADMIN@$IP"
```

**2b. Load the key into `ssh-agent` for the rest of your session**

Loading the key into the agent means you can omit `-i` on subsequent `ssh`,
`scp`, `rsync`, and `git` invocations:

```bash
# Start an agent if one isn't already running in this shell
eval "$(ssh-agent -s)"

# Add the key (prompts for a passphrase only if the key has one — these don't)
ssh-add "$KEY_FILE"

# Verify it's loaded
ssh-add -l

# Now you can SSH without -i
ssh "$ADMIN@$IP"
```

The key stays in the agent until the shell exits (or `ssh-add -D` is run).
To persist across shells, add an entry to `~/.ssh/config`:

```sshconfig
Host cyclecloud
  HostName        <vm-public-ip-or-private-ip>
  User            cyclecloudadmin
  IdentityFile    ~/.ssh/cyclecloud.pem
  IdentitiesOnly  yes
  # When using Bastion tunneling on a local port, also add:
  # ProxyCommand none
  # Port         2222
```

Then simply `ssh cyclecloud`.

**2c. SSH over Azure Bastion tunneling**

When `access_mode = "bastion"` the VM has no public IP. Open a tunnel that
forwards a local port to port 22 on the VM, then SSH to `localhost`:

```bash
RG=$(terraform output -raw resource_group_name)
BAS=$(terraform output -raw bastion_host_name)
VM_ID=$(az vm show -g "$RG" -n "$(terraform output -raw cyclecloud_vm_name)" --query id -o tsv)

# Forward localhost:2222 -> VM:22 (leave running in its own terminal)
az network bastion tunnel \
  --name "$BAS" --resource-group "$RG" \
  --target-resource-id "$VM_ID" \
  --resource-port 22 --port 2222 &

ssh -p 2222 -i "$KEY_FILE" "$ADMIN@localhost"
```

## Variables

Declared in [terraform/variables.tf](terraform/variables.tf):

| Name | Type | Default | Notes |
|---|---|---|---|
| `location` | string | `southcentralus` | Azure region for all resources |
| `vm_admin_username` | string | `cyclecloudadmin` | Admin user on the CycleCloud VM |
| `application_name` | string | `""` | Product / application name used as the leading token in every resource name (`<application_name>-<abbrev>...`). Must be 2-20 chars of lowercase letters/numbers/hyphens, starting with a letter. Empty (default) falls back to `random_pet.naming.id` for collision-free lab deployments. **Changing this after apply will destroy and recreate every resource** because Azure resource names are immutable |
| `vnet_address_space` | list(string) | `["10.150.0.0/16"]` | VNet space; `locals.tf` carves subnets from `[0]` |
| `access_mode` | string | `bastion` | `bastion` deploys Azure Bastion (no public IP on VM). `public_ip` attaches a Standard public IP + NSG to the VM NIC, allowing 22/443 inbound from `current_ip_address` only; no Bastion or `AzureBastionSubnet` is deployed |
| `tags` | map(string) | see file | Merged with a `deployed_by` tag |
| `current_ip_address` | string | `""` | Caller's public IPv4 (or `x.x.x.x/32`). Used in the Key Vault firewall allow list and, when `access_mode = "public_ip"`, as the source for the VM NSG inbound rules. Must be a real value at apply time |

## Naming convention

Every resource follows the [Andrew Matveychuk naming
convention](https://andrewmatveychuk.com/naming-convention-for-azure-resources):
`<product>-<abbrev>[-<identifier>]`, lowercase kebab-case, product first.

- `<product>` is `var.application_name` if set, otherwise `random_pet.naming.id`
  (exposed as `local.naming_token`).
- `<abbrev>` is the standard short type code: `rg`, `vnet`, `nsg`, `pip`,
  `nat`, `bas`, `kv`, `la`, `st`, `vm`, `nic`, `uai`, `pe`, `psc`, `pdzg`,
  `ampls`, `diag`, `disk`, `ipconfig`.
- `<identifier>` disambiguates when one resource type appears more than once
  (e.g. `pip-bas`, `pip-nat`, `pip-cc`; `nsg-server`, `nsg-bastion`, `nsg-cc`).
- Storage account and Key Vault names use `local.naming_token_compact`
  (hyphens stripped from `naming_token`) and are truncated to 24 chars to
  satisfy Azure's stricter naming rules for those resource types.

## Azure authentication

The `azurerm` provider authenticates from environment variables. Export the
following in the shell that runs Terraform — they are **not** read from
`*.tfvars.hcl`:

```bash
export ARM_SUBSCRIPTION_ID=<subscription-guid>
export ARM_TENANT_ID=<tenant-guid>
# For service-principal auth (skip both when using `az login` /
# `az account set` for interactive auth):
export ARM_CLIENT_ID=<sp-app-id>
export ARM_CLIENT_SECRET=<sp-secret>
```

[environments/example.tfvars.hcl](environments/example.tfvars.hcl) lists these
`ARM_*` names as a copy-paste reference for the variables you need to export;
the only value actually consumed from the tfvars file by the configuration is
`current_ip_address`.

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

- **NSG coverage is partial.** The `server` subnet has an NSG (allow
  22/443/8080 from `VirtualNetwork`, default deny otherwise) and
  `AzureBastionSubnet` has the Bastion-required ruleset when `access_mode =
  "bastion"`. The `cluster` and `private_endpoint` subnets still rely on the
  Azure default rules. In `public_ip` mode the VM NIC NSG provides the
  Internet-facing allow rules.
- **`azurerm_user_assigned_identity.cyclecloud`** is attached to the VM but
  has no role assignments of its own. It's reserved for future cluster nodes
  / CycleCloud account configuration.
- **Key Vault firewall** allows a single `current_ip_address`. Empty string
  default will fail apply; set it explicitly.
- **AMA extension version pin.** `type_handler_version = "1.0"` in
  [terraform/cyclecloud.tf](terraform/cyclecloud.tf) is the oldest schema; a
  newer pin (e.g. `"1.33"`) would surface explicit upgrade behavior. Auto-
  upgrade is enabled, so the agent itself is current regardless.
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
