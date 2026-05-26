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

In `access_mode` = `public_ip` / `bastion`, `network_acls.default_action`
is currently **`Allow`** -- a temporary workaround to keep
`terraform destroy` and operator `az keyvault secret show` calls working
regardless of egress IP.

The enforcing path is fully wired:
`default_action = "Deny"` + `ip_rules = local.allowed_source_ips`,
where the list is the union of `var.allowed_ip_addresses` and
`data.http.current_ip` (normalized to `/32`) resolved at plan time
(see [terraform/locals.tf](../terraform/locals.tf) and
[terraform/keyvault.tf](../terraform/keyvault.tf)). Flipping the action
back to `Deny` re-enables the IP allow-list.

In `access_mode = "private_ip"` this gap does not apply: the vault is
set to `public_network_access_enabled = false` with `default_action = "Deny"`
automatically -- but that introduces its own reachability requirement;
see [Key Vault reachability in private_ip mode](#key-vault-reachability-in-private_ip-mode).

**TODO**: revert public_ip / bastion modes to `Deny` once the destroy-time
/ CI access story is resolved (CI needs egress to `api.ipify.org` for the
auto-detection, or a static service-principal-IP allow list).

## Key Vault reachability in `private_ip` mode

When `access_mode = "private_ip"` (or any spoke deployment that pins it),
[terraform/keyvault.tf](../terraform/keyvault.tf) sets
`public_network_access_enabled = false` and `network_acls.default_action = "Deny"`.
The vault is then reachable only through its private endpoint in the
`private_endpoint` subnet ([terraform/private_endpoints.tf](../terraform/private_endpoints.tf)).

That changes what the **operator's terraform run** needs:

- `azurerm_key_vault_secret.{private_key,public_key,cyclecloud_admin_password}`
  and the `data.azurerm_key_vault_secret.public_key` lookup all hit the KV
  **data plane** (`<vault>.vault.azure.net`), not the ARM control plane.
  With public access off, the runner needs a network path to the PE IP
  AND DNS that resolves the vault FQDN to that IP.
- Same for [post-config/downloadSSH.sh](../post-config/downloadSSH.sh)
  and any `az keyvault secret show` the operator runs by hand.

Practical requirements:

1. **Network path** -- run terraform / `az` from somewhere with line of
   sight to the spoke's `private_endpoint` subnet: a jumpbox / dev VM in
   the hub or another peered spoke, an ExpressRoute / VPN connection into
   the hub, or a CI runner deployed into a peered VNet.
2. **DNS resolution** -- the runner's resolver must return the PE's
   private IP for `<vault>.vault.azure.net`. In a typical ALZ that means
   the hub-managed `privatelink.vaultcore.azure.net` zone is linked to
   the spoke (or to the runner's VNet) and Azure Policy has registered
   the spoke PE into it. From outside Azure, point the resolver at the
   Azure DNS Private Resolver / a hub-side DNS forwarder.

Failure mode if either is missing: `terraform apply` / `destroy` /
refresh fails with `403 Forbidden` (path exists, firewall denied) or a
TLS / connect-timeout error against the public KV endpoint (DNS still
resolved to the public IP). Both are recoverable -- fix the path / DNS
and re-run; no state changes are persisted on failure.

**Mitigation if you cannot route to the PE during apply**: temporarily
flip `access_mode` to `bastion` or `public_ip` for the initial apply,
then switch to `private_ip` once secrets are written and the cluster is
up. Switching access modes does not recreate the VM (see
[docs/deploying.md](deploying.md)).

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

## Single subscription (standalone mode)

Standalone deployments (`deployment_mode = "standalone"`) are
single-subscription -- everything goes into the subscription the default
`azurerm` provider is bound to.

Spoke deployments (`deployment_mode = "spoke"`) DO split across two
subscriptions: the default provider for the spoke, plus the aliased
`azurerm.hub` provider for the hub-side peering write. See
[docs/hub-spoke.md](hub-spoke.md) and
[terraform/providers.tf](../terraform/providers.tf).

## No backend configured

State is local; configure an `azurerm` backend in
[terraform/providers.tf](../terraform/providers.tf) for team use.
