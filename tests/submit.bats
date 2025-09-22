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

# --- Tests for 'gss submit' ---
@test "submit: creates PRs for a multi-branch stack" {
    # This is the standard use case: create PRs for all branches in the stack
    # that don't already have one.
    
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-b

    # Action
    run "$GSS_CMD" submit

    # Assertions
    assert_success
    assert_output --partial "Created PR #20 for 'feature-a'"
    assert_output --partial "Created PR #21 for 'feature-b'"

    # --- State Assertions ---
    # Verify that the PR numbers have been saved to the git config.
    assert_branch_pr_number feature-a 20
    assert_branch_pr_number feature-b 21
}

@test "submit: skips branches that already have a PR" {
    # The command should be idempotent and not try to re-create a PR
    # if one is already associated with a branch.
    
    # Setup
    create_stack feature-a feature-b
    git config branch.feature-a.pr-number 10 # Pre-configure feature-a with a PR
    run git checkout feature-b

    # Action
    run "$GSS_CMD" submit

    # Assertions
    assert_success
    assert_output --partial "PR #10 already exists for branch 'feature-a'"
    assert_output --partial "Created PR #20 for 'feature-b'"

    # --- State Assertions ---
    assert_branch_pr_number feature-a 10 # Should be unchanged
    assert_branch_pr_number feature-b 20
}

@test "submit: skips branches with no new commits" {
    # If a branch in the stack is "empty" (has no commits that are different
    # from its parent), the command should not create a PR for it.
    
    # Setup
    run "$GSS_CMD" create feature-a
    run create_commit "commit for a"
    run "$GSS_CMD" create feature-b # No commit on feature-b

    # Action
    run "$GSS_CMD" submit

    # Assertions
    assert_success
    assert_output --partial "Skipping PR for 'feature-b': No new commits"
    
    # --- State Assertions ---
    assert_branch_pr_number feature-a 20
    assert_branch_has_no_pr_number feature-b
}

@test "submit: works correctly when run from the middle of a stack" {
    # Like other commands, `submit` should operate on the entire stack,
    # regardless of which branch is currently checked out.
    
    # Setup
    create_stack feature-a feature-b feature-c
    run git checkout feature-b # Start from the middle

    # Action
    run "$GSS_CMD" submit

    # Assertions
    assert_success

    # --- State Assertions ---
    assert_branch_pr_number feature-a 20
    assert_branch_pr_number feature-b 21
    assert_branch_pr_number feature-c 22
}

@test "submit: fails gracefully if GitHub API returns an error" {
    # If the `gh` command fails for any reason, the script should report
    # the error and stop, not leave the repo in a half-finished state.
    
    # Setup
    create_stack feature-a
    mock_pr_create_failure # Tell the mock to fail the next PR creation

    # Action
    run "$GSS_CMD" submit

    # Assertions
    assert_failure
    assert_output --partial "Failed to create PR for 'feature-a'"
    
    # --- State Assertions ---
    # The PR number should NOT have been saved.
    assert_branch_has_no_pr_number feature-a
}

@test "submit: tracks an existing untracked PR on GitHub" {
    # This test ensures that if a PR exists on GitHub but is not tracked
    # by gss locally, 'submit' will find it, track it, and not create a new one.
    # NOTE: This test requires a new helper function 'mock_existing_pr <branch> <pr_number>' 
    # in test_helper.bash and a corresponding update to the 'tests/mocks/gh' 
    # script to handle 'gh pr view <branch-name> --json number'.

    # Setup
    create_stack feature-a
    # We simulate that PR #30 was created on GitHub for 'feature-a' outside of gss.
    mock_untracked_pr feature-a 30

    # Action
    run "$GSS_CMD" submit

    # Assertions
    assert_success
    # The output should show that it found and tracked the PR, not created one.
    assert_output --partial "Tracked PR #30 for branch 'feature-a'"
    refute_output --partial "Created PR"

    # --- State Assertions ---
    # The config should now contain the PR number it discovered.
    assert_branch_pr_number feature-a 30
}