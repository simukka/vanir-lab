# vanir-lab

A laptop lab for GPU cluster orchestration on a shared pool, modelled on what
Verda's public job postings and docs say about their platform (as of
2026-11). No GPUs are needed: the fleet is 16 fake 8×H200 nodes (128 GPUs)
simulated by [KWOK](https://kwok.sigs.k8s.io/), and the real scheduler
components run on a 2-node [kind](https://kind.sigs.k8s.io/) cluster.

```
kind (Docker)                         fake fleet (kwok)
┌──────────────────────────┐          block b0            block b1
│ control-plane            │          ├ rack b0-r0 ×4     ├ rack b1-r0 ×4
│ worker: Kueue, JobSet,   │  ───►    └ rack b0-r1 ×4     └ rack b1-r1 ×4
│   kwok-controller, ...   │          each host: nvidia.com/gpu: 8
└──────────────────────────┘
```

Fake pods go Running as soon as they're bound. Job-owned pods finish after the
duration in their `vanir.lab/runtime` annotation (e.g. `"90s"`).

## Quick start

```bash
make tools      # kind, kubectl, helm, kwok → ~/.local/bin (pinned, checksummed)
make up         # cluster + fleet + JobSet + Kueue
make module-1   # reset, then run a module scenario (with assertions)
make watch      # live queues / workloads / per-rack GPU map
make down
```

## Modules

| # | Topic | Posting line it explores |
|---|---|---|
| 01 | Silos | "Capacity sits idle in one silo while another is starved" |
| 02 | Kueue cohorts, borrowing, fair-share | "quotas, priorities, fair-share and queueing" |
| 03 | Priority tiers and preemption | "preemption" |
| 04 | Perishable compute | "Fill it with short-lived and preemptible work, and reclaim it cleanly" |
| 05 | Gang + topology-aware placement | "gang scheduling, topology-aware placement" |
| 06 | Inference vs batch, observability | "latency-sensitive inference autoscaling and batch backfill", "queue depth, wait times, fragmentation" |
| 07 | Your own controller (Go) | "Develop Kubernetes operators and controllers" |

## Versions

kind v0.33.0 (Kubernetes 1.37.0), kwok v0.8.0, Kueue 0.20.4, JobSet v0.13.0,
Helm v4.3.1.
