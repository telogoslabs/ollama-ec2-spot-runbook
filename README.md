# Ollama EC2 Spot Runbook

Run Ollama on AWS GPU Spot with a repeatable bootstrap script and a simple operational workflow.

This repository contains:

- `scripts/user_data_clone_runbook.sh` — root user-data script to clone/update this repo into `/home/ubuntu`
- `scripts/user_data_ollama_prod.sh` — bootstrap script for runtime setup
- `orig-readme.md` — early notes and planning source

## EC2 User Data (Root): Clone Runbook Only

Use this in EC2 user data so the runbook is available when you log in as `ubuntu`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_USER=ubuntu
RUNBOOK_DIR=/home/$TARGET_USER/ollama-ec2-spot-runbook
RUNBOOK_REPO_URL=https://github.com/telogoslabs/ollama-ec2-spot-runbook.git

export DEBIAN_FRONTEND=noninteractive
if ! command -v git >/dev/null 2>&1; then
	apt-get update -y
	apt-get install -y git
fi

if [[ -d "$RUNBOOK_DIR/.git" ]]; then
	git -C "$RUNBOOK_DIR" fetch --all --prune
	git -C "$RUNBOOK_DIR" reset --hard origin/main
elif [[ ! -d "$RUNBOOK_DIR" ]]; then
	git clone "$RUNBOOK_REPO_URL" "$RUNBOOK_DIR"
fi

id -u "$TARGET_USER" >/dev/null 2>&1 && chown -R "$TARGET_USER:$TARGET_USER" "$RUNBOOK_DIR"
```

After SSH login as `ubuntu`:

```bash
cd /home/ubuntu/ollama-ec2-spot-runbook
bash ./scripts/user_data_ollama_prod.sh
```

## Goals

- Start quickly on AWS GPU Spot
- Keep setup reproducible
- Maintain a practical model workflow for large artifacts
- Keep operational steps simple and CLI-driven

## Recommended Target

- Instance family: `g7e` (example: `g7e.2xlarge`)
- OS baseline: Ubuntu 22.04 DLAMI with CUDA support
- Access pattern: SSH/CLI only

References:

- https://aws.amazon.com/ec2/instance-types/g7e/
- https://docs.aws.amazon.com/dlami/latest/devguide/aws-deep-learning-x86-base-with-single-cuda-ami-ubuntu-22-04.html

## What the Script Does

`scripts/user_data_ollama_prod.sh` performs the following:

1. Installs optional utility package (`nvtop`)
2. Installs Ollama, OpenCode, and Claude CLI if missing
3. Configures Ollama model path through a systemd override
4. Reloads/restarts `ollama` service and validates health
5. Pulls configured models **sequentially** (one at a time)


## Default Model Pull List

By default, the script pre-pulls:

- `glm-4.7-flash:bf16`
- `qwen3.5:122b`
- `qwen3-coder-next:q8_0`

Model links:

- https://ollama.com/library/glm-4.7-flash:bf16
- https://ollama.com/library/qwen3.5:122b
- https://ollama.com/library/qwen3-coder-next:q8_0

## Environment Variables

- `LOG_FILE` (default: `$HOME/ollama-bootstrap.log`)
- `OLLAMA_MODELS_DIR` (default: `/opt/dlami/nvme/ollama/models`)
- `MODEL_PULLS` (default: the 3-model list above)

Examples:

```bash
# disable pre-pulls
MODEL_PULLS="" ./scripts/user_data_ollama_prod.sh

# override model path and custom pull list
OLLAMA_MODELS_DIR=/data/ollama/models \
MODEL_PULLS="glm-4.7-flash:bf16,qwen3-coder-next:q8_0" \
./scripts/user_data_ollama_prod.sh
```

## Launch Prerequisites

Before running on EC2, verify:

- SSH key pair available locally
- Security group allows SSH from your source IP
- EBS sizing is sufficient for model artifacts
- Spot interruption behavior is understood

## Typical Usage

After SSH into the instance:

```bash
cd /home/ubuntu/ollama-ec2-spot-runbook
bash ./scripts/user_data_ollama_prod.sh
```

Check status:

```bash
tail -n 200 ~/ollama-bootstrap.log
systemctl status ollama --no-pager
systemctl show ollama | grep OLLAMA_MODELS
```

## Storage Strategy

- Use attached EBS/NVMe for active model files
- Use S3 as cold storage/archive if you tear down frequently
- Keep at least one known-good baseline model easily available

## Spot Reliability Notes

- Large models can take significant time to pull
- Sequential pulls are slower, but logs are cleaner and behavior is more predictable
- For large-model workflows, validate `nvidia-smi` and run a quick prompt test before heavy use

## Validation Checklist

- `nvidia-smi` shows expected GPU
- `ollama` CLI is available
- `systemctl is-active ollama` reports active
- Baseline model pull completes
- A basic inference prompt succeeds

## Teardown Checklist

- Persist anything needed before terminate/stop
- Stop idle GPU instances to control cost
- Track AMI/EBS/S3 storage growth over time
