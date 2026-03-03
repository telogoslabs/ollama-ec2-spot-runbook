#!/usr/bin/env bash
set -euo pipefail

# Dedicated log file (override with LOG_FILE env var)
LOG_FILE="${LOG_FILE:-$HOME/ollama-bootstrap.log}"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting Ollama bootstrap $(date -Iseconds)"

# User-data overrides
: "${OLLAMA_MODELS_DIR:=/opt/dlami/nvme/ollama/models}"
: "${MODEL_PULLS:=glm-4.7-flash:bf16,qwen3.5:122b,qwen3-coder-next:q8_0}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

apt-get install -y nvtop || true

if ! command -v ollama >/dev/null 2>&1; then
  echo "[INFO] Installing Ollama"
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "[INFO] Ollama already present"
fi

if ! command -v opencode >/dev/null 2>&1; then
  echo "[INFO] Installing OpenCode"
  curl -fsSL https://opencode.ai/install | bash
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "[INFO] Installing Claude CLI"
  curl -fsSL https://claude.ai/install.sh | bash
fi

echo "[INFO] Preparing model directory: $OLLAMA_MODELS_DIR"
mkdir -p "$OLLAMA_MODELS_DIR"
OLLAMA_BASE_DIR="$(dirname "$OLLAMA_MODELS_DIR")"

if id -u ollama >/dev/null 2>&1; then
  chown -R ollama:ollama "$OLLAMA_BASE_DIR"
else
  chown -R root:root "$OLLAMA_BASE_DIR"
fi
chmod -R 755 "$OLLAMA_BASE_DIR"

mkdir -p /etc/systemd/system/ollama.service.d
tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_MODELS=$OLLAMA_MODELS_DIR"
EOF

systemctl daemon-reload
systemctl enable ollama
systemctl restart ollama

# Wait for service to settle
for _ in {1..30}; do
  if systemctl is-active --quiet ollama; then
    break
  fi
  sleep 2
done

if ! systemctl is-active --quiet ollama; then
  echo "[ERROR] Ollama did not start"
  systemctl status ollama --no-pager || true
  exit 1
fi

echo "[INFO] Effective service env"
systemctl show ollama | grep OLLAMA_MODELS || true

# Optional pre-pulls; keep empty by default to reduce boot risk on Spot
if [[ -n "$MODEL_PULLS" ]]; then
  IFS=',' read -r -a models <<<"$MODEL_PULLS"
  for model in "${models[@]}"; do
    model_trimmed="$(echo "$model" | xargs)"
    [[ -n "$model_trimmed" ]] || continue
    echo "[INFO] Pulling model: $model_trimmed"
    if ! ollama pull "$model_trimmed"; then
      echo "[ERROR] Pull failed: $model_trimmed"
      exit 1
    fi
  done
fi

echo "[INFO] Bootstrap complete $(date -Iseconds)"
