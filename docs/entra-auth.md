# Entra ID authentication

Opt-in Microsoft Entra ID app registration for CycleCloud single sign-on.

## What this enables

Setting `entra_auth_enabled = true` creates everything the CycleCloud web
UI needs on the **identity side** to authenticate users via Entra ID:

| Resource | Purpose |
|---|---|
| `azuread_application.cyclecloud` | The app registration itself. Exposes the `user_access` OAuth2 scope on `api://{client_id}` with v1.0 access tokens (CycleCloud rejects v2.0). |
| App roles | `Administrator`, `SuperUser`, `User`. With `entra_enable_ondemand = true`, also `Global.Node.User`, `Global.Node.Admin`. |
| Redirect URIs | `http://localhost`, `https://localhost` always (CLI device-code flow). One `https://<host>/home` + `https://<host>/sso` pair per entry in `entra_cyclecloud_hostnames` (SPA flow). |
| `azuread_service_principal.cyclecloud` | Materializes the app in your tenant; `app_role_assignment_required = true` means only granted users/groups can sign in. |
| `azuread_app_role_assignment.deployer_superuser` | Auto-grants the user running `terraform apply` the `SuperUser` role so they can log in immediately after deploy. |
| `azuread_app_role_assignment.extra_admins` | Optional `Administrator` grants for `var.entra_extra_admin_object_ids`. |
| `azuread_application_federated_identity_credential.ondemand` | OOD-only. Trusts the Open OnDemand VM's user-assigned MI so OOD can OIDC-auth without a client secret. |

Microsoft Graph delegated permissions (`profile`, `User.Read`) and the
`upn` optional ID-token claim are configured automatically.

The mapping to Microsoft's reference template is intentional — this
matches the `ccwEntraApp.json` bicep that ships with
`cyclecloud-slurm-workspace`, but is expressed via the `hashicorp/azuread`
provider so the whole deployment stays on a single Terraform graph.

## What this does NOT do (yet)

The Terraform plan stops at the identity side. It does **not** configure
the CycleCloud server (`/opt/cycle_server/config/cycle_server.properties`)
to consume Entra auth. That is a deliberate scope cut:

- Entra SPA redirect URIs must be `https://` FQDNs. None of the current
  access modes (`bastion`, `public_ip`) produces a usable HTTPS endpoint
  on their own — CycleCloud's apt build doesn't ship a TLS keystore, so
  port 8443 is dead, and bastion has no public hostname at all.
- The natural pair is the proposed `access_mode = "app_gateway"`, which
  terminates TLS at an Application Gateway with a Key Vault cert. The
  server-side bootstrap edits will land alongside that mode.

Until then, after a successful apply you can either (a) wire CycleCloud
manually via the UI's *Settings → Authentication* using the values
emitted by the `entra_*` outputs, or (b) skip server-side enablement and
just validate the app registration with the `https://localhost` redirect
URI / `cyclecloud` CLI device-code flow.

The `entra_next_steps` output prints copy-pasteable commands for the
manual server-side config when you're ready.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `entra_auth_enabled` | `false` | Master toggle. When false, no AAD resources are created. |
| `entra_app_display_name` | `""` | App registration display name. Falls back to `<naming_token>-cyclecloud`. |
| `entra_cyclecloud_hostnames` | `[]` | FQDNs to populate SPA redirect URIs (`https://<host>/home`, `https://<host>/sso`). Empty is valid — you can add hostnames later. |
| `entra_enable_ondemand` | `false` | Adds the two `Global.Node.*` roles and a federated identity credential for Open OnDemand. |
| `entra_ondemand_mi_principal_id` | `""` | Object ID of the OOD VM's user-assigned MI. Required iff `entra_enable_ondemand = true`; plan fails otherwise. |
| `entra_extra_admin_object_ids` | `[]` | Additional Entra user/group object IDs to auto-grant the `Administrator` app role. |

## Outputs

After `terraform apply` with `entra_auth_enabled = true`:

```text
entra_tenant_id                    -> Directory (tenant) ID
entra_client_id                    -> Application (client) ID
entra_application_object_id        -> App registration object ID
entra_service_principal_object_id  -> Enterprise application object ID (for role assignments)
entra_app_role_ids                 -> Map of role value -> GUID
entra_redirect_uris                -> { public_client = [...], single_page_application = [...] }
entra_next_steps                   -> Manual server-side config commands
```

When `entra_auth_enabled = false`, every `entra_*` output is `null` (or
`{}` for the role-id map). This is asserted by the `terraform test`
suite — see [tests/locals.tftest.hcl](../terraform/tests/locals.tftest.hcl).

## Required permissions on the deployer

The principal running `terraform apply` must be able to write to the
directory (the existing AzureRM-only deployer SP is *not* enough):

- `Application.ReadWrite.OwnedBy` (or admin equivalent) — create the app
  registration and service principal.
- `AppRoleAssignment.ReadWrite.All` — auto-grant the deployer
  `SuperUser` (and any `entra_extra_admin_object_ids` users
  `Administrator`).

In tenants with restricted-app-registration policies, the deployer may
also need to be in a directory role that allows new app registrations
(e.g. "Application Developer" or "Cloud Application Administrator").

## Assigning users / groups to roles post-deploy

The module auto-grants only the deployer (`SuperUser`) and any explicit
`entra_extra_admin_object_ids` (`Administrator`). To add more users or
groups, use the values emitted by the outputs:

```bash
# Grant a user the "User" role
az ad app-role assignment create \
  --app-role-id   $(terraform output -raw entra_app_role_ids | jq -r .User) \
  --principal-id  <user-or-group-object-id> \
  --resource-id   $(terraform output -raw entra_service_principal_object_id)
```

Or do it through the portal: *Enterprise applications → \<app name\> →
Users and groups → Add user/group*.

## Tearing it down

`terraform destroy` removes the app registration, service principal,
role assignments, and FIC in the standard reverse-dependency order. No
manual cleanup is needed — including no orphaned enterprise application,
which is the most common manual-cleanup footgun when removing app
registrations via the portal.
