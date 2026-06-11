# =============================================================================
# Microsoft Entra ID application registration for CycleCloud SSO.
# =============================================================================
# Mirrors Microsoft's reference template (cyclecloud-slurm-workspace
# bicep/entra/ccwEntraApp.json) -- expressed via the hashicorp/azuread
# provider rather than the Microsoft.Graph bicep extension so we stay on a
# single Terraform graph and don't need a side-car bicep deployment.
#
# All resources here are gated on var.entra_auth_enabled. When false
# (the default), no AAD writes happen and the AzureAD provider is never
# exercised beyond the data sources in main.tf.
#
# What this file does NOT do (deliberate scope cut):
#   * Configure the CycleCloud server (cycle_server.properties) to actually
#     consume Entra auth. That requires a stable https:// FQDN, which
#     today's bastion / public_ip access modes do not provide. See
#     docs/entra-auth.md.
#   * Add app users / groups beyond the deployer + var.entra_extra_admin_object_ids.
#     User -> role assignment is an operator-controlled identity policy
#     decision; this module exposes the role IDs as outputs so operators
#     can grant them via az / portal / their preferred IdM tool.
# =============================================================================

locals {
  entra_create = var.entra_auth_enabled ? 1 : 0

  # Stable per-app GUIDs for app roles and the user_access OAuth scope. We
  # build them with uuidv5() over a per-application namespace so:
  #   * IDs survive across plans (deterministic from a stable string).
  #   * Re-running on a different application_name produces different IDs,
  #     avoiding cross-deployment collisions.
  entra_app_name_seed = coalesce(var.entra_app_display_name, "${local.naming_token}-cyclecloud")

  entra_role_ids = {
    Administrator     = uuidv5("dns", "administrator.${local.entra_app_name_seed}")
    SuperUser         = uuidv5("dns", "superuser.${local.entra_app_name_seed}")
    User              = uuidv5("dns", "user.${local.entra_app_name_seed}")
    Global_Node_User  = uuidv5("dns", "global.node.user.${local.entra_app_name_seed}")
    Global_Node_Admin = uuidv5("dns", "global.node.admin.${local.entra_app_name_seed}")
  }

  entra_user_access_scope_id = uuidv5("dns", "user_access.${local.entra_app_name_seed}")

  # Base 3 roles always present; the two Global.Node.* roles are added
  # only when Open OnDemand support is requested.
  entra_app_roles = concat(
    [
      {
        value       = "Administrator"
        id          = local.entra_role_ids.Administrator
        display     = "Administrator"
        description = "CycleCloud Administrator"
      },
      {
        value       = "SuperUser"
        id          = local.entra_role_ids.SuperUser
        display     = "SuperUser"
        description = "CycleCloud SuperUser"
      },
      {
        value       = "User"
        id          = local.entra_role_ids.User
        display     = "User"
        description = "CycleCloud User"
      },
    ],
    var.entra_enable_ondemand ? [
      {
        value       = "Global.Node.User"
        id          = local.entra_role_ids.Global_Node_User
        display     = "Global.Node.User"
        description = "Log in to all nodes as regular user (Open OnDemand)"
      },
      {
        value       = "Global.Node.Admin"
        id          = local.entra_role_ids.Global_Node_Admin
        display     = "Global.Node.Admin"
        description = "Log in to all nodes as administrator (Open OnDemand)"
      },
    ] : []
  )

  # Redirect URIs derived from operator-supplied hostnames. Empty list is
  # valid -- the Authentication blade just won't have SPA entries until
  # the operator adds them (or re-applies after setting the variable).
  entra_spa_redirect_uris = flatten([
    for h in var.entra_cyclecloud_hostnames : [
      "https://${h}/home",
      "https://${h}/sso",
    ]
  ])

  # Microsoft Graph well-known IDs:
  #   00000003-0000-0000-c000-000000000000 -> Microsoft Graph app id
  #   14dad69e-099b-42c9-810b-d002981feec1 -> profile (delegated)
  #   e1fe6dd8-ba31-4d61-89e7-88639da4683d -> User.Read (delegated)
  ms_graph_app_id             = "00000003-0000-0000-c000-000000000000"
  ms_graph_profile_scope_id   = "14dad69e-099b-42c9-810b-d002981feec1"
  ms_graph_user_read_scope_id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
}

# Pin to the Microsoft Graph SP in the deployer's tenant. Required as the
# resource_app_id target on the "Graph delegated permissions" block of
# required_resource_access.
data "azuread_service_principal" "msgraph" {
  count     = local.entra_create
  client_id = local.ms_graph_app_id
}

