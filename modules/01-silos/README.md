# 01: Silos

**Question:** why does a GPU cloud with a backlog still have idle GPUs?

Four tenants each get a ClusterQueue with a fixed `nominalQuota` and no cohort,
so quota can't move between them:

| Tenant | GPUs | Models |
|---|---|---|
| acme | 48 | Reserved instant-cluster customer, currently idle |
| nimbus | 32 | On-demand training with a backlog of 6 × 16-GPU jobs |
| serverless | 32 | Inference pool, 2 replicas running |
| hpclab | 16 | Slinky Slurm cluster: one `slurmd` pod holds each whole node |

Expected result: nimbus has 64 GPUs of work pending while 64 GPUs sit idle.

## How this maps to Verda

At Verda the silos are harder than here. Each instant cluster is its own
kubeadm control plane on dedicated nodes, and GPU VMs are another separate pool.
Here a silo is only a quota boundary inside one cluster, which is the
best case. The scheduling problem is the same either way.

The hpclab tenant shows a second-order problem. Slinky gives `slurmd` the
whole node, so to Kubernetes those GPUs look allocated even when Slurm has an
empty queue. A layer that pools capacity needs a signal from inside Slurm
(e.g. `sinfo` idle nodes) or something like slurm-bridge, where Slurm schedules
pods directly.

## Try

```bash
make module-1
make watch                       # in another terminal
k get cq nimbus -o yaml | yq .status
```
