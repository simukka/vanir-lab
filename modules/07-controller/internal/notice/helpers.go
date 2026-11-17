// Package notice implements the eviction-notice controller: when Kueue evicts
// a workload running on perishable capacity, tell its pods why and by when
// they must be gone, and measure how long the reclaim actually took.
package notice

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	kueue "sigs.k8s.io/kueue/apis/kueue/v1beta2"
)

const (
	// PerishableLabel marks a ClusterQueue whose workloads run on borrowed,
	// reclaimable capacity (spot, backfill, health checks).
	PerishableLabel = "vanir.lab/perishable"

	// Pod annotations: the notice itself. Readable from inside the container
	// through a downward API volume (metadata.annotations).
	AnnReason   = "vanir.lab/eviction-reason"
	AnnMessage  = "vanir.lab/eviction-message"
	AnnDeadline = "vanir.lab/eviction-deadline"

	// Workload annotations: controller bookkeeping.
	// AnnNoticeFor holds the Evicted condition's transition time the notice was
	// sent for, so a later, separate eviction gets its own notice.
	AnnNoticeFor    = "vanir.lab/notice-for"
	AnnNoticeSentAt = "vanir.lab/notice-sent-at"
	AnnReclaimedAt  = "vanir.lab/reclaimed-at"

	jobNameLabel = "batch.kubernetes.io/job-name"
)

// EvictedCondition returns the workload's Evicted condition if it is True.
func EvictedCondition(wl *kueue.Workload) *metav1.Condition {
	c := apimeta.FindStatusCondition(wl.Status.Conditions, kueue.WorkloadEvicted)
	if c == nil || c.Status != metav1.ConditionTrue {
		return nil
	}
	return c
}

// EvictionReason prefers the specific preemption reason (InCohortReclamation,
// InClusterQueue, ...) over the generic Evicted reason (Preempted).
func EvictionReason(wl *kueue.Workload) (reason, message string) {
	if c := apimeta.FindStatusCondition(wl.Status.Conditions, kueue.WorkloadPreempted); c != nil && c.Status == metav1.ConditionTrue {
		return c.Reason, c.Message
	}
	if c := EvictedCondition(wl); c != nil {
		return c.Reason, c.Message
	}
	return "", ""
}

// IsPerishable reports whether the workload's ClusterQueue (resolved through
// its LocalQueue) carries the perishable label. Admission is cleared on
// eviction, so status.admission can't be used here.
func IsPerishable(ctx context.Context, c client.Client, wl *kueue.Workload) (bool, error) {
	if wl.Spec.QueueName == "" {
		return false, nil
	}
	var lq kueue.LocalQueue
	if err := c.Get(ctx, types.NamespacedName{Namespace: wl.Namespace, Name: string(wl.Spec.QueueName)}, &lq); err != nil {
		return false, client.IgnoreNotFound(err)
	}
	var cq kueue.ClusterQueue
	if err := c.Get(ctx, types.NamespacedName{Name: string(lq.Spec.ClusterQueue)}, &cq); err != nil {
		return false, client.IgnoreNotFound(err)
	}
	return cq.Labels[PerishableLabel] == "true", nil
}

// PodsForWorkload lists the pods behind a workload. Supports batch Jobs and
// plain pods (Kueue pod integration, e.g. Deployment replicas).
func PodsForWorkload(ctx context.Context, c client.Client, wl *kueue.Workload) ([]corev1.Pod, error) {
	for _, ref := range wl.OwnerReferences {
		switch {
		case ref.Kind == "Job" && ref.APIVersion == "batch/v1":
			var pods corev1.PodList
			if err := c.List(ctx, &pods, client.InNamespace(wl.Namespace),
				client.MatchingLabels{jobNameLabel: ref.Name}); err != nil {
				return nil, fmt.Errorf("listing pods of job %s: %w", ref.Name, err)
			}
			return pods.Items, nil
		case ref.Kind == "Pod" && ref.APIVersion == "v1":
			var pod corev1.Pod
			err := c.Get(ctx, types.NamespacedName{Namespace: wl.Namespace, Name: ref.Name}, &pod)
			if err != nil {
				return nil, client.IgnoreNotFound(err)
			}
			return []corev1.Pod{pod}, nil
		}
	}
	return nil, nil
}

// Victims filters pods to those that existed when the workload was evicted
// and are still holding resources. Pods created afterwards belong to a later
// re-admission, not to this eviction.
func Victims(pods []corev1.Pod, evictedAt time.Time) []corev1.Pod {
	var out []corev1.Pod
	for _, p := range pods {
		if p.CreationTimestamp.After(evictedAt) {
			continue
		}
		if p.Status.Phase == corev1.PodSucceeded || p.Status.Phase == corev1.PodFailed {
			continue
		}
		out = append(out, p)
	}
	return out
}

// Deadline is when the pod will be killed: its deletionTimestamp if the
// deletion has started (that already includes the grace period), otherwise
// now plus its terminationGracePeriodSeconds.
func Deadline(p *corev1.Pod, now time.Time) time.Time {
	if p.DeletionTimestamp != nil {
		return p.DeletionTimestamp.Time
	}
	grace := int64(corev1.DefaultTerminationGracePeriodSeconds)
	if p.Spec.TerminationGracePeriodSeconds != nil {
		grace = *p.Spec.TerminationGracePeriodSeconds
	}
	return now.Add(time.Duration(grace) * time.Second)
}
