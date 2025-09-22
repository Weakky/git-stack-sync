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

# --- Tests for 'gss track --pr' ---

@test "track --pr: successfully tracks an open PR" {
    # SCENARIO: The standard happy path. The current branch and its parent
    # match the PR's head and base refs.
    
    # Setup
    run "$GSS_CMD" create feature-a
    run create_commit "feat: add feature a"
    # Mock PR #42 with head=feature-a and base=main
    mock_pr_state 42 OPEN main feature-a

    # Action
    run "$GSS_CMD" track --pr 42
    
    # Assertions
    assert_success
    assert_output --partial "'feature-a' associated with PR #42"

    # --- State Assertions ---
    assert_branch_pr_number feature-a 42
}

@test "track --pr: succeeds when branch has no parent yet" {
    # SCENARIO: A branch exists locally but is not yet part of a gss stack.
    # Tracking by PR should succeed as long as the head ref matches. The
    # parent relationship is not enforced if it doesn't exist locally.
    
    # Setup
    run git checkout -b feature-untracked
    run create_commit "feat: untracked feature"
    # Mock PR #43 where the head is our untracked branch
    mock_pr_state 43 OPEN main feature-untracked

    # Action
    run "$GSS_CMD" track --pr 43

    # Assertions
    assert_success
    assert_output --partial "'feature-untracked' associated with PR #43"

    # --- State Assertions ---
    assert_branch_pr_number feature-untracked 43
    # The parent should NOT have been set automatically.
    run jq -r ".branchParents[\"feature-untracked\"]" "$BATS_TEST_TMPDIR/local/.git/GSS_CONFIG_CACHE"
    assert_output "null"
}

@test "track --pr: fails if --pr and --parent are used together" {
    # SCENARIO: The user provides both mutually exclusive flags.
    run "$GSS_CMD" create feature-a
    
    # Action
    run "$GSS_CMD" track --pr 42 --parent main
    
    # Assertions
    assert_failure
    assert_output --partial "Cannot use both --pr and --parent flags together"

    # --- State Assertions ---
    assert_branch_has_no_pr_number feature-a
}

@test "track --pr: fails if PR number is not a number" {
    run "$GSS_CMD" create feature-a
    
    # Action
    run "$GSS_CMD" track --pr "not-a-number"
    
    # Assertions
    assert_failure
    assert_output --partial "A valid PR number is required"
    assert_branch_has_no_pr_number feature-a
}

@test "track --pr: fails if PR number is zero or negative" {
    run "$GSS_CMD" create feature-a
    
    # Action
    run "$GSS_CMD" track --pr 0
    assert_failure
    assert_output --partial "A valid PR number is required"

    run "$GSS_CMD" track --pr -10
    assert_failure
    assert_output --partial "A valid PR number is required"

    # --- State Assertions ---
    assert_branch_has_no_pr_number feature-a
}

@test "track --pr: fails if PR is closed" {
    run "$GSS_CMD" create feature-a
    mock_pr_state 44 CLOSED main feature-a

    # Action
    run "$GSS_CMD" track --pr 44
    
    # Assertions
    assert_failure
    assert_output --partial "PR #44 is CLOSED. Cannot track a closed PR."
    assert_branch_has_no_pr_number feature-a
}

@test "track --pr: fails if PR is merged" {
    run "$GSS_CMD" create feature-a
    mock_pr_state 45 MERGED main feature-a
    
    # Action
    run "$GSS_CMD" track --pr 45
    
    # Assertions
    assert_failure
    assert_output --partial "PR #45 is MERGED. Cannot track a closed PR."
    assert_branch_has_no_pr_number feature-a
}

@test "track --pr: fails if PR head branch does not match current branch" {
    # SCENARIO: The user is on 'feature-a' but tries to track a PR
    # whose head branch is 'some-other-branch'.
    run "$GSS_CMD" create feature-a
    mock_pr_state 46 OPEN main some-other-branch
    
    # Action
    run "$GSS_CMD" track --pr 46
    
    # Assertions
    assert_failure
    assert_output --partial "Current branch 'feature-a' does not match PR head 'some-other-branch'"
    assert_branch_has_no_pr_number feature-a
}

@test "track --pr: fails if PR base branch does not match tracked parent" {
    # SCENARIO: The user is on 'feature-b' whose parent is tracked as 'feature-a',
    # but the PR's base is 'main'. This is a state mismatch that should be prevented.
    create_stack feature-a feature-b
    mock_pr_state 47 OPEN main feature-b
    
    # Action
    run "$GSS_CMD" track --pr 47
    
    # Assertions
    assert_failure
    assert_output --partial "Current parent 'feature-a' does not match PR base 'main'"
    assert_branch_has_no_pr_number feature-b
}