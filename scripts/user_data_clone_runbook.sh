#!/usr/bin/env bash
set -euo pipefail

# Root user-data helper: clone/update runbook into the target user's home.
LOG_FILE="${LOG_FILE:-/var/log/ollama-runbook-clone.log}"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting runbook clone setup $(date -Iseconds)"

: "${RUNBOOK_REPO_URL:=https://github.com/telogoslabs/ollama-ec2-spot-runbook.git}"
: "${TARGET_USER:=ubuntu}"
: "${TARGET_GROUP:=$TARGET_USER}"
: "${RUNBOOK_DIR:=/home/$TARGET_USER/ollama-ec2-spot-runbook}"

export DEBIAN_FRONTEND=noninteractive
if ! command -v git >/dev/null 2>&1; then
  echo "[INFO] Installing git"
  apt-get update -y
  apt-get install -y git
fi

echo "[INFO] Ensuring runbook repository at $RUNBOOK_DIR"
mkdir -p "$(dirname "$RUNBOOK_DIR")"

if [[ -d "$RUNBOOK_DIR/.git" ]]; then
  echo "[INFO] Updating existing repository"
  git -C "$RUNBOOK_DIR" fetch --all --prune
  git -C "$RUNBOOK_DIR" reset --hard origin/main
elif [[ -d "$RUNBOOK_DIR" ]]; then
  echo "[WARN] $RUNBOOK_DIR exists but is not a git repository; skipping clone"
else
  echo "[INFO] Cloning repository"
  git clone "$RUNBOOK_REPO_URL" "$RUNBOOK_DIR"
fi

if id -u "$TARGET_USER" >/dev/null 2>&1; then
  chown -R "$TARGET_USER:$TARGET_GROUP" "$RUNBOOK_DIR"
else
  echo "[WARN] User $TARGET_USER not found; skipping chown"
fi

echo "[INFO] Runbook available at $RUNBOOK_DIR"
echo "[INFO] Next: sudo -u $TARGET_USER bash $RUNBOOK_DIR/scripts/user_data_ollama_prod.sh"
echo "[INFO] Clone setup complete $(date -Iseconds)"
