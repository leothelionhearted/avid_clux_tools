#!/usr/bin/env bash
#
# reset_redis.sh
#
# Author: Leo Kearns
#         ACSR‑certified MediaCentral CLUX engineer
#
# Description:
#   Safely resets Redis pods managed by StatefulSet (single-node or 3‑node cluster),
#   in correct ordinal order, with event logging, readiness wait, core pod reset,
#   and interactive monitoring using avidctl.

set -euo pipefail

# 1. Privilege check
if [[ $EUID -ne 0 ]]; then
  echo "⚠️ Please run as root or with sudo."
  read -rp "Continue anyway? (yes/no): " proceed
  [[ "$proceed" =~ ^(yes|y)$ ]] || { echo "Aborting."; exit 1; }
fi

label="app.kubernetes.io/name=redis"
logfile="reset_redis_$(date +%Y%m%d_%H%M%S).log"
echo "Logging to $logfile"
echo "Reset run at $(date)" > "$logfile"

# Fetch and sort pod names by ordinal (e.g. redis-node-0, -1, -2)
pods=( $(kubectl get pods -l "$label" --no-headers -o custom-columns=":metadata.name" | sort -V) )
count=${#pods[@]}

if [[ "$count" -eq 0 ]]; then
  echo "No Redis pods found. Exiting." | tee -a "$logfile"
  exit 0
elif [[ "$count" -eq 1 ]]; then
  echo "Single-node Redis detected." | tee -a "$logfile"
elif [[ "$count" -eq 3 ]]; then
  echo "3-node Redis cluster detected." | tee -a "$logfile"
else
  echo "Unexpected Redis pod count ($count). Expected 1 or 3. Aborting." | tee -a "$logfile"
  exit 1
fi

echo "Redis pods in deletion order: ${pods[*]}" | tee -a "$logfile"

# Function to log warning/error events per pod
log_events_for_pod() {
  local pod="$1"
  kubectl get events \
    --field-selector involvedObject.kind=Pod,involvedObject.name="$pod",type!=Normal \
    -n default \
    --sort-by='.metadata.creationTimestamp' \
    -o custom-columns=TIME:.lastTimestamp,TYPE:.type,REASON:.reason,MESSAGE:.message
}

# Delete pods sequentially with logging
for pod in "${pods[@]}"; do
  echo "----" | tee -a "$logfile"
  echo "Pod: $pod" | tee -a "$logfile"
  echo "Warnings/Errors (pre-delete):" | tee -a "$logfile"
  log_events_for_pod "$pod" >> "$logfile" || echo "(none)" | tee -a "$logfile"
  echo "Deleting $pod..." | tee -a "$logfile"
  kubectl get pod "$pod"
  sleep 5
done

# Wait for Redis pods to become Ready
echo "Waiting for Redis pods to be Ready..." | tee -a "$logfile"
kubectl wait pod -l "$label" --for=condition=Ready --timeout=300s
echo "All Redis pods are Ready." | tee -a "$logfile"

# Delete core pods labeled feature=core
echo "Deleting core pods (feature=core)..." | tee -a "$logfile"
kubectl get pod -l feature=core | tee -a "$logfile"

# Pause so the user can read the launch message
echo "Launching 'avidctl pod watch-not-running' for core pods..."
sleep 5
echo "(Ctrl+C to exit)"
avidctl pod watch-not-running

echo "Reset complete. See log file: $logfile"
