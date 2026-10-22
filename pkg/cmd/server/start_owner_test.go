package server

import (
	"testing"
	"time"

	helmv2 "github.com/fluxcd/helm-controller/api/v2"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/cozystack/cozystack/api/v1alpha1"
	"github.com/cozystack/cozystack/pkg/config"
)

// TestOwnedDefinitionsDropsKindDuplicate pins that cozystack-api registers one
// resource per kind: a definition declaring a kind an older definition already
// owns is left out rather than registered as a second resource for one GVK, and
// is reported so the operator can see why its kind is missing.
func TestOwnedDefinitionsDropsKindDuplicate(t *testing.T) {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	mk := func(name, kind string, at time.Time) v1alpha1.ApplicationDefinition {
		d := v1alpha1.ApplicationDefinition{ObjectMeta: metav1.ObjectMeta{Name: name, CreationTimestamp: metav1.NewTime(at)}}
		d.Spec.Application.Kind = kind
		return d
	}
	kept, skipped := ownedDefinitions([]v1alpha1.ApplicationDefinition{
		mk("a-redis-shadow", "Redis", base.Add(time.Hour)),
		mk("redis", "Redis", base),
		mk("postgres", "Postgres", base),
		mk("no-kind", "", base),
	})
	names := map[string]bool{}
	for _, d := range kept {
		names[d.Name] = true
	}
	// A definition with no kind claims nothing, so it is not anyone's duplicate.
	if len(kept) != 3 || !names["redis"] || !names["postgres"] || !names["no-kind"] {
		t.Fatalf("kept = %v, want redis, postgres and no-kind", names)
	}
	if len(skipped) != 1 || skipped[0] != `ApplicationDefinition "a-redis-shadow" declares kind Redis already owned by "redis"` {
		t.Fatalf("skipped = %q", skipped)
	}
}

// TestResourceConfigFromRegistersOwnerOnly pins that the resource config
// cozystack-api serves is built from the owners only: one resource per kind,
// carrying the owner's chart.
func TestResourceConfigFromRegistersOwnerOnly(t *testing.T) {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	mk := func(name, artifact string, at time.Time) v1alpha1.ApplicationDefinition {
		d := v1alpha1.ApplicationDefinition{ObjectMeta: metav1.ObjectMeta{Name: name, CreationTimestamp: metav1.NewTime(at)}}
		d.Spec.Application.Kind = "Redis"
		d.Spec.Release.ChartRef = &helmv2.CrossNamespaceSourceReference{Kind: "ExternalArtifact", Name: artifact, Namespace: "cozy-system"}
		return d
	}
	rc := resourceConfigFrom([]v1alpha1.ApplicationDefinition{
		mk("a-redis-shadow", "shadow-artifact", base.Add(time.Hour)),
		mk("redis", "redis-artifact", base),
	}, helmReleaseFlagValues{})
	if len(rc.Resources) != 1 || rc.Resources[0].Release.ChartRef.Name != "redis-artifact" {
		t.Fatalf("resources = %+v, want the owner's redis-artifact only", rc.Resources)
	}
}

// TestResourceConfigFromSkipsMalformedDefinition pins that a definition whose
// release.cozystack.io/* annotation does not parse is left out while the valid
// ones are still registered, so it cannot keep cozystack-api from starting.
func TestResourceConfigFromSkipsMalformedDefinition(t *testing.T) {
	mk := func(name, kind, timeout string) v1alpha1.ApplicationDefinition {
		d := v1alpha1.ApplicationDefinition{ObjectMeta: metav1.ObjectMeta{Name: name}}
		d.Spec.Application.Kind = kind
		d.Spec.Release.ChartRef = &helmv2.CrossNamespaceSourceReference{Kind: "ExternalArtifact", Name: name, Namespace: "cozy-system"}
		if timeout != "" {
			d.Annotations = map[string]string{config.HelmInstallTimeoutAnnotation: timeout}
		}
		return d
	}
	rc := resourceConfigFrom([]v1alpha1.ApplicationDefinition{
		mk("redis", "Redis", ""),
		mk("broken", "Broken", "not-a-duration"),
		mk("postgres", "Postgres", "10m"),
	}, helmReleaseFlagValues{})
	var kinds []string
	for _, r := range rc.Resources {
		kinds = append(kinds, r.Application.Kind)
	}
	if len(kinds) != 2 || kinds[0] != "Redis" || kinds[1] != "Postgres" {
		t.Fatalf("registered kinds = %v, want Redis and Postgres only", kinds)
	}
}
