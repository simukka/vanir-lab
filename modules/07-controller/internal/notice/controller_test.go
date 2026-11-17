package notice

import (
	"context"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
	dto "github.com/prometheus/client_model/go"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/events"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	kueue "sigs.k8s.io/kueue/apis/kueue/v1beta2"
)

// Fixed clock: the workload was evicted at t0, the test reconciles at t0+5s.
var (
	t0  = time.Date(2026, 11, 17, 12, 0, 0, 0, time.UTC)
	now = t0.Add(5 * time.Second)
)

type fixture struct {
	t       *testing.T
	c       client.Client
	r       *Reconciler
	metrics *Metrics
	clock   time.Time
}

func newFixture(t *testing.T, objs ...client.Object) *fixture {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	if err := kueue.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objs...).
		WithStatusSubresource(&kueue.Workload{}).Build()
	f := &fixture{t: t, c: c, metrics: NewMetrics(prometheus.NewRegistry()), clock: now}
	f.r = &Reconciler{
		Client:       c,
		Recorder:     events.NewFakeRecorder(100),
		Metrics:      f.metrics,
		Now:          func() time.Time { return f.clock },
		PollInterval: 2 * time.Second,
	}
	return f
}

func (f *fixture) reconcile() ctrl.Result {
	f.t.Helper()
	res, err := f.r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Namespace: "spot", Name: "wl"}})
	if err != nil {
		f.t.Fatalf("reconcile: %v", err)
	}
	return res
}

func (f *fixture) workload() *kueue.Workload {
	f.t.Helper()
	var wl kueue.Workload
	if err := f.c.Get(context.Background(), types.NamespacedName{Namespace: "spot", Name: "wl"}, &wl); err != nil {
		f.t.Fatal(err)
	}
	return &wl
}

func (f *fixture) pod(name string) *corev1.Pod {
	f.t.Helper()
	var p corev1.Pod
	if err := f.c.Get(context.Background(), types.NamespacedName{Namespace: "spot", Name: name}, &p); err != nil {
		f.t.Fatal(err)
	}
	return &p
}

// finishPod simulates kubelet removing a terminating pod.
func (f *fixture) finishPod(name string) {
	f.t.Helper()
	p := f.pod(name)
	p.Finalizers = nil
	if err := f.c.Update(context.Background(), p); err != nil {
		f.t.Fatal(err)
	}
}

// --- object builders ---

func queues(perishable bool) []client.Object {
	labels := map[string]string{}
	if perishable {
		labels[PerishableLabel] = "true"
	}
	return []client.Object{
		&kueue.ClusterQueue{ObjectMeta: metav1.ObjectMeta{Name: "spot", Labels: labels}},
		&kueue.LocalQueue{ObjectMeta: metav1.ObjectMeta{Namespace: "spot", Name: "spot"},
			Spec: kueue.LocalQueueSpec{ClusterQueue: "spot"}},
	}
}

func evictedWorkload(at time.Time) *kueue.Workload {
	return &kueue.Workload{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "spot", Name: "wl",
			OwnerReferences: []metav1.OwnerReference{{APIVersion: "batch/v1", Kind: "Job", Name: "train", UID: "job-uid"}},
		},
		Spec: kueue.WorkloadSpec{QueueName: "spot"},
		Status: kueue.WorkloadStatus{Conditions: []metav1.Condition{
			{Type: kueue.WorkloadEvicted, Status: metav1.ConditionTrue, Reason: "Preempted",
				Message: "Preempted to accommodate a workload", LastTransitionTime: metav1.NewTime(at)},
			{Type: kueue.WorkloadPreempted, Status: metav1.ConditionTrue, Reason: kueue.InCohortReclamationReason,
				Message:            "Preempted to accommodate a workload (UID: abc) due to reclamation within the cohort",
				LastTransitionTime: metav1.NewTime(at)},
		}},
	}
}

// terminatingPod is a victim pod: created before the eviction, being deleted
// with a deadline (deletionTimestamp). The finalizer keeps the fake client
// from removing it until finishPod.
func terminatingPod(name string, created, deadline time.Time) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "spot", Name: name,
			Labels:            map[string]string{jobNameLabel: "train"},
			CreationTimestamp: metav1.NewTime(created),
			DeletionTimestamp: ptr.To(metav1.NewTime(deadline)),
			Finalizers:        []string{"test/hold"},
		},
		Spec:   corev1.PodSpec{TerminationGracePeriodSeconds: ptr.To[int64](45)},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
}

