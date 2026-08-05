#!/usr/bin/env bats

# Contract for the issue triage labeler. Like promote-gate-contract.bats and
# release-freeze-contract.bats, these tests pin executable/structural workflow
# lines rather than prose: a guard demoted to a comment must never satisfy the
# contract. The workflow's own comments name every API and constant asserted
# below, so the JS block is filtered on `//` as well as `#`.
#
# No PR lane can exercise this workflow. It runs on `issues`, on a daily cron
# and on workflow_dispatch, so the first real execution is a sweep over every
# open issue in the repository, writing a label to each. The lines pinned here
# are the ones that bound that blast radius: the skip that keeps pull requests
# out of it, the skip that keeps an already-triaged issue out of it, the pacing
# and the per-run cap that keep the sweep inside GitHub's secondary rate limits,
# the pinned action, and the token scopes. Each is a single deletion away from a
# repository-wide mess that nothing reports — drop the pull-request skip and
# every open PR is told it needs triage; drop the pacing and the sweep is
# throttled and dies half done.
#
# The rate-limit tests assert the invariant (stay under GitHub's published
# ceilings) rather than today's constants, so tuning the pacing within the safe
# band does not need a test edit, while leaving it does go red.
#
# Known ceiling of the approach: these are structural greps, so they prove a
# guard is present and executable, not that it is reachable. Wrapping one in
# `if (false)` satisfies every pin here. Behavioural coverage of the script
# would need a JS runtime, and `checks` runs where none is guaranteed, so a
# harness would go silently green wherever node is missing.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/issue-triage.yaml"
STALE="$REPO_ROOT/.github/workflows/stale.yaml"
LABELS="$REPO_ROOT/.github/labels.yml"

# GitHub's documented secondary rate limits for content-generating requests.
# https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
WRITES_PER_MINUTE=80
WRITES_PER_HOUR=500

# Strip YAML comments. POSIX `grep` only: the unit-test runner has no ripgrep.
# grep exits 1 when nothing is selected (legitimate for an all-comment block)
# and 2 on a real error, so only the latter propagates.
code_lines() {
  local rc=0
  grep -v '^[[:space:]]*#' || rc=$?
  [ "$rc" -le 1 ]
}

# Strip JavaScript comments. The labeling logic lives in a github-script
# `script: |` block whose comments discuss the pull_request skip, the cap and
# the pacing by name, so filtering on `#` alone would let a comment satisfy a
# pin.
script_lines() {
  local rc=0
  grep -v '^[[:space:]]*//' || rc=$?
  [ "$rc" -le 1 ]
}

# Body of one job, up to the next top-level job key.
job_block() {
  awk -v job="  $1:" '
    $0 == job { inside = 1; next }
    /^  [a-z0-9_-]+:$/ { inside = 0 }
    inside' "$2"
}

# Integer on the right of the first `=` on the first matching line. Callers
# assert the plain-literal form first, because this strips non-digits rather
# than evaluating: `= 60 * 1000;` would read as 601000 and quietly satisfy a
# bound it never computed.
number_after_eq() {
  awk -F'=' 'NR == 1 { gsub(/[^0-9]/, "", $2); print $2 }'
}

# The declaration this file can read: one integer literal, no arithmetic.
literal_const() { # <name> <block>
  printf '%s\n' "$2" | script_lines | grep -qE "const $1 = [0-9]+;[[:space:]]*$"
}

# Minutes past midnight for a 5-field cron, from its first two fields.
cron_minutes() {
  sed "s/^[^']*'//; s/'.*$//" | awk 'NR == 1 { print $2 * 60 + $1 }'
}

@test "the workflow under contract exists" {
  [ -f "$WF" ]
}

# ── what the sweep must not touch ────────────────────────────────────────────
# listForRepo returns pull requests alongside issues, and the sweep re-reads
# every open issue every day. Both skips below are the difference between a
# no-op pass and a repository-wide mislabeling that no run reports as an error.

