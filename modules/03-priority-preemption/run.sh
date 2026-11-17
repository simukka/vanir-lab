#!/usr/bin/env bash
# Module 03: lenders take their quota back. Preemption policies on the
# ClusterQueues decide who gets evicted when a lender (reserved customer,
# inference) needs capacity that is currently lent out.
source "$(dirname "$0")/../../scripts/lib.sh"
M=03

POLICY='preemption: {reclaimWithinCohort: Any, withinClusterQueue: LowerPriority}'

say "Full pool: every GPU outside inference headroom is in use, 64 of them borrowed"
cq acme 48 fleet "" "$POLICY"
cq nimbus 32 fleet "" "$POLICY"
cq orbit 16 fleet "" "$POLICY"
cq serverless 32 fleet 16 "$POLICY"
for t in acme nimbus orbit serverless; do tenant $t; localqueue $t $t; done

serve serverless llm-70b serverless inference 1 8
# nimbus mixes on-demand and spot work; orbit runs on-demand only.
job nimbus od-1 nimbus on-demand 2 8
job nimbus od-2 nimbus on-demand 2 8
job nimbus spot-1 nimbus spot 2 8
job nimbus spot-2 nimbus spot 2 8
job orbit od-1 orbit on-demand 2 8
job orbit od-2 orbit on-demand 2 8
job orbit od-3 orbit on-demand 2 8

eventually 90 "120/128 GPUs allocated" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 120 ]]"
snapshot

# evictions: print every workload that has been preempted, oldest first.
evictions() {
  k get workloads -A -o json | python3 -Ic '
import sys, json
rows = []
for w in json.load(sys.stdin)["items"]:
    for c in w.get("status", {}).get("conditions", []):
        if c["type"] == "Preempted" and c["status"] == "True":
            rows.append((c["lastTransitionTime"], w["metadata"]["namespace"],
                         w["metadata"]["ownerReferences"][0]["name"],
                         w["spec"].get("priorityClassRef", {}).get("name", "?"),
                         c["type"], c.get("reason", ""), c.get("message", "")[:90]))
for r in sorted(rows):
    print("  %s  %-6s %-7s %-10s %s" % (r[0][11:19], r[1], r[2], r[3], r[5]))
'
}

say "acme (reserved, lent all 48) comes back and needs 32 GPUs"
job acme reserved-1 acme reserved 4 8
eventually 60 "acme's reserved job admitted" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; admitted_count acme) == 1 ]]"
echo "Evictions so far:"; evictions

say "serverless scales 1 → 3 replicas (+16 GPUs: 8 from headroom, 8 reclaimed)"
k -n serverless scale deploy/llm-70b --replicas=3 >/dev/null
eventually 60 "3 inference replicas admitted" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; admitted_count serverless) == 3 ]]"
sleep 3
snapshot
echo "All evictions:"; evictions

victims=$(evictions | awk '$2!="" {print $2}' | sort -u | tr '\n' ' ')
[[ $victims != *acme* && $victims != *serverless* ]] \
  && pass "only borrowing tenants were preempted (victims: ${victims})" \
  || fail "a lender was preempted: $victims"
[[ $(admitted_count nimbus) -ge 2 && $(admitted_count orbit) -ge 1 ]] \
  && pass "borrowers kept their nominal quota" || fail "a borrower lost nominal quota"

cat <<'EOT'

Takeaways
- reclaimWithinCohort lets a lender evict borrowers to get its nominal quota
  back. Without it (module 02) acme would just wait.
- Victims are workloads running on *borrowed* quota. Nominal quota is never
  taken, whatever the priority. That's the contract a reserved customer buys.
- With fairSharing enabled, Kueue first picks the borrower whose share is
  highest, then the lowest-priority workloads inside it. Compare the eviction
  list with the priorities: spot in one queue is not necessarily evicted
  before on-demand in another.
- Every eviction above was instant: no notice, no checkpoint window. That is
  Verda's spot behaviour today. Module 04 adds a grace period.
EOT
