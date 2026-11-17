# 04: Perishable compute

**Posting:** *"Build support for perishable compute: capacity that is free
only for a short window, such as idle reservations, spot-like capacity or gaps
between jobs. Fill it with short-lived and preemptible work, and reclaim it
cleanly when higher-priority work needs it."*

## Design used here

Perishable work gets **ClusterQueues with `nominalQuota: 0`**, so everything
it runs on is borrowed:

| Queue | Nominal | Preemption | Work |
|---|---|---|---|
| acme | 48 | reclaim Any | Reserved customer, idle: the perishable capacity |
| nimbus | 48 | reclaim Any | On-demand training |
| serverless | 32 (lend 16) | reclaim Any | Inference |
| **spot** | 0 | Never | Preemptible jobs |
| **ops** | 0 | Never | Health-check sweeps, `max-exec-time-seconds: 60` |

The ops queue copies what Verda's docs say about their health checks: they
"queue behind customer workloads, and do not preempt them."

Because zero-quota queues only ever borrow, fair sharing always ranks them
highest, so they're evicted first. This fixes the module 03 problem where an
on-demand job lost to spot.

## Two kinds of reclaim

kwok's delete stage is patched to keep a terminating pod, and its GPUs, until
`terminationGracePeriodSeconds` expires, the way a kubelet waits after SIGTERM.

| | Victim's grace | Kueue admits owner | Owner's pods all Running |
|---|---|---|---|
| A: no notice (Verda spot today) | 0 s | 1 s | **3 s** |
| B: 45 s notice | 45 s | 1 s | **45 s** |

## Findings

1. **Admission isn't reclaim.** Kueue releases the victim's quota when it
   evicts, not when the victim's pods have exited. In B, acme was admitted
   after 1 s but its pods sat `Pending` for 45 s while the same GPUs were
   promised to two workloads. An SLO for reserved customers has to be measured
   at "pods running", and the metrics layer (module 06) has to show this gap.
2. **A notice period moves cost from one party to the other.** No notice: the
   spot user loses work. With notice: the reserved owner waits. Ways to soften
   it:
   - lend only part of a reservation (`lendingLimit`) and keep a warm buffer
     for instant reclaim
   - set notice length by workload type (inference replica: seconds; training
     with a fresh checkpoint: a minute)
   - for a planned reclaim, start the notice *before* the owner submits
3. **The notice carries no information.** The victim gets SIGTERM and nothing
   else: no reason, deadline, or "you'll be requeued". A checkpoint-aware
   trainer needs to know it has N seconds. Module 07 builds a controller that
   publishes that.
4. **Gap filling works.** Health checks borrowed idle GPUs, finished in 20 s,
   and `max-exec-time` caps how long a hung check can keep holding capacity.

## Try

- `GRACE=10` vs `GRACE=120` on the spot jobs. Plot GPUs-in-hand latency.
- Give acme `lendingLimit: 32` so 16 GPUs are never lent out. Does a 16-GPU
  reserved job now start instantly in case B?
