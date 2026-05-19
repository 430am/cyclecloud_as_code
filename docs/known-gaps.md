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
`default_action = "Deny"` + `ip_rules = local.key_vault_allowed_ips`,
where the list is the union of `var.current_ip_address` and
`data.http.current_ip` resolved at plan time
(see [terraform/locals.tf](../terraform/locals.tf) and
[terraform/keyvault.tf](../terraform/keyvault.tf)). Flipping the action
back to `Deny` re-enables the IP allow-list.

**TODO**: revert once the destroy-time / CI access story is resolved (CI
needs egress to `api.ipify.org` for the auto-detection, or a static
service-principal-IP allow list).

## `data.http.current_ip` requires outbound HTTPS to api.ipify.org

Called on every plan / apply / destroy. Air-gapped or restricted-egress
runners will fail there; swap to a known-static IP or short-circuit the
data source when that matters.

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
