# Shared helpers for module run.sh scripts. Source, don't execute.
# shellcheck shell=bash
set -euo pipefail

CTX=kind-vanir
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
k() { kubectl --context "$CTX" "$@"; }
# Exported so `eventually ... bash -c "..."` checks can call k and helpers.
export CTX; export -f k

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# tenant <name>: namespace managed by Kueue.
tenant() {
  k create ns "$1" --dry-run=client -o yaml | k apply -f - >/dev/null
  k label ns "$1" vanir.lab/tenant=true --overwrite >/dev/null
}

# cq <name> <gpus> [cohort] [gpu-lending-limit] [extra-spec]
# ClusterQueue on the h200 flavor. CPU/memory quota scale with GPUs so GPUs are
# always the binding resource. extra-spec is top-level spec keys in YAML flow
# style, separated by "; ", e.g.
#   'preemption: {reclaimWithinCohort: Any}; fairSharing: {weight: "2"}'
cq() {
  local name=$1 gpus=$2 cohort=${3:-} lend=${4:-} extra=${5:-}
  local lendcpu="" lendmem="" lendgpu="" nl=$'\n'
  extra=${extra//; /${nl}  }
  if [[ -n $lend ]]; then
    lendcpu=", lendingLimit: \"$((lend * 16))\""
    lendmem=", lendingLimit: \"$((lend * 256))Gi\""
    lendgpu=", lendingLimit: \"$lend\""
  fi
  k apply -f - >/dev/null <<EOF
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: $name
  labels: {vanir.lab/module: "${M:-x}"}
spec:
  ${cohort:+cohortName: $cohort}
  namespaceSelector: {}
  ${extra}
  resourceGroups:
  - coveredResources: [cpu, memory, nvidia.com/gpu]
    flavors:
    - name: h200
      resources:
      - {name: cpu, nominalQuota: "$((gpus * 16))"$lendcpu}
      - {name: memory, nominalQuota: "$((gpus * 256))Gi"$lendmem}
      - {name: nvidia.com/gpu, nominalQuota: "$gpus"$lendgpu}
EOF
}

# localqueue <ns> <clusterqueue>: LocalQueue named after the namespace's CQ.
localqueue() {
  k apply -f - >/dev/null <<EOF
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata: {name: $2, namespace: $1}
spec: {clusterQueue: $2}
EOF
}

# job <ns> <name> <queue> <priority> <pods> <gpus-per-pod> [runtime] [extra-annotations-yaml]
# A gang: Kueue admits all pods' GPUs at once or none. runtime is a duration
# for the fake pods ("90s"); omitted = runs ~forever.
# Env knobs: GRACE=<s> eviction notice (terminationGracePeriodSeconds, default 0)
#            MAX_EXEC=<s> Kueue max execution time before the job is evicted.
#            TOPO=required|preferred:<node-label> Kueue TAS placement, e.g.
#                 TOPO=required:vanir.lab/rack (all pods inside one rack).
job() {
  local ns=$1 name=$2 queue=$3 prio=$4 pods=$5 gpus=$6 runtime=${7:-} extra=${8:-}
  local maxexec=""
  [[ -n ${MAX_EXEC:-} ]] && maxexec="kueue.x-k8s.io/max-exec-time-seconds: \"$MAX_EXEC\""
  local topo=""
  [[ -n ${TOPO:-} ]] && topo="kueue.x-k8s.io/podset-${TOPO%%:*}-topology: ${TOPO#*:}, "
  k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: $ns
  labels:
    kueue.x-k8s.io/queue-name: $queue
    kueue.x-k8s.io/priority-class: $prio
    $maxexec
  annotations: {$extra}
spec:
  parallelism: $pods
  completions: $pods
  completionMode: Indexed
  backoffLimit: 0
  suspend: true
  template:
    metadata:
      annotations: {${topo}${runtime:+vanir.lab/runtime: "$runtime"}}
    spec:
      restartPolicy: Never
      terminationGracePeriodSeconds: ${GRACE:-0}
      containers:
      - name: worker
        image: fake.local/trainer:latest
        resources:
          requests: {cpu: "8", memory: 64Gi, nvidia.com/gpu: "$gpus"}
          limits: {nvidia.com/gpu: "$gpus"}
EOF
}

# serve <ns> <name> <queue> <priority> <replicas> <gpus-per-replica>
# Long-running pods (inference, slurmd). Each replica is its own Kueue workload.
serve() {
  local ns=$1 name=$2 queue=$3 prio=$4 replicas=$5 gpus=$6
  k apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
  namespace: $ns
  labels:
    kueue.x-k8s.io/queue-name: $queue
    kueue.x-k8s.io/priority-class: $prio
spec:
  replicas: $replicas
  selector: {matchLabels: {app: $name}}
  template:
    metadata:
      labels: {app: $name}
    spec:
      terminationGracePeriodSeconds: ${GRACE:-0}
      containers:
      - name: server
        image: fake.local/$name:latest
        resources:
          requests: {cpu: "8", memory: 64Gi, nvidia.com/gpu: "$gpus"}
          limits: {nvidia.com/gpu: "$gpus"}
EOF
}

# jsonpath helper: jp <args...> <jsonpath>
jp() { local path=${!#}; k get "${@:1:$#-1}" -o "jsonpath=${path}"; }

# admitted_count <ns>: number of admitted workloads in a namespace.
admitted_count() {
  k get workloads -n "$1" -o json | python3 -Ic 'import sys,json
print(sum(any(c["type"]=="Admitted" and c["status"]=="True" for c in w.get("status",{}).get("conditions",[])) for w in json.load(sys.stdin)["items"]))'
}
pending_count() {
  k get workloads -n "$1" -o json | python3 -Ic 'import sys,json
print(sum(not any(c["type"] in ("Admitted","Finished") and c["status"]=="True" for c in w.get("status",{}).get("conditions",[])) for w in json.load(sys.stdin)["items"]))'
}

# eventually <timeout-s> <description> <cmd...>: retry cmd until it succeeds.
eventually() {
  local t=$1 desc=$2; shift 2
  for ((i = 0; i < t; i++)); do
    if "$@" >/dev/null 2>&1; then pass "$desc"; return 0; fi
    sleep 1
  done
  fail "$desc (after ${t}s)"
}

# gpus_allocated [ns]: GPUs held by running pods on the fake fleet.
gpus_allocated() {
  local scope=(-A); [[ -n "${1:-}" ]] && scope=(-n "$1")
  k get pods "${scope[@]}" -o json | python3 -Ic 'import sys,json
print(sum(int(c.get("resources",{}).get("limits",{}).get("nvidia.com/gpu",0))
  for p in json.load(sys.stdin)["items"]
  if p["status"].get("phase")=="Running" and not p["metadata"].get("deletionTimestamp")
  for c in p["spec"]["containers"]))'
}

snapshot() { "$LAB_ROOT/tools/watch.sh" --once; }
