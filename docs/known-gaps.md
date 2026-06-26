# Known gaps / TODO

Intentional rough edges. Pick them up as needed.

## NSG coverage is partial

The `server` subnet has an NSG (allow 22/8080/8443 from `VirtualNetwork`,
default deny otherwise) and `AzureBastionSubnet` has the Bastion-required
ruleset when `access_mode = "bastion"`. The `cluster` and `private_endpoint`
subnets still rely on the Azure default rules. In `public_ip` mode the VM
NIC NSG **and** the matching subnet-NSG rules
(`azurerm_network_security_rule.server_allow_caller_*` in
[terraform/cyclecloud.tf](../terraform/cyclecloud.tf)) provide the
Internet-facing allow rules.

## Key Vault firewall

`network_acls.default_action` is currently **`Allow`** — a temporary
workaround to keep `terraform destroy` and operator
`az keyvault secret show` calls working regardless of egress IP.

The enforcing path is fully wired:
`default_action = "Deny"` + `ip_rules = local.allowed_source_ips`,
where the list is the union of `var.allowed_ip_addresses` and
`data.http.current_ip` (normalized to `/32`) resolved at plan time
(see [terraform/locals.tf](../terraform/locals.tf) and
[terraform/keyvault.tf](../terraform/keyvault.tf)). Flipping the action
back to `Deny` re-enables the IP allow-list.

**TODO**: revert once the destroy-time / CI access story is resolved (CI
needs egress to `api.ipify.org` for the auto-detection, or a static
service-principal-IP allow list).

## Key Vault private endpoint vs Terraform refresh

The `azurerm_key_vault` resource does a Key Vault **data-plane** read for
certificate contacts during refresh. If the vault FQDN resolves to a private
endpoint IP that the Terraform runner cannot actually reach, `plan` / `apply`
fail with:

`retrieving contact for KeyVault: keyvault.BaseClient#GetCertificateContacts: ... context deadline exceeded`

To keep local workstations and generic CI runners reliable, this repo leaves
the Key Vault private endpoint **disabled by default** via
`var.enable_key_vault_private_endpoint = false`.

Enable it only when the runner has a working route and DNS story for the vault
private endpoint. If you do need the PE from a peered or separate network,
make sure your private DNS setup supports fallback to the public endpoint when
the private record is not reachable.

## `data.http.current_ip` requires outbound HTTPS to api.ipify.org

Called on every plan / apply / destroy. Air-gapped or restricted-egress
runners will fail there; swap to a known-static IP or short-circuit the
data source when that matters.

## NFS share quota is 100 GiB, not 10 GiB

The two NFSv4.1 shares in [terraform/files.tf](../terraform/files.tf)
(`sched`, `shared`) were originally requested at 10 GiB each but are
provisioned at 100 GiB. Premium FileStorage (the only tier that supports
NFS on Azure Files) enforces a hard 100 GiB minimum per share; smaller
quotas are rejected with `InvalidShareQuota`. For this dev environment
the extra capacity is cheap noise; revisit if cost matters or if Azure
ever lifts the floor.

## HTTPS on 8443 is not configured out of the box

The `cyclecloud8` Debian package install on Ubuntu ships **without** a
TLS keystore, so the CycleCloud web app only listens on **HTTP 8080**
after `await_startup` returns. Port 8443 is open at the NSG level (server
subnet) but the cycle_server process never binds to it until you
generate a keystore.

That's why the cloud-init bootstrap calls
`cyclecloud initialize --url=http://localhost:8080/` instead of the
HTTPS form -- loopback HTTP is the only port that exists, and the
traffic never leaves the VM so there's nothing to protect.

For operator-facing access this means:

- **Bastion mode**: the tunnel forwards 8080 (see
  [access-modes.md](access-modes.md#option-a-bastion-access_mode--bastion)).
  Browser-to-Bastion is HTTPS (Bastion's own cert); only the inside of
  the tunnel is plaintext.
- **public_ip mode**: HTTP runs unencrypted over the Internet, scoped to
  `var.allowed_ip_addresses` (+ auto-detected operator IP) by NSG but
  still in cleartext. Acceptable for a dev box; **do not** use this mode
  for anything sensitive without enabling TLS first.

**Fix path** (untested in this repo): after `await_startup` succeeds,
run something like
`/opt/cycle_server/cycle_server keystore automatic <hostname>` (or the
equivalent CC8 utility), wait for 8443 to respond, then point both the
bootstrap CLI and the operator docs back at `https://...:8443/`. The
NSG rules are already in place.

## CycleCloud Insiders / version pinning

The cloud-init pulls `cyclecloud stable main`; no version pin.

## No automation of cluster creation (Phase 2)

Phase 1 (this repo) ends with the subscription registered. Adding
`cyclecloud create_cluster <Template> <Name> -p params.json` +
`cyclecloud start_cluster` to the cloud-init `runcmd` (and polling
`cyclecloud show_nodes scheduler --states=Started`) would extend this to a
full one-shot SLURM/PBS deployment — see the marconetto/azadventures
chapter11 script for the pattern.

## Single subscription

Earlier scaffolding referenced aliased `workload_subscription` /
`hub_subscription` providers; the current config is single-subscription.
If a hub/spoke split is needed, re-introduce those aliases in
[terraform/providers.tf](../terraform/providers.tf) and corresponding
`var.*_subscription_id` inputs.

## No backend configured

State is local; configure an `azurerm` backend in
[terraform/providers.tf](../terraform/providers.tf) for team use.
