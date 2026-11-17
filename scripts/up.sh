#!/usr/bin/env bash
# Create the lab: kind cluster, kwok controller + stages, fake GPU fleet, Kueue.
set -euo pipefail
cd "$(dirname "$0")/.."

KWOK_VERSION=v0.8.0
KUEUE_VERSION=0.20.4
JOBSET_VERSION=v0.13.0
CTX=kind-vanir

if ! kind get clusters | grep -qx vanir; then
  kind create cluster --config cluster/kind.yaml
fi
k() { kubectl --context "$CTX" "$@"; }

echo "==> kwok controller"
k apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok.yaml"
k apply -f cluster/kwok/stages.yaml
k -n kube-system rollout status deploy/kwok-controller --timeout=180s

echo "==> fake GPU fleet"
python3 -I cluster/fleet/gen-nodes.py | k apply -f -
k wait --for=condition=Ready node -l type=kwok --timeout=120s

echo "==> JobSet (gang-friendly multi-pod training jobs)"
k apply --server-side -f "https://github.com/kubernetes-sigs/jobset/releases/download/${JOBSET_VERSION}/manifests.yaml"
k -n jobset-system rollout status deploy/jobset-controller-manager --timeout=180s

echo "==> Kueue ${KUEUE_VERSION}"
helm --kube-context "$CTX" upgrade --install kueue oci://registry.k8s.io/kueue/charts/kueue \
  --version "$KUEUE_VERSION" -n kueue-system --create-namespace \
  -f cluster/kueue/values.yaml --wait --timeout 5m
k apply -f cluster/kueue/base.yaml

echo
k get nodes -L vanir.lab/rack,nvidia.com/gpu.product
echo "lab is up (context: $CTX)"
