#!/usr/bin/env python3
"""Print GPU allocation per fake node, grouped by rack, coloured by tenant.

Reads `kubectl get nodes,pods -o json` from stdin.
"""
import json
import sys
from collections import defaultdict

data = json.load(sys.stdin)
nodes, pods = {}, []
for it in data["items"]:
    if it["kind"] == "Node" and it["metadata"]["labels"].get("type") == "kwok":
        nodes[it["metadata"]["name"]] = it
    elif it["kind"] == "Pod":
        pods.append(it)

# Tenant letter per namespace, so each GPU cell shows who holds it.
used = defaultdict(list)  # node -> [ns, ns, ...] one entry per GPU
for p in pods:
    node = p["spec"].get("nodeName")
    if node not in nodes or p["status"].get("phase") not in ("Running", "Pending"):
        continue
    if p["metadata"].get("deletionTimestamp"):
        continue
    gpus = sum(int(c.get("resources", {}).get("limits", {}).get("nvidia.com/gpu", 0))
               for c in p["spec"]["containers"])
    used[node] += [p["metadata"]["namespace"]] * gpus

tenants = sorted({ns for v in used.values() for ns in v})
letters = {ns: chr(ord("A") + i) for i, ns in enumerate(tenants)}

racks = defaultdict(list)
for name, n in sorted(nodes.items()):
    racks[n["metadata"]["labels"]["vanir.lab/rack"]].append(name)

total = sum(int(n["status"]["allocatable"]["nvidia.com/gpu"]) for n in nodes.values())
alloc = sum(len(v) for v in used.values())
for rack, names in sorted(racks.items()):
    cells = []
    for name in names:
        cap = int(nodes[name]["status"]["allocatable"]["nvidia.com/gpu"])
        held = [letters[ns] for ns in used[name]]
        cells.append("".join(held) + "." * (cap - len(held)))
    print(f"{rack:7} " + " ".join(f"[{c}]" for c in cells))
print(f"GPUs allocated {alloc}/{total} ({100 * alloc // max(total, 1)}%)   "
      + "  ".join(f"{l}={ns}" for ns, l in letters.items()))
