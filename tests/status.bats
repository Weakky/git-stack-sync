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

@test "status: fails when run on the base branch and lists stacks" {
    # Setup a stack to be listed
    run "$GSS_CMD" create feature-a
    run "$GSS_CMD" create feature-b
    run git checkout main

    # Action
    run "$GSS_CMD" status
    assert_failure
    assert_output --partial "Found stack(s):"
    assert_output --partial "- feature-a (2 branches)"
}

# --- Tests for 'gss status' ---
@test "status: displays a clean, up-to-date stack" {
    # This tests the ideal state: all local branches are synced with their
    # parents and remotes, and all have open PRs.
    
    # Setup
    create_stack feature-a feature-b
    mock_pr_state 10 OPEN
    mock_pr_state 11 OPEN
    track_pr feature-a 10
    track_pr feature-b 11
    run "$GSS_CMD" push --yes
    run git checkout feature-a # Explicitly checkout the branch to test
    local shas_before; shas_before=$(get_all_branch_shas)

    # Action
    run "$GSS_CMD" status

    # Assertions
    assert_success
    assert_output --partial "feature-a *"
    assert_output --partial "Status: 🟢 Synced"
    assert_output --partial "PR:     🟢 #10: OPEN"
    assert_output --partial "feature-b"
    assert_output --partial "Status: 🟢 Synced"
    assert_output --partial "PR:     🟢 #11: OPEN"
    assert_output --partial "Stack is up to date"

    # --- State Assertions ---
    local shas_after; shas_after=$(get_all_branch_shas)
    assert_equal "$shas_before" "$shas_after"
}

@test "status: indicates when a branch needs to be pushed" {
    # This tests the state where a local branch has commits that are not
    # yet on the remote.
    
    # Setup
    create_stack feature-a
    local shas_before; shas_before=$(get_all_branch_shas)

    # Action
    run "$GSS_CMD" status

    # Assertions
    assert_success
    assert_output --partial "Status: ⚪ Not on remote"
    assert_output --partial "PR:     ⚪ No PR submitted"
    assert_output --partial "Run 'gss push' to update the remote."

    # --- State Assertions ---
    local shas_after; shas_after=$(get_all_branch_shas)
    assert_equal "$shas_before" "$shas_after"
}

@test "status: indicates when stack is behind the base branch" {
    # This tests the state where `main` has new commits, and the stack needs
    # to be synced.
    
    # Setup
    create_stack feature-a
    run git checkout main
    run create_commit "new commit on main"
    run git push origin main
    run git checkout feature-a
    local shas_before; shas_before=$(get_all_branch_shas)

    # Action
    run "$GSS_CMD" status

    # Assertions
    assert_success
    assert_output --partial "Status: 🟡 Behind 'main'"
    assert_output --partial "Run 'gss sync' to update the base and rebase the stack."

    # --- State Assertions ---
    local shas_after; shas_after=$(get_all_branch_shas)
    assert_equal "$shas_before" "$shas_after"
}

@test "status: indicates when a branch is behind its parent" {
    # This tests the state where a parent branch in the stack has been
    # amended, and its children need to be restacked.
    
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-a
    run create_commit "amend commit" "content" "file.txt"
    run git commit --amend --no-edit
    run git checkout feature-b
    local shas_before; shas_before=$(get_all_branch_shas)

    # Action
    run "$GSS_CMD" status

    # Assertions
    assert_success
    assert_output --partial "feature-b *"
    assert_output --partial "Status: 🟡 Behind 'feature-a'"
    assert_output --partial "Run 'gss restack' from the out-of-date branch"

    # --- State Assertions ---
    local shas_after; shas_after=$(get_all_branch_shas)
    assert_equal "$shas_before" "$shas_after"
}

@test "status: displays merged and closed PRs and suggests sync" {
    # This test ensures the status correctly reflects when PRs have been
    # merged or closed on GitHub, and that it gives the correct summary.
    
    # Setup
    create_stack feature-a feature-b
    track_pr feature-a 10
    track_pr feature-b 11
    mock_pr_state 10 MERGED
    mock_pr_state 11 CLOSED
    local shas_before; shas_before=$(get_all_branch_shas)

    # Action
    run "$GSS_CMD" status

    # Assertions
    assert_success
    assert_output --partial "PR:     🟣 #10: MERGED"
    assert_output --partial "PR:     🔴 #11: CLOSED"
    assert_output --partial "Run 'gss sync' to update the base and rebase the stack."

    # --- State Assertions ---
    local shas_after; shas_after=$(get_all_branch_shas)
    assert_equal "$shas_before" "$shas_after"
}
