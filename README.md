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
| [terraform/keyvault.tf](terraform/keyvault.tf) | RBAC-mode Key Vault holding an ephemeral ED25519 SSH key pair (write-only secrets) and an auto-generated CycleCloud web-UI admin password, plus a `time_sleep` to wait for the caller's KV Administrator RBAC assignment to propagate before secrets are written. **`network_acls.default_action` is currently `Allow`** (see [Known gaps](#known-gaps--todo)); the `ip_rules` list (configured + auto-detected operator IP) is computed but not enforcing |
| [terraform/ssh.tf](terraform/ssh.tf) | `ephemeral.tls_private_key` (ED25519) + `ephemeral.tls_public_key` — in-memory key pair that is never written to state; only the Key Vault secrets persist |
| [terraform/monitoring.tf](terraform/monitoring.tf) | Log Analytics workspace, linked storage account (private-only), `azurerm_log_analytics_linked_storage_account`, diagnostic settings for Key Vault / VM / monitoring storage blob+table services |
| [terraform/locker.tf](terraform/locker.tf) | Dedicated CycleCloud locker storage account (LRS, RBAC-only, public network disabled) with a private `cyclecloud` blob container and diagnostic settings forwarded to the shared workspace — isolated from the monitoring SA so locker churn doesn't pollute diagnostic logs and the VM identity's blob-data RBAC stays scoped to one account |
| [terraform/private_endpoints.tf](terraform/private_endpoints.tf) | Private DNS zones, VNet links, AMPLS scope + scoped service, PEs for Key Vault, monitoring storage (blob + table), locker storage (blob), AMPLS |
| [terraform/cyclecloud.tf](terraform/cyclecloud.tf) | Ubuntu 24.04 managed OS disk built `FromImage`, NIC in `server` subnet, VM with `SystemAssigned + UserAssigned` identity, cloud-init rendered from [scripts/cloud-config.yaml.tftpl](scripts/cloud-config.yaml.tftpl) via `templatefile()`, Azure Monitor Linux Agent (`AzureMonitorLinuxAgent`) VM extension; optional public IP + NSG on the NIC when `access_mode = "public_ip"` |
| [terraform/roles.tf](terraform/roles.tf) | Custom **CycleCloud Orchestrator Role `<naming_token>`** assigned to the VM identity at subscription scope, Key Vault Administrator for caller, Key Vault Secrets User + Storage Blob Data Contributor (scoped to the dedicated locker SA) for the VM identity, Storage Blob + Table Data Contributor for the LA workspace identity on the monitoring SA |
| [terraform/locals.tf](terraform/locals.tf) | Subnet CIDR math via `cidrsubnet`, tag merging, DNS zone catalogs, `naming_token` / `naming_token_compact` (drive every resource name) |
| [terraform/outputs.tf](terraform/outputs.tf) | Resource group, VM name/IP, Bastion name, Key Vault URI, etc. |
| [scripts/cloud-config.yaml.tftpl](scripts/cloud-config.yaml.tftpl) | cloud-init template: installs OpenJDK 8, Azure CLI, and `cyclecloud8`, then runs the Phase 1 bootstrap — fetches the admin password + public key from Key Vault via managed identity, drops `account_data.json` into `/opt/cycle_server/config/data/` to bypass the web wizard, installs the CycleCloud CLI, runs `cyclecloud initialize` + `cyclecloud account create` to register the subscription with MSI auth. All secret-dependent steps live in a single `runcmd` shell block so the `CCPASSWORD` / `CCPUBKEY` shell vars stay in scope (cloud-init runs each list item in a fresh shell) |

### Subnet layout

`var.vnet_address_space` defaults to `["10.150.0.0/16"]`. From [terraform/locals.tf](terraform/locals.tf):

