# Variables and naming convention

Reference for every input variable and how each resource name is constructed.

## Variables

Declared in [terraform/variables.tf](../terraform/variables.tf):

| Name | Type | Default | Notes |
|---|---|---|---|
| `location` | string | `southcentralus` | Azure region for all resources |
| `vm_admin_username` | string | `cyclecloudadmin` | Admin user on the CycleCloud VM |
| `application_name` | string | `""` | Product / application name used as the leading token in every resource name (`<application_name>-<abbrev>...`). Must be 2-20 chars of lowercase letters/numbers/hyphens, starting with a letter. Empty (default) falls back to `random_pet.naming.id` for collision-free lab deployments. **Changing this after apply will destroy and recreate every resource** because Azure resource names are immutable |
| `vnet_address_space` | list(string) | `["10.150.0.0/16"]` | VNet space; `locals.tf` carves subnets from `[0]` |
| `access_mode` | string | `bastion` | `bastion` deploys Azure Bastion (no public IP on VM). `public_ip` attaches a Standard public IP to the VM NIC; the server-subnet NSG opens 22/8080/8443 inbound from `allowed_ip_addresses` (plus the auto-detected operator IP). See [access-modes.md](access-modes.md) |
| `tags` | map(string) | see file | Merged with a `deployed_by` tag |
| `allowed_ip_addresses` | list(string) | `[]` | Additional caller IPv4 addresses / CIDRs allowed on the Key Vault firewall and the server-subnet NSG. The operator's live public IP is auto-detected via `data.http.current_ip` (ipify) and merged in automatically, so this only needs entries for teammates, CI runners, jump hosts, etc. Bare IPs are normalized to `/32`. Currently advisory on KV (firewall is default-Allow — see [known-gaps.md](known-gaps.md#key-vault-firewall)); enforcing on the server NSG when `access_mode = "public_ip"` |

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
  (e.g. `pip-bas`, `pip-nat`, `pip-cc`; `nsg-server`, `nsg-bastion`).
- Storage account and Key Vault names use `local.naming_token_compact`
  (hyphens stripped from `naming_token`) and are truncated to 24 chars to
  satisfy Azure's stricter naming rules for those resource types.