func objs(extra ...client.Object) []client.Object { return append(queues(true), extra...) }

// --- tests ---

func TestIgnoresWorkloadThatIsNotEvicted(t *testing.T) {
	wl := evictedWorkload(t0)
	wl.Status.Conditions = nil
	f := newFixture(t, objs(wl, terminatingPod("p0", t0.Add(-time.Minute), t0.Add(45*time.Second)))...)

	if res := f.reconcile(); res.RequeueAfter != 0 {
		t.Errorf("RequeueAfter = %v, want 0", res.RequeueAfter)
	}
	if got := f.pod("p0").Annotations[AnnDeadline]; got != "" {
		t.Errorf("pod got a notice for a running workload: %q", got)
	}
}

func TestIgnoresNonPerishableQueue(t *testing.T) {
	f := newFixture(t, append(queues(false), evictedWorkload(t0),
		terminatingPod("p0", t0.Add(-time.Minute), t0.Add(45*time.Second)))...)

	f.reconcile()
	if got := f.pod("p0").Annotations[AnnDeadline]; got != "" {
		t.Errorf("non-perishable pod got a notice: %q", got)
	}
	if got := testutil.ToFloat64(f.metrics.Notices.WithLabelValues(kueue.InCohortReclamationReason)); got != 0 {
		t.Errorf("notices = %v, want 0", got)
	}
}

func TestSendsNoticeToVictimPods(t *testing.T) {
	deadline := t0.Add(45 * time.Second)
	f := newFixture(t, objs(evictedWorkload(t0),
		terminatingPod("p0", t0.Add(-time.Minute), deadline),
		terminatingPod("p1", t0.Add(-time.Minute), deadline))...)

	res := f.reconcile()

	for _, name := range []string{"p0", "p1"} {
		ann := f.pod(name).Annotations
		if ann[AnnReason] != kueue.InCohortReclamationReason {
			t.Errorf("%s reason = %q, want %q", name, ann[AnnReason], kueue.InCohortReclamationReason)
		}
		if ann[AnnDeadline] != deadline.Format(time.RFC3339) {
			t.Errorf("%s deadline = %q, want %q", name, ann[AnnDeadline], deadline.Format(time.RFC3339))
		}
		if ann[AnnMessage] == "" {
			t.Errorf("%s has no eviction message", name)
		}
	}
	wl := f.workload()
	if wl.Annotations[AnnNoticeFor] != t0.Format(time.RFC3339) {
		t.Errorf("workload %s = %q, want %q", AnnNoticeFor, wl.Annotations[AnnNoticeFor], t0.Format(time.RFC3339))
	}
	if res.RequeueAfter == 0 {
		t.Error("victims are still terminating; want a requeue to check on them")
	}
	if got := testutil.ToFloat64(f.metrics.Notices.WithLabelValues(kueue.InCohortReclamationReason)); got != 1 {
		t.Errorf("notices = %v, want 1", got)
	}
}

func TestNoticeIsIdempotent(t *testing.T) {
	f := newFixture(t, objs(evictedWorkload(t0),
		terminatingPod("p0", t0.Add(-time.Minute), t0.Add(45*time.Second)))...)

	f.reconcile()
	first := f.pod("p0").ResourceVersion
	f.clock = now.Add(2 * time.Second)
	f.reconcile()
	f.reconcile()

	if got := f.pod("p0").ResourceVersion; got != first {
		t.Errorf("pod was patched again on a repeat reconcile (rv %s → %s)", first, got)
	}
	if got := testutil.ToFloat64(f.metrics.Notices.WithLabelValues(kueue.InCohortReclamationReason)); got != 1 {
		t.Errorf("notices = %v, want exactly 1 across repeat reconciles", got)
	}
}

func TestMarksReclaimedWhenVictimsAreGone(t *testing.T) {
	f := newFixture(t, objs(evictedWorkload(t0),
		terminatingPod("p0", t0.Add(-time.Minute), t0.Add(45*time.Second)))...)

	f.reconcile()
	if f.workload().Annotations[AnnReclaimedAt] != "" {
		t.Fatal("marked reclaimed while a victim pod still exists")
	}

	f.clock = t0.Add(46 * time.Second)
	f.finishPod("p0")
	res := f.reconcile()

	if got := f.workload().Annotations[AnnReclaimedAt]; got != f.clock.Format(time.RFC3339) {
		t.Errorf("%s = %q, want %q", AnnReclaimedAt, got, f.clock.Format(time.RFC3339))
	}
	if res.RequeueAfter != 0 {
		t.Errorf("RequeueAfter = %v after reclaim, want 0", res.RequeueAfter)
	}
	if n := testutil.CollectAndCount(f.metrics.ReclaimSeconds); n != 1 {
		t.Errorf("reclaim histogram series = %d, want 1", n)
	}
	// One more reconcile must not observe the reclaim twice.
	f.reconcile()
	if got := histCount(t, f.metrics.ReclaimSeconds); got != 1 {
		t.Errorf("reclaim observations = %d, want 1", got)
	}
}

