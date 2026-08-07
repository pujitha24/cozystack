# shellcheck shell=bash
# Helpers for asserting that a Flux HelmRelease did not fall into an
# install/upgrade remediation cycle during an e2e run.
#
# Background: Flux helm-controller's ClearFailures() zeroes
# .status.installFailures / .status.upgradeFailures on every successful
# reconciliation (see the upstream ClearFailures method on
# HelmReleaseStatus). That makes those counters useless for a guard that
# runs after the HelmRelease has reached Ready - the values are always 0.
#
# What survives a successful reconciliation is .status.history, a bounded
# list of release Snapshots. Each Snapshot carries a status field that
# tracks the Helm release state: deployed, superseded, failed, uninstalled,
# and so on. A remediation cycle leaves a footprint there, and the two
# helpers below read it at two different strengths.
#
# helmrelease_has_teardown is the narrow one: it reports whether the
# release was REMOVED, which an "uninstalled" Snapshot proves. Two
# configurations can write that status: the default RemediateOnFailure
# strategy's install remediation, which uninstalls before retrying, and an
# upgrade remediation explicitly set to strategy: uninstall (the default
# there is rollback). Which of them a release has is what tells a caller
# whether the removal was expected - under RetryOnFailure, with no
# uninstalling upgrade remediation configured, nothing in the release
# uninstalls to recover at all: a failed attempt keeps its manifests
# applied and is retried as an upgrade.
#
# helmrelease_has_remediation_cycle is the broad one: any "failed" or
# "uninstalled" Snapshot. It catches one case the narrow reading gives up,
# the upgrade remediation that rolls back rather than uninstalls and so
# leaves "failed" alone behind - but it is not proof that anything was
# removed, because "failed" is also what a retried install leaves under
# RetryOnFailure, where the manifests stayed in place throughout. A caller
# that fails a run on this reading fails it on a release that recovered by
# design; the e2e guard therefore reports this one and fails on the other.
#
# Both take a newline-delimited list of snapshot statuses (whatever the
# caller extracted via kubectl -o jsonpath or equivalent) and return 0 when
# the footprint is present, 1 otherwise. Empty input is treated as "no
# history yet, nothing observed" by both.
#
# Neither reading takes the release's configured strategy, because the
# strategy answers a different question than the history does: the history
# says what happened, the strategy says what the release was supposed to be
# able to do about it. Weighing the two against each other is the caller's
# decision and differs per caller - the e2e guard reads
# .spec.install.strategy.name and treats a teardown as a failure only on a
# release configured to retry in place, since there the removal has no
# explanation inside the release. Keeping that out of here leaves each helper
# answering one question about one list of statuses.

helmrelease_has_teardown() {
    statuses="$1"
    if [ -z "${statuses}" ]; then
        return 1
    fi
    if printf '%s\n' "${statuses}" | grep --extended-regexp --quiet '^uninstalled$'; then
        return 0
    fi
    return 1
}

helmrelease_has_remediation_cycle() {
    statuses="$1"
    if [ -z "${statuses}" ]; then
        return 1
    fi
    # printf + grep over the pipe, rather than a heredoc plus while read.
    # printf %s treats the status string as a literal payload, so any stray
    # $ in a future caller's input does not trigger shell expansion. grep
    # returns 0 iff at least one line matches the allowlist, which is
    # exactly the contract the caller wants, so we can return its exit
    # status directly.
    if printf '%s\n' "${statuses}" | grep --extended-regexp --quiet '^(failed|uninstalled)$'; then
        return 0
    fi
    return 1
}
