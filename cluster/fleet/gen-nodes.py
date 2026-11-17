#!/usr/bin/env python3
"""Emit fake GPU nodes for kwok.

Fleet shape mirrors a small GPU cloud pod: blocks (IB spine domains) contain
racks (leaf switches), racks contain 8-GPU hosts. Default: 2 blocks x 2 racks x
4 hosts = 16 nodes / 128 GPUs.

Usage: gen-nodes.py [--blocks N] [--racks N] [--hosts N] | kubectl apply -f -
"""
import argparse
import json

p = argparse.ArgumentParser()
p.add_argument("--blocks", type=int, default=2)
p.add_argument("--racks", type=int, default=2, help="racks per block")
p.add_argument("--hosts", type=int, default=4, help="hosts per rack")
p.add_argument("--gpus", type=int, default=8)
p.add_argument("--product", default="NVIDIA-H200")
args = p.parse_args()

items = []
for b in range(args.blocks):
    for r in range(args.racks):
        for h in range(args.hosts):
            name = f"gpu-b{b}-r{r}-h{h}"
            items.append({
                "apiVersion": "v1",
                "kind": "Node",
                "metadata": {
                    "name": name,
                    "annotations": {
                        "node.alpha.kubernetes.io/ttl": "0",
                        "kwok.x-k8s.io/node": "fake",
                    },
                    "labels": {
                        "kubernetes.io/hostname": name,
                        "kubernetes.io/role": "agent",
                        "type": "kwok",
                        "vanir.lab/pool": "gpu",
                        "vanir.lab/block": f"b{b}",
                        "vanir.lab/rack": f"b{b}-r{r}",
                        "nvidia.com/gpu.product": args.product,
                        "nvidia.com/gpu.count": str(args.gpus),
                    },
                },
                "spec": {
                    # Keep real system pods (DaemonSets etc.) off the fake fleet.
                    "taints": [{
                        "key": "kwok.x-k8s.io/node",
                        "value": "fake",
                        "effect": "NoSchedule",
                    }],
                },
                "status": {
                    "allocatable": {
                        "cpu": "128", "memory": "2Ti", "pods": "110",
                        "nvidia.com/gpu": str(args.gpus),
                    },
                    "capacity": {
                        "cpu": "128", "memory": "2Ti", "pods": "110",
                        "nvidia.com/gpu": str(args.gpus),
                    },
                },
            })

print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}, indent=1))
