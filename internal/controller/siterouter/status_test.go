// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The Cozystack Authors.

package siterouter

// T09 status-surface tests — written FIRST (Phase A).
//
// Two surfaces, both consumed by the upstream consumer at runtime (DECISIONS.md D4/D9):
//
//   - pending-route pods: after the controller programs the namespace
//     ovn.kubernetes.io/routes annotation, the kube-ovn webhook only inherits it
//     onto pods at CREATE, so pods that predate the route keep lagging until they
//     roll. The controller surfaces which tenant workload pods are still missing
//     the route (count + names) via a recorded Event — WITHOUT restarting or
//     deleting anything (that is the tenant's decision).
//   - machine-readable reasons: the reconcile-error/Event reasons are a stable
//     contract; a rename would break the upstream consumer's runtime consumption.
//
// Phase B adds the pending-route surfacing (in updateStatus / a helper it calls)
// and the reasonPendingRoutes constant. Until then these are red.

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/cozystack/cozystack/internal/siterouter/denyset"
)

// tenantPod builds a plain tenant workload pod in tenant-test. It deliberately
// carries NO SiteRouter lineage labels, so the pending-route detection treats it
// as a workload that needs the return route — not as the gateway pod (which the
// detection must exclude). An optional routes annotation stands in for a pod that
// already inherited the namespace route (up-to-date) vs one that has not
// (lagging).
func tenantPod(name string, annotations map[string]string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:        name,
			Namespace:   "tenant-test",
			Annotations: annotations,
		},
		Status: corev1.PodStatus{Phase: corev1.PodRunning, PodIP: "10.244.9.9"},
	}
}

// TestReconcile_SurfacesPendingRoutePods encodes the T09 Acceptance "pending-route
// pods are visible (condition/message or WorkloadMonitor), no restart triggered".
// After a ready reconcile programs the namespace routes, a tenant pod that has not
// yet inherited the annotation is reported as pending (by name, via an Event with
// the stable reason), an up-to-date pod is not, the gateway pod is excluded, and
// no pod is deleted or modified.
func TestReconcile_SurfacesPendingRoutePods(t *testing.T) {
	fakeV := &fakeVyOS{retrieveResult: json.RawMessage(`{"rule":{"5":{"action":"accept"}}}`)}
	objs := readyObjects(t, "demo", routedValues(), "10.244.0.5")

	// The routes annotation this reconcile will program on the tenant namespace
	// (the two disjoint remoteCIDRs of routedValues via gateway 10.244.0.5),
	// computed with the same canonical encoder the controller uses so the
	// up-to-date pod carries a byte-identical value.
	programmed, err := mergeRoutes("", "10.244.0.5", []string{"172.31.0.0/16", "10.10.0.0/16"})
	if err != nil {
		t.Fatalf("compute programmed routes: %v", err)
	}

	upToDate := tenantPod("tenant-workload-uptodate", map[string]string{routesAnnotation: programmed})
	lagging := tenantPod("tenant-workload-lagging", nil) // predates the route; not yet inherited
	objs = append(objs, upToDate, lagging)

	r, rec := newVyOSReconciler(t, fakeV, objs...)
	reconcileInstance(t, r, "demo")

	// A pending-route Event names the lagging pod and not the up-to-date one.
	var pending string
	for _, e := range recordedEvents(rec) {
		if strings.Contains(e, reasonPendingRoutes) {
			pending = e
			break
		}
	}
	if pending == "" {
		t.Fatalf("expected a %q event surfacing pending-route pods", reasonPendingRoutes)
	}
	if !strings.Contains(pending, "tenant-workload-lagging") {
		t.Errorf("pending-route event %q should name the lagging pod", pending)
	}
	if strings.Contains(pending, "tenant-workload-uptodate") {
		t.Errorf("pending-route event %q must not report the up-to-date pod as pending", pending)
	}

	// No pod restarted or deleted — surfacing is informational only.
	for _, name := range []string{"tenant-workload-uptodate", "tenant-workload-lagging"} {
		p := &corev1.Pod{}
		if err := r.Get(context.Background(), types.NamespacedName{Namespace: "tenant-test", Name: name}, p); err != nil {
			t.Errorf("pending-route surfacing must not delete pod %s: %v", name, err)
			continue
		}
		if p.DeletionTimestamp != nil {
			t.Errorf("pending-route surfacing must not mark pod %s for deletion", name)
		}
	}
}

// TestSurfacePendingRoutePods_UsesUncachedReader encodes the R6 fix: the
// tenant-pod List must go through the uncached APIReader, not the label-scoped
// cached client. The controller's Pod cache is scoped to SiteRouter gateway pods
// (CacheByObject), so an ordinary tenant workload pod is absent from it; listing
// through the cached client would find none and the PendingRoutes event would
// never fire in production. Here the cached Client is seeded WITHOUT the lagging
// tenant pod and the uncached APIReader WITH it — the event must still fire, which
// only happens if the uncached reader is used.
func TestSurfacePendingRoutePods_UsesUncachedReader(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatalf("add client-go scheme: %v", err)
	}

	programmed, err := mergeRoutes("", "10.244.0.5", []string{"172.31.0.0/16"})
	if err != nil {
		t.Fatalf("compute programmed routes: %v", err)
	}
	ns := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{Name: "tenant-test", Annotations: map[string]string{routesAnnotation: programmed}},
	}
	lagging := tenantPod("tenant-workload-lagging", nil) // predates the route; not inherited

	// Cached client (the label-scoped Pod cache): holds the namespace but NOT the
	// tenant workload pod — the production cache never sees non-gateway pods.
	cached := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ns.DeepCopy()).Build()
	// Uncached reader: the namespace AND the lagging tenant pod.
	uncached := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ns.DeepCopy(), lagging).Build()

	rec := record.NewFakeRecorder(16)
	r := &SiteRouterReconciler{Client: cached, APIReader: uncached, Scheme: scheme, Recorder: rec}

	inst := &instance{
		hr:        siteRouterHR("demo"),
		name:      "demo",
		namespace: "tenant-test",
		values:    map[string]interface{}{"remoteCIDRs": []interface{}{"172.31.0.0/16"}},
	}

	if err := r.surfacePendingRoutePods(context.Background(), inst); err != nil {
		t.Fatalf("surfacePendingRoutePods: %v", err)
	}

	if !hasEventReason(rec, reasonPendingRoutes) {
		t.Errorf("expected a %q event via the uncached reader; the cached (gateway-only) client would miss the tenant pod and never fire it", reasonPendingRoutes)
	}
}