@test "pull requests are skipped by the classifier" {
  block="$(job_block triage "$WF")"
  [ -n "$block" ]

  # Losing this tells every open pull request it needs triage, on the first
  # sweep, with a green job.
  printf '%s\n' "$block" | script_lines | grep -qF 'if (issue.pull_request) return null'
}

@test "an issue that already carries a triage label is left alone" {
  block="$(job_block triage "$WF")"
  [ -n "$block" ]

  # The sweep is additive and never removes a label, so without this skip a
  # daily pass re-adds a second, contradictory triage/* label to issues a
  # maintainer has already classified.
  printf '%s\n' "$block" | script_lines | grep -qF "labels.some((n) => n.startsWith('triage/'))"
}

# ── staying inside GitHub's secondary rate limits ────────────────────────────
# The sweep is the only bulk writer in the tree. The action's client carries no
# throttling plugin, its retry default is off, and a throttled write answers
# 403, which is exempt from retry anyway: an unpaced sweep does not slow down
# when it is throttled, it fails the job partway and leaves the backlog half
# labeled.

@test "writes are paced under the per-minute ceiling" {
  block="$(job_block triage "$WF")"
  [ -n "$block" ]

  # The wait has to be executed, not merely declared.
  printf '%s\n' "$block" | script_lines | grep -qF 'await sleep(WRITE_INTERVAL_MS)'

  literal_const WRITE_INTERVAL_MS "$block"
  interval="$(printf '%s\n' "$block" | script_lines | grep -F 'const WRITE_INTERVAL_MS' | number_after_eq)"
  [ -n "$interval" ]
  [ "$interval" -gt 0 ]

  # 60000 / interval is the resulting writes-per-minute.
  rate="$(awk -v i="$interval" 'BEGIN { print int(60000 / i) }')"
  [ "$rate" -le "$WRITES_PER_MINUTE" ]
}

@test "a single run cannot exceed the hourly ceiling" {
  block="$(job_block triage "$WF")"
  [ -n "$block" ]

  # The cap has to gate the loop, not just exist as a constant.
  printf '%s\n' "$block" | script_lines | grep -qF 'if (writes >= MAX_WRITES_PER_RUN)'

  literal_const MAX_WRITES_PER_RUN "$block"
  cap="$(printf '%s\n' "$block" | script_lines | grep -F 'const MAX_WRITES_PER_RUN' | number_after_eq)"
  [ -n "$cap" ]
  [ "$cap" -gt 0 ]
  # Strictly under: a run sized exactly to the ceiling leaves no room for the
  # event-driven writes that share the same hourly budget.
  [ "$cap" -lt "$WRITES_PER_HOUR" ]
}

@test "a hung run cannot hold the queue for the default six hours" {
  block="$(job_block triage "$WF")"
  [ -n "$block" ]

  # Every run of this workflow shares one concurrency group, so a call that
  # hangs blocks each issue filed behind it until the job times out. A capped
  # run paces roughly seven minutes, so the bound is generous and still far
  # under the 360-minute default.
  minutes="$(printf '%s\n' "$block" | code_lines | grep -F 'timeout-minutes:' | awk -F: 'NR == 1 { gsub(/[^0-9]/, "", $2); print $2 }')"
  [ -n "$minutes" ]
  [ "$minutes" -gt 0 ]
  [ "$minutes" -lt 60 ]
}

@test "the manual entry point defaults to dry-run" {
  # Bounded by indentation: nothing below the input is a key at this level, so
  # a stop condition matching the next sibling key would run to end of file and
  # call the rest of the workflow part of the block.
  block="$(code_lines < "$WF" | awk '
    /^      dry_run:$/ { inside = 1; next }
    inside && !/^        / { exit }
    inside')"
  [ -n "$block" ]

  # workflow_dispatch is the only way a human starts a repository-wide write,
  # and this is the whole of what stands between clicking Run and one. Every
  # other guard of that class is pinned above; this one is a single word away
  # from writing to every open issue on the first click, which is exactly the
  # shape the rest of this file exists to catch.
  default="$(printf '%s\n' "$block" | awk '/^[[:space:]]*default:/ { print $2; exit }')"
  [ "$default" = "true" ]

  # The declared default is what the form shows. It is deliberately not what
  # makes this safe: the derivation keys on the event and treats an absent or
  # unrecognised input as a dry run, which is why it is pinned separately.
  # Pinning only the default would leave `const dryRun = false;` green.
  wf="$(job_block triage "$WF")"
  printf '%s\n' "$wf" | script_lines | grep -qF "context.eventName !== 'schedule' &&"
  printf '%s\n' "$wf" | script_lines | grep -qF "String(context.payload.inputs?.dry_run ?? 'true') !== 'false'"
}

