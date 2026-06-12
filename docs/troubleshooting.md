# Troubleshooting

Things that have bitten this project, with the fix that worked.

If you hit something not listed here, the four diagnostic surfaces that
cover most of it are:

1. Browser DevTools (F12 → Network, tick *Preserve log*) when the UI
   misbehaves.
2. `az vm run-command invoke ... --command-id RunShellScript --scripts '...'`
   from your workstation — works without SSH, works even when the VM is
   only reachable via Bastion.
3. `/var/log/cc-bootstrap.log` on the VM — the timestamped per-stage
   transcript from [scripts/cc-bootstrap.sh.tftpl](../scripts/cc-bootstrap.sh.tftpl).
4. `/opt/cycle_server/logs/application.log` on the VM — the CycleCloud
   JVM's own log.

---

## Web UI hangs after sign-in (page never finishes loading)

You authenticate with the username + password from Key Vault, the spinner
runs, and the page never reaches the dashboard.

### 1. Look at the network panel first

In the browser, **F12** → **Network** → tick **Preserve log** → submit
the form again. The two giveaways:

- A request stuck on **Pending** — note its URL. Common offenders are
  `/home`, `/ui/...`, and `/messaging` (the UI's long-poll endpoint).
- A **302** redirecting you to a hostname other than `localhost:8080`
  (for example the VM's internal name, or `https://...:8443`). CycleCloud
  occasionally redirects to a hostname your browser can't reach, and the
  page just spins. The CC8 package on this image only listens on **HTTP
  8080** — port 8443 isn't bound until a TLS keystore is configured (see
  [known-gaps.md](known-gaps.md#https-on-8443-is-not-configured-out-of-the-box)).

Also check the **Console** tab for CSP / mixed-content / WebSocket
errors. Browser extensions (ad-blockers, privacy tools) can also block
`/messaging` long-polls — reproduce in an **InPrivate** window with
extensions disabled before going further.

### 2. Hit the API directly through the same tunnel

While the tunnel is up:

```bash
curl -i http://localhost:8080/ui/metadata
curl -i -u cyclecloudadmin:'<password>' http://localhost:8080/cloud/api/cloudProviders
```

- Both `200` → the server is healthy; the problem is in the browser
  (stale cookie, extension, cached service worker). Clear cookies for
  `localhost` and retry in InPrivate.
- `/ui/metadata` is `200` but the authenticated call hangs or returns
  `401` → the user record didn't land. Go to step 3.
- `/ui/metadata` non-`200` → the cycle_server REST layer never came up
  cleanly. Go to step 3.

### 3. Verify the bootstrap actually finished

`terraform apply` shouldn't return until `/var/lib/cc-bootstrap.done`
exists, but confirm. From your workstation (no SSH needed):

```bash
cd terraform
RG=$(terraform output -raw resource_group_name)
VM=$(terraform output -raw cyclecloud_vm_name)

az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript --scripts '
    ls -la /var/lib/cc-bootstrap.done /var/lib/cc-bootstrap.failed 2>&1
    ls /opt/cycle_server/config/data/account_data.json* 2>&1
    /opt/cycle_server/cycle_server status
    ss -ltnp | grep -E ":(8080|8443)"
    tail -n 80 /var/log/cc-bootstrap.log
  '
```

What you want to see:

- `cc-bootstrap.done` present, **no** `cc-bootstrap.failed`.
- `account_data.json.imported` (renamed by `cycle_server` once it
  processes the record — see stage 3 of
  [scripts/cc-bootstrap.sh.tftpl](../scripts/cc-bootstrap.sh.tftpl)). If
  it's still `account_data.json`, the admin user and
  `cycleserver.installation.complete=true` row never landed, and the UI
  sits waiting for the setup wizard that the bootstrap was supposed to
  skip.
- `cycle_server status` reports **Running**.
- Port **8080** listening; **8443** not listening is expected here.

### 4. Inspect the cycle_server application logs

```bash
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript --scripts '
    sudo tail -n 100 /opt/cycle_server/logs/application.log
    sudo tail -n 50  /opt/cycle_server/logs/cycle_server.out
  '
```

Look for stack traces around the timestamp you clicked *Sign in*.

### 5. Likely fixes

- **Stale Bastion tunnel** — Ctrl-C [post-config/bastionConnect.sh](../post-config/bastionConnect.sh)
  and re-run it. The Azure CLI tunnel occasionally wedges after the first
  request burst.
- **Browser session stuck** — close all tabs to `localhost:8080`, clear
  cookies for `localhost`, reopen in InPrivate.
- **Bootstrap half-finished** — re-run it idempotently:

  ```bash
  az vm run-command invoke -g "$RG" -n "$VM" \
    --command-id RunShellScript --scripts '
      sudo rm -f /var/lib/cc-bootstrap.done /var/lib/cc-bootstrap.failed
      sudo /usr/local/sbin/cc-bootstrap.sh
    '
  ```

---

## Bastion web tunnel feels slow / laggy

`az network bastion tunnel` opens a fresh WebSocket through Bastion for
**every** inbound TCP connection. Browsers open 6+ parallel connections
per origin, so every page load pays that WebSocket-setup cost six times
over and the UI feels gluey.

### Fix: use the two-layer multiplexed connect script

[post-config/bastionConnect.sh](../post-config/bastionConnect.sh) opens
the Bastion tunnel to **SSH (port 22)** instead of 8080, then runs a
plain `ssh -L 8080:localhost:8080` over it. All browser sockets multiplex
over the single SSH connection, which is materially snappier:

```bash
cd post-config
./downloadSSH.sh        # once per deploy
./bastionConnect.sh
```

Then browse to <http://localhost:8080>.

See [access-modes.md](access-modes.md#option-a-bastion-access_mode--bastion)
for the full Bastion access flow.

### Optional: scale up Bastion

[terraform/bastion.tf](../terraform/bastion.tf) doesn't set
`scale_units`, so the host runs on the Standard SKU default of **2**.
Each scale unit adds throughput and concurrent-session headroom; Standard
accepts 2–50. To raise it, add `scale_units = 4` (or higher) to the
`azurerm_bastion_host` block. Scale units are billed per hour — 4 units
is roughly 2× the Standard base cost.

### `bastionConnect.sh` exits silently with no output

A prior version of the script used:

```bash
az network bastion ssh ... -- -N -L 8080:localhost:8080
```

Some `az` / bastion-extension versions silently **drop** the args after
`--`. With no `-N` and no command, OpenSSH connects, finds nothing to
do, and exits **0** — `set -e` doesn't fire because nothing failed.

The current [post-config/bastionConnect.sh](../post-config/bastionConnect.sh)
sidesteps this by running `az network bastion tunnel` to forward
**port 22** in the background, then running a normal local `ssh -L`
against the forwarded port. Both layers are visible processes you can
strace, log, or kill independently.

If the script still dies silently after the rewrite, run with tracing
and a known-good extension:

```bash
az extension add --name bastion --upgrade
az --version | head
bash -x ./bastionConnect.sh 2>&1 | tee /tmp/bastion.log
```

If layer 1 (`[1/3]`) succeeds but layer 2 (`[3/3]`) fails, replace `-N`
with `-v` temporarily to see the SSH handshake:

```bash
ssh -i ~/.ssh/cyclecloud.pem -p 50022 -v cyclecloudadmin@localhost
```

The usual SSH-side culprits are the key not being `chmod 600`, the wrong
admin username, or a stale `known_hosts` entry (the rewrite uses a
dedicated `~/.ssh/known_hosts_cyclecloud` to avoid that — delete it if
you've redeployed the VM).

---

## `terraform apply` hangs at `null_resource.cyclecloud_ready`

`apply` polls the VM every 20 s via `az vm run-command` looking for
`/var/lib/cc-bootstrap.done` (or fast-fail on `/var/lib/cc-bootstrap.failed`).
A long hang means the cloud-init `runcmd` never reached the sentinel.

### Cloud-init didn't finish

```bash
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript --scripts '
    cloud-init status --long
    tail -n 200 /var/log/cloud-init-output.log
  '
```

Two failure modes that have actually bitten this project (both fixed in
[scripts/cloud-config.yaml.tftpl](../scripts/cloud-config.yaml.tftpl), worth
knowing if you edit the cloud-config):

- **`gpg --dearmor` prompts on `/dev/tty`** when the Microsoft keyring
  already exists from the `az` installer. cloud-init has no TTY, so it
  hangs forever. Always pass `--yes` to `gpg --dearmor`.
- **`set -o pipefail` / `trap ... ERR` in `runcmd`** — cloud-init runs
  `runcmd` under `/bin/sh` (dash on Ubuntu), which doesn't support
  either. Wrap blocks that need them in a `/bin/bash <<'BASH_EOF' ...
  BASH_EOF` here-doc.

### Bootstrap failed but the sentinel isn't there

`cc-bootstrap.sh` writes `/var/lib/cc-bootstrap.failed` on `trap ERR`.
If it's present, look at `/var/log/cc-bootstrap.log` for the FATAL line.
Common cause: the VM's managed identity hadn't been granted Key Vault
Secrets User yet when stage 1 ran. Re-run after the RBAC has propagated:

```bash
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript --scripts '
    sudo rm -f /var/lib/cc-bootstrap.done /var/lib/cc-bootstrap.failed
    sudo /usr/local/sbin/cc-bootstrap.sh
  '
```

---

## `Settings → Subscriptions` is empty in the web UI

The bootstrap got far enough to create the admin user (or you wouldn't
have logged in) but `cyclecloud account create` didn't register the
subscription. Usually a transient RBAC propagation race on the VM's
identity.

Re-run the whole bootstrap idempotently (see the snippet just above).
If it keeps failing, check that the CycleCloud Orchestrator role
assignment from [terraform/roles.tf](../terraform/roles.tf) is present
on **both** the VM's system-assigned MI and the user-assigned identity
at subscription scope.

---

## `az keyvault secret show` returns Forbidden

The caller doesn't have **Key Vault Administrator** (or
**Key Vault Secrets User**) on the vault.
[terraform/roles.tf](../terraform/roles.tf) grants Administrator to the
deploying principal at apply time, but the assignment can take a minute
to propagate. Wait, then retry. If it's still 403, confirm you're using
the right tenant:

```bash
az account show --query '{name:name, user:user.name, tenant:tenantId}'
```

The Key Vault firewall is currently `default_action = "Allow"` (see
[known-gaps.md](known-gaps.md#key-vault-firewall)), so source IP is not
the problem today. If you've flipped it to `Deny`, your egress IP needs
to be in `var.allowed_ip_addresses` (or auto-detected via
`data.http.current_ip`).

---

## `az network bastion tunnel` exits with `Forbidden`

The signed-in principal doesn't have **Reader** on the Bastion host
**and** **Virtual Machine User Login** (or **Contributor**) on the
target VM, or `tunneling_enabled` was never set. The Bastion host in
this repo already has `tunneling_enabled = true`
([terraform/bastion.tf](../terraform/bastion.tf)) and requires Standard
SKU — confirm both before chasing RBAC.

---

## NFS mount hangs or returns Permission denied

The shares from [terraform/files.tf](../terraform/files.tf) are
NFSv4.1-only, reachable on **port 2049** via the file private endpoint.
Common causes:

- Mounting from a host that isn't in the `server` or `cluster` subnet —
  the file PE only resolves inside the VNet.
- `nfs-common` not installed (`sudo apt-get install -y nfs-common`).
- Wrong mount options. Use exactly:

  ```bash
  sudo mount -t nfs -o vers=4,minorversion=1,sec=sys \
    "${SA}.file.core.windows.net:/${SA}/sched" /sched
  ```

  `sec=sys` is required — NFSv4.1 on Azure Files uses POSIX (uid/gid)
  authentication, not Kerberos.

See [post-deploy.md](post-deploy.md#mounting-the-nfs-shares-sched-and-shared)
for the full mount procedure.
