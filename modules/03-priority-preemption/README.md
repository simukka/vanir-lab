# 03: Priority tiers and reclaim

**Question:** once idle quota is lent out, how does the owner get it back?

Every ClusterQueue gets:

```yaml
preemption:
  reclaimWithinCohort: Any          # take back lent quota from any borrower
  withinClusterQueue: LowerPriority # inside my own queue, higher prio evicts lower
```

Priority tiers (from `cluster/kueue/base.yaml`, inferred from Verda's
products): `reserved 10000 > inference 5000 > on-demand 1000 > spot 100 >
healthcheck 10`.

## Scenario

1. The pool is full (120/128). nimbus and orbit borrow 64 GPUs between them.
2. acme, a reserved customer that had lent all 48 GPUs, submits a 32-GPU job.
3. serverless scales from 1 to 3 replicas. 8 GPUs come from its held headroom
   and 8 are reclaimed from borrowers.

## What a run showed (Kueue 0.20.4, fair sharing on)

```
06:17:56  nimbus spot-1  spot       InCohortReclamation
06:17:56  orbit  od-2    on-demand  InCohortReclamation   ← on-demand evicted…
06:17:58  nimbus spot-2  spot       InCohortReclamation   ← …while this spot job was still running
```

- Only workloads on **borrowed** quota are victims. Nominal quota is never
  taken, at any priority.
- **Fair share beats priority across queues.** Kueue picks the borrower with
  the highest share first, then the lowest priority inside it. So an
  on-demand job in orbit was evicted while a spot job in nimbus kept running.
  For a cloud that sells "spot is always evicted first", that's a
  product-level bug. You'd need spot in its own ClusterQueue with
  nominal 0, which is what module 04 does.
- The evictions are **instant**. The pods get deleted and the Job is suspended
  and requeued, with no notice. That matches Verda's current spot behaviour
  per their forum ("deleted immediately without warning").

## Try

- Remove the `fairSharing` block from `cluster/kueue/values.yaml`, run
  `make up` again (it upgrades the Helm release), and rerun. Does the eviction
  order follow priority now?
- Change acme's policy to `reclaimWithinCohort: LowerPriority`. A reserved
  job can still reclaim, but a "spot" tenant could no longer evict anything.
