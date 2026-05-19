# Deploying

End-to-end deployment flow: clone, configure, apply. Assumes
[prerequisites.md](prerequisites.md) is satisfied.

## Getting the code

First-time clone:

```bash
# Clone via SSH (preferred — matches the existing remote in this repo)
git clone git@github.com:430am/cyclecloud_testing.git
cd cyclecloud_testing

# ...or via HTTPS
git clone https://github.com/430am/cyclecloud_testing.git
cd cyclecloud_testing
```

Pull upstream changes on subsequent updates:

```bash
# Fast-forward your local main with whatever is on the remote
git checkout main
git pull --ff-only origin main
```

If you are working on a fork and `origin` points at your fork, add the
upstream once and sync from it:

```bash
git remote add upstream git@github.com:430am/cyclecloud_testing.git   # one-time
git fetch upstream
git checkout main
git merge --ff-only upstream/main
git push origin main                                                  # optional
```

After pulling, re-run `terraform init -upgrade` inside `terraform/` if
provider versions in [terraform/providers.tf](../terraform/providers.tf)
changed, then `terraform plan` to see whether anything needs to be applied.

## Deploying

```bash
cd terraform

# 1. Author your tfvars (do not commit)
cp environments/example.tfvars.hcl environments/local.tfvars.hcl
# edit current_ip_address (must be a valid IPv4, e.g. "203.0.113.10")

# 2. Auth + plan
export ARM_SUBSCRIPTION_ID=<your-sub-id>
az login
terraform init
terraform plan  -var-file=environments/local.tfvars.hcl
terraform apply -var-file=environments/local.tfvars.hcl
```

Outputs (see [terraform/outputs.tf](../terraform/outputs.tf)) include the
CycleCloud VM private IP, Bastion host name, and Key Vault URI — everything
you need to reach the server.

## Next steps

- Choose how you'll reach the VM: [access-modes.md](access-modes.md).
- Pull the SSH key out of Key Vault: [ssh-key.md](ssh-key.md).
- Watch the cloud-init bootstrap finish and log into the web UI:
  [post-deploy.md](post-deploy.md).
