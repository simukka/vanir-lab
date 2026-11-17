# 02: Cohorts, borrowing, fair sharing

**Question:** what's the smallest change that turns silos into a shared pool?

Phase 1 recreates the silos. Phase 2 re-applies every ClusterQueue with
`cohortName: fleet`. Quota is still owned per tenant (`nominalQuota`), but
unused quota in the cohort can now be **borrowed**.

| Tenant | Nominal | Phase 2 role |
|---|---|---|
| acme | 48 | Idle reserved customer, lends all 48 |
| nimbus | 32 | Borrows |
| orbit | 16 | Borrows |
| serverless | 32 | `lendingLimit: 16`, keeps 16 guaranteed (8 used, 8 idle headroom) |

Expected: allocation goes from 56 to 120 GPUs, and the 64 lent GPUs are
split about evenly between nimbus and orbit.

## Concepts

- **nominalQuota**: what a tenant is guaranteed. This is the contract.
- **borrowingLimit**: how far above nominal a tenant may go (unset = unlimited).
- **lendingLimit**: how much of its nominal a tenant lets others use. The
  remainder is held even when idle. Inference uses it to reserve scale-up
  headroom, so the 8 idle GPUs in the GPU map are deliberate.
- **Fair sharing** (`fairSharing` in `cluster/kueue/values.yaml`): when several
  queues compete for borrowable capacity, Kueue admits from the queue with the
  lowest *dominant resource share* (borrowed / lendable, divided by
  `fairSharing.weight`). That's why nimbus doesn't take everything despite
  having more jobs. Try `fairSharing: {weight: "3"}` on orbit.

## Notice

- The GPU map shows nimbus's 2-node jobs scattered across racks. Nothing
  here asks for locality yet (module 05).
- acme has zero free capacity now. Without preemption, a reserved customer
  coming back gets nothing. Fixing that is the core of perishable compute
  (modules 03–04).

## Try

```bash
make module-2
k get cq orbit -o jsonpath='{.status.fairSharing}'
```
