#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/ollama-runbook-clone.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting runbook clone setup $(date -Iseconds)"

TARGET_USER="ubuntu"
RUNBOOK_DIR="/home/$TARGET_USER/ollama-ec2-spot-runbook"

git clone "https://github.com/telogoslabs/ollama-ec2-spot-runbook.git" "$RUNBOOK_DIR"
chown -R "$TARGET_USER:$TARGET_USER" "$RUNBOOK_DIR"

echo "[INFO] Runbook available at $RUNBOOK_DIR"
echo "[INFO] Next: sudo -u $TARGET_USER bash $RUNBOOK_DIR/scripts/user_data_ollama_prod.sh"
echo "[INFO] Clone setup complete $(date -Iseconds)"
