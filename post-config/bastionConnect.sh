#!/bin/bash
# Open a multiplexed HTTP forward to the CycleCloud VM via Bastion.
#
#   layer 1: `az network bastion tunnel` forwards localhost:50022 -> VM:22
#   layer 2: `ssh -L 8080:localhost:8080` over that tunnel; all browser
#            sockets multiplex through one SSH connection (one Bastion WS),
#            which is materially snappier than `az network bastion tunnel`
#            forwarding 8080 directly (a fresh WS per browser socket).
#
# Run ./downloadSSH.sh first so the private key is on disk.

set -euo pipefail

cd ../terraform # so terraform output works
RG=$(terraform output -raw resource_group_name)
VM_NAME=$(terraform output -raw cyclecloud_vm_name)
VM_ID=$(az vm show -g "$RG" -n "$VM_NAME" --query id -o tsv)
BAS=$(terraform output -raw bastion_host_name)
SSH_USER=$(terraform output -raw cyclecloud_vm_admin_username)
KEY=~/.ssh/cyclecloud.pem

LOCAL_SSH_PORT=50022
LOCAL_WEB_PORT=8080

if [[ ! -f "$KEY" ]]; then
  echo "ERROR: $KEY not found -- run ./downloadSSH.sh first" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${TUNNEL_PID:-}" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "[cleanup] stopping bastion tunnel (pid $TUNNEL_PID)"
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "[1/3] starting bastion tunnel: localhost:$LOCAL_SSH_PORT -> $VM_NAME:22"
az network bastion tunnel \
  --name "$BAS" --resource-group "$RG" \
  --target-resource-id "$VM_ID" \
  --resource-port 22 --port "$LOCAL_SSH_PORT" &
TUNNEL_PID=$!

echo "[2/3] waiting for tunnel to accept connections"
tunnel_up=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/$LOCAL_SSH_PORT) 2>/dev/null; then
    exec 3<&- 3>&-
    echo "      tunnel up after ${i}s"
    tunnel_up=1
    break
  fi
  sleep 1
done
if [[ "$tunnel_up" -ne 1 ]]; then
  echo "ERROR: bastion tunnel never came up on port $LOCAL_SSH_PORT" >&2
  exit 1
fi

echo "[3/3] forwarding http://localhost:$LOCAL_WEB_PORT -> $VM_NAME:8080"
echo "      Ctrl-C here to disconnect."
ssh -i "$KEY" -p "$LOCAL_SSH_PORT" -N \
  -L "${LOCAL_WEB_PORT}:localhost:8080" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts_cyclecloud" \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  "$SSH_USER@localhost"