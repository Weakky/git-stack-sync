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

@test "untrack: correctly updates cache with forked branches (REGRESSION)" {
    # This tests a specific cache invalidation bug.
    # If a parent has multiple children (a forked stack), untracking one child
    # should not cause the other child's relationship to be removed from the cache.

    # Setup: Create a fork: parent -> child-a AND parent -> child-b
    run "$GSS_CMD" create parent-branch
    run "$GSS_CMD" create child-a
    run git checkout parent-branch
    run "$GSS_CMD" create child-b
    run git checkout child-a # Start from the branch we will untrack

    # Action: Untrack child-a. Since there are no commits, this will succeed.
    # The fix in `unset_parent_branch` ensures this only removes the 'parent -> child-a'
    # link from the cache, leaving 'parent -> child-b' intact.
    run "$GSS_CMD" untrack

    # Assertions
    assert_success
    assert_output --partial "Stopped tracking 'child-a'"

    # --- State Assertions ---
    # The key assertion: the other half of the fork must still exist.
    # Running another gss command that relies on the cache (`list`) will prove this.
    # The remaining stack is main -> parent-branch -> child-b, which is a 2-branch stack.
    run "$GSS_CMD" list
    assert_success
    assert_output --partial "parent-branch (2 branches)"
    refute_output --partial "child-a"
}
