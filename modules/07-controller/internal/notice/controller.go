package notice

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/events"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	kueue "sigs.k8s.io/kueue/apis/kueue/v1beta2"
)

// Reconciler watches Kueue Workloads. For an evicted workload on a perishable
// ClusterQueue it:
//  1. sends a notice: annotates every victim pod with reason, message and
//     deadline, and records which eviction the notice was for;
//  2. waits (requeueing) until the victim pods are gone;
//  3. marks the workload reclaimed and observes the reclaim latency.
//
// Every step must be idempotent: the reconcile can run any number of times
// for the same state, including after a crash halfway through.
type Reconciler struct {
	client.Client
	Recorder events.EventRecorder
	Metrics  *Metrics
	// Now is injectable for tests.
	Now func() time.Time
	// PollInterval is how often to re-check victims that are still terminating.
	PollInterval time.Duration
}

// Reconcile is yours to write. `make test` (in this directory) runs the spec;
// the tests in controller_test.go describe every behaviour expected below.
// All the helpers you need are in helpers.go, plus annotatePod and
// annotateWorkload further down this file.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	_ = logger // e.g. logger.Info("eviction notice sent", "pods", n)

	var wl kueue.Workload
	if err := r.Get(ctx, req.NamespacedName, &wl); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// TODO(1) Filter. Return early (no requeue) unless the workload is
	//   evicted (EvictedCondition) and on a perishable queue (IsPerishable).
	//   Remember the eviction time: evicted.LastTransitionTime.

	// TODO(2) Find the victims: PodsForWorkload, then Victims(pods, evictedAt).
	//   Why filter by creation time? Read TestIgnoresPodsCreatedAfterEviction.

	// TODO(3) Notice, exactly once per eviction.
	//   Key the notice on the eviction time (RFC3339) stored in AnnNoticeFor.
	//   If the workload's AnnNoticeFor != key:
	//     - for each victim: annotatePod with AnnReason / AnnMessage
	//       (EvictionReason) and AnnDeadline (Deadline(pod, r.Now()), RFC3339 UTC)
	//     - annotateWorkload: AnnNoticeFor=key, AnnNoticeSentAt=now, and drop
	//       AnnReclaimedAt (a leftover from an earlier eviction)
	//     - r.Metrics.Notices.WithLabelValues(reason).Inc()
	//     - r.Metrics.NoticeSeconds.Observe(latest deadline - now)
	//     - r.Recorder.Eventf(&wl, nil, corev1.EventTypeNormal, "EvictionNotice", "Notify", ...)
	//     - if victims remain, requeue after r.PollInterval
	//   Think about ordering: if the process crashes between the pod patches and
	//   the workload patch, what happens on the next reconcile? Is that safe?

	// TODO(4) Wait. If AnnReclaimedAt is already set, you're done. If victims
	//   are still there, return ctrl.Result{RequeueAfter: r.PollInterval}.
	//   (Alternative to polling: watch Pods and map them to their Workload.
	//   What would that cost, and what would it buy?)

	// TODO(5) Reclaimed. annotateWorkload with AnnReclaimedAt=now, observe
	//   r.Metrics.ReclaimSeconds (now - evictedAt), and emit a "Reclaimed" event.

	return ctrl.Result{}, nil
}

// annotatePod merge-patches annotations onto a pod, skipping the API call if
// they are already set. Terminating pods can still be patched.
func (r *Reconciler) annotatePod(ctx context.Context, p *corev1.Pod, ann map[string]string) error {
	if hasAll(p.Annotations, ann) {
		return nil
	}
	patch := client.MergeFrom(p.DeepCopy())
	if p.Annotations == nil {
		p.Annotations = map[string]string{}
	}
	for k, v := range ann {
		p.Annotations[k] = v
	}
	if err := r.Patch(ctx, p, patch); err != nil {
		return client.IgnoreNotFound(fmt.Errorf("annotating pod %s: %w", p.Name, err))
	}
	return nil
}

// annotateWorkload sets annotations and removes the keys in drop.
func (r *Reconciler) annotateWorkload(ctx context.Context, wl *kueue.Workload, ann map[string]string, drop ...string) error {
	patch := client.MergeFrom(wl.DeepCopy())
	if wl.Annotations == nil {
		wl.Annotations = map[string]string{}
	}
	for k, v := range ann {
		wl.Annotations[k] = v
	}
	for _, k := range drop {
		delete(wl.Annotations, k)
	}
	return r.Patch(ctx, wl, patch)
}

func hasAll(have, want map[string]string) bool {
	for k, v := range want {
		if have[k] != v {
			return false
		}
	}
	return true
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&kueue.Workload{}).
		Named("eviction-notice").
		Complete(r)
}
