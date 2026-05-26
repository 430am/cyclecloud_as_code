# Hub-and-spoke deployment

How to deploy this stack as a spoke that consumes pre-existing hub
landing-zone services (central private DNS, central Log Analytics, and a
peered hub VNet for inbound reachability).

In short: set `deployment_mode = "spoke"`, point `var.hub` at the hub's
resources, and pick `access_mode = "private_ip"` to get a VM with no
public IP and no Bastion. See
[terraform/environments/spoke.tfvars.hcl](../terraform/environments/spoke.tfvars.hcl)
for a complete example.

## What `deployment_mode = "spoke"` changes

Compared to `standalone`:

| Concern | standalone | spoke |
|---|---|---|
| Log Analytics workspace | created locally | reused: `var.hub.monitoring.log_analytics_workspace_id` |
| AMPLS scope + scoped service + private endpoint | created locally | not created (hub's AMPLS, if any, is out of scope) |
| Monitoring storage account + linked storage + its PEs | created locally | not created |
| Private DNS zones (`privatelink.*`) | created locally | not created (hub owns them) |
| VNet links from those zones to this VNet | created locally | not created — hub team links the spoke VNet out of band |
| PE `private_dns_zone_group` (KV / locker blob / files) | attached locally | omitted — relies on hub Azure Policy to register A-records |
| VNet peering | none | spoke→hub (always) + hub→spoke (default true, see below) |
| NAT gateway egress | created | still created (no change) |
| Diagnostic settings (KV, VM, locker blob, files) | local LA | hub LA |

Everything else (VM, NIC, Key Vault, storage accounts, NFS shares, custom
RBAC role, locker, NSGs, NAT gateway) is identical in both modes.

## What `access_mode = "private_ip"` changes

- No public IP attached to the VM NIC.
- No Azure Bastion deployed (no `AzureBastionSubnet`).
- Server-subnet NSG keeps only the `VirtualNetwork → VirtualNetwork` rule
  on 22/8080/8443. The operator-IP allow rule is **not** created.
- Key Vault `public_network_access_enabled = false`,
  `network_acls.default_action = "Deny"`, no `ip_rules`. KV is reachable
  exclusively via its private endpoint.

`private_ip` is only valid when `deployment_mode = "spoke"` — without a
peered hub VNet there is no path to reach the VM or KV from outside the
local VNet. The module enforces this with a `check` block.

## What the hub team must provide

This module does **not** write to hub resources beyond optional VNet
peering. The hub is expected to provide:

1. **Private DNS zones** in a central RG, covering at minimum:
   - `privatelink.vaultcore.azure.net`
   - `privatelink.blob.core.windows.net`
   - `privatelink.file.core.windows.net`
   - `privatelink.table.core.windows.net` *(only if you re-enable the
     local monitoring SA later)*
   - Monitor zones (`privatelink.monitor.azure.com`,
     `.ods.opinsights.azure.com`, `.oms.opinsights.azure.com`,
     `.agentsvc.azure-automation.net`) if hub AMPLS is in use.
2. **VNet links** from each of those zones to this spoke's VNet, OR a
   central DNS-resolver setup (e.g. Azure Private DNS Resolver) that
   forwards `privatelink.*` to the hub-hosted zones. The spoke VNet ID
   is exposed as `terraform output virtual_network_id`.
3. **Azure Policy** that auto-registers PE A-records into the right
   hub-hosted zone — the built-in *"Configure private DNS zone group..."*
   policies cover every privatelink service this module creates. Without
   this, the PEs created by the spoke (KV, locker blob, NFS files) will
   provision but DNS will not resolve them.
4. **Log Analytics workspace** in the hub, whose resource ID goes into
   `var.hub.monitoring.log_analytics_workspace_id`.
5. **(Optional)** Forced-tunnel egress via a hub Azure Firewall, attached
   to the spoke subnets by an Azure Policy that pushes a UDR. The local
   NAT gateway stays in place either way; once a UDR is associated to a
   subnet it takes precedence at routing time without any change here.

## VNet peering: who creates which side

By default the module creates **both** sides of the peering:

- `spoke → hub`: created with the default `azurerm` provider (spoke
  subscription). Requires Network Contributor on this spoke VNet (you
  always have this in the spoke RG you're deploying into).
- `hub → spoke`: created with the aliased `azurerm.hub` provider against
  `var.hub.subscription_id`. Requires Network Contributor on the hub
  VNet for the deploying principal.

If the hub team manages their side themselves (common in tightly
governed landing zones), opt out of the reverse peering:

```hcl
hub = {
  # ...
  virtual_network = {
    id                     = "<hub vnet id>"
    create_reverse_peering = false
  }
  # ...
}
```

In that case the deploying principal only needs spoke-side permissions,
and the hub team creates the hub→spoke peering pointing at
`terraform output virtual_network_id`.

## Required RBAC for the deploying principal

In the spoke subscription (same as standalone):

- `Contributor` (or equivalent) on the target subscription / RG.
- `User Access Administrator` (the role definition + role assignments
  this stack creates require this).
- `Key Vault Administrator` data-plane access — granted by the stack
  itself via [terraform/roles.tf](../terraform/roles.tf).

Additionally in the hub subscription, **only if**
`create_reverse_peering = true`:

- `Network Contributor` on the hub VNet.

## Reaching the VM (and KV) from your workstation

`private_ip` mode means there is **no** Internet path to the VM or to
Key Vault. The operator running `terraform plan/apply/destroy` must have
network reachability to the spoke from wherever they run the command,
because the `azurerm_key_vault_secret` resources hit the KV data plane
on every refresh, and `data.azurerm_key_vault_secret.public_key` reads
the key back to feed the VM's `admin_ssh_key`.

Concretely, run terraform from one of:

- A jumpbox / dev VM inside the hub or another peered spoke.
- A workstation connected via ExpressRoute or site-to-site VPN to the
  hub, with central DNS configured to resolve `privatelink.vaultcore.azure.net`.
- A self-hosted CI runner sitting in a peered VNet.

The `null_resource.cyclecloud_ready` poll uses `az vm run-command
invoke`, which goes through the Azure ARM control plane (public
endpoint), so it works from anywhere with `az login` regardless of
network path.

For interactive access to the CycleCloud web UI in this mode, the most
common patterns are:

- Tunnel via a hub-hosted Azure Bastion that targets the spoke VM by
  resource ID + private IP (Bastion can target peered VNets).
- Run a browser on a jumpbox inside the peered network.
- ExpressRoute / VPN + central DNS so `https://<spoke-vm-fqdn>:8080`
  resolves and routes.

## Outputs useful to hand to the hub team

- `terraform output virtual_network_id` — pass to the hub team for DNS
  zone links and (if applicable) the hub→spoke peering they're creating.
- `terraform output resource_group_name` — for any out-of-band tooling
  they want to point at this spoke.
- `terraform output log_analytics_workspace_id` — confirms the
  diagnostic settings target the hub workspace they expected.
