# Terraform tests

Plan-only tests for the deterministic logic in this module. They run in
seconds and need no Azure credentials. A CI workflow that runs them on
every PR is planned but not yet wired up -- for now they're a local
gate, invoked from `terraform/` with `terraform test`.

## Running locally

From the [terraform/](../) directory:

```bash
terraform init -backend=false   # first time only
terraform test
```

A successful run prints `Success! N passed, 0 failed.` for each file
under this directory.

## How they're wired

Each `*.tftest.hcl` file declares `mock_provider "azurerm"` / `azuread` /
`http` blocks that supply canned responses for the data sources the root
module consumes (`azurerm_client_config`, `azurerm_subscription`,
`azuread_user`, `http`). Tests then run `command = plan` and assert on
**outputs** -- so anything you want to assert on must be exposed via
[outputs.tf](../outputs.tf).

The `random`, `tls`, `time`, and `cloudinit` providers are intentionally
left unmocked: they're local-only (no network, no credentials) and the
`tls_private_key` ephemeral resource isn't compatible with
`mock_provider` today.

## What's covered today

- [locals.tftest.hcl](locals.tftest.hcl)
  - subnet CIDR math under default and custom `vnet_address_space`
  - `access_mode` -> `use_bastion` / `use_public_ip` resolution
    (the new `use_private_ip` flag and `deployment_mode` / `is_spoke`
    toggles are not yet covered — see *Good candidates to add*)
  - `AzureBastionSubnet` is conditionally included only in bastion mode
  - `naming_token` / `naming_token_compact` derivation and length ceiling

## Good candidates to add

- **PE / DNS-zone invariant** -- assert every `azurerm_private_endpoint`
  references a `private_dns_zone_ids` entry that's also present in
  `local.private_dns_names` (catches the "added a PE, forgot the zone"
  bug class). Requires iterating planned resource attributes.
- **NSG rule surface** -- in `public_ip` mode, assert the NIC + server
  subnet NSG rules expose exactly `22 / 8080 / 8443` from
  `var.current_ip_address` and nothing else.
- **Cloud-init render** -- a test that asserts the rendered template
  contains `http://localhost:8080/` and the locker SA name. Easiest if
  the rendered string is exposed as an output (gated behind a test-only
  variable so it isn't shown in normal runs).
- **`key_vault_allowed_ips` dedup** -- set `var.current_ip_address`
  equal to the mocked `data.http.current_ip` body; assert the resolved
  list has exactly one entry.
