#!/usr/bin/env bash
# Install VictoriaMetrics + Grafana into the monitoring namespace.
set -euo pipefail
cd "$(dirname "$0")/.."
CTX=kind-vanir
k() { kubectl --context "$CTX" "$@"; }

k apply -f cluster/observability/victoriametrics.yaml
k -n monitoring create configmap grafana-dashboards \
  --from-file=cluster/observability/dashboards/ --dry-run=client -o yaml | k apply -f -
k apply -f cluster/observability/grafana.yaml
k -n monitoring rollout status deploy/vmsingle --timeout=180s
k -n monitoring rollout status deploy/grafana --timeout=300s
cat <<'EOT'
observability is up. Open Grafana with:
  kubectl -n monitoring port-forward svc/grafana 3000:3000   → http://localhost:3000
EOT
