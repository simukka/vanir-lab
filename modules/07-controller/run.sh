#!/usr/bin/env bash
# Module 07: deploy the eviction-notice controller and rerun module 04's
# graceful reclaim. Victim pods now learn why and by when they must exit, and
# the real reclaim latency becomes a metric.
source "$(dirname "$0")/../../scripts/lib.sh"
M=07
HERE="$LAB_ROOT/modules/07-controller"

say "Build + load controller image"
docker build -q -t vanir.lab/eviction-notice:dev "$HERE" >/dev/null
kind load docker-image vanir.lab/eviction-notice:dev --name vanir >/dev/null
k apply -f "$HERE/config/deploy.yaml" >/dev/null
k -n vanir-system rollout restart deploy/eviction-notice >/dev/null
k -n vanir-system rollout status deploy/eviction-notice --timeout=120s

if k -n monitoring get deploy vmsingle >/dev/null 2>&1; then
  k apply -f "$LAB_ROOT/cluster/observability/victoriametrics.yaml" >/dev/null
  k -n monitoring rollout restart deploy/vmsingle >/dev/null
  k -n monitoring rollout status deploy/vmsingle --timeout=120s >/dev/null
fi

RECLAIM='preemption: {reclaimWithinCohort: Any, withinClusterQueue: LowerPriority}'
NEVER='preemption: {reclaimWithinCohort: Never, withinClusterQueue: Never}'

say "acme lends 64 idle GPUs to spot; spot jobs get a 30 s grace period"
cq acme 64 fleet "" "$RECLAIM"
cq nimbus 64 fleet "" "$RECLAIM"
cq spot 0 fleet "" "$NEVER"
k label clusterqueue spot vanir.lab/perishable=true --overwrite >/dev/null
for t in acme nimbus spot; do tenant $t; localqueue $t $t; done
# nimbus fills its own 64, so spot can only be running on acme's lent quota.
for i in 1 2 3 4; do job nimbus "od-$i" nimbus on-demand 2 8; done
for i in 1 2 3 4; do GRACE=30 job spot "spot-$i" spot spot 2 8; done
eventually 60 "fleet full: nimbus 64 own + spot 64 borrowed from acme" \
  bash -c "[[ \$(source $LAB_ROOT/scripts/lib.sh; gpus_allocated) == 128 ]]"

say "acme reclaims 32 GPUs"
job acme reserved-1 acme reserved 4 8
noticed() {
  k get pods -n spot -o json | python3 -Ic 'import sys,json
n=sum(1 for p in json.load(sys.stdin)["items"] if "vanir.lab/eviction-deadline" in p["metadata"].get("annotations",{}))
sys.exit(0 if n >= 4 else 1)'
}
export -f noticed
eventually 15 "victim pods received an eviction notice" noticed

echo "Notice as seen by a victim pod (what a downward API volume would expose):"
k get pods -n spot -o json | python3 -Ic '
import sys, json
for p in json.load(sys.stdin)["items"]:
    a = p["metadata"].get("annotations", {})
    if "vanir.lab/eviction-deadline" in a:
        print("  pod:", p["metadata"]["name"])
        for key in ("vanir.lab/eviction-reason", "vanir.lab/eviction-deadline", "vanir.lab/eviction-message"):
            print(f"    {key}: {a[key][:100]}")
        break'

reclaimed() {
  k get workloads -n spot -o json | python3 -Ic 'import sys,json
n=sum(1 for w in json.load(sys.stdin)["items"] if "vanir.lab/reclaimed-at" in w["metadata"].get("annotations",{}))
sys.exit(0 if n >= 2 else 1)'
}
export -f reclaimed
eventually 60 "controller marked both evicted workloads reclaimed" reclaimed

echo "Events:"
k get events -n spot --field-selector reportingComponent=eviction-notice \
  -o custom-columns='REASON:.reason,WORKLOAD:.involvedObject.name,MESSAGE:.message' 2>/dev/null | sed 's/^/  /'

echo "Exact reclaim latency per workload (reclaimed-at minus eviction):"
k get workloads -n spot -o json | python3 -Ic '
import sys, json
from datetime import datetime
ts = lambda s: datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
for w in json.load(sys.stdin)["items"]:
    a = w["metadata"].get("annotations", {})
    if "vanir.lab/reclaimed-at" in a:
        print("  %s: %ds" % (w["metadata"]["ownerReferences"][0]["name"],
              (ts(a["vanir.lab/reclaimed-at"]) - ts(a["vanir.lab/notice-for"])).total_seconds()))'

if k -n monitoring get deploy vmsingle >/dev/null 2>&1; then
  sleep 15
  q='histogram_quantile(0.9, sum by (le)(vanir_eviction_reclaim_seconds_bucket))'
  p90=$(k get --raw "/api/v1/namespaces/monitoring/services/vmsingle:http/proxy/api/v1/query?query=$(python3 -Ic 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$q")" \
    | python3 -Ic 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "none")')
  echo "vanir_eviction_reclaim_seconds p90 from VictoriaMetrics: $p90 (interpolated inside a histogram bucket)"
  [[ $p90 != none ]] && pass "reclaim latency is now a metric" || fail "no reclaim metric scraped"
fi

cat <<'EOT'

Takeaways
- Kueue says "admitted" at eviction time; vanir_eviction_reclaim_seconds says
  when the owner actually got the GPUs (~30 s here, the grace period).
- A checkpoint-aware trainer can mount metadata.annotations via a downward API
  volume and see the reason plus an absolute deadline, instead of guessing
  from SIGTERM.
- Idempotency is keyed on the Evicted condition's transition time: repeat
  reconciles do nothing, and a later eviction gets a fresh notice.
EOT
