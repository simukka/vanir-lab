# 07: Write the controller (Go)

**Posting:** *"Develop Kubernetes operators and controllers … You pay attention
to API design, concurrency, idempotency, retries and error recovery."*

## The problem (from module 04)

When Kueue reclaims lent capacity, the victim gets SIGTERM and nothing else.
It doesn't learn why, how long it has, or whether it will be requeued.
Kueue's own metrics also hide how long the reclaiming owner waited, because
it marks the owner *admitted* at eviction time, not when the GPUs are free.

## What you build: `eviction-notice`

A controller-runtime controller watching Kueue `Workload`s. For a workload
evicted from a ClusterQueue labelled `vanir.lab/perishable=true`:

1. **Notice**: annotate every victim pod:
   ```yaml
   vanir.lab/eviction-reason: InCohortReclamation
   vanir.lab/eviction-deadline: "2026-11-17T06:57:05Z"   # absolute, not "30s"
   vanir.lab/eviction-message: Preempted to accommodate a workload (UID: …)
   ```
   A trainer can mount these with a downward API volume (`metadata.annotations`)
   and decide whether a checkpoint fits before the deadline.
2. **Wait** until the victim pods are gone. They may be terminating for the
   whole grace period.
3. **Reclaimed**: record it and observe `vanir_eviction_reclaim_seconds`, the
   latency the owner actually felt.

The pieces you need already exist:

| File | What's there |
|---|---|
| `internal/notice/helpers.go` | `EvictedCondition`, `EvictionReason`, `IsPerishable`, `PodsForWorkload`, `Victims`, `Deadline`, annotation keys |
| `internal/notice/metrics.go` | `vanir_eviction_notices_total`, `_notice_seconds`, `_reclaim_seconds` |
| `internal/notice/controller.go` | `annotatePod`, `annotateWorkload`, wiring, and **`Reconcile` with TODO(1–5)** |
| `internal/notice/controller_test.go` | The spec: 8 tests on a fake client with an injected clock |
| `cmd/main.go` | Manager: metrics on `:8080`, probes on `:8081` |

## Loop

```bash
cd modules/07-controller
make test            # 5 tests fail on the skeleton; make them pass
make run             # build image, load into kind, deploy, run the e2e scenario
```

`make run` deploys the controller, gives spot jobs a 30 s grace period,
reclaims 32 GPUs for acme, and checks:
- the victim pods received a notice
- both workloads were marked reclaimed (~31 s)
- `vanir_eviction_reclaim_seconds` shows up in VictoriaMetrics, if `make obs` ran

## Things to think about while writing it

- **Idempotency.** A reconcile can run any number of times for the same state.
  Why is the notice keyed on the Evicted condition's `lastTransitionTime`
  rather than a boolean "notice sent"? (`TestNewEvictionGetsNewNotice`)
- **Crash safety.** The pods are patched before the workload. What happens if
  the process dies between the two? What if the order were reversed?
- **Level vs edge.** Nothing here reacts to the eviction *event*. It reacts to
  the current state, so a restarted controller catches up on its own.
- **Polling vs watching.** `RequeueAfter` polls terminating pods. Watching
  Pods and mapping them back to the Workload is more responsive. What does
  it cost in cache memory on a 10k-pod cluster?
- **Ownership.** Pods created after the eviction belong to a re-admission.
  `Victims` filters them by creation time. Why does that matter?
  (`TestIgnoresPodsCreatedAfterEviction`)

## The upstream angle

A notice only helps if the victim gets it **before** eviction. Kueue
0.20.4 already has `spec.preemptionGates` on Workloads ("gates governing
whether the workload can trigger preemptions"). The scheduler only honours them
when the alpha `ConcurrentAdmission` or `MultiKueueOrchestratedPreemption`
features are on. A general "graceful reclaim" built on that, where the preemptor
is gated, victims are notified, and the gate opens after a deadline or once
victims checkpoint, is the kind of upstream contribution the posting asks for.

## Stuck?

A reference implementation exists on the local branch `07-solution`. It isn't
pushed to GitHub. `git diff main 07-solution -- modules/07-controller` shows
it.
