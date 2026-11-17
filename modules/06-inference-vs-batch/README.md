# 06: Inference vs batch, observability

**Posting:** *"latency-sensitive inference autoscaling and batch backfill, all
competing for the same GPUs"* and *"Build observability for scheduling and
utilisation, including queue depth, wait times, fragmentation, preemption
rates, GPU utilisation and SLOs."*

## Setup

- `make obs` installs **VictoriaMetrics** (single-node, scraping Kueue's
  authenticated metrics endpoint) and **Grafana** with the dashboard
  `cluster/observability/dashboards/vanir.json`. VictoriaMetrics and Grafana
  are what Verda's observability and SRE postings name.
- `tools/queue-autoscaler.py` scales `serverless/llm-70b` the way Verda's
  serverless containers do, on **queue load = queued requests / replicas**
  ([docs](https://docs.verda.com/containers/scaling/)). It pushes queue length
  and desired/ready replicas to VictoriaMetrics.

```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000   # http://localhost:3000
```

## Scenario

| t | Event |
|---|---|
| 0 s | Pool full: inference 8, training 32, spot backfill 80, 8 headroom |
| 30 s | Request queue 2 → 12. Autoscaler asks for 6 replicas (48 GPUs, 16 above nominal) |
| ~37 s | 6 replicas ready. Kueue preempted 2 spot jobs, training untouched |
| 150 s | Queue back to 2. Scale to 1. Spot jobs are readmitted into the gap |

A run measured scale-up latency of **6.5 s**, from desired to all replicas
ready, including preemption.

## Dashboard

| Panel | Metric | Why |
|---|---|---|
| GPU allocation | `kueue_cluster_queue_resource_usage / nominal_quota` | Allocation, not utilisation. DCGM gives the real busy %. |
| Borrowed GPUs | usage − nominal, per queue | The perishable part of the fleet |
| Queue depth | `kueue_pending_workloads` | Backlog per tenant |
| Evictions/min | `kueue_evicted_workloads_total` by queue, reason | Preemption rate, who pays |
| Admission wait p90 | `kueue_admission_wait_time_seconds` | Queueing SLO |
| Admitted → ready p90 | `kueue_admitted_until_ready_wait_time_seconds` | The module 04 gap: admitted but GPUs not yet free |
| Inference queue vs replicas | pushed by the autoscaler | Is scaling keeping up? |

## Not covered (yet)

- **Utilisation.** These are allocation metrics. Real utilisation needs
  `dcgm-exporter` (`DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_PROF_SM_ACTIVE`). Verda's
  health-check stack already runs it on customer clusters.
- **Fragmentation.** Kueue doesn't export "largest placeable gang per topology
  level". A small exporter could compute it from Node/Pod state (module 05's
  definition). Good candidate for a second Go controller.
- **Model load time.** On real hardware it dominates scale-up latency, which
  is why inference keeps unlendable headroom.
