# Example tfvars for a standalone deployment with operator-controlled
# overrides. Copy to environments/local.tfvars.hcl and edit. Do NOT commit
# real credentials or IPs to version control.
#
# For spoke (hub-and-spoke landing zone) deployments, start from
# environments/spoke.tfvars.hcl instead -- it has the hub schema filled in.

# ---------------------------------------------------------------------------
# Provider credentials
# ---------------------------------------------------------------------------
# These are azurerm provider environment variables, NOT Terraform input
# variables. They're listed here for convenience so a single file documents
# the full local setup; export them before running terraform, e.g.:
#
#   set -a; source environments/local.tfvars.hcl; set +a
#
# Skip the CLIENT_* pair entirely if you authenticate via `az login`.
ARM_SUBSCRIPTION_ID = "00000000-0000-0000-0000-000000000000"
ARM_TENANT_ID       = "00000000-0000-0000-0000-000000000000"
ARM_CLIENT_ID       = "00000000-0000-0000-0000-000000000000"
ARM_CLIENT_SECRET   = "replace-with-client-secret"

# ---------------------------------------------------------------------------
# Naming + region
# ---------------------------------------------------------------------------
# Leave application_name empty to fall back to a random_pet token (good for
# parallel lab deploys). Set it to a stable string for shared environments.
# application_name = "ccdev"
# location         = "southcentralus"

# ---------------------------------------------------------------------------
# Topology
# ---------------------------------------------------------------------------
# deployment_mode = "standalone" (default) builds its own VNet, private DNS
# zones, Log Analytics workspace, AMPLS, and monitoring storage. Flip to
# "spoke" only if you also fill in the `hub` block below; see
# environments/spoke.tfvars.hcl for the canonical spoke example and
# docs/hub-spoke.md for the design.
# deployment_mode = "standalone"

# Spoke-only -- the entire `hub` block is ignored when
# deployment_mode = "standalone". Required (non-null) when "spoke".
# hub = {
#   subscription_id = "00000000-0000-0000-0000-000000000000"
#   # tenant_id     = "00000000-0000-0000-0000-000000000000"  # only if hub is in a different tenant
#
#   virtual_network = {
#     id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/hub-rg/providers/Microsoft.Network/virtualNetworks/hub-vnet"
#     # allow_forwarded_traffic = true   # default: true   (needed when hub firewall forwards spoke traffic)
#     # use_remote_gateways     = false  # default: false  (true => use hub ER/VPN gateways)
#     # create_reverse_peering  = true   # default: true   (false => hub team manages hub->spoke side themselves)
#   }
#
#   monitoring = {
#     log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/hub-mon-rg/providers/Microsoft.OperationalInsights/workspaces/hub-law"
#   }
# }

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
# Default is 10.150.0.0/16. In spoke mode this MUST NOT overlap with the hub
# VNet or any other peered spoke -- VNet peering rejects overlapping spaces.
# vnet_address_space = ["10.150.0.0/16"]

# ---------------------------------------------------------------------------
# Access mode
# ---------------------------------------------------------------------------
# How to reach the CycleCloud VM. See docs/access-modes.md.
#   public_ip  (default) -- Standard public IP on the VM NIC, NSG opens
#                           22/8080/8443 from allowed_ip_addresses + the
#                           auto-detected operator IP.
#   bastion              -- Azure Bastion (Standard, tunneling enabled); no
#                           public IP on the VM.
#   private_ip           -- No public IP, no Bastion. Reach the VM over hub
#                           peering only. Requires deployment_mode = "spoke".
#                           Also disables Key Vault public network access
#                           (PE only) -- see docs/known-gaps.md for the
#                           reachability implications.
# access_mode = "bastion"

# Additional caller IPs / CIDRs to allow on the Key Vault firewall and the
# server-subnet NSG. The operator's live public IP is auto-detected via
# ipify and merged in automatically, so this only needs entries for
# teammates, CI runners, jump hosts, etc.
#
# Ignored in access_mode = "private_ip" (KV public access is disabled and
# the NSG operator rule is not created).
# allowed_ip_addresses = ["203.0.113.10", "198.51.100.0/24"]

# ---------------------------------------------------------------------------
# Tags (merged with the built-in deployed_by tag)
# ---------------------------------------------------------------------------
# tags = {
#   managed_by = "terraform"
#   project    = "cyclecloud testing"
#   workload   = "Azure CycleCloud"
#   owner      = "your-team"
# }
