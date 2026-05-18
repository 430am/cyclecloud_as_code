ephemeral "tls_private_key" "cyclecloud_ephemeral" {
  algorithm = "ED25519"
}

ephemeral "tls_public_key" "cyclecloud_ephemeral" {
  private_key_openssh = ephemeral.tls_private_key.cyclecloud_ephemeral.private_key_openssh
}