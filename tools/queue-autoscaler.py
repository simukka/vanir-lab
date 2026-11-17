#!/usr/bin/env python3
"""Scale an inference Deployment on queue load, like Verda serverless containers.

Verda's docs define queue load = queued requests / replicas and scale up when
it exceeds a threshold. Here the request queue is simulated by a step profile,
desired replicas = ceil(queue / threshold), clamped to [min, max].

Each tick pushes vanir_inference_{queue_length,replicas_desired,replicas_ready}
to VictoriaMetrics, and every scale-up is timed until the new replicas are
Ready (they may first need Kueue to preempt someone). A JSON summary is printed
on exit.

Usage:
  queue-autoscaler.py --deploy serverless/llm-70b --profile 0:2,30:12,150:2 --duration 210
"""
import argparse
import json
import math
import subprocess
import sys
import time

p = argparse.ArgumentParser()
p.add_argument("--deploy", required=True, help="namespace/name")
p.add_argument("--profile", required=True, help="t:queue,... step function, t in seconds")
p.add_argument("--threshold", type=float, default=2.0, help="queue load per replica")
p.add_argument("--min", type=int, default=1)
p.add_argument("--max", type=int, default=8)
p.add_argument("--duration", type=int, required=True)
p.add_argument("--interval", type=float, default=3.0)
p.add_argument("--context", default="kind-vanir")
args = p.parse_args()

ns, name = args.deploy.split("/")
profile = sorted((int(t), int(q)) for t, q in (s.split(":") for s in args.profile.split(",")))
VM_IMPORT = "/api/v1/namespaces/monitoring/services/vmsingle:http/proxy/api/v1/import/prometheus"


def kubectl(*a, stdin=None):
    return subprocess.run(["kubectl", "--context", args.context, *a], input=stdin,
                          capture_output=True, text=True, check=True).stdout


def queue_at(t):
    q = profile[0][1]
    for start, val in profile:
        if t >= start:
            q = val
    return q


def push(metrics):
    labels = f'deployment="{name}",namespace="{ns}"'
    body = "".join(f"vanir_inference_{k}{{{labels}}} {v}\n" for k, v in metrics.items())
    try:
        kubectl("create", "--raw", VM_IMPORT, "-f", "-", stdin=body)
    except subprocess.CalledProcessError as e:  # metrics are best-effort
        print(f"push failed: {e.stderr.strip()}", file=sys.stderr)


start = time.time()
pending_scaleup = None  # (t_requested, target)
scaleups = []
max_ready = 0
while (t := time.time() - start) < args.duration:
    q = queue_at(t)
    desired = max(args.min, min(args.max, math.ceil(q / args.threshold)))
    d = json.loads(kubectl("get", "deploy", "-n", ns, name, "-o", "json"))
    current = d["spec"]["replicas"]
    ready = d.get("status", {}).get("readyReplicas", 0)
    max_ready = max(max_ready, ready)

    if desired != current:
        kubectl("scale", "deploy", "-n", ns, name, f"--replicas={desired}")
        print(f"t={t:5.0f}s queue={q:3d} load={q / max(current, 1):.1f} scale {current} -> {desired}")
        pending_scaleup = (t, desired) if desired > current else None
    if pending_scaleup and ready >= pending_scaleup[1]:
        lat = t - pending_scaleup[0]
        scaleups.append({"to": pending_scaleup[1], "seconds": round(lat, 1)})
        print(f"t={t:5.0f}s {pending_scaleup[1]} replicas ready after {lat:.1f}s")
        pending_scaleup = None

    push({"queue_length": q, "replicas_desired": desired, "replicas_ready": ready})
    time.sleep(args.interval)

print(json.dumps({"scaleups": scaleups, "max_ready": max_ready,
                  "unfinished_scaleup": pending_scaleup is not None}))
