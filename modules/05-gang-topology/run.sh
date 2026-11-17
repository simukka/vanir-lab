#!/usr/bin/env bash
# Module 05: gang scheduling + topology-aware placement, and the fragmentation
# that strict topology creates.
source "$(dirname "$0")/../../scripts/lib.sh"
M=05

cq train 128 "" "" 'preemption: {withinClusterQueue: LowerPriority}'
tenant train; localqueue train train

# racks_of <job>: distinct racks the job's pods landed on.
racks_of() {
  k get pods -n train -l job-name="$1" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | sed -E 's/gpu-(b[0-9]+)-(r[0-9]+)-.*/\1-\2/' | sort -u | grep -c . || true
}
running_pods() { k get pods -n train -l job-name="$1" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l; }
export -f racks_of running_pods

say "A) Fragment the fleet: 16 single-node jobs, then free one node per rack"
for i in $(seq -w 1 16); do job train "fill-$i" train on-demand 1 8; done
eventually 60 "fleet full (128/128)" bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 128 ]]"
# Delete the fill job on host h0 of every rack.
for node in gpu-b0-r0-h0 gpu-b0-r1-h0 gpu-b1-r0-h0 gpu-b1-r1-h0; do
  j=$(k get pods -n train --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.labels.job-name}')
  k -n train delete job "$j" --wait=true >/dev/null
done
eventually 30 "32 GPUs free, 8 in each rack" bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 96 ]]"
snapshot | sed -n '/GPU map/,$p'

say "B) 32-GPU gang that REQUIRES one rack: enough GPUs in total, but no rack fits"
TOPO=required:vanir.lab/rack job train gang-rack train on-demand 4 8
sleep 8
k get workloads -n train -o json | python3 -Ic '
import sys, json
for w in json.load(sys.stdin)["items"]:
    if w["metadata"]["ownerReferences"][0]["name"] != "gang-rack": continue
    for c in w["status"].get("conditions", []):
        if c["type"] == "QuotaReserved": print("  QuotaReserved:", c["status"], "-", c["message"][:160])'
[[ $(running_pods gang-rack) == 0 ]] && pass "gang is all-or-nothing: 0/4 pods started" || fail "partial gang started"

say "C) Same gang with PREFERRED rack: admitted, but spread across racks"
TOPO=preferred:vanir.lab/rack job train gang-pref train on-demand 4 8
eventually 30 "preferred gang running" bash -c "[[ \$(running_pods gang-pref) == 4 ]]"
n=$(racks_of gang-pref)
echo "  gang-pref spans $n racks (all-reduce crosses the spine)"
[[ $n -gt 1 ]] && pass "preferred placement degraded to $n racks" || fail "expected spread, got $n rack"

say "D) Defragment: drain rack b1-r1 (delete its fill jobs) → required gang fits"
k -n train delete job gang-pref --wait=true >/dev/null
for node in gpu-b1-r1-h1 gpu-b1-r1-h2 gpu-b1-r1-h3; do
  j=$(k get pods -n train --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.labels.job-name}')
  [[ -n $j ]] && k -n train delete job "$j" --wait=true >/dev/null
done
eventually 30 "required-rack gang running" bash -c "[[ \$(running_pods gang-rack) == 4 ]]"
n=$(racks_of gang-rack)
[[ $n == 1 ]] && pass "gang-rack placed inside a single rack" || fail "gang-rack spans $n racks"
snapshot | sed -n '/GPU map/,$p'

cat <<'EOT'

Takeaways
- Gang admission is all-or-nothing. A half-started 4-node job would only burn
  GPUs while it waits for NCCL peers.
- "Free GPUs" is the wrong capacity metric. With 32 free GPUs, the largest
  rack-local slot was 8. Fragmentation = 1 - largest_placeable / free.
- required vs preferred is a product decision: wait for locality (queue time)
  or run now on a worse fabric (step time). On GB300 NVL72 the unit is the
  NVLink domain (a rack); leaving it costs an order of magnitude in bandwidth, so
  "required" is often the only sensible option.
- Getting back to a fit took deliberate draining. A real scheduler needs a
  defrag policy: pack small jobs into partially used racks, or preempt
  spot/backfill to clear a domain for a large gang.
EOT
