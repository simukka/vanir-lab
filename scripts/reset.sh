#!/usr/bin/env bash
# Remove all module objects (tenant namespaces, queues, cohorts) but keep the
# cluster, fleet and base Kueue objects.
set -euo pipefail
CTX=kind-vanir
k() { kubectl --context "$CTX" "$@"; }

k delete ns -l vanir.lab/tenant=true --wait=true --ignore-not-found
k delete localqueue --all -A --ignore-not-found
k delete clusterqueue -l vanir.lab/module --ignore-not-found
k delete cohort -l vanir.lab/module --ignore-not-found
echo "reset done"
