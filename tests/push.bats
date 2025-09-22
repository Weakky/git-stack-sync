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

# --- Tests for 'gss push' ---
@test "push: pushes a multi-branch stack" {
    # This is the standard use case: push all local branches in the current
    # stack to the remote.
    
    # Setup
    create_stack feature-a feature-b
    local a_sha; a_sha=$(git rev-parse feature-a)
    local b_sha; b_sha=$(git rev-parse feature-b)
    run git checkout feature-b

    # Action
    run "$GSS_CMD" push --yes

    # Assertions
    assert_success
    assert_output --partial "All branches pushed"

    # --- State Assertions ---
    # Verify that the remote branches exist and point to the same commits as local.
    local remote_a_sha; remote_a_sha=$(git rev-parse origin/feature-a)
    local remote_b_sha; remote_b_sha=$(git rev-parse origin/feature-b)
    assert_equal "$a_sha" "$remote_a_sha"
    assert_equal "$b_sha" "$remote_b_sha"
}

@test "push: pushes a single-branch stack" {
    # This tests that the command works correctly for the simplest case.
    
    # Setup
    run "$GSS_CMD" create feature-a
    run create_commit "commit-a"
    local a_sha; a_sha=$(git rev-parse feature-a)

    # Action
    run "$GSS_CMD" push --yes

    # Assertions
    assert_success

    # --- State Assertions ---
    local remote_a_sha; remote_a_sha=$(git rev-parse origin/feature-a)
    assert_equal "$a_sha" "$remote_a_sha"
}

@test "push: force-pushes after a rebase" {
    # This is a critical workflow. After a `sync` or `restack`, local branches
    # have new commit SHAs. `push` must use --force-with-lease to update the
    # remote branches to match.
    
    # Setup
    create_stack feature-a feature-b
    run "$GSS_CMD" push --yes # Initial push
    run git checkout main
    run create_commit "new base commit"
    run git push origin main
    run git checkout feature-b
    run "$GSS_CMD" sync # This rebases feature-a and feature-b
    local new_a_sha; new_a_sha=$(git rev-parse feature-a)
    local new_b_sha; new_b_sha=$(git rev-parse feature-b)

    # Action
    run "$GSS_CMD" push --yes

    # Assertions
    assert_success

    # --- State Assertions ---
    # The remote branches should now point to the new, rebased SHAs.
    local remote_a_sha; remote_a_sha=$(git rev-parse origin/feature-a)
    local remote_b_sha; remote_b_sha=$(git rev-parse origin/feature-b)
    assert_equal "$new_a_sha" "$remote_a_sha"
    assert_equal "$new_b_sha" "$remote_b_sha"
}

@test "push: cancels push if user answers no" {
    # This test ensures that the command respects the user's choice when
    # they are prompted for confirmation.
    
    # Setup
    create_stack feature-a
    
    # Action: Use a here-string to provide 'n' to the confirmation prompt.
    # This is more robust than using a pipe with echo.
    run "$GSS_CMD" push <<< "n"
    
    # Assertions
    assert_success
    assert_output --partial "Push cancelled"

    # --- State Assertions ---
    # The remote branch should not have been created.
    run git rev-parse origin/feature-a
    assert_failure
}
