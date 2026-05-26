#!/bin/bash
set -euo pipefail

# Convenience wrapper that pulls the ephemeral SSH private key from Key Vault
# into ~/.ssh/cyclecloud.pem. See docs/ssh-key.md.
#
# NOTE: In access_mode = "private_ip" (spoke deployments) the Key Vault has
# public network access disabled. This script must run from somewhere with
# network reachability to the spoke's KV private endpoint (hub jumpbox,
# ExpressRoute, VPN, peered VNet) and DNS that resolves the vault FQDN to
# the PE. From an unrelated workstation the `az` call will fail with a
# 403 / connect timeout. See:
#   docs/known-gaps.md#key-vault-reachability-in-private_ip-mode
#   docs/hub-spoke.md#reaching-the-vm-and-kv-from-your-workstation

cd ../terraform   # so terraform output works
KEY_FILE=~/.ssh/cyclecloud.pem
az keyvault secret show --vault-name "$(terraform output -raw key_vault_name)" --name "$(terraform output -raw ssh_private_key_secret_name)" --query value -o tsv > "$KEY_FILE"
chmod 600 "$KEY_FILE"