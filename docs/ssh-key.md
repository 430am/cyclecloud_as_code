# SSH private key

Pulling the generated SSH private key out of Key Vault and using it.

The key pair is generated as an in-memory `ephemeral.tls_private_key` (see
[terraform/ssh.tf](../terraform/ssh.tf)) and **never written to Terraform
state**. The private and public keys are stored in Key Vault as write-only
secrets; the public key is also injected into the VM's `admin_ssh_key`
block at apply time.

## 1. Download the key from Key Vault

```bash
cd terraform   # so `terraform output` works

KEY_FILE=~/.ssh/cyclecloud.pem

az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name      "$(terraform output -raw ssh_private_key_secret_name)" \
  --query value -o tsv > "$KEY_FILE"

chmod 600 "$KEY_FILE"
```

A convenience wrapper that does the same thing lives at
[post-config/downloadSSH.sh](../post-config/downloadSSH.sh):

```bash
cd post-config && ./downloadSSH.sh
```

It `cd`s into `../terraform` so `terraform output` resolves, writes
`~/.ssh/cyclecloud.pem`, and `chmod 600`s the result — useful after a fresh
`terraform apply` or whenever you need to re-pull the key onto a new
workstation.

> Note: the Key Vault firewall is currently `default_action = "Allow"`
> (see [known-gaps.md](known-gaps.md#key-vault-firewall)), so the
> `az keyvault secret show` call above succeeds from any source IP. The
> `ip_rules` allow list (configured + auto-detected operator IP via
> `data.http.current_ip`) is still computed in
> [terraform/locals.tf](../terraform/locals.tf) so that tightening
> `default_action` back to `Deny` is a one-line change.

## 2a. Use the key for a single SSH command

```bash
cd terraform

ADMIN=$(terraform output -raw cyclecloud_vm_admin_username)
IP=$(terraform output -raw cyclecloud_vm_public_ip)   # public_ip mode only

ssh -i ~/.ssh/cyclecloud.pem "$ADMIN@$IP"
```

## 2b. Load the key into `ssh-agent` for the rest of your session

Loading the key into the agent means you can omit `-i` on subsequent `ssh`,
`scp`, `rsync`, and `git` invocations:

```bash
# Start an agent if one isn't already running in this shell
eval "$(ssh-agent -s)"

# Add the key (prompts for a passphrase only if the key has one — these don't)
ssh-add ~/.ssh/cyclecloud.pem

# Verify it's loaded
ssh-add -l

# Now you can SSH without -i
ssh "$ADMIN@$IP"
```

The key stays in the agent until the shell exits (or `ssh-add -D` is run).
To persist across shells, add an entry to `~/.ssh/config`:

```sshconfig
Host cyclecloud
  HostName        <vm-public-ip-or-private-ip>
  User            cyclecloudadmin
  IdentityFile    ~/.ssh/cyclecloud.pem
  IdentitiesOnly  yes
  # When using Bastion tunneling on a local port, also add:
  # ProxyCommand none
  # Port         2222
```

Then simply `ssh cyclecloud`.

## 2c. SSH over Azure Bastion tunneling

When `access_mode = "bastion"` the VM has no public IP. Open a tunnel that
forwards a local port to port 22 on the VM, then SSH to `localhost`:

```bash
cd terraform

RG=$(terraform output -raw resource_group_name)
BAS=$(terraform output -raw bastion_host_name)
VM_ID=$(az vm show -g "$RG" -n "$(terraform output -raw cyclecloud_vm_name)" --query id -o tsv)
ADMIN=$(terraform output -raw cyclecloud_vm_admin_username)

# Forward localhost:2222 -> VM:22 (leave running in its own terminal)
az network bastion tunnel \
  --name "$BAS" --resource-group "$RG" \
  --target-resource-id "$VM_ID" \
  --resource-port 22 --port 2222 &

ssh -p 2222 -i ~/.ssh/cyclecloud.pem "$ADMIN@localhost"
```
