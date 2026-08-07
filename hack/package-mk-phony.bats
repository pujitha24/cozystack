#!/usr/bin/env bats
# -----------------------------------------------------------------------------
# Unit tests for the .PHONY declaration in hack/package.mk, which most package
# Makefiles under packages/ include.
#
# `.PHONY=a b c` assigns a variable; `.PHONY: a b c` declares targets. Only the
# second does anything, and make reports neither. The declaration lists the nine
# targets package.mk defines and stops there.
#
# `update` and `image` are deliberately absent: package.mk does not define them,
# the including package Makefile does, and naming an undefined target in .PHONY
# creates it as an empty target. That turns "No rule to make target" (exit 2)
# into "Nothing to be done" (exit 0) wherever the rule is missing, including the
# CI build matrix, which is parsed from the root Makefile `build:` target and
# runs `make -C <pkg> image` per unit. The last two tests pin the exclusion.
#
# The first test is narrower than its name suggests: it probes the names on the
# `.PHONY:` line, so it cannot see a name dropped from that line. The
# set-equality test is what guards every name's presence.
#
# Constraints on anyone editing this file: every make invocation is pinned to
# LC_ALL=C, because the assertions match English make wording; cozytest.sh
# recognizes only @test blocks and a bare `}` at column 0, and injects `set -e`,
# so exit statuses are captured explicitly rather than tested inline.
#
# Run with: hack/cozytest.sh hack/package-mk-phony.bats
# -----------------------------------------------------------------------------

@test "every target hack/package.mk declares phony still runs when a file of that name exists" {
    repo=$(pwd)
    targets=$(sed -n 's/^\.PHONY:[[:space:]]*//p' "$repo/hack/package.mk")

    # Without this guard the loop below is a vacuous pass against `.PHONY=`,
    # which the sed no longer matches.
    if [ -z "$targets" ]; then
        echo "no '.PHONY:' declaration found in hack/package.mk" >&2
        exit 1
    fi

    tmp=$(mktemp -d)
    printf 'include %s/hack/package.mk\n' "$repo" > "$tmp/Makefile"

    for t in $targets; do
        touch "$tmp/$t"
    done

    for t in $targets; do
        # cozytest.sh runs with `set -e`, so capture the exit status explicitly
        # rather than letting a failing make abort before the diagnostics below.
        rc=0
        out=$(LC_ALL=C make --dry-run --directory "$tmp" "$t" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "make $t exited $rc under --dry-run:" >&2
            echo "$out" >&2
            rm -rf "$tmp"
            exit 1
        fi
        case "$out" in
            *"is up to date"*)
                echo "make $t no-oped with a file named $t present:" >&2
                echo "$out" >&2
                echo "hack/package.mk does not actually declare $t phony" >&2
                rm -rf "$tmp"
                exit 1
                ;;
        esac
    done

    rm -rf "$tmp"
}

@test "the probe reports up-to-date when .PHONY is written as an assignment" {
    # Negative control: proves the probe can see a file-backed target at all.
    # Names are spelled out because deriving them from the mutated copy is what
    # stops working. help, check and clean are package.mk's only targets with no
    # prerequisites, so this does not depend on decoy timestamps.
    repo=$(pwd)
    tmp=$(mktemp -d)

    sed 's/^\.PHONY:/.PHONY=/' "$repo/hack/package.mk" > "$tmp/package.mk"
    if ! grep -q '^\.PHONY=' "$tmp/package.mk"; then
        echo "mutation to the assignment form did not apply to the copy" >&2
        rm -rf "$tmp"
        exit 1
    fi

    printf 'include %s/package.mk\n' "$tmp" > "$tmp/Makefile"

    for t in help check clean; do
        touch "$tmp/$t"
    done

    for t in help check clean; do
        rc=0
        out=$(LC_ALL=C make --dry-run --directory "$tmp" "$t" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "make $t exited $rc under --dry-run:" >&2
            echo "$out" >&2
            rm -rf "$tmp"
            exit 1
        fi
        case "$out" in
            *"is up to date"*) ;;
            *)
                echo "probe failed to detect a file-backed $t:" >&2
                echo "$out" >&2
                rm -rf "$tmp"
                exit 1
                ;;
        esac
    done

    rm -rf "$tmp"
}

