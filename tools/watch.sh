#!/usr/bin/env bash
# Live view of the lab: ClusterQueues, workloads and per-rack GPU allocation.
# Usage: tools/watch.sh [--once]
set -euo pipefail
cd "$(dirname "$0")/.."
CTX=kind-vanir
k() { kubectl --context "$CTX" "$@"; }

snapshot() {
  echo "== ClusterQueues"
  k get clusterqueue -o custom-columns='NAME:.metadata.name,COHORT:.spec.cohortName,PENDING:.status.pendingWorkloads,ADMITTED:.status.admittedWorkloads,GPU_USED:.status.flavorsUsage[0].resources[?(@.name=="nvidia.com/gpu")].total,GPU_BORROWED:.status.flavorsUsage[0].resources[?(@.name=="nvidia.com/gpu")].borrowed' 2>/dev/null || true
  echo
  echo "== Workloads"
  k get workloads -A -l '!vanir.lab/ignore' \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.ownerReferences[0].name,PRIO:.spec.priorityClassRef.name,QUEUE:.spec.queueName,ADMITTED:.status.conditions[?(@.type=="Admitted")].status,EVICTED:.status.conditions[?(@.type=="Evicted")].reason,FINISHED:.status.conditions[?(@.type=="Finished")].status' 2>/dev/null || true
  echo
  echo "== GPU map (one char per GPU, letter = tenant, . = idle)"
  k get nodes,pods -A -o json | python3 -I tools/gpu-map.py
}

if [[ "${1:-}" == "--once" ]]; then
  snapshot
else
  export -f snapshot k; export CTX
  watch -n 2 -t bash -c snapshot
fi
