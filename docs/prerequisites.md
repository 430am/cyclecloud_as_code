# Prerequisites

What you need installed and configured before running `terraform apply`.

## Tooling

- **Terraform `~> 1.15`** — uses `ephemeral` resources and write-only Key
  Vault secret attributes, both introduced in 1.10/1.11. The pin lives in
  [terraform/providers.tf](../terraform/providers.tf).
- **Azure CLI**, logged in (`az login`) with the target subscription set as
  the default (`az account set --subscription <id>`).

## Azure permissions

The caller must be able to create custom role definitions and role
assignments at the **subscription** scope — in practice this means **Owner**,
or **User Access Administrator + Contributor**.

## Network access

- Your **current public IPv4** is only **required** when
  `access_mode = "public_ip"` (it becomes the only source allowed inbound to
  the VM NIC NSG and the matching `server` subnet NSG rules — see
  [access-modes.md](access-modes.md)).
- The Key Vault firewall is currently `default_action = "Allow"`, so the IP
  is **not** strictly required to read KV secrets; see
  [known-gaps.md](known-gaps.md#key-vault-firewall) for the planned tightening.
- The `data.http.current_ip` data source calls `https://api.ipify.org` on
  every plan / apply / destroy to auto-detect the operator IP. Air-gapped or
  restricted-egress runners need outbound HTTPS to that host (or a code
  change to short-circuit the data source).

## Azure authentication for the `azurerm` provider

The provider authenticates from environment variables — they are **not**
read from `*.tfvars.hcl`:

```bash
export ARM_SUBSCRIPTION_ID=<subscription-guid>
export ARM_TENANT_ID=<tenant-guid>

# For service-principal auth (skip both when using `az login` /
# `az account set` for interactive auth):
export ARM_CLIENT_ID=<sp-app-id>
export ARM_CLIENT_SECRET=<sp-secret>
```

[terraform/environments/example.tfvars.hcl](../terraform/environments/example.tfvars.hcl) lists
these `ARM_*` names as a copy-paste reference for the variables you need to
export; no values are required from the tfvars file (the operator IP is
auto-detected via ipify, and `allowed_ip_addresses` is optional).

## State

State is currently local (no backend configured). For team use, add an
`azurerm` backend block to [terraform/providers.tf](../terraform/providers.tf);
see [known-gaps.md](known-gaps.md#no-backend-configured).
