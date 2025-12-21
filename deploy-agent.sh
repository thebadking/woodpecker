#!/usr/bin/env bash

set -euo pipefail

BINARY_LOCAL="dist/woodpecker-agent-amd64"
BINARY_REMOTE="/usr/local/bin/woodpecker-agent"
SERVICE_NAME="woodpecker-agent.service"

# Optional: set user, leave empty to use current user
SSH_USER=""

SERVERS=(
  "ru.safemetrics.app"
  "ae.safemetrics.app"
  "kk.safemetrics.app"
  "main.safemetrics.app"
)

if [[ ! -f "$BINARY_LOCAL" ]]; then
  echo "Local binary not found: $BINARY_LOCAL"
  exit 1
fi

LOCAL_SHA=$(sha256sum "$BINARY_LOCAL" | awk '{print $1}')

for SERVER in "${SERVERS[@]}"; do
  TARGET="${SSH_USER:+$SSH_USER@}$SERVER"

  echo "---- Deploying to $SERVER ----"

  scp "$BINARY_LOCAL" "$TARGET:/tmp/woodpecker-agent"

  ssh "$TARGET" bash <<EOF
set -euo pipefail

ROLLBACK_NEEDED=false

rollback() {
  if [[ "\$ROLLBACK_NEEDED" == "true" ]]; then
    echo "Rolling back on $SERVER"
    sudo mv -f ${BINARY_REMOTE}.bak $BINARY_REMOTE
    sudo systemctl start $SERVICE_NAME
  fi
}

trap rollback ERR

if [[ -f "$BINARY_REMOTE" ]]; then
  sudo cp "$BINARY_REMOTE" "${BINARY_REMOTE}.bak"
  ROLLBACK_NEEDED=true
fi

sudo systemctl stop $SERVICE_NAME

sudo install -m 755 /tmp/woodpecker-agent $BINARY_REMOTE
sudo rm -f /tmp/woodpecker-agent

REMOTE_SHA=\$(sha256sum $BINARY_REMOTE | awk '{print \$1}')
if [[ "$LOCAL_SHA" != "\$REMOTE_SHA" ]]; then
  echo "Checksum mismatch"
  exit 1
fi

sudo systemctl start $SERVICE_NAME
sudo systemctl is-active --quiet $SERVICE_NAME

if [[ "\$ROLLBACK_NEEDED" == "true" ]]; then
  sudo rm -f ${BINARY_REMOTE}.bak
fi

echo "Deployment successful on $SERVER"
EOF

done

echo "All deployments completed successfully"
