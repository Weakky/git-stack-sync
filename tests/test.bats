#!/usr/bin/env bats

load 'bats-support/load'
load 'bats-assert/load'
load 'test_helper'

# --- Variables and Pre-run Checks ---
STGIT_CMD_BASE="$BATS_TEST_DIRNAME/../stgit"
STGIT_CMD=""

# Auto-detect whether the script is named 'stgit' or 'stgit.sh'
if [[ -f "$STGIT_CMD_BASE" ]]; then
    STGIT_CMD="$STGIT_CMD_BASE"
elif [[ -f "${STGIT_CMD_BASE}.sh" ]]; then
    STGIT_CMD="${STGIT_CMD_BASE}.sh"
else
    echo "🔴 Error: Could not find the stgit script. Looked for '$STGIT_CMD_BASE' and '${STGIT_CMD_BASE}.sh'." >&2
    exit 1
fi

# Check if the found script is executable
if [[ ! -x "$STGIT_CMD" ]]; then
    echo "🔴 Error: The stgit script found at '$STGIT_CMD' is not executable." >&2
    echo "💡 Please run 'chmod +x ${STGIT_CMD##*/}' to fix this." >&2
    exit 1
fi

# Add the mocks directory to the PATH so 'gh' calls resolve to our mock.
export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"

# --- Hooks ---
setup() {
    # Set up a clean git repo before each test
    setup_git_repo
}

# --- Tests for 'stgit create' ---
@test "create: creates a new child branch" {
    run "$STGIT_CMD" create feature-a
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-a'"

    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"

    run git config --get branch.feature-a.parent
    assert_output "main"
}

@test "create: creates a nested child branch" {
    # Setup: Create the first branch in the stack
    run "$STGIT_CMD" create feature-a
    assert_success
    
    # Action: Create the nested branch
    run "$STGIT_CMD" create feature-b
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-b'"

    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b"

    run git config --get branch.feature-b.parent
    assert_output "feature-a"
}

# --- Tests for commands on the base branch ---
@test "next: fails when run on the base branch" {
    # Setup: We are on 'main' by default
    run "$STGIT_CMD" next
    assert_failure
    assert_output --partial "command cannot be run from the base branch"
}

@test "status: fails when run on the base branch and lists stacks" {
    # Setup a stack to be listed
    "$STGIT_CMD" create feature-a
    "$STGIT_CMD" create feature-b
    git checkout main

    # Action
    run "$STGIT_CMD" status
    assert_failure
    assert_output --partial "Found 1 stack(s):"
    assert_output --partial "- feature-a (2 branches)"
}

