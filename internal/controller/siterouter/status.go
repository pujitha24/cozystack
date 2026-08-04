// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The Cozystack Authors.

package siterouter

import (
	"context"
	"fmt"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// reasonPendingRoutes is the stable, machine-readable reason the controller
// records when tenant workload pods have not yet inherited the site-router return
// route. It is part of the D4 machine-readable contract the upstream consumer
// consumes at runtime — do not rename without updating the consumers.
const reasonPendingRoutes = "PendingRoutes"

// reasonBootImageUnavailable is the stable reason recorded when an instance's boot
// disk has no clone source: the golden appliance DataVolume is absent. Same
// machine-readable contract as reasonPendingRoutes — do not rename casually.
const reasonBootImageUnavailable = "BootImageUnavailable"

// goldenBootImage addresses the shared appliance DataVolume every gateway boot
// disk clones. It is a contract with two charts and must be kept in sync with
// both: packages/system/vyos-router-image/templates/dv.yaml creates it, and
// packages/apps/site-router/templates/dv.yaml clones it.
const (
	goldenBootImageNamespace = "cozy-public"
	goldenBootImageName      = "vyos-router"
)

// dataVolumeGVK is the CDI DataVolume kind, read as unstructured — the repo reads
// KubeVirt/CDI objects by GVK rather than vendoring their API module (see
// vyospush.go's vmiGVK).
var dataVolumeGVK = schema.GroupVersionKind{Group: "cdi.kubevirt.io", Version: "v1beta1", Kind: "DataVolume"}

// updateStatus surfaces the instance's status. In Phase 1 the runtime readiness
// (tunnel up, source filter active) rides the gateway WorkloadMonitor (rendered by
// T10) plus the HelmRelease Ready condition, NOT a status subresource on the app
// CR — convertHelmReleaseToApplication is deliberately not extended (D9). The one
// signal this step surfaces directly is the set of tenant workload pods still
// missing the return route: kube-ovn only stamps ovn.kubernetes.io/routes onto a
// pod at CREATE, so pods that predate the route keep lagging until they restart.
// The controller reports them (count + names) via a recorded Event and MUTATES
// NOTHING — rolling a pod is the tenant's decision, never the controller's.
func (r *SiteRouterReconciler) updateStatus(ctx context.Context, inst *instance) error {
	if err := r.surfaceBootImageUnavailable(ctx, inst); err != nil {
		return err
	}
	return r.surfacePendingRoutePods(ctx, inst)
}

// surfaceBootImageUnavailable records a Warning Event when the instance's boot disk
// has no clone source, i.e. the golden appliance DataVolume is missing.
//
// This exists because the chart cannot report it. The boot DataVolume clones
// cozy-public/vyos-router, and the app chart looks that golden up to guard against
// a terminally-failed import and a StorageClass mismatch — but `lookup` returns
// nothing both on a cluster with no golden and under a clusterless `helm template`,
// so the chart cannot tell absence from "there is no cluster to ask" and must not
// fail on it. The controller can: it always runs against a live cluster, so a
// NotFound here is the real thing.
//
// Without this the failure is silent in the way the review called out — a
// DataVolume stuck Pending on a source PVC that does not exist, a VM that never
// boots, and nothing anywhere saying why. Read-only and best-effort: it records an
// Event and mutates nothing.
func (r *SiteRouterReconciler) surfaceBootImageUnavailable(ctx context.Context, inst *instance) error {
	// The HTTP override does not clone the golden, so its absence is irrelevant.
	if boolField(inst.values["image"], "enabled") {
		return nil
	}

	dv := &unstructured.Unstructured{}
	dv.SetGroupVersionKind(dataVolumeGVK)
	err := r.reader().Get(ctx, types.NamespacedName{
		Namespace: goldenBootImageNamespace,
		Name:      goldenBootImageName,
	}, dv)
	if err == nil {
		return nil
	}
	if !apierrors.IsNotFound(err) {
		// Anything other than NotFound (RBAC, API outage, CRD absent) is not
		// evidence the golden is missing, and reporting it as such would be a lie.
		return fmt.Errorf("get golden boot image %s/%s: %w",
			goldenBootImageNamespace, goldenBootImageName, err)
	}

	if r.Recorder != nil {
		r.Recorder.Eventf(inst.hr, corev1.EventTypeWarning, reasonBootImageUnavailable,
			"boot disk has no clone source: golden appliance DataVolume %s/%s does not exist, so this gateway's boot disk stays Pending and the VM never starts. Ensure the cozystack.vyos-router-image package is installed, or set image.enabled=true with image.url to import an appliance disk over HTTP instead.",
			goldenBootImageNamespace, goldenBootImageName)
	}
	return nil
}

// surfacePendingRoutePods records an Event naming the tenant workload pods in the
// instance namespace that have not yet inherited every route entry the namespace
// carries. It is read-only: it never patches, deletes or restarts a pod. Gateway
// pods (this instance's or a co-tenant site-router's) are excluded — they are the
// next hop, not workloads that need the return route — as are pods already being
// torn down. When no route is programmed yet, or every workload is up to date,
// nothing is recorded.
func (r *SiteRouterReconciler) surfacePendingRoutePods(ctx context.Context, inst *instance) error {
	// A route is only pending once this instance actually declares remoteCIDRs.
	if len(stringSlice(inst.values[remoteCIDRsValueKey])) == 0 {
		return nil
	}

	ns := &corev1.Namespace{}
	if err := r.reader().Get(ctx, types.NamespacedName{Name: inst.namespace}, ns); err != nil {
		return fmt.Errorf("get namespace %s for pending-route surfacing: %w", inst.namespace, err)
	}
	wantDsts, err := routeDsts(ns.Annotations[routesAnnotation])
	if err != nil {
		return fmt.Errorf("decode namespace %s routes annotation: %w", inst.namespace, err)
	}
	if len(wantDsts) == 0 {
		return nil // nothing programmed yet; nothing can be pending
	}

	// List through the UNCACHED reader: the controller's Pod cache is label-scoped
	// to SiteRouter gateway pods (CacheByObject), so ordinary tenant workload pods
	// are absent from it. Listing them through the cached client would find none
	// and the PendingRoutes event would never fire in production.
	pods := &corev1.PodList{}
	if err := r.reader().List(ctx, pods, client.InNamespace(inst.namespace)); err != nil {
		return fmt.Errorf("list pods in namespace %s: %w", inst.namespace, err)
	}

	var pending []string
	for i := range pods.Items {
		p := &pods.Items[i]
		// A gateway pod (this or a co-tenant site-router) is the route's next hop,
		// not a workload that needs the return route — skip it.
		if p.Labels[appKindLabelKey] == siteRouterKind {
			continue
		}
		// A pod on its way out will be replaced with the annotation inherited.
		if p.DeletionTimestamp != nil {
			continue
		}
		haveDsts, err := routeDsts(p.Annotations[routesAnnotation])
		if err != nil {
			// A pod carrying an unparseable annotation is not the controller's to
			// interpret; leave it out rather than guess it is pending.
			continue
		}
		if !coversDsts(haveDsts, wantDsts) {
			pending = append(pending, p.Name)
		}
	}
	if len(pending) == 0 {
		return nil
	}

	sort.Strings(pending)
	if r.Recorder != nil {
		r.Recorder.Eventf(inst.hr, corev1.EventTypeNormal, reasonPendingRoutes,
			"%d tenant pod(s) have not yet inherited the site-router return route and will reach the remote site only after they restart: %s",
			len(pending), strings.Join(pending, ", "))
	}
	return nil
}

// routeDsts decodes an ovn.kubernetes.io/routes annotation value into the set of
// its destination CIDRs, reusing the same decoder the mediation path uses. An
// empty value yields an empty set (not an error).
func routeDsts(annotation string) (map[string]struct{}, error) {
	entries, err := decodeRoutes(annotation)
	if err != nil {
		return nil, err
	}
	out := make(map[string]struct{}, len(entries))
	for _, e := range entries {
		out[e.Dst] = struct{}{}
	}
	return out, nil
}

// coversDsts reports whether have contains every destination in want — i.e. the
// pod already carries every route the namespace does (co-tenant extras on the pod
// are fine). An empty want is trivially covered.
func coversDsts(have, want map[string]struct{}) bool {
	for d := range want {
		if _, ok := have[d]; !ok {
			return false
		}
	}
	return true
}
