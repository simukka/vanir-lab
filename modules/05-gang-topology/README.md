# 05: Gangs, topology and fragmentation

**Posting:** *"Implement gang scheduling, topology-aware placement and
preemption for multi-node training."*

Kueue **Topology Aware Scheduling (TAS)** uses the `gpu-fabric` Topology from
`cluster/kueue/base.yaml` (block → rack → host). A job opts in with a pod
template annotation:

```yaml
kueue.x-k8s.io/podset-required-topology: vanir.lab/rack   # must fit in one rack
kueue.x-k8s.io/podset-preferred-topology: vanir.lab/rack  # try, else spread
```

`TOPO=required:vanir.lab/rack job ...` in `scripts/lib.sh` sets it.

## Scenario

1. **Fragment**: fill all 16 nodes with single-node jobs, then free host `h0`
   in every rack. 32 GPUs are free, 8 per rack.
2. **Required** 4-node gang: Kueue refuses to reserve quota:
   > topology "gpu-fabric" allows to fit only 1 out of 4 pod(s); all pods must
   > fit in a single "vanir.lab/rack" topology domain
   No pods start, because admission is all-or-nothing.
3. **Preferred** 4-node gang: admitted at once, one pod per rack, so traffic
   crosses the spine.
4. **Defragment**: free a whole rack and the required gang is placed inside
   it.

## Findings

- **Free GPUs aren't capacity.** Measure the largest gang you can place at
  each topology level. A useful fragmentation metric:
  `1 - largest_placeable_at_level / free_gpus`. Here it was `1 - 8/32 = 75%`
  at rack level.
- **Required vs preferred trades queue time for step time.** On GB300 NVL72
  the rack *is* the NVLink domain, so splitting a tensor-parallel group across
  racks hurts badly. Verda sells NVL72 "from a single tray up to 2+ racks",
  which makes this placement problem central for them.
- **Defrag needs policy.** Here we drained a rack by hand. Real options are
  to bin-pack small jobs into already broken racks, migrate checkpointable
  jobs, or preempt spot/backfill (module 04) to clear one domain for a big
  gang. Kueue TAS packs within its chosen domain, but it won't move running
  work to make room.

## Try

```bash
make module-5
k get workload -n train -o json | jq '.items[].status.admission.podSetAssignments[0].topologyAssignment'
```

- Use `TOPO=required:vanir.lab/block` for an 8-node gang. How many free nodes
  does a block need?
- Add a spot tenant from module 04 and see whether a required gang can preempt
  spot to clear a rack.
