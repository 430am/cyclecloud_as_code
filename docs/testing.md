# Testing

How tests are organized in this repo, how to run them locally, and what
each tier guarantees.

The strategy is layered so the cheap checks catch most regressions and
the expensive ones are reserved for real deploys.

## Tier 1 - static checks (seconds, no Azure)

Run locally via [pre-commit](https://pre-commit.com/) (a GitHub Actions
workflow that runs the same gates on every PR is planned but not yet
wired up):

| Check | Catches |
|---|---|
| `terraform fmt -check -recursive` | style drift |
| `terraform validate` | HCL + provider schema errors |
| [`tflint`](https://github.com/terraform-linters/tflint) (config in [.tflint.hcl](../.tflint.hcl)) | unused vars, deprecated args, invalid Azure SKUs, naming-convention violations, missing descriptions |
| [`trivy config`](https://trivy.dev/) | security misconfig (public storage, weak TLS, etc.). Advisory only today -- accepted findings will move to `.trivyignore` once CI lands |

First-time setup and full-repo run:

```bash
pip install pre-commit
pre-commit install                  # wires the hooks into .git/hooks
pre-commit run --all-files          # one-shot full-repo run
```

See [.pre-commit-config.yaml](../.pre-commit-config.yaml).

## Tier 2 - `terraform test` plan-only (subsecond, no Azure)

Tests under [terraform/tests/](../terraform/tests/) stub the `azurerm` /
`azuread` / `http` providers via `mock_provider` and assert on planned
outputs. No Azure credentials are needed. Run from `terraform/`:

```bash
terraform init -backend=false       # first time only
terraform test
```

See [terraform/tests/README.md](../terraform/tests/README.md) for the
current coverage and a list of recommended additions (PE / DNS-zone
invariant, NSG rule surface, cloud-init render, etc.).

## Tier 3 - end-to-end apply (minutes, real Azure, on demand)

Not yet implemented. Planned as a `workflow_dispatch` GitHub Actions
workflow wired to a dedicated scratch subscription via OIDC federation,
with one job per `access_mode` and an unconditional `terraform destroy`
in cleanup. Track this under [known-gaps.md](known-gaps.md) if you
start the work.
