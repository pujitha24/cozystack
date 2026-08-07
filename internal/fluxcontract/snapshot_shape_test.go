// Package fluxcontract holds contract tests for upstream Flux types this
// repository reads through kubectl rather than through the Go API.
//
// A shell script that pulls a field out of a Kubernetes object with
// `kubectl -o jsonpath` depends on the serialized shape of an upstream Go
// struct, and nothing in the shell layer can observe that dependency. Rename
// the field upstream and the expression stops matching: kubectl prints
// nothing, exits zero, and the caller reads the empty output as an answer
// about the object rather than as a question that no longer parses.
//
// The test for that cannot live in the shell layer either. Pointing an
// expression at a document written by the same test proves the reader can read
// that document and nothing else, because a rename moves neither side.
//
// So this file supplies neither half. The expression is read out of the script
// that ships it, and the object is built from the upstream type at the version
// go.mod pins. What is left to assert is that the one still finds the other.
package fluxcontract

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	helmv2 "github.com/fluxcd/helm-controller/api/v2"
	"k8s.io/client-go/util/jsonpath"
)

// The script the e2e remediation guard runs, read at test time so the
// expression under test is the one that ships rather than a copy of it.
const guardScript = "../../hack/e2e-chainsaw/_lib/run-kubernetes.sh"

// The `-o jsonpath` argument the guard passes to kubectl, in the spellings
// kubectl accepts and both quote placements this script already mixes:
// `-ojsonpath='{range …}'` here, `-o 'jsonpath={range …}'` a few hundred lines
// up. Anchored on the range over .status.history so an unrelated jsonpath
// elsewhere in the script cannot be picked up instead.
//
// Worth covering both, because a miss is reported as "the guard stopped
// reading history" and would send the next reader to the wrong file over what
// was only a change of quoting.
//
// Single quotes only, deliberately. The expression contains `{"\n"}`, so a
// double-quoted shell argument would have to escape its way around its own
// delimiter; nobody writes it that way, and matching it would mean giving up
// the delimiter as a terminator.
var historyExpr = regexp.MustCompile(
	`--?o(?:utput)?[= ]?'?jsonpath='?(\{range \.status\.history\[\*\]\}[^']*)'`)

// readGuardExpression pulls the release-history jsonpath out of the guard. A
// miss fails rather than skips: the guard losing this read is the change this
// test exists to notice.
func readGuardExpression(t *testing.T) string {
	t.Helper()
	src, err := os.ReadFile(filepath.Clean(guardScript))
	if err != nil {
		t.Fatalf("reading %s: %v", guardScript, err)
	}
	m := historyExpr.FindSubmatch(src)
	if m == nil {
		t.Fatalf("no `-o jsonpath` over .status.history found in %s. "+
			"If the guard reads release history another way now, this test has to follow it there. "+
			"If it stopped reading history at all, the e2e remediation guard asserts nothing.",
			guardScript)
	}
	return string(m[1])
}

// A HelmRelease whose history carries the statuses the guard reads. Built from
// the upstream types, so a renamed or retyped field is a compile error here
// before it is a silent empty read against a live cluster.
func helmReleaseWithHistory() *helmv2.HelmRelease {
	return &helmv2.HelmRelease{
		Status: helmv2.HelmReleaseStatus{
			History: helmv2.Snapshots{
				{Version: 2, Status: "deployed"},
				{Version: 1, Status: "uninstalled"},
			},
		},
	}
}

// The guard's expression, run over the upstream type through JSON, the way
// kubectl runs it. Serialization is the whole point: the struct's json tags
// are what the expression actually sees.
//
// Only the match is asserted. How kubectl's printer behaves on a path that is
// absent is kubectl's own configuration, not part of the Flux contract, and
// guessing at it here would put the expectation and the fixture back in the
// same hands.
func TestGuardExpressionReadsUpstreamHistoryStatuses(t *testing.T) {
	expr := readGuardExpression(t)

	raw, err := json.Marshal(helmReleaseWithHistory())
	if err != nil {
		t.Fatalf("marshalling HelmRelease: %v", err)
	}
	var generic any
	if err := json.Unmarshal(raw, &generic); err != nil {
		t.Fatalf("unmarshalling HelmRelease: %v", err)
	}

	jp := jsonpath.New("guard")
	if err := jp.Parse(expr); err != nil {
		t.Fatalf("parsing the guard's expression %q: %v", expr, err)
	}
	var out strings.Builder
	if err := jp.Execute(&out, generic); err != nil {
		t.Fatalf("running the guard's expression %q over an upstream HelmRelease: %v. "+
			"The serialized shape no longer satisfies the expression.", expr, err)
	}

	var got []string
	for _, line := range strings.Split(out.String(), "\n") {
		if line != "" {
			got = append(got, line)
		}
	}
	want := []string{"deployed", "uninstalled"}
	if len(got) != len(want) {
		t.Fatalf("expression %q returned %q, want one line per Snapshot status %q",
			expr, out.String(), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("status %d: got %q, want %q", i, got[i], want[i])
		}
	}
}
