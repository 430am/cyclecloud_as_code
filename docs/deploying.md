# Deploying

End-to-end deployment flow: clone, configure, apply. Assumes
[prerequisites.md](prerequisites.md) is satisfied.

## Getting the code

First-time clone:

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
provider versions in [terraform/providers.tf](../terraform/providers.tf)
changed, then `terraform plan` to see whether anything needs to be applied.

## Deploying

```bash
cd terraform

# 1. Author your tfvars (do not commit). Optional: add allowed_ip_addresses
#    entries for teammates / CI runners. The operator's own public IP is
#    auto-detected via ipify, so the file can be empty for a solo deploy.
cp environments/example.tfvars.hcl environments/local.tfvars.hcl

# 2. Auth + plan
export ARM_SUBSCRIPTION_ID=<your-sub-id>
az login
terraform init
terraform plan  -var-file=environments/local.tfvars.hcl
terraform apply -var-file=environments/local.tfvars.hcl
```

Outputs (see [terraform/outputs.tf](../terraform/outputs.tf)) include the
CycleCloud VM private IP, Bastion host name, and Key Vault URI — everything
you need to reach the server.

## Common CLI overrides

Every variable in [terraform/variables.tf](../terraform/variables.tf) can be
overridden at the command line with `-var 'name=value'` (or via the
`TF_VAR_<name>` environment variable). The two you'll reach for most often
are `access_mode` and `application_name`; both are also documented in the
full variable reference at [variables.md](variables.md).

### `access_mode` — how operators reach the VM

Picks between an Azure Bastion deployment and a Standard public IP on the
VM NIC. See [access-modes.md](access-modes.md) for the full comparison and
the connection commands for each mode.

| Value | VM public IP? | Bastion deployed? | Inbound source on the server NSG |
|---|---|---|---|
| `bastion` (default) | no | yes (Standard, tunneling enabled) | `VirtualNetwork` only |
| `public_ip` | yes (Standard) | no | `VirtualNetwork` + `var.allowed_ip_addresses` (plus auto-detected operator IP) |

**Bastion mode (default)** — no flags needed:

```bash
terraform apply -var-file=environments/local.tfvars.hcl
```

**Public-IP mode** — flip the mode on the CLI; the operator's egress IP is
auto-detected via ipify, so no other flags are required for a solo deploy:

```bash
terraform apply \
  -var-file=environments/local.tfvars.hcl \
  -var 'access_mode=public_ip'
```

To allow teammates / CI runners in addition to your own IP, set
`allowed_ip_addresses` (either in the tfvars file or on the CLI):

```bash
terraform apply \
  -var-file=environments/local.tfvars.hcl \
  -var 'access_mode=public_ip' \
  -var 'allowed_ip_addresses=["203.0.113.10","198.51.100.0/24"]'
```

Switching modes after the first apply is supported and reasonably cheap:
flipping `bastion` → `public_ip` destroys the Bastion host, its public IP,
and the `AzureBastionSubnet`, and creates a VM public IP. The VM itself is
not recreated. The reverse direction is symmetric.

### `application_name` — naming token for every resource

Sets the leading `<product>` segment in every resource name (the
[Andrew Matveychuk convention](https://andrewmatveychuk.com/naming-convention-for-azure-resources)
— `<product>-<abbrev>[-<identifier>]`). Empty (the default) falls back to a
generated `random_pet.naming.id`, which is perfect for throwaway labs where
parallel runs would otherwise collide on names.

Constraints (enforced by the variable's `validation` block):

- Lowercase letters, numbers, and hyphens only.
- Must start with a letter.
- 2–20 characters. The 20-char ceiling exists because Key Vault and storage
  account names are capped at 24 chars and the resources append a short
  suffix (e.g. `kv`, `stcc`, `stmon`) to a hyphen-stripped form of the
  token — see [variables.md](variables.md#naming-convention).

**Default (random pet)** — collision-free names like
`fullbarnacle-rg`, `fullbarnacle-vnet`, `fullbarnaclekv`:

```bash
terraform apply -var-file=environments/local.tfvars.hcl
```

**Named deployment** — pin a stable token so you can identify the
deployment in the portal:

```bash
terraform apply \
  -var-file=environments/local.tfvars.hcl \
  -var 'application_name=cc-dev'
# -> cc-dev-rg, cc-dev-vnet, cc-devkv, cc-devstcc, cc-devstmon, cc-dev-vm-cyclecloud, ...
```

**⚠️ Changing `application_name` after an apply destroys and recreates
every resource**, because Azure resource names are immutable. Treat it as a
deploy-time decision, not a knob to tune later. If you need to rename, plan
on a full `terraform destroy` + `terraform apply` cycle (or a new workspace
/ state file).

### Combining overrides

CLI flags compose cleanly with `-var-file`; later `-var` flags take
precedence over earlier ones and over values in the tfvars file:

```bash
terraform apply \
  -var-file=environments/local.tfvars.hcl \
  -var 'application_name=cc-dev' \
  -var 'access_mode=public_ip' \
  -var 'location=eastus2'
```

For repeatable invocations, prefer putting these values into the tfvars
file (or into an environment-specific file like
`environments/dev.tfvars.hcl`) rather than typing them on the CLI every
time.

## Next steps

- Choose how you'll reach the VM: [access-modes.md](access-modes.md).
- Pull the SSH key out of Key Vault: [ssh-key.md](ssh-key.md).
- Watch the cloud-init bootstrap finish and log into the web UI:
  [post-deploy.md](post-deploy.md).
