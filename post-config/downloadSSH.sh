#!/bin/bash
set -euo pipefail

cd ../terraform   # so terraform output works
KEY_FILE=~/.ssh/cyclecloud.pem
az keyvault secret show --vault-name "$(terraform output -raw key_vault_name)" --name "$(terraform output -raw ssh_private_key_secret_name)" --query value -o tsv > "$KEY_FILE"
chmod 600 "$KEY_FILE"