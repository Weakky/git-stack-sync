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

# --- Tests for 'gss create' ---
@test "create: creates a new child branch" {
    run "$GSS_CMD" create feature-a
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-a'"

    # --- State Assertions ---
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"
    assert_branch_parent feature-a main
}

@test "create: creates a nested child branch" {
    # Setup: Create the first branch in the stack
    run "$GSS_CMD" create feature-a
    assert_success
    
    # Action: Create the nested branch
    run "$GSS_CMD" create feature-b
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-b'"

    # --- State Assertions ---
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b"
    assert_branch_parent feature-b feature-a
}

@test "create: fails when branch already exists" {
    # Setup: Create the initial branch
    run "$GSS_CMD" create feature-a
    assert_success

    # Action: Attempt to create the same branch again
    run "$GSS_CMD" create feature-a
    assert_failure
    assert_output --partial "🔴 Error: Could not create branch 'feature-a'"

    # --- State Assertions ---
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"
}