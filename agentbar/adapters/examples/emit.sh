#!/usr/bin/env bash
# Report a long job to AgentBar from any shell script.
# Simplest: wrap the command and AgentBar shows started / done / failed:
#     agentbar run -- ./train.sh
# Or report steps yourself:
set -euo pipefail
SESSION="nightly-$(date +%s)"
ab() { agentbar emit --agent nightly-job --session "$SESSION" --title "nightly" "$@" || true; }

ab --event started --message "Backing up the database"
sleep 2
ab --event working --message "Uploading backup"
sleep 2
ab --event finished --message "Backup uploaded"
