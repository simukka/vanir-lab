#!/usr/bin/env bash
# Module 02: one cohort. Idle quota is lent to tenants with a backlog, and
# fair sharing splits the borrowed capacity between them.
source "$(dirname "$0")/../../scripts/lib.sh"
M=02

say "Phase 1: silos again (no cohort), two tenants with a backlog"
#  acme       48  reserved, idle: lends everything
#  nimbus     32  on-demand, 8 × 16-GPU jobs queued (128 GPUs of demand)
#  orbit      16  on-demand, 6 × 16-GPU jobs queued (96 GPUs of demand)
#  serverless 32  inference, 1 replica (8 GPUs) running
cq acme 48
cq nimbus 32
cq orbit 16
cq serverless 32
for t in acme nimbus orbit serverless; do tenant $t; localqueue $t $t; done

serve serverless llm-70b serverless inference 1 8
for i in $(seq 1 8); do job nimbus "train-$i" nimbus on-demand 2 8; done
for i in $(seq 1 6); do job orbit "train-$i" orbit on-demand 2 8; done

eventually 60 "silo state: 56/128 GPUs allocated" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 56 ]]"
snapshot

say "Phase 2: join every ClusterQueue to cohort 'fleet' at the same moment"
# Everything is already pending, so admission order is decided by fair
# sharing (DRS: borrowed share of the cohort's lendable quota), not by who
# submitted first.
# serverless also gets lendingLimit 16 (only valid inside a cohort): it lends
# at most half its quota, so 16 GPUs stay guaranteed to it. One replica uses 8;
# the other 8 stay idle as scale-up headroom that nobody can borrow.
cq acme 48 fleet
cq nimbus 32 fleet
cq orbit 16 fleet
cq serverless 32 fleet 16

eventually 60 "pool state: 120/128 GPUs allocated (8 held back as inference headroom)" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 120 ]]"
sleep 2
snapshot

borrowed() { jp clusterqueue "$1" '{.status.flavorsUsage[0].resources[?(@.name=="nvidia.com/gpu")].borrowed}'; }
nb=$(borrowed nimbus) ob=$(borrowed orbit)
echo "borrowed GPUs: nimbus=$nb orbit=$ob"
[[ $nb -ge 16 && $ob -ge 16 ]] && pass "both backlogged tenants got a share of the lent capacity" \
  || fail "expected both tenants to borrow, got nimbus=$nb orbit=$ob"
lent=$(( nb + ob ))
[[ $lent == 64 ]] && pass "exactly acme's 48 + serverless's lendable 16 were lent" || fail "lent=$lent, expected 64"

cat <<'EOT'

Takeaways
- Same hardware, same demand: 56 → 120 GPUs allocated just by joining a cohort.
- lendingLimit is how a tenant (here: inference) keeps guaranteed headroom.
- Borrowed capacity was split between nimbus and orbit rather than going to
  whoever queued first; that is fairSharing (see cluster/kueue/values.yaml).
- Problem left open: acme now has 0 free GPUs. If acme submits, nothing makes
  room for it, because these queues have no preemption policy. Module 03.
EOT