// TestMachineReadableReasons_Stable pins the reason strings the upstream consumer
// consumes at runtime (D4) so a rename cannot slip through. InvalidRemoteCIDR is owned by the
// shared deny-set helper; the rest are the controller's own reconcile reasons.
func TestMachineReadableReasons_Stable(t *testing.T) {
	want := map[string]string{
		denyset.ReasonInvalidRemoteCIDR: "InvalidRemoteCIDR",
		reasonConfigureFailed:           "ConfigureFailed",
		reasonSourceFilterPending:       "SourceFilterPending",
		reasonPendingRoutes:             "PendingRoutes",
		reasonBootImageUnavailable:      "BootImageUnavailable",
		reasonBGPLocalASNInvalid:        "BGPLocalASNInvalid",
	}
	for got, expect := range want {
		if got != expect {
			t.Errorf("machine-readable reason drifted: got %q, want %q", got, expect)
		}
	}
}

// goldenDV builds the shared appliance DataVolume the boot disk clones, as
// unstructured — the controller reads CDI objects by GVK rather than vendoring
// their API module.
func goldenDV() *unstructured.Unstructured {
	dv := &unstructured.Unstructured{}
	dv.SetGroupVersionKind(dataVolumeGVK)
	dv.SetNamespace(goldenBootImageNamespace)
	dv.SetName(goldenBootImageName)
	return dv
}

// schemeWithDataVolume registers the CDI DataVolume GVK so the fake client can
// serve it as unstructured.
func schemeWithDataVolume(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatalf("add client-go scheme: %v", err)
	}
	scheme.AddKnownTypeWithName(dataVolumeGVK, &unstructured.Unstructured{})
	scheme.AddKnownTypeWithName(dataVolumeGVK.GroupVersion().WithKind(dataVolumeGVK.Kind+"List"), &unstructured.UnstructuredList{})
	return scheme
}

// TestSurfaceBootImageUnavailable covers the one failure the chart cannot report.
// The app chart guards the golden it clones, but `lookup` returns nothing both on a
// cluster with no golden and under a clusterless `helm template`, so the chart
// cannot fail on absence without breaking every offline render. The controller
// always has a live cluster, so a NotFound here is real — and without this Event the
// symptom is a DataVolume stuck Pending on a source that does not exist, a VM that
// never boots, and no explanation anywhere.
func TestSurfaceBootImageUnavailable(t *testing.T) {
	tests := []struct {
		name          string
		goldenPresent bool
		values        map[string]interface{}
		wantEvent     bool
	}{
		{
			name:          "golden missing while cloning it -> Warning",
			goldenPresent: false,
			values:        map[string]interface{}{},
			wantEvent:     true,
		},
		{
			name:          "golden present -> silent",
			goldenPresent: true,
			values:        map[string]interface{}{},
			wantEvent:     false,
		},
		// The HTTP override never touches the golden, so its absence says nothing
		// about this instance and must not be reported against it.
		{
			name:          "http override with no golden -> silent",
			goldenPresent: false,
			values:        map[string]interface{}{"image": map[string]interface{}{"enabled": true}},
			wantEvent:     false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			scheme := schemeWithDataVolume(t)
			b := fake.NewClientBuilder().WithScheme(scheme)
			if tt.goldenPresent {
				b = b.WithObjects(goldenDV())
			}
			c := b.Build()
			rec := record.NewFakeRecorder(16)
			r := &SiteRouterReconciler{Client: c, APIReader: c, Scheme: scheme, Recorder: rec}

			inst := &instance{
				hr:        siteRouterHR("demo"),
				name:      "demo",
				namespace: "tenant-test",
				values:    tt.values,
			}
			if err := r.surfaceBootImageUnavailable(context.Background(), inst); err != nil {
				t.Fatalf("surfaceBootImageUnavailable: %v", err)
			}
			got := hasEventReason(rec, reasonBootImageUnavailable)
			if got != tt.wantEvent {
				t.Errorf("event %q fired = %v, want %v", reasonBootImageUnavailable, got, tt.wantEvent)
			}
		})
	}
}

// The golden's address is a contract with two charts
// (packages/system/vyos-router-image and packages/apps/site-router). Drifting
// either side makes every gateway clone a source that does not exist, so pin both.
func TestGoldenBootImageAddress_Stable(t *testing.T) {
	if goldenBootImageNamespace != "cozy-public" {
		t.Errorf("golden namespace drifted: got %q, want cozy-public", goldenBootImageNamespace)
	}
	if goldenBootImageName != "vyos-router" {
		t.Errorf("golden name drifted: got %q, want vyos-router", goldenBootImageName)
	}
}
