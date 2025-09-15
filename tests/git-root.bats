#!/usr/bin/env bats

load 'bats-support/load'
load 'bats-assert/load'
load 'test_helper'
load 'debug'

# --- Variables ---
GSS_CMD_BASE="$BATS_TEST_DIRNAME/../gss"
GSS_CMD=""

if [[ -f "$GSS_CMD_BASE" ]]; then
    GSS_CMD="$GSS_CMD_BASE"
elif [[ -f "${GSS_CMD_BASE}.sh" ]]; then
    GSS_CMD="${GSS_CMD_BASE}.sh"
else
    echo "🔴 Error: Could not find the gss script." >&2
    exit 1
fi
export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"

# --- Hooks ---
# We no longer use a global setup hook, as some tests in this file
# should not be run inside a git repository.

teardown() {
    if [ "$BATS_TEST_STATUS" -ne 0 ]; then
        echo "Teardown: Test failed. Dumping state..." >&2
        gss_debug_dump "State at time of failure"
    fi
    cleanup_mock_gh_state
}

# --- Test Suite ---

@test "subfolder: create command works from a subdirectory" {
    # This test requires a git repo, so we call the helper manually.
    setup_git_repo

    # Setup
    mkdir -p "deeply/nested/subfolder"
    cd "deeply/nested/subfolder"

    # Action
    run "$GSS_CMD" create feature-from-subfolder
    assert_success
    
    # Assertions
    # The script should have cd'd to the repo root, so we don't need to.
    assert_branch_exists feature-from-subfolder
    assert_branch_parent feature-from-subfolder main
}

@test "subfolder: status command works from a subdirectory" {
    # This test requires a git repo.
    setup_git_repo

    # Setup
    create_stack br1 br2
    mkdir "sub"
    cd "sub"

    # Action
    run "$GSS_CMD" status
    
    # Assertions
    assert_success
    assert_output --partial "br1"
    assert_output --partial "br2"
}

@test "subfolder: fails when not run from a git repository" {
    # This test must NOT run inside a git repo, so we do not call setup_git_repo.
    # Setup: cd to a directory that is guaranteed NOT to be a git repo.
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir"

    # Action
    run "$GSS_CMD" status
    
    # Assertions
    assert_failure
    assert_output --partial "Not a git repository"

    # Cleanup
    rm -rf "$temp_dir"
}