@test "a failed write neither aborts the sweep nor passes unnoticed" {
  block="$(job_block triage "$WF")"
  [ -n "$block" ]

  # Without the catch, one issue transferred or deleted mid-sweep costs the run
  # the rest of the backlog and its summary line with it.
  printf '%s\n' "$block" | script_lines | grep -qF 'catch (err)'

  # A refusal is the other kind of failure and wants the opposite reaction: 403
  # is what both a lost `issues: write` and the secondary rate limit answer, 429
  # is the other throttle shape. The status is what separates them from the
  # benign 404 of a vanished issue, so the discrimination has to be on status.
  printf '%s\n' "$block" | script_lines | grep -qE "err\.status === 403.*err\.status === 429|err\.status === 429.*err\.status === 403"

  # And one refusal has to be enough to go red. Counting instead would make the
  # alarm dead in the regime the sweep lives in once the backlog is drained,
  # where a whole run writes to only a handful of issues.
  printf '%s\n' "$block" | script_lines | grep -qF 'if (refused > 0)'
  printf '%s\n' "$block" | script_lines | grep -qF 'core.setFailed'

  # And the run has to stop at the first refusal rather than carry on. A
  # refusal applies to every write left, so continuing repeats a rejected
  # request up to the cap, which is what gets an integration banned and what
  # burns the repository's hourly budget on a permission regression.
  # -A10 rather than -A5: the warning between the two is prose and gains a
  # line whenever it is reworded, which would fail this on a no-op edit.
  printf '%s\n' "$block" | script_lines | grep -A10 -F 'refused += 1;' | grep -qF 'break;'
}

# ── supply chain and token scope ─────────────────────────────────────────────

@test "every action is pinned to a digest" {
  # zizmor gates this tree-wide, but this file is the one that fails on the
  # workflow that has issues: write, so it pins its own.
  # Asserted as "every `uses:` is a digest" rather than "no tag matches a
  # tag-shaped pattern", because every such pattern has a gap: `@main` is
  # neither `@v7` nor `@1.2.3`, and a branch is the most mutable of the three.
  # Counting digests rather than naming the one action keeps a second, properly
  # pinned step from going red for no reason. A repo-local `./.github/actions/`
  # step would need an exemption here; it is not the same class of risk.
  total="$(code_lines < "$WF" | grep -cE '^[[:space:]]*(-[[:space:]]*)?uses:' || true)"
  pinned="$(code_lines < "$WF" | grep -cE '^[[:space:]]*(-[[:space:]]*)?uses:.*@[0-9a-f]{40}([[:space:]]|$)' || true)"
  [ "${total:-0}" -gt 0 ]
  [ "${total:-0}" -eq "${pinned:-0}" ]
}

@test "the token is read-only except for one job that writes issues" {
  # A job-level block replaces the top-level one rather than extending it, so
  # the two assertions below are the whole permission surface.
  code_lines < "$WF" | grep -qF 'contents: read'
  printf '%s\n' "$(job_block triage "$WF")" | code_lines | grep -qF 'issues: write'

  # Nothing else is writable. This is what keeps a labeling workflow from
  # quietly acquiring contents: write or pull-requests: write later. The
  # trailing-comment form is matched too, because a permission gets added
  # with its justification on the same line, which is exactly the shape an
  # assertion anchored at `write$` would wave through.
  count="$(code_lines < "$WF" | grep -cE '^[[:space:]]+[a-z-]+:[[:space:]]*write[[:space:]]*(#.*)?$' || true)"
  [ "${count:-0}" -eq 1 ]
}