@test "the .PHONY list and the targets package.mk defines are the same set" {
    # The first test only probes names already on the list, so this is the sole
    # guard on a name being dropped from it. The reverse direction catches a
    # declared-but-undefined name, which make turns into an empty target.
    # `%-update` is out of reach for both: .PHONY matches literally.
    repo=$(pwd)
    # Flattened because the `case` tests match on " name " and an embedded
    # newline makes a name fail that check and get reported wrongly.
    declared=$(sed -n 's/^\.PHONY:[[:space:]]*//p' "$repo/hack/package.mk" \
        | tr '\n' ' ')
    # A target name outside this pattern — leading underscore, dot, slash — is
    # legal in make and skipped here in silence, so keep new names inside it.
    # The second grep drops assignments, `:+` covering `::=` and `:::=`.
    defined=$(grep -E '^[A-Za-z0-9][A-Za-z0-9_-]*:' "$repo/hack/package.mk" \
        | grep -vE '^[A-Za-z0-9][A-Za-z0-9_-]*:+=' | sed 's/:.*//' | sort -u \
        | tr '\n' ' ')

    if [ -z "$declared" ] || [ -z "$defined" ]; then
        echo "could not extract targets from hack/package.mk — extraction broke" >&2
        exit 1
    fi

    missing=""
    for t in $defined; do
        case " $declared " in
            *" $t "*) ;;
            *) missing="$missing $t" ;;
        esac
    done

    if [ -n "$missing" ]; then
        echo "hack/package.mk defines these targets but does not declare them phony:$missing" >&2
        echo "a file of that name next to a package Makefile would silence the recipe" >&2
        exit 1
    fi

    undefined=""
    for t in $declared; do
        case " $defined " in
            *" $t "*) ;;
            *) undefined="$undefined $t" ;;
        esac
    done

    if [ -n "$undefined" ]; then
        echo "hack/package.mk declares these targets phony but defines none of them:$undefined" >&2
        echo "naming an undefined target in .PHONY creates it as an empty target, so the" >&2
        echo "command reports success instead of failing with 'No rule to make target'" >&2
        exit 1
    fi
}

@test "update and image stay undeclared so a package without the rule fails loudly" {
    # Pins the exclusion: a package with no `update:`/`image:` rule must still
    # fail loudly. Declaring them centrally would make every such package report
    # success having built nothing, CI included.
    repo=$(pwd)
    tmp=$(mktemp -d)

    printf 'include %s/hack/package.mk\n' "$repo" > "$tmp/Makefile"

    for t in update image; do
        rc=0
        out=$(LC_ALL=C make --directory "$tmp" "$t" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "expected 'make $t' to fail in a package that defines no $t rule," >&2
            echo "but it exited 0 — is $t named in the .PHONY list?" >&2
            echo "$out" >&2
            rm -rf "$tmp"
            exit 1
        fi
        case "$out" in
            *"No rule to make target"*) ;;
            *)
                echo "expected 'make $t' to report no rule to make target, got:" >&2
                echo "$out" >&2
                rm -rf "$tmp"
                exit 1
                ;;
        esac
    done

    rm -rf "$tmp"
}

@test "adding update and image to the .PHONY list silences that failure" {
    # Negative control. Test 4 passes vacuously if its Makefile never reads
    # package.mk at all: a broken `include` path also exits non-zero with "No
    # rule to make target", naming the missing file. This mutates a copy and
    # greps that the mutation landed, so a wrong path fails here instead.
    repo=$(pwd)
    tmp=$(mktemp -d)

    sed 's/^\(\.PHONY:.*\)$/\1 update image/' "$repo/hack/package.mk" > "$tmp/package.mk"
    if ! grep -q '^\.PHONY:.* update image$' "$tmp/package.mk"; then
        echo "mutation extending the declaration did not apply to the copy" >&2
        rm -rf "$tmp"
        exit 1
    fi

    printf 'include %s/package.mk\n' "$tmp" > "$tmp/Makefile"

    for t in update image; do
        rc=0
        out=$(LC_ALL=C make --directory "$tmp" "$t" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "mutation did not take effect: 'make $t' still failed with exit $rc" >&2
            echo "$out" >&2
            rm -rf "$tmp"
            exit 1
        fi
        case "$out" in
            *"Nothing to be done"*) ;;
            *)
                echo "expected the mutated copy to report nothing to be done for $t, got:" >&2
                echo "$out" >&2
                rm -rf "$tmp"
                exit 1
                ;;
        esac
    done

    rm -rf "$tmp"
}