| Key (and subnet name) | CIDR | Used for |
|---|---|---|
| `cluster` | `10.150.0.0/23` | CycleCloud-managed compute nodes |
| `private_endpoint` | `10.150.2.0/26` | All `azurerm_private_endpoint` NICs |
| `server` | `10.150.2.64/26` | CycleCloud server VM NIC |
| `AzureBastionSubnet` | `10.150.2.128/26` | Bastion (name is required by Azure; only created when `access_mode = "bastion"`) |

## Architecture

The diagram below shows the Azure resources created by a single `terraform
apply` and how they wire together. Dashed components are conditional on
`var.access_mode` (Bastion vs. direct public IP); everything else is deployed
unconditionally.

```mermaid
flowchart LR
    operator(["Operator<br/>(current_ip_address)"])
    internet{{Internet}}

    subgraph SUB["Azure Subscription"]
        customRole["Custom role:<br/>CycleCloud Orchestrator"]

        subgraph RG["Resource Group: &lt;naming_token&gt;-rg"]
            direction LR

            uai["User-Assigned MI<br/>&lt;naming_token&gt;-uai"]

            subgraph KVBOX["Key Vault (RBAC; firewall: Allow + IP list)"]
                kv[("Key Vault<br/>&lt;naming_token&gt;kv")]
                sPwd["secret: cc-admin-password"]
                sPriv["secret: cc-private-key"]
                sPub["secret: cc-public-key"]
                kv --- sPwd
                kv --- sPriv
                kv --- sPub
            end

            subgraph MON["Observability"]
                la["Log Analytics<br/>Workspace"]
                ampls["AMPLS<br/>(Private-Only)"]
                stMon[("Storage Account<br/>monitoring (LRS)<br/>public access: disabled")]
                la --- ampls
                la -- linked ingestion --> stMon
            end

            subgraph LOCK["CycleCloud Locker"]
                stLocker[("Storage Account<br/>locker (LRS)<br/>public access: disabled")]
                ccContainer["blob container:<br/>cyclecloud"]
                stLocker --- ccContainer
            end

            subgraph VNET["VNet 10.150.0.0/16"]
                direction TB

                subgraph SNCluster["subnet: cluster<br/>10.150.0.0/23"]
                    clusterFuture["(future CycleCloud<br/>compute nodes)"]
                end

                subgraph SNServer["subnet: server (NSG)<br/>10.150.2.64/26"]
                    nic["NIC<br/>nic-cc"]
                    vm["Linux VM (Ubuntu 24.04)<br/>vm-cyclecloud<br/>SystemAssigned + UAI<br/>+ AzureMonitorLinuxAgent"]
                    osDisk[("Managed OS Disk<br/>Premium_LRS")]
                    nic --- vm
                    vm --- osDisk
                end

                subgraph SNPE["subnet: private_endpoint<br/>10.150.2.0/26"]
                    peKv["PE → Key Vault"]
                    peMonBlob["PE → monitoring blob"]
                    peMonTbl["PE → monitoring table"]
                    peLocker["PE → locker blob"]
                    peAmpls["PE → AMPLS"]
                end

                subgraph SNBas["subnet: AzureBastionSubnet<br/>10.150.2.128/26"]
                    bastion["Azure Bastion<br/>(Standard, tunneling)"]
                end

                pdns["Private DNS zones<br/>(vaultcore / blob / table /<br/>monitor / ods / oms / agentsvc)"]
            end

            nat["NAT Gateway<br/>+ Public IP"]
            pipBas["Public IP (Bastion)"]
            pipVm["Public IP (VM NIC)"]
            nsgNic["NIC NSG<br/>(caller IP only)"]
        end
    end

    %% Operator access paths
    operator -- "HTTPS 443<br/>(Bastion mode)" -.-> pipBas -.-> bastion
    bastion -.->|"SSH 22 /<br/>HTTPS tunnel"| vm
    operator == "SSH 22 / HTTPS 443 / 8080<br/>(public_ip mode)" ==> pipVm
    pipVm === nsgNic === nic

    %% Egress
    SNCluster -- egress --> nat
    SNServer  -- egress --> nat
    nat --> internet

    %% Private-endpoint data paths (storage SAs have public access disabled;
    %% the KV firewall is currently default-Allow, see Known gaps)
    vm -- "MI: get secrets" --> peKv --> kv
    vm -- "MI: blob R/W (locker)" --> peLocker --> stLocker
    vm -- "AMA logs/metrics" --> peAmpls --> ampls
    stMon -. PE .- peMonBlob
    stMon -. PE .- peMonTbl
    pdns -. resolves .- peKv
    pdns -. resolves .- peMonBlob
    pdns -. resolves .- peMonTbl
    pdns -. resolves .- peLocker
    pdns -. resolves .- peAmpls

    %% KV firewall is default-Allow today, so the operator's data-plane calls
    %% reach KV directly over the Internet (no IP filtering enforced)
    operator -. "KV data plane<br/>(default-Allow today;<br/>IP list computed but<br/>not enforcing)" .- kv

    %% Identity / RBAC
    vm -- "system MI" --> customRole
    customRole -. "scope: subscription" .- SUB
    vm -- "system MI" --> sPwd
    vm -- "system MI" --> sPub
    uai -. "attached for<br/>future cluster nodes" .- vm

    %% Diagnostics
    kv      -. diag .-> la
    vm      -. diag .-> la
    stMon   -. diag .-> la
    stLocker -. diag .-> la

    classDef cond stroke-dasharray: 4 3,stroke:#888;
    class bastion,pipBas,SNBas,pipVm,nsgNic cond;
```

