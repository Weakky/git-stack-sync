#!/usr/bin/env bats

load 'bats-support/load'
load 'bats-assert/load'
load 'test_helper'
load 'debug'

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
export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"

# --- Hooks ---
setup() {
    setup_git_repo
}

teardown() {
    if [ "$BATS_TEST_STATUS" -ne 0 ]; then
        echo "Teardown: Test failed. Dumping state..." >&2
        gss_debug_dump "State at time of failure"
    fi
    cleanup_mock_gh_state
}

# --- Test Suite for 'gss amend' ---

# --- Core Functionality ---

@test "amend: amends commit and restacks a single child branch" {
    # SCENARIO: The most common use case. Amending a parent should rebase the direct child.
    create_stack br1 br2
    run git checkout br1
    
    # Create a change to amend
    echo "new content" > new-file.txt
    git add new-file.txt
    local sha_br1_before; sha_br1_before=$(git rev-parse HEAD)
    
    # Action
    run "$GSS_CMD" amend --yes
    
    # Assertions
    assert_success
    assert_output --partial "Commit amended successfully"
    assert_output --partial "Restack complete"

    # --- State Assertions ---
    local sha_br1_after; sha_br1_after=$(git rev-parse HEAD)
    assert_not_equal "$sha_br1_before" "$sha_br1_after"
    assert_commit_is_ancestor "$sha_br1_after" br2
    assert_current_branch br1 # Should return to original branch
}

@test "amend: amends bottom of a multi-branch stack and restacks all children" {
    # SCENARIO: Amending the very first branch of a stack must trigger a cascading rebase of all descendants.
    create_stack br1 br2 br3
    run git checkout br1

    echo "amend bottom" > bottom.txt
    git add bottom.txt
    
    # Action
    run "$GSS_CMD" amend --yes
    
    # Assertions
    assert_success
    
    # --- State Assertions ---
    local new_br1_sha; new_br1_sha=$(git rev-parse br1)
    assert_commit_is_ancestor "$new_br1_sha" br2
    assert_commit_is_ancestor "$new_br1_sha" br3

    local new_br2_sha; new_br2_sha=$(git rev-parse br2)
    assert_commit_is_ancestor "$new_br2_sha" br3
}

@test "amend: amends middle of a stack, only restacks subsequent children" {
    # SCENARIO: Ensure that amending a middle branch does not affect its parent, only its children.
    create_stack br1 br2 br3
    run git checkout br2
    local sha_br1_before; sha_br1_before=$(git rev-parse br1)

    echo "amend middle" > middle.txt
    git add middle.txt
    
    # Action
    run "$GSS_CMD" amend --yes
    
    # Assertions
    assert_success

    # --- State Assertions ---
    local sha_br1_after; sha_br1_after=$(git rev-parse br1)
    assert_equal "$sha_br1_before" "$sha_br1_after" # Parent should be untouched

    local new_br2_sha; new_br2_sha=$(git rev-parse br2)
    assert_commit_is_ancestor "$new_br2_sha" br3 # Child should be rebased
    assert_current_branch br2
}

@test "amend: amends top of stack with no children" {
    # SCENARIO: Amending the top of a stack should succeed and not attempt to restack anything.
    create_stack br1 br2
    run git checkout br2
    
    echo "amend top" > top.txt
    git add top.txt
    local sha_br2_before; sha_br2_before=$(git rev-parse HEAD)

    # Action
    run "$GSS_CMD" amend --yes
    
    # Assertions
    assert_success
    assert_output --partial "Stack is internally consistent. Nothing to restack."

    # --- State Assertions ---
    local sha_br2_after; sha_br2_after=$(git rev-parse HEAD)
    assert_not_equal "$sha_br2_before" "$sha_br2_after"
}

# --- User Interaction and Guards ---

@test "amend: cancels if user answers no to confirmation prompt" {
    create_stack br1
    echo "content" > file.txt
    git add file.txt
    local sha_before; sha_before=$(git rev-parse HEAD)

    # Action: Use a here-string to pipe 'n' into the prompt
    run "$GSS_CMD" amend <<< "n"
    
    # Assertions
    assert_success
    assert_output --partial "Amend cancelled"

    # --- State Assertions ---
    local sha_after; sha_after=$(git rev-parse HEAD)
    assert_equal "$sha_before" "$sha_after"
    # Staged file should still be there
    run git status --porcelain
    assert_output --partial "A  file.txt"
}

