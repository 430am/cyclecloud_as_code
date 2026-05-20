# Example Azure service principal credentials for local Terraform use.
# Copy this file to environments/local.tfvars.hcl and replace placeholder
# values with your real Azure service principal credentials.
# Do not commit real credentials to version control.

ARM_SUBSCRIPTION_ID = "00000000-0000-0000-0000-000000000000"
ARM_CLIENT_ID       = "00000000-0000-0000-0000-000000000000"
ARM_CLIENT_SECRET   = "replace-with-client-secret"
ARM_TENANT_ID       = "00000000-0000-0000-0000-000000000000"

# Additional caller IPs / CIDRs to allow on the Key Vault firewall and the
# server-subnet NSG (when access_mode = "public_ip"). The operator's live
# public IP is auto-detected via ipify and merged in automatically, so this
# only needs entries for teammates, CI runners, jump hosts, etc.
# allowed_ip_addresses = ["203.0.113.10", "198.51.100.0/24"]
