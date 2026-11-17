#!/usr/bin/env bash
# Module 01: silos. Every tenant gets a fixed slice of the fleet, no sharing.
source "$(dirname "$0")/../../scripts/lib.sh"
M=01

say "Create four silos (128 GPUs total), each a ClusterQueue with no cohort"
#  acme      48 GPUs  reserved instant-cluster customer (idle right now)
#  nimbus    32 GPUs  on-demand training customer (has a backlog)
#  serverless 32 GPUs inference pool
#  hpclab    16 GPUs  Slinky-style Slurm cluster: slurmd pods hold whole nodes
for spec in acme:48 nimbus:32 serverless:32 hpclab:16; do
  name=${spec%%:*} gpus=${spec##*:}
  k apply -f - >/dev/null <<EOF
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: $name
  labels: {vanir.lab/module: "$M"}
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: [cpu, memory, nvidia.com/gpu]
    flavors:
    - name: h200
      resources:
      - {name: cpu, nominalQuota: "$((gpus * 16))"}
      - {name: memory, nominalQuota: "$((gpus * 256))Gi"}
      - {name: nvidia.com/gpu, nominalQuota: "$gpus"}
EOF
  tenant "$name"
  localqueue "$name" "$name"
done

say "Workloads"
# nimbus: 6 two-node training jobs (16 GPUs each) = 96 GPUs of demand.
for i in 1 2 3 4 5 6; do job nimbus "train-$i" nimbus on-demand 2 8; done
# serverless: 2 inference replicas of 8 GPUs.
serve serverless llm-70b serverless inference 2 8
# hpclab: Slinky gives each slurmd pod a whole node, whether Slurm runs jobs or not.
serve hpclab slurmd hpclab reserved 2 8
# acme: reserved but idle. Nothing submitted.

eventually 60 "nimbus fills its 32-GPU silo (2 jobs admitted)" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; admitted_count nimbus) == 2 ]]"
eventually 60 "inference + slurmd pods are running" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 64 ]]"
sleep 3

snapshot

pending=$(pending_count nimbus)
alloc=$(gpus_allocated)
[[ $pending == 4 ]] && pass "nimbus has 4 jobs (64 GPUs) stuck pending" || fail "expected 4 pending, got $pending"
idle=$((128 - alloc))
[[ $idle -ge 64 ]] && pass "$idle GPUs sit idle while nimbus waits (acme's 48 + serverless headroom 16)" \
  || fail "expected >=64 idle GPUs, got $idle"
cat <<'EOT'

Takeaway: utilisation is capped by the silo boundaries, not by demand.
Also note hpclab: its 16 GPUs show as "allocated" even though Slurm is running
no jobs. Allocated != busy, and the Slinky whole-node model hides that from K8s.
Next: module 02 puts the silos in one cohort so idle quota can be lent.
EOT
