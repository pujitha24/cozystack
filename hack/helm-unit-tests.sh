#!/bin/sh
set -eu

# Script to run unit tests for all Helm charts.
# It iterates through directories in packages/apps, packages/core,
# packages/extra, packages/system, and packages/library and runs the 'test'
# Makefile target if it exists. Keep this list in step with the loop below:
# packages/core carries suites of its own, so dropping it to match a stale
# comment would silently stop running them.

FAILED_DIRS_FILE="$(mktemp)"
OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$FAILED_DIRS_FILE" "$OUTPUT_FILE"' EXIT

tests_found=0

check_and_run_test() {
    dir="$1"
    makefile="$dir/Makefile"

    if [ ! -f "$makefile" ]; then
        return 0
    fi

    if make -C "$dir" -n test >/dev/null 2>&1; then
        echo "Running tests in $dir"
        tests_found=$((tests_found + 1))

        # LC_ALL=C because both checks below match make and helm-unittest on
        # their English wording, and a localized make would disarm the first
        # one silently -- the failure mode this whole guard exists to remove.
        rc=0
        LC_ALL=C make -C "$dir" test > "$OUTPUT_FILE" 2>&1 || rc=$?
        cat "$OUTPUT_FILE"

        if [ "$rc" -ne 0 ]; then
            printf '%s\n' "$dir" >> "$FAILED_DIRS_FILE"
            return 1
        fi

        # The discovery gate above succeeds against a file-backed target too, so
        # it cannot tell a real recipe from one make will skip. Match what make
        # actually reports rather than looking for a colliding path, because a
        # package that declares the target phony runs its recipe regardless of
        # what sits next to the Makefile. The quoting around the target name
        # differs between make 3.x and 4.x, so accept either opening quote;
        # anchoring on the trailing quote alone would also match a sub-make
        # reporting some other target whose name ends in "test".
        if grep -qE "[\`']test' is up to date" "$OUTPUT_FILE"; then
            echo "ERROR: a 'test' target was reported up to date while testing" >&2
            echo "       $dir, so its recipe was skipped. The target is shadowed by" >&2
            echo "       a file or directory of that name, here or in a sub-make" >&2
            echo "       this package invokes. Remove the path, or declare the" >&2
            echo "       target phony in the Makefile that defines it." >&2
            printf '%s\n' "$dir" >> "$FAILED_DIRS_FILE"
            return 1
        fi

        # helm-unittest is fail-closed on a suite it cannot parse and on one
        # declaring `tests: []`, but fail-open on suites that are absent: it
        # reports zero of them and exits 0. Charts whose suites were deleted,
        # moved, or renamed past the tests/*_test.yaml glob land here.
        if grep -qE 'Test Suites:[[:space:]]+0 passed,[[:space:]]+0 total' "$OUTPUT_FILE"; then
            echo "ERROR: $dir ran no test suites. Its Makefile declares a 'test'" >&2
            echo "       target, so suite files are expected under tests/ matching" >&2
            echo "       *_test.yaml; helm-unittest exits 0 when it finds none." >&2
            printf '%s\n' "$dir" >> "$FAILED_DIRS_FILE"
            return 1
        fi

        # A third silent-pass shape is deliberately not covered, so it is not
        # rediscovered as new: a `test:` rule whose recipe never runs anything,
        # meaning it carries no recipe of its own AND no prerequisite that does.
        # make then prints "Nothing to be done for 'test'." and exits 0, the
        # discovery gate above passes, and neither marker appears. Nothing in
        # the tree is in that state: packages/system/dashboard is the only
        # recipe-less `test:` rule and its prerequisites do carry recipes.
        # Catching it needs a third match rather than a change to either of
        # the two above.
    fi

    return 0
}

for package_dir in packages/apps packages/core packages/extra packages/system packages/library; do
    if [ ! -d "$package_dir" ]; then
        echo "Warning: Directory $package_dir does not exist, skipping..." >&2
        continue
    fi

    for dir in "$package_dir"/*; do
        [ -d "$dir" ] || continue
        check_and_run_test "$dir" || true
    done
done

if [ "$tests_found" -eq 0 ]; then
    echo "No directories with 'test' Makefile targets found."
    exit 0
fi

if [ -s "$FAILED_DIRS_FILE" ]; then
    echo "ERROR: Tests failed in the following directories:" >&2
    while IFS= read -r dir; do
        echo "  - $dir" >&2
    done < "$FAILED_DIRS_FILE"
    exit 1
fi

echo "All Helm unit tests passed."