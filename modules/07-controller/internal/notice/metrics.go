package notice

import "github.com/prometheus/client_golang/prometheus"

// Metrics are injected into the Reconciler so tests can use a fresh registry.
type Metrics struct {
	// Notices counts eviction notices sent, by eviction reason.
	Notices *prometheus.CounterVec
	// NoticeSeconds is how much warning a victim got (deadline - notice time).
	NoticeSeconds prometheus.Histogram
	// ReclaimSeconds is eviction → last victim pod gone: how long the
	// reclaiming owner waited for the GPUs, which Kueue's own metrics hide
	// because it admits the owner at eviction time.
	ReclaimSeconds prometheus.Histogram
}

func NewMetrics(reg prometheus.Registerer) *Metrics {
	buckets := []float64{1, 2, 5, 10, 20, 30, 45, 60, 90, 120, 300}
	m := &Metrics{
		Notices: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "vanir_eviction_notices_total",
			Help: "Eviction notices sent to perishable workloads.",
		}, []string{"reason"}),
		NoticeSeconds: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "vanir_eviction_notice_seconds",
			Help:    "Warning time given to evicted pods (deadline minus notice time).",
			Buckets: buckets,
		}),
		ReclaimSeconds: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "vanir_eviction_reclaim_seconds",
			Help:    "Time from eviction until the last victim pod was gone.",
			Buckets: buckets,
		}),
	}
	reg.MustRegister(m.Notices, m.NoticeSeconds, m.ReclaimSeconds)
	return m
}