# -----------------------------------------------------------------------------
# Application object. We deliberately set identifier_uris here using the
# application's own client_id via the self-reference pattern from the
# azuread provider docs (api.known_client_applications is not what we
# want; identifier_uris is set directly because we know the format
# "api://${client_id}" and the provider supports the self-reference).
# -----------------------------------------------------------------------------
resource "azuread_application" "cyclecloud" {
  count        = local.entra_create
  display_name = local.entra_app_name_seed

  # AzureADMyOrg = single-tenant. CycleCloud is an internal admin tool;
  # cross-tenant access is never wanted.
  sign_in_audience = "AzureADMyOrg"

  # PublicClient flag in the manifest. Required for the CLI device-code
  # flow that the cyclecloud CLI uses.
  fallback_public_client_enabled = true

  # ---- Exposed API: user_access scope on api://${client_id} ---------------
  # CycleCloud's docs require requested_access_token_version = 1 (the v2.0
  # access tokens emitted by default are not accepted by the server).
  api {
    requested_access_token_version = 1

    oauth2_permission_scope {
      id                         = local.entra_user_access_scope_id
      value                      = "user_access"
      type                       = "User"
      enabled                    = true
      admin_consent_display_name = "Access Azure CycleCloud"
      admin_consent_description  = "Allow the application to access Azure CycleCloud on behalf of the signed-in user."
      user_consent_display_name  = "Access Azure CycleCloud"
      user_consent_description   = "Allow the application to access Azure CycleCloud on your behalf."
    }
  }

  # ---- App roles (Administrator / SuperUser / User [+ Global.Node.*]) -----
  dynamic "app_role" {
    for_each = { for r in local.entra_app_roles : r.value => r }
    content {
      allowed_member_types = ["User", "Application"]
      description          = app_role.value.description
      display_name         = app_role.value.display
      enabled              = true
      id                   = app_role.value.id
      value                = app_role.value.value
    }
  }

  # ---- Redirect URIs ------------------------------------------------------
  # Public client URIs (CLI / device code) always present. SPA URIs only
  # populated when entra_cyclecloud_hostnames is non-empty.
  public_client {
    redirect_uris = [
      "http://localhost",
      "https://localhost",
    ]
  }

  single_page_application {
    redirect_uris = local.entra_spa_redirect_uris
  }

  # ---- Required resource access ------------------------------------------
  # Microsoft Graph: profile, User.Read (delegated).
  required_resource_access {
    resource_app_id = local.ms_graph_app_id

    resource_access {
      id   = local.ms_graph_profile_scope_id
      type = "Scope"
    }

    resource_access {
      id   = local.ms_graph_user_read_scope_id
      type = "Scope"
    }
  }

  # ---- Optional claims: emit upn in id_token -----------------------------
  optional_claims {
    id_token {
      name      = "upn"
      essential = false
    }
  }

  # We let Azure auto-generate identifier_uris via the separate
  # azuread_application_identifier_uri resource below, because the URI
  # format depends on the application's own client_id (which isn't known
  # until create time). Setting it inline causes "ApplicationsClient.BaseClient
  # ... identifier_uri must be of the form api://{appId}" on first apply.
}

# Add api://${client_id} as the application's identifier URI. Split out so
# the application can be created first (giving us a client_id) and then
# the URI attached. The azuread provider models this as a separate
# resource specifically to avoid the self-reference cycle.
resource "azuread_application_identifier_uri" "cyclecloud" {
  count          = local.entra_create
  application_id = azuread_application.cyclecloud[0].id
  identifier_uri = "api://${azuread_application.cyclecloud[0].client_id}"
}

# Service principal materializes the app in the deployer's tenant so app
# role assignments (below) and end-user sign-in work.
resource "azuread_service_principal" "cyclecloud" {
  count     = local.entra_create
  client_id = azuread_application.cyclecloud[0].client_id

  # Mirrors bicep "Properties -> Assignment Required = Yes" recommendation.
  # Means only users / groups explicitly granted an app role can sign in.
  app_role_assignment_required = true
}

# Auto-grant the deploying user the SuperUser role -- matches the bicep
# template's behaviour and means the operator can log into CycleCloud
# immediately after the apply without a separate identity-side ticket.
resource "azuread_app_role_assignment" "deployer_superuser" {
  count               = local.entra_create
  app_role_id         = local.entra_role_ids.SuperUser
  principal_object_id = data.azuread_user.current_user.object_id
  resource_object_id  = azuread_service_principal.cyclecloud[0].object_id
}

# Optional extra Administrator grants for additional named principals
# (users or groups). Useful for teams; defaults to empty.
resource "azuread_app_role_assignment" "extra_admins" {
  for_each = var.entra_auth_enabled ? toset(var.entra_extra_admin_object_ids) : toset([])

  app_role_id         = local.entra_role_ids.Administrator
  principal_object_id = each.value
  resource_object_id  = azuread_service_principal.cyclecloud[0].object_id
}

# Federated identity credential for Open OnDemand. Lets the OOD VM's
# user-assigned MI exchange its workload-identity token for an
# application-scoped token without storing a client secret. The subject
# is the MI's principal (object) ID; the issuer is the tenant's v2.0
# OIDC endpoint.
resource "azuread_application_federated_identity_credential" "ondemand" {
  count          = var.entra_auth_enabled && var.entra_enable_ondemand ? 1 : 0
  application_id = azuread_application.cyclecloud[0].id
  display_name   = "openondemand-mi"
  description    = "Trust the Open OnDemand VM's user-assigned MI as a federated credential for CycleCloud."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"
  subject        = var.entra_ondemand_mi_principal_id

  # Fail at plan time instead of letting the Graph API reject an empty
  # subject during apply. Only fires when this resource is actually being
  # created (count > 0), so disabled-by-default deployments are unaffected.
  lifecycle {
    precondition {
      condition     = length(var.entra_ondemand_mi_principal_id) > 0
      error_message = "entra_enable_ondemand requires entra_ondemand_mi_principal_id to be set (object ID of the Open OnDemand UAI)."
    }
  }
}