**How to read it**

- **Solid double-arrow** = `public_ip` mode operator path (direct SSH / HTTPS
  from `var.current_ip_address` to the VM NIC's public IP, gated by both the
  NIC NSG and the matching `server` subnet NSG rules).
- **Dashed lines through Bastion** = `bastion` mode operator path (browser →
  Bastion public IP → tunneled SSH/HTTPS to the VM's private IP; no public
  IP on the VM).
- **Private endpoints** in the `private_endpoint` subnet are how the VM
  reaches Key Vault, the locker storage account, the monitoring storage
  account, and Azure Monitor. Both storage accounts have `public_network_
  access_enabled = false`, so they're reachable **only** via their PEs.
  The Key Vault is **currently** configured with `network_acls.default_
  action = "Allow"` (see [Known gaps](#known-gaps--todo)) — the
  `key_vault_allowed_ips` list (configured + auto-detected operator IP) is
  computed and assigned but not enforcing while default-Allow is in effect.
  Private DNS zones are VNet-linked so the storage / KV FQDNs resolve to
  the PE NICs from inside the VNet.
- **NAT Gateway** provides deterministic egress for the `cluster` and
  `server` subnets — required so package installs (`apt`, `cyclecloud8`,
  Azure CLI) and any future cluster nodes have outbound Internet without
  exposing inbound surface.
- **Identity**: the VM's **system-assigned** MI is the principal that holds
  the custom **CycleCloud Orchestrator** role at subscription scope (it
  also gets `Key Vault Secrets User` on the vault and
  `Storage Blob Data Contributor` on the locker SA). The **user-assigned**
  identity is attached but reserved for future cluster-node use.

## Prerequisites

- Terraform `~> 1.15` (uses `ephemeral` resources and write-only KV secret
  attributes, both introduced in 1.10/1.11; the pin in
  [terraform/providers.tf](terraform/providers.tf) is `~> 1.15`)
- Azure CLI logged in (`az login`) and the target subscription set as default
- The caller has rights to create custom role definitions and role assignments
  at the subscription scope (typically Owner or User Access Administrator +
  Contributor)
- Your current public IPv4 (only **required** when `access_mode = "public_ip"`,
  where it becomes the only source allowed inbound to the VM NIC NSG and the
  matching `server` subnet NSG rules). The KV firewall is currently default-
  Allow, so the IP isn't strictly required for KV access; see
  [Known gaps](#known-gaps--todo)

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
- `public_ip` — VM gets a Standard public IP. A NIC-level NSG **and**
  matching subnet-level rules on the `server` NSG (added by
  `azurerm_network_security_rule.server_allow_caller_*` in
  [terraform/cyclecloud.tf](terraform/cyclecloud.tf)) allow SSH (22),
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

A convenience wrapper that does the same thing lives at
[post-config/downloadSSH.sh](post-config/downloadSSH.sh):

```bash
cd post-config && ./downloadSSH.sh
```

It `cd`s into `../terraform` so `terraform output` resolves, writes
`~/.ssh/cyclecloud.pem`, and `chmod 600`s the result — useful after a fresh
`terraform apply` or whenever you need to re-pull the key onto a new
workstation.

> Note: the Key Vault firewall is currently `default_action = "Allow"`
> (see [Known gaps](#known-gaps--todo)), so the `az keyvault secret show`
> calls below succeed from any source IP. The `ip_rules` allow list
> (configured + auto-detected operator IP via `data.http.current_ip`) is
> still computed in [terraform/locals.tf](terraform/locals.tf) so that
> tightening `default_action` back to `Deny` is a one-line change.

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
| `access_mode` | string | `bastion` | `bastion` deploys Azure Bastion (no public IP on VM). `public_ip` attaches a Standard public IP + NIC NSG to the VM and also opens matching rules on the `server` subnet NSG, allowing 22/443/8080 inbound from `current_ip_address` only; no Bastion or `AzureBastionSubnet` is deployed |
| `tags` | map(string) | see file | Merged with a `deployed_by` tag |
| `current_ip_address` | string | `""` | Caller's public IPv4 (or `x.x.x.x/32`). Populated into `local.key_vault_allowed_ips` (alongside `data.http.current_ip`) and, when `access_mode = "public_ip"`, used as the source for the VM NIC NSG and the matching `server`-subnet NSG rules. Required when `access_mode = "public_ip"`; optional otherwise (the KV firewall is currently default-Allow, so the IP list isn't enforcing) |

## Naming convention

Every resource follows the [Andrew Matveychuk naming
convention](https://andrewmatveychuk.com/naming-convention-for-azure-resources):
`<product>-<abbrev>[-<identifier>]`, lowercase kebab-case, product first.

- `<product>` is `var.application_name` if set, otherwise `random_pet.naming.id`
  (exposed as `local.naming_token`).
- `<abbrev>` is the standard short type code: `rg`, `vnet`, `nsg`, `pip`,
  `nat`, `bas`, `kv`, `la`, `st` (storage uses suffixed variants `stmon`
  for monitoring and `stcc` for the CycleCloud locker to disambiguate the
  two accounts), `vm`, `nic`, `uai`, `pe`, `psc`, `pdzg`, `ampls`, `diag`,
  `disk`, `ipconfig`.
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

## Post-deploy: CycleCloud is already configured

The cloud-init bootstrap in
[scripts/cloud-config.yaml.tftpl](scripts/cloud-config.yaml.tftpl) runs the
full CycleCloud install end-to-end — there is **no web wizard to click
through**. This is **Phase 1** of the project (see
[Known gaps](#known-gaps--todo) for Phase 2 — cluster automation). After
`terraform apply` completes, the VM still needs ~5–10 minutes to finish:

1. `cyclecloud8` package install
2. `await_startup` (CycleCloud web app comes online)
3. CycleCloud CLI install from `/opt/cycle_server/tools/cyclecloud-cli.zip`
4. Managed-identity login + Key Vault secret fetch (in the single
   secret-dependent `runcmd` shell block — see the note in
   [scripts/cloud-config.yaml.tftpl](scripts/cloud-config.yaml.tftpl) about
   why everything that needs `CCPASSWORD` / `CCPUBKEY` has to share one
   shell)
5. Drop `account_data.json` into `/opt/cycle_server/config/data/` (skips the
   site name / EULA / admin-account wizard; CycleCloud renames it to
   `*.imported` once processed)
6. `cyclecloud initialize --batch --url=https://localhost/ ...`
7. `cyclecloud account create -f azure_data.json` (registers the subscription
   using `AzureRMUseManagedIdentity: true`, with the locker storage account
   and `cyclecloud` container already provisioned by Terraform)

### Verifying the bootstrap finished

SSH into the VM (see [SSH private key](#ssh-private-key-both-modes) below)
and watch cloud-init complete:

```bash
sudo cloud-init status --wait                          # blocks until done
sudo grep -E 'CycleCloud|cyclecloud' /var/log/cloud-init-output.log | tail -40
ls /opt/cycle_server/config/data/account_data.json.imported   # should exist
sudo -u cyclecloudadmin /usr/local/bin/cyclecloud locker list # should list the configured account
```

### Logging into the web UI

The admin username is `var.vm_admin_username` (default `cyclecloudadmin`).
The password was generated by Terraform and stored write-only in Key Vault:

```bash
cd terraform
az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name      "$(terraform output -raw cyclecloud_admin_password_secret_name)" \
  --query value -o tsv
```

Open the web UI per the mode you deployed in (`https://localhost:8443` after
the Bastion tunnel, or `https://<public-ip>:8080` directly) and sign in with
those credentials. The subscription should already be listed under
**Settings → Subscriptions** — if it is, the bootstrap finished cleanly and
you can go straight to creating a cluster.

> If `Settings → Subscriptions` is empty, the `cyclecloud account create` step
> failed (usually a transient RBAC propagation race). Inspect
> `/var/log/cloud-init-output.log` on the VM, then re-run the command by hand:
> `runuser -l cyclecloudadmin -c "cyclecloud account create -f ~/azure_data.json"`.

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
- **Key Vault firewall is currently `default_action = "Allow"`** — a
  temporary workaround to keep `terraform destroy` and operator
  `az keyvault secret show` calls working regardless of egress IP. The
  enforcing path (`default_action = "Deny"` + `ip_rules =
  local.key_vault_allowed_ips`, where the list is the union of
  `var.current_ip_address` and `data.http.current_ip` resolved at plan
  time) is fully wired in [terraform/locals.tf](terraform/locals.tf) and
  [terraform/keyvault.tf](terraform/keyvault.tf); flipping the action back
  to `Deny` re-enables the IP allow-list. TODO: revert once the
  destroy-time / CI access story is resolved (CI needs egress to
  `api.ipify.org` for the auto-detection, or a static SP-IP allow-list).
- **`data.http.current_ip`** calls `https://api.ipify.org` on every plan /
  apply / destroy. Air-gapped or restricted-egress runners will fail there;
  swap to a known-static IP or short-circuit the data source when that
  matters.
- **AMA extension version pin.** `type_handler_version = "1.0"` in
  [terraform/cyclecloud.tf](terraform/cyclecloud.tf) is the oldest schema; a
  newer pin (e.g. `"1.33"`) would surface explicit upgrade behavior. Auto-
  upgrade is enabled, so the agent itself is current regardless.
- **CycleCloud Insiders / version pinning.** The cloud-init pulls
  `cyclecloud stable main`; no version pin.
- **No automation of cluster creation (Phase 2).** Phase 1 (this repo) ends
  with the subscription registered. Adding
  `cyclecloud create_cluster <Template> <Name> -p params.json` +
  `cyclecloud start_cluster` to the cloud-init `runcmd` (and polling
  `cyclecloud show_nodes scheduler --states=Started`) would extend this to a
  full one-shot SLURM/PBS deployment — see the marconetto/azadventures
  chapter11 script for the pattern.
- **Single subscription.** Earlier scaffolding referenced aliased
  `workload_subscription` / `hub_subscription` providers; the current config is
  single-subscription. If a hub/spoke split is needed, re-introduce those
  aliases in `providers.tf` and corresponding `var.*_subscription_id` inputs.
- **No backend configured.** State is local; configure an `azurerm` backend
  for team use.
