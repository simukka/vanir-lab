#!/usr/bin/env bash
# Module 04: perishable compute. Idle reserved capacity is filled with spot and
# health-check work that is always the first to go, then reclaimed for the
# owner. We measure what an eviction notice costs the owner in reclaim latency.
source "$(dirname "$0")/../../scripts/lib.sh"
M=04

RECLAIM='preemption: {reclaimWithinCohort: Any, withinClusterQueue: LowerPriority}'
NEVER='preemption: {reclaimWithinCohort: Never, withinClusterQueue: Never}'

say "Cohort with two zero-quota queues for perishable work"
#  acme       48  reserved, idle → its quota is the perishable capacity
#  nimbus     48  on-demand, using 32
#  serverless 32  inference, lendingLimit 16
#  spot        0  only ever borrows; never preempts anyone
#  ops         0  fleet health checks; borrows, never preempts (as Verda's docs say)
cq acme 48 fleet "" "$RECLAIM"
cq nimbus 48 fleet "" "$RECLAIM"
cq serverless 32 fleet 16 "$RECLAIM"
cq spot 0 fleet "" "$NEVER"
cq ops 0 fleet "" "$NEVER"
for t in acme nimbus serverless spot ops; do tenant $t; localqueue $t $t; done

serve serverless llm-70b serverless inference 1 8
job nimbus od-1 nimbus on-demand 2 8
job nimbus od-2 nimbus on-demand 2 8
eventually 60 "customer work running (40 GPUs)" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 40 ]]"

say "Fill the gaps: 2 health-check sweeps (20 s, capped at 60 s) + 4 spot jobs"
for i in 1 2; do MAX_EXEC=60 job ops "hc-$i" ops healthcheck 1 8 20s; done
for i in 1 2 3 4; do job spot "spot-$i" spot spot 2 8; done
eventually 60 "pool full: 120/128 (8 = inference headroom)" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 120 ]]"
snapshot

finished() { jp job -n "$1" "$2" '{.status.conditions[?(@.type=="Complete")].status}' | grep -q True; }
eventually 60 "health checks ran in the gap and completed" \
  bash -c "source $LAB_ROOT/scripts/lib.sh; $(declare -f finished); finished ops hc-1 && finished ops hc-2"

# latency <ns> <job>: prints "<admitted-s> <running-s>", both measured from job
# creation. admitted = Kueue reserved quota; running = last pod became Ready,
# i.e. the owner actually has its GPUs.
latency() {
  k get workloads,pods -n "$1" -o json | python3 -Ic '
import sys, json
from datetime import datetime
ts = lambda s: datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
job = sys.argv[1]
items = json.load(sys.stdin)["items"]
w = next(i for i in items if i["kind"] == "Workload" and i["metadata"]["ownerReferences"][0]["name"] == job)
t0 = ts(w["metadata"]["creationTimestamp"])
adm = next(c for c in w["status"]["conditions"] if c["type"] == "Admitted" and c["status"] == "True")
ready = [c["lastTransitionTime"] for p in items if p["kind"] == "Pod"
         and p["metadata"]["labels"].get("job-name") == job
         for c in p["status"].get("conditions", []) if c["type"] == "Ready" and c["status"] == "True"]
print(int((ts(adm["lastTransitionTime"]) - t0).total_seconds()),
      int((max(map(ts, ready)) - t0).total_seconds()))
' "$2"
}
running_pods() { k get pods -n "$1" -l job-name="$2" --field-selector=status.phase=Running --no-headers | wc -l; }
victims() {
  k get workloads -A -o json | python3 -Ic '
import sys, json
print(" ".join(sorted({w["metadata"]["namespace"] for w in json.load(sys.stdin)["items"]
  if any(c["type"] == "Preempted" and c["status"] == "True" for c in w["status"].get("conditions", []))})))'
}

say "A) No notice (Verda spot today): acme reclaims 32 GPUs"
job acme reserved-1 acme reserved 4 8
eventually 60 "all 4 acme pods running" \
  bash -c "source $LAB_ROOT/scripts/lib.sh; $(declare -f running_pods); [[ \$(running_pods acme reserved-1) == 4 ]]"
read -r adm_a lat_a < <(latency acme reserved-1)
v=$(victims)
echo "admitted after ${adm_a}s, GPUs in hand after ${lat_a}s   preempted tenants: $v"
[[ $v == spot ]] && pass "only spot was preempted; nimbus on-demand untouched" || fail "victims: $v"

say "B) With notice: spot jobs get a 45 s grace period to checkpoint"
k -n acme delete job reserved-1 --wait=true >/dev/null
k -n spot delete jobs --all --wait=true >/dev/null
for i in 1 2 3 4; do GRACE=45 job spot "spot-g$i" spot spot 2 8; done
# Health checks are done, so spot now holds 64 and 24 GPUs are free: acme
# still needs one spot job (16 GPUs) evicted to fit its 32.
eventually 60 "spot refilled: 104/128 allocated" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 104 ]]"
job acme reserved-2 acme reserved 4 8
sleep 5
echo "5 s after acme submits:"
k get pods -n spot --no-headers | awk '{print "  " $1, $3}' | sort -k2 | head -8
echo "acme pods running: $(running_pods acme reserved-2)/4 (admitted: $(admitted_count acme))"
eventually 90 "all 4 acme pods running after the grace period" \
  bash -c "source $LAB_ROOT/scripts/lib.sh; $(declare -f running_pods); [[ \$(running_pods acme reserved-2) == 4 ]]"
read -r adm_b lat_b < <(latency acme reserved-2)
echo "admitted after ${adm_b}s, GPUs in hand after ${lat_b}s"
snapshot

[[ $lat_a -le 10 ]] && pass "no-notice reclaim: ${lat_a}s" || fail "no-notice reclaim took ${lat_a}s"
[[ $lat_b -ge 40 ]] && pass "graceful reclaim: ${lat_b}s (notice period is paid by the owner)" \
  || fail "graceful reclaim only took ${lat_b}s; expected ≥ 40s"

cat <<EOT

Takeaways
- Zero-quota queues (spot, ops) hold only borrowed capacity, so under fair
  sharing they always have the highest share and are evicted first. This fixes
  module 03's "on-demand evicted before spot" problem.
- Health checks used idle capacity and finished without delaying anyone. Their
  max-exec-time cap keeps a hung sweep from holding capacity forever.
- Kueue admitted acme after ${adm_b}s even with notice: it releases the victim's
  quota at eviction, not when its pods exit. For ~45 s the same GPUs are
  promised twice, and acme's pods sit Pending. The owner-facing number is
  "GPUs in hand", not admission.
- Reclaim latency: no notice ${lat_a}s vs 45 s notice ${lat_b}s. A graceful
  eviction moves the cost from the spot user (lost work) to the reserved owner
  (waiting). A real design needs both a notice window and an SLO for the
  owner, e.g. lend only part of a reservation, or keep a small warm buffer.
- Kueue only marks the workload evicted. The notice itself is just SIGTERM
  plus terminationGracePeriodSeconds. Nothing tells the job *why*, or how long
  it has, in a machine-readable way. Module 07's controller adds that.
EOT