func TestIgnoresPodsCreatedAfterEviction(t *testing.T) {
	// The workload was evicted and immediately re-admitted: a fresh pod exists
	// that has nothing to do with the eviction.
	fresh := terminatingPod("new", t0.Add(3*time.Second), t0.Add(time.Hour))
	fresh.DeletionTimestamp, fresh.Finalizers = nil, nil
	f := newFixture(t, objs(evictedWorkload(t0), fresh)...)

	f.reconcile()
	f.reconcile()

	if got := f.pod("new").Annotations[AnnDeadline]; got != "" {
		t.Errorf("post-eviction pod got a notice: %q", got)
	}
	if f.workload().Annotations[AnnReclaimedAt] == "" {
		t.Error("no victims left, workload should be marked reclaimed")
	}
}

func TestNewEvictionGetsNewNotice(t *testing.T) {
	f := newFixture(t, objs(evictedWorkload(t0),
		terminatingPod("p0", t0.Add(-time.Minute), t0.Add(45*time.Second)))...)
	f.reconcile()
	f.finishPod("p0")
	f.clock = t0.Add(50 * time.Second)
	f.reconcile() // reclaimed

	// Re-admitted, then evicted again ten minutes later.
	t1 := t0.Add(10 * time.Minute)
	wl := f.workload()
	for i := range wl.Status.Conditions {
		wl.Status.Conditions[i].LastTransitionTime = metav1.NewTime(t1)
	}
	if err := f.c.Status().Update(context.Background(), wl); err != nil {
		t.Fatal(err)
	}
	// This time the notice races ahead of the Job controller: the victim pod
	// isn't terminating yet, so the deadline is now + its 45s grace period.
	p1 := terminatingPod("p1", t1.Add(-time.Minute), time.Time{})
	p1.DeletionTimestamp, p1.Finalizers = nil, nil
	if err := f.c.Create(context.Background(), p1); err != nil {
		t.Fatal(err)
	}
	f.clock = t1.Add(time.Second)
	f.reconcile()

	if got, want := f.pod("p1").Annotations[AnnDeadline], f.clock.Add(45*time.Second).Format(time.RFC3339); got != want {
		t.Errorf("second eviction deadline = %q, want %q", got, want)
	}
	got := f.workload().Annotations
	if got[AnnNoticeFor] != t1.Format(time.RFC3339) {
		t.Errorf("%s = %q, want the second eviction %q", AnnNoticeFor, got[AnnNoticeFor], t1.Format(time.RFC3339))
	}
	if got[AnnReclaimedAt] != "" {
		t.Errorf("stale %s from the first eviction: %q", AnnReclaimedAt, got[AnnReclaimedAt])
	}
	if n := testutil.ToFloat64(f.metrics.Notices.WithLabelValues(kueue.InCohortReclamationReason)); n != 2 {
		t.Errorf("notices = %v, want 2", n)
	}
}

func TestDeadlineFallsBackToGracePeriod(t *testing.T) {
	p := &corev1.Pod{Spec: corev1.PodSpec{TerminationGracePeriodSeconds: ptr.To[int64](20)}}
	if got, want := Deadline(p, now), now.Add(20*time.Second); !got.Equal(want) {
		t.Errorf("Deadline = %v, want %v", got, want)
	}
	if got, want := Deadline(&corev1.Pod{}, now), now.Add(30*time.Second); !got.Equal(want) {
		t.Errorf("Deadline without grace = %v, want default 30s → %v", got, want)
	}
}

func histCount(t *testing.T, h prometheus.Histogram) uint64 {
	t.Helper()
	ch := make(chan prometheus.Metric, 1)
	h.Collect(ch)
	var m dto.Metric
	if err := (<-ch).Write(&m); err != nil {
		t.Fatal(err)
	}
	return m.GetHistogram().GetSampleCount()
}