@test "amend: does nothing when there are no changes to amend" {
    create_stack br1
    local sha_before; sha_before=$(git rev-parse HEAD)

    # Action
    run "$GSS_CMD" amend --yes
    
    # Assertions
    assert_success
    assert_output --partial "No changes (staged or unstaged) to amend"

    # --- State Assertions ---
    local sha_after; sha_after=$(git rev-parse HEAD)
    assert_equal "$sha_before" "$sha_after"
}

@test "amend: fails when run on the base branch" {
    # Action
    run "$GSS_CMD" amend
    
    # Assertions
    assert_failure
    assert_output --partial "command cannot be run from the base branch"
}

@test "amend: fails when run on an untracked branch" {
    run git checkout -b feature-untracked
    create_commit "untracked commit"

    # Action
    run "$GSS_CMD" amend
    
    # Assertions
    assert_failure
    assert_output --partial "command requires a tracked branch"
}


# --- Complex Scenarios & Conflicts ---

@test "amend: handles rebase conflict in child branch gracefully" {
    # SCENARIO: An amend on a parent branch creates a content conflict with a child branch.
    # The script must pause the rebase and provide instructions.
    create_stack br1 br2
    run git checkout br2
    create_commit "br2 changes" "line two" "conflict.txt"
    
    run git checkout br1
    echo "line 2" > conflict.txt # This will conflict with br2's commit
    git add conflict.txt
    
    # Action
    run "$GSS_CMD" amend --yes
    
    # Assertions
    assert_failure
    assert_output --partial "Rebase conflict detected"
    assert_output --partial "run 'gss continue'"

    # --- State Assertions ---
    # A state file must exist for 'continue' to work
    assert [ -f ".git/GSS_OPERATION_STATE" ]
    run cat ".git/GSS_OPERATION_STATE"
    assert_output --partial '"command": "restack"'
    assert_output --partial '"originalBranch": "br1"'
}

@test "amend: 'continue' resumes successfully after resolving a conflict" {
    # SCENARIO: Follow-up to the previous test. After the user fixes the conflict,
    # 'gss continue' should finalize the operation.
    create_stack br1 br2
    run git checkout br2
    create_commit "br2 changes" "line two" "conflict.txt"
    run git checkout br1
    echo "line 2" > conflict.txt
    git add conflict.txt
    local new_br1_sha; new_br1_sha=$(git rev-parse br1) # Get SHA *before* amend for later check
    run "$GSS_CMD" amend --yes
    assert_failure # Expected to fail and pause

    # Manual conflict resolution
    echo "resolved content" > conflict.txt
    git add conflict.txt
    GIT_EDITOR=true git rebase --continue
    
    # Action
    run "$GSS_CMD" continue
    
    # Assertions
    assert_success
    assert_output --partial "Operation complete"

    # --- State Assertions ---
    refute [ -f ".git/GSS_OPERATION_STATE" ] # State file should be cleaned up
    assert_commit_is_ancestor "$(git rev-parse br1)" br2
    assert_current_branch br1 # Should return to original branch
}

@test "amend: handles child branch that becomes empty after amend" {
    # SCENARIO: An amend on a parent introduces the *exact same changes* as a child's commit.
    # After the restack, the child branch should be "empty" (point to the same SHA as the parent)
    # and the script should warn the user.
    
    # Manually create the stack to control commits precisely.
    run "$GSS_CMD" create br1
    create_commit "initial work on br1" "content" "file-a.txt"
    run "$GSS_CMD" create br2
    create_commit "add feature B" "content for B" "file-b.txt"
    run "$GSS_CMD" create br3
    create_commit "add feature C" "content for C" "file-c.txt"

    run git checkout br1
    # Stage the exact same change that br2 introduced
    echo "content for B" > file-b.txt
    git add file-b.txt
    
    # Action
    run "$GSS_CMD" amend --yes
    
    # Assertions
    assert_success
    assert_output --partial "After rebasing, branch 'br2' has no new changes"

    # --- State Assertions ---
    local sha_br1; sha_br1=$(git rev-parse br1)
    local sha_br2; sha_br2=$(git rev-parse br2)
    assert_equal "$sha_br1" "$sha_br2" # br2 is now empty
    assert_commit_is_ancestor "$sha_br2" br3 # br3 is correctly rebased on top
}