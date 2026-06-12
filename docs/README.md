# Docs

Operator-facing documentation for `cyclecloud_as_code`. The root
[README.md](../README.md) covers project overview, architecture, and a
five-line quickstart; deeper how-tos and reference material live here.

| Doc | Read when |
|---|---|
| [prerequisites.md](prerequisites.md) | Setting up a fresh workstation or CI runner — Terraform version, Azure CLI auth, required RBAC, what `var.current_ip_address` is for |
| [deploying.md](deploying.md) | Cloning the repo, authoring tfvars, and running `terraform init / plan / apply` |
| [access-modes.md](access-modes.md) | Choosing between `bastion` and `public_ip`, opening the web UI |
| [ssh-key.md](ssh-key.md) | Pulling the generated SSH private key out of Key Vault and using it with `ssh` / `ssh-agent` / Bastion tunneling |
| [variables.md](variables.md) | Reference for every input variable and the naming convention applied to each resource |
| [post-deploy.md](post-deploy.md) | What the cloud-init bootstrap does, how to verify it finished, and how to log into the CycleCloud web UI |
| [testing.md](testing.md) | How tests are organized (static checks, `terraform test`, planned E2E) and how to run them locally |
| [entra-auth.md](entra-auth.md) | Opt-in Microsoft Entra ID app registration for CycleCloud SSO — what gets created, what's deferred, and the variables to set |
| [troubleshooting.md](troubleshooting.md) | Symptoms we've actually hit and the fixes that worked — UI hangs after login, Bastion tunnel lag, `bastionConnect.sh` exiting silently, bootstrap failures, NFS mount issues |
| [known-gaps.md](known-gaps.md) | Intentional rough edges and TODOs (KV firewall posture, cluster automation, NSG coverage, etc.) |

## Conventions used in these docs

- Relative links: `[](deploying.md)` between docs, `[](../README.md)` back
  to the project root, `[](../terraform/<file>.tf)` to source.
- Every doc starts with a one-sentence purpose statement so it stands on
  its own when reached via a deep link.
- Commands assume the working directory called out at the top of each
  shell block (usually `terraform/` or `post-config/`).
