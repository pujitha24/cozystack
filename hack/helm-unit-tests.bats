#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Unit tests for hack/helm-unit-tests.sh, which decides per package directory
# whether to run `make test` and turns the results into one exit code.
#
# The script judges a package by that exit code alone, and exit 0 has two very
# different meanings. helm-unittest is fail-closed on a suite it cannot parse
# and on a suite declaring `tests: []`, but fail-open on suites that are not
# there at all: it prints "Test Suites: 0 passed, 0 total" and exits 0. So a
# chart whose suites were deleted, moved, or renamed past the `tests/*_test.yaml`
# glob reports success having asserted nothing. The other way in is the
# discovery gate: `make -C dir -n test` succeeds for a file-backed target too, so
# a path named `test` beside a package Makefile whose `test:` rule is not phony
# makes both the gate and the run exit 0 without the recipe firing.
#
# The fixtures below stub `make` output rather than invoking helm, so the tests
# stay hermetic and need no plugin installed. What they exercise is the script's
# own reaction to each shape of output.
#
# cozytest.sh's awk parser recognizes only @test blocks and a bare `}` at column
# 0, and injects `set -e`, so exit statuses are captured explicitly.
#
# Run with: hack/cozytest.sh hack/helm-unit-tests.bats
# -----------------------------------------------------------------------------

# Build a throwaway tree with one package whose `make test` prints $1 and exits
# $2. Echoes the tree root.
_tree() {
    _t=$(mktemp -d)
    mkdir -p "$_t/packages/apps/sample"
    printf 'test:\n\t@printf "%%s\\n" "%s"\n\t@exit %s\n' "$1" "$2" \
        > "$_t/packages/apps/sample/Makefile"
    printf '%s' "$_t"
}

@test "a chart reporting zero test suites fails instead of passing silently" {
    repo=$(pwd)
    t=$(_tree "Test Suites: 0 passed, 0 total" 0)

    rc=0
    out=$(cd "$t" && sh "$repo/hack/helm-unit-tests.sh" 2>&1) || rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "helm-unit-tests.sh exited 0 for a chart that ran no suites:" >&2
        echo "$out" >&2
        echo "a chart whose suite files vanished would report success" >&2
        rm -rf "$t"
        exit 1
    fi

    # Assert on this check's own wording, so the test cannot stay green on a
    # refusal that came from somewhere else.
    case "$out" in
        *"ran no test suites"*) ;;
        *)
            echo "refused, but not by the zero-suite check:" >&2
            echo "$out" >&2
            rm -rf "$t"
            exit 1
            ;;
    esac

    rm -rf "$t"
}

@test "a shadowed test target is refused before it can no-op" {
    # `make -n test` succeeds against a file-backed target, so the discovery
    # gate cannot tell a real recipe from one make will skip. The script has to
    # notice the colliding path itself.
    repo=$(pwd)
    t=$(_tree "Test Suites: 1 passed, 1 total" 0)
    touch "$t/packages/apps/sample/test"

    rc=0
    out=$(cd "$t" && sh "$repo/hack/helm-unit-tests.sh" 2>&1) || rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "helm-unit-tests.sh exited 0 with a path named 'test' beside the Makefile:" >&2
        echo "$out" >&2
        echo "make would report the target up to date and skip the recipe" >&2
        rm -rf "$t"
        exit 1
    fi

    case "$out" in
        *"reported up to date"*) ;;
        *)
            echo "refused, but not by the shadowed-target check:" >&2
            echo "$out" >&2
            rm -rf "$t"
            exit 1
            ;;
    esac

    rm -rf "$t"
}

@test "a colliding path is tolerated when the target is declared phony" {
    # The check has to key on what make reports, not on the path existing: a
    # package declaring `.PHONY: test` runs its recipe regardless of what sits
    # beside the Makefile, so rejecting it would be a false failure — and would
    # contradict the remedy the other check names.
    repo=$(pwd)
    t=$(mktemp -d)
    mkdir -p "$t/packages/apps/sample"
    printf '.PHONY: test\ntest:\n\t@printf "%%s\\n" "Test Suites: 1 passed, 1 total"\n' \
        > "$t/packages/apps/sample/Makefile"
    touch "$t/packages/apps/sample/test"

    rc=0
    out=$(cd "$t" && sh "$repo/hack/helm-unit-tests.sh" 2>&1) || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "helm-unit-tests.sh rejected a phony target whose recipe does run:" >&2
        echo "$out" >&2
        rm -rf "$t"
        exit 1
    fi

    rm -rf "$t"
}

@test "a sub-make reporting another target up to date is not mistaken for ours" {
    # The shadowed-target check keys on make's wording, so it has to distinguish
    # our target from any other whose name merely ends in "test". A package that
    # delegates to a sub-make can legitimately print such a line while its own
    # suites run.
    repo=$(pwd)
    t=$(mktemp -d)
    mkdir -p "$t/packages/apps/sample"
    {
        printf 'test:\n'
        printf '\t@printf "%%s\\n" "make[1]: '"'"'unittest'"'"' is up to date."\n'
        printf '\t@printf "%%s\\n" "Test Suites: 2 passed, 2 total"\n'
    } > "$t/packages/apps/sample/Makefile"

    rc=0
    out=$(cd "$t" && sh "$repo/hack/helm-unit-tests.sh" 2>&1) || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "helm-unit-tests.sh refused a package over an unrelated target:" >&2
        echo "$out" >&2
        rm -rf "$t"
        exit 1
    fi

    rm -rf "$t"
}

@test "a chart that runs suites still passes" {
    # Guards against the two checks above being satisfied by refusing everything.
    repo=$(pwd)
    t=$(_tree "Test Suites: 3 passed, 3 total" 0)

    rc=0
    out=$(cd "$t" && sh "$repo/hack/helm-unit-tests.sh" 2>&1) || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "helm-unit-tests.sh rejected a chart that ran three suites:" >&2
        echo "$out" >&2
        rm -rf "$t"
        exit 1
    fi

    rm -rf "$t"
}

@test "a package whose tests fail is still reported" {
    # The pre-existing behaviour, pinned so the new checks cannot replace it.
    repo=$(pwd)
    t=$(_tree "Test Suites: 1 failed, 1 total" 1)

    rc=0
    out=$(cd "$t" && sh "$repo/hack/helm-unit-tests.sh" 2>&1) || rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "helm-unit-tests.sh exited 0 for a package whose tests failed:" >&2
        echo "$out" >&2
        rm -rf "$t"
        exit 1
    fi

    case "$out" in
        *"packages/apps/sample"*) ;;
        *)
            echo "the failing package was not named in the summary:" >&2
            echo "$out" >&2
            rm -rf "$t"
            exit 1
            ;;
    esac

    rm -rf "$t"
}

@test "a package with no test target is skipped, not failed" {
    # The script must stay silent about the many packages that define no `test`
    # rule at all, or every run turns red on packages that never had suites.
    repo=$(pwd)
    t=$(mktemp -d)
    mkdir -p "$t/packages/apps/notests"
    printf 'build:\n\t@echo nothing\n' > "$t/packages/apps/notests/Makefile"

    rc=0
    out=$(cd "$t" && sh "$repo/hack/helm-unit-tests.sh" 2>&1) || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "helm-unit-tests.sh failed on a package that defines no test target:" >&2
        echo "$out" >&2
        rm -rf "$t"
        exit 1
    fi

    rm -rf "$t"
}
