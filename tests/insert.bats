#!/usr/bin/env bats

load 'bats-support/load'
load 'bats-assert/load'
load 'test_helper'
load 'debug' # Load the new debug helper

# --- Variables and Pre-run Checks ---
GSS_CMD_BASE="$BATS_TEST_DIRNAME/../dist/index"
GSS_CMD=""

# Auto-detect whether the script is named 'gss' or 'gss.sh'
if [[ -f "$GSS_CMD_BASE" ]]; then
    GSS_CMD="$GSS_CMD_BASE"
elif [[ -f "${GSS_CMD_BASE}.js" ]]; then
    GSS_CMD="${GSS_CMD_BASE}.js"
else
    echo "🔴 Error: Could not find the gss script. Looked for '$GSS_CMD_BASE' and '${GSS_CMD_BASE}.sh'." >&2
    exit 1
fi

# Check if the found script is executable
if [[ ! -x "$GSS_CMD" ]]; then
    echo "🔴 Error: The gss script found at '$GSS_CMD' is not executable." >&2
    echo "💡 Please run 'chmod +x ${GSS_CMD##*/}' to fix this." >&2
    exit 1
fi

# Add the mocks directory to the PATH so 'gh' calls resolve to our mock.
export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"

# --- Hooks ---
setup() {
    # Set up a clean git repo before each test
    setup_git_repo
}

teardown() {
    # If the test failed, print detailed debug info.
    if [ "$BATS_TEST_STATUS" -ne 0 ]; then
        echo "Teardown: Test failed. Dumping state..." >&2
        gss_debug_dump "State at time of failure"
        
        echo "--- MOCK GH STATE ---" >&2
        if [ -d "/tmp/gss_mock_gh_state" ] && [ -n "$(ls -A /tmp/gss_mock_gh_state)" ]; then
            ls -l /tmp/gss_mock_gh_state/ >&2
            cat /tmp/gss_mock_gh_state/* >&2
        else
            echo "  (no mock state found)" >&2
        fi
        echo "--- END MOCK GH STATE ---" >&2
    fi
    # Clean up mock state after each test
    cleanup_mock_gh_state
}

# --- Tests for 'gss insert' ---
@test "insert: inserts a branch in the middle of a stack" {
    # This test verifies that inserting a new branch (`feature-b`) between two
    # existing branches (`feature-a` and `feature-c`) correctly updates the
    # parentage and rebases the descendant branch (`feature-c`).
    
    # Setup
    create_stack feature-a feature-c
    run git checkout feature-c
    run create_commit "commit for c"
    local c_sha_before; c_sha_before=$(git rev-parse HEAD)
    run git checkout feature-a

    # Action
    run "$GSS_CMD" insert feature-b

    # Assertions
    assert_success
    assert_output --partial "Successfully inserted 'feature-b' into the stack"

    # --- State Assertions ---
    assert_branch_parent feature-b feature-a
    assert_branch_parent feature-c feature-b
    # The original commit on 'c' should still be reachable from the new 'c'.
    assert_commit_is_reachable "$c_sha_before" feature-c
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b"
}

@test "insert: inserts a branch at the end of a stack" {
    # This tests inserting a new branch when checked out on the top-most
    # branch of a stack. It should simply extend the stack.
    
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-b

    # Action
    run "$GSS_CMD" insert feature-c

    # Assertions
    assert_success

    # --- State Assertions ---
    assert_branch_parent feature-c feature-b
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-c"
}

@test "insert: inserts --before a branch in the middle of a stack" {
    # This test verifies the `--before` flag. Inserting `feature-b` before
    # `feature-c` should place it between `feature-a` and `feature-c`.
    
    # Setup
    create_stack feature-a feature-c
    run git checkout feature-c
    run create_commit "commit for c"
    local c_sha_before; c_sha_before=$(git rev-parse HEAD)

    # Action
    run "$GSS_CMD" insert --before feature-b

    # Assertions
    assert_success

    # --- State Assertions ---
    assert_branch_parent feature-b feature-a
    assert_branch_parent feature-c feature-b
    assert_commit_is_reachable "$c_sha_before" feature-c
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b"
}

@test "insert: inserts --before at the beginning of a stack" {
    # This tests inserting a branch before the very first branch of a stack.
    # The new branch should become the new "bottom" of the stack.
    
    # Setup
    create_stack feature-b feature-c
    run git checkout feature-b
    run create_commit "commit for b"
    local b_sha_before; b_sha_before=$(git rev-parse HEAD)

    # Action
    run "$GSS_CMD" insert --before feature-a

    # Assertions
    assert_success

    # --- State Assertions ---
    assert_branch_parent feature-a main
    assert_branch_parent feature-b feature-a
    assert_commit_is_reachable "$b_sha_before" feature-b
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"
}

@test "insert: inserts a branch with an existing PR" {
    # If the branch that is being re-parented has a PR, `insert` should
    # update the base of that PR on GitHub.
    
    # Setup
    create_stack feature-a feature-c
    git config branch.feature-c.pr-number 15
    mock_pr_state 15 OPEN
    run git checkout feature-a

    # Action
    run "$GSS_CMD" insert feature-b

    # Assertions
    assert_success
    # The mock for `gh api` doesn't produce output, but we can check the logs.
    assert_output --partial "Updating GitHub PR for 'feature-c'"

    # --- State Assertions ---
    assert_branch_parent feature-c feature-b
}
