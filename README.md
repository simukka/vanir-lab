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
make obs        # VictoriaMetrics + Grafana (module 06 installs it if missing)
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
Helm v4.3.1, VictoriaMetrics v1.154.1, Grafana 13.2.5.

## Findings so far

- Joining silos into one Kueue cohort took allocation from 56 to 120 of 128
  GPUs with the same demand (02).
- With fair sharing on, *share* decides victims before priority does: an
  on-demand job lost to spot in another queue (03). Zero-quota spot queues
  fix that (04).
- Kueue admits the reclaiming owner at **eviction** time. With a 45 s notice
  period the owner's pods wait Pending for 45 s on GPUs promised twice (04).
- Strict rack placement: 32 free GPUs, largest placeable gang 8 (05).
- Inference burst past quota took 6.5 s, preempting only spot; backfill refilled
  the gap afterwards (06).
- An eviction-notice controller makes the real reclaim latency (31 s with a
  30 s grace period) a metric, and gives victims a machine-readable deadline (07).
