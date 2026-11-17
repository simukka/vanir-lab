#!/usr/bin/env bash
# Module 06: an inference traffic burst scales serving above its quota, spot
# backfill makes room, then refills the gap when traffic drops. Everything
# lands in VictoriaMetrics / Grafana.
source "$(dirname "$0")/../../scripts/lib.sh"
M=06

if ! k -n monitoring get deploy grafana >/dev/null 2>&1; then
  say "Installing observability (VictoriaMetrics + Grafana)"
  "$LAB_ROOT/scripts/obs-up.sh"
fi

RECLAIM='preemption: {reclaimWithinCohort: Any, withinClusterQueue: LowerPriority}'
NEVER='preemption: {reclaimWithinCohort: Never, withinClusterQueue: Never}'

say "Cohort: inference can grow past its nominal 32 by borrowing"
cq acme 48 fleet "" "$RECLAIM"
cq nimbus 48 fleet "" "$RECLAIM"
cq serverless 32 fleet 24 "$RECLAIM"
cq spot 0 fleet "" "$NEVER"
for t in acme nimbus serverless spot; do tenant $t; localqueue $t $t; done

serve serverless llm-70b serverless inference 1 8
job nimbus od-1 nimbus on-demand 2 8
job nimbus od-2 nimbus on-demand 2 8
for i in 1 2 3 4 5; do job spot "backfill-$i" spot spot 2 8; done
eventually 90 "pool full: 120/128 (inference 8, training 32, spot 80)" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 120 ]]"
snapshot | sed -n '/GPU map/,$p'

say "Traffic burst: queue 2 → 12 at t=30s, back to 2 at t=150s (threshold 2/replica)"
echo "Grafana: kubectl -n monitoring port-forward svc/grafana 3000:3000 → http://localhost:3000"
summary=$(python3 -I "$LAB_ROOT/tools/queue-autoscaler.py" --deploy serverless/llm-70b \
  --profile 0:2,30:12,150:2 --threshold 2 --max 6 --duration 210 | tee /dev/stderr | tail -1)

snapshot | sed -n '/GPU map/,$p'

vmq() { # vmq <promql>: scalar result from VictoriaMetrics
  k get --raw "/api/v1/namespaces/monitoring/services/vmsingle:http/proxy/api/v1/query?query=$(python3 -Ic 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")" \
    | python3 -Ic 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)'
}

max_ready=$(echo "$summary" | python3 -Ic 'import sys,json; print(json.load(sys.stdin)["max_ready"])')
lat=$(echo "$summary" | python3 -Ic 'import sys,json; s=json.load(sys.stdin)["scaleups"]; print(max([x["seconds"] for x in s] or [-1]))')
spot_evictions=$(vmq 'sum(increase(kueue_evicted_workloads_total{cluster_queue="spot"}[10m]))')
nimbus_evictions=$(vmq 'sum(increase(kueue_evicted_workloads_total{cluster_queue="nimbus"}[10m])) or vector(0)')
peak_borrow=$(vmq 'max_over_time((sum(kueue_cluster_queue_resource_usage{cluster_queue="serverless",resource="nvidia.com/gpu"}) - 32)[5m:10s])')
echo "max ready replicas=$max_ready  slowest scale-up=${lat}s  spot evictions=$spot_evictions  nimbus evictions=$nimbus_evictions  serverless peak borrow=${peak_borrow} GPUs"

[[ $max_ready == 6 ]] && pass "inference reached 6 replicas (48 GPUs, 16 above nominal)" || fail "max ready $max_ready"
python3 -Ic "import sys; sys.exit(0 if float('$spot_evictions') > 0 else 1)" \
  && pass "spot backfill was evicted to make room (seen in Kueue metrics)" || fail "no spot evictions recorded"
python3 -Ic "import sys; sys.exit(0 if float('$nimbus_evictions') == 0 else 1)" \
  && pass "on-demand training was not touched" || fail "nimbus was evicted"
eventually 60 "backfill refilled the gap after the burst (≥112/128 allocated)" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) -ge 112 ]]"

cat <<EOT

Takeaways
- Inference borrowed ${peak_borrow} GPUs above its nominal quota. Under fair
  sharing it could preempt spot (which holds only borrowed quota), but not
  on-demand training running within its own quota.
- Scale-up latency (desired → ready) was ${lat}s including preemption. On real
  hardware add model load time: weights from cache/NVMe take tens of seconds
  to minutes. That's why inference keeps unlendable headroom (lendingLimit).
- After the burst the spot jobs were readmitted automatically: capacity
  moved backfill → inference → backfill without a human.
- Open Grafana (dashboard "vanir-lab: shared GPU pool") to see queue depth,
  borrowed GPUs per queue and evictions per minute line up with the burst.
EOT