# ── interaction with the rest of the tree ────────────────────────────────────

@test "runs are serialised and never cancelled" {
  # A sweep works from a listing taken when it started. Letting a second run
  # overlap it lets the two read the same issue differently and leave it
  # holding two contradictory labels; cancelling one mid-sweep leaves the
  # backlog half labeled with a green-looking cancelled run.
  block="$(code_lines < "$WF" | awk '/^concurrency:/ { inside = 1; next } /^[a-z]/ { inside = 0 } inside')"
  [ -n "$block" ]
  printf '%s\n' "$block" | grep -qF 'cancel-in-progress: false'
}

@test "no accepted-signal label widens the stale exemption set" {
  [ -f "$STALE" ]

  # `triage/accepted` is itself on exempt-issue-labels, so awarding it for a
  # label that is NOT on that list quietly grants a permanent reprieve the
  # stale policy withheld — which is what treating every `priority/*` tier as
  # a signal did, `priority/backlog` being the tier stale.yaml leaves reapable.
  # An assignee is deliberately not covered here: it is not a label, and its
  # exemption is the one the workflow argues for out loud.
  exempt="$(awk '
    /^[[:space:]]*exempt-issue-labels:/ { inside = 1; next }
    /^[[:space:]]*[a-z-]+:/ { inside = 0 }
    inside' "$STALE")"
  [ -n "$exempt" ]

  # One entry per line, so the containment check below can be exact. The value
  # is a folded scalar: comma-separated entries wrapped across several indented
  # lines, each line carrying a trailing comma. Matching a signal label as a
  # substring of that block would pass one that is merely a prefix of an exempt
  # entry — `priority/important` against `priority/important-soon` — and that
  # prefix is a label the stale policy never exempted.
  exempt_labels="$(printf '%s\n' "$exempt" | tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')"
  [ -n "$exempt_labels" ]

  signals="$(script_lines < "$WF" |
    awk '/const ACCEPTED_SIGNAL_LABELS = \[/ { inside = 1; next } /\];/ { inside = 0 } inside' |
    sed -n "s/^[[:space:]]*'\([^']*\)'.*/\1/p")"

  # Non-vacuous: an empty list, or a classifier that stopped reading it, must
  # not let this pass by having nothing to check.
  count="$(printf '%s\n' "$signals" | grep -c . || true)"
  [ "${count:-0}" -ge 4 ]
  printf '%s\n' "$(job_block triage "$WF")" | script_lines | grep -qF 'ACCEPTED_SIGNAL_LABELS.includes(n)'

  for label in $signals; do
    printf '%s\n' "$exempt_labels" | grep -qxF "$label"
  done
}

@test "the sweep runs after the stale bot, not before it" {
  [ -f "$STALE" ]

  # Labeling bumps updated_at, which the stale bot reads as activity. Running
  # first would hand every issue it is about to label a fresh clock in the same
  # morning, so the sweep goes second and lets that day's stale pass complete
  # on the state it was scheduled against.
  # `-e`, because the pattern opens with a dash and grep would read it as one.
  sweep="$(code_lines < "$WF" | grep -F -e '- cron:' | cron_minutes)"
  stale="$(code_lines < "$STALE" | grep -F -e '- cron:' | cron_minutes)"
  [ -n "$sweep" ] && [ -n "$stale" ]
  [ "$sweep" -gt "$stale" ]
}

@test "both labels the workflow applies are declared in the repository" {
  [ -f "$LABELS" ]

  # addLabels creates a label that does not exist, with a default colour and no
  # description, so a typo here is invisible until someone notices two triage
  # labels with almost the same name.
  for label in $(script_lines < "$WF" | grep -E "const (NEEDS_TRIAGE|ACCEPTED) = " | sed "s/^[^']*'//; s/'.*$//"); do
    code_lines < "$LABELS" | grep -qF "name: $label"
  done
}
