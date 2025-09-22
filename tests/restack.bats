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
    # Create a standard 3-branch stack for all tests
    create_stack br1 br2 br3
}

teardown() {
    if [ "$BATS_TEST_STATUS" -ne 0 ]; then
        echo "Teardown: Test failed. Dumping state..." >&2
        gss_debug_dump "State at time of failure"
    fi
    cleanup_mock_gh_state
}

# --- Test Suite for the "Smart" gss restack ---

@test "restack: does nothing if stack is consistent" {
    # This test verifies that if the stack has no breaks in its history,
    # the command exits cleanly without performing any actions.
    
    # Setup: The stack is already consistent from the setup hook.
    # Get a snapshot of SHAs before running the command.
    local shas_before; shas_before=$(get_all_branch_shas)
    
    # Action: Run restack from the top of the stack
    run "$GSS_CMD" restack

    # Assertions
    assert_success
    assert_output --partial "Stack is internally consistent. Nothing to restack."

    # --- State Assertions ---
    # No SHAs should have changed.
    local shas_after; shas_after=$(get_all_branch_shas)
    assert_equal "$shas_before" "$shas_after"
}

@test "restack: amends bottom, runs from top" {
    # SCENARIO: The first branch of the stack is amended.
    # We run 'restack' from the top to ensure it can find the break
    # all the way at the bottom and fix the entire stack.
    
    # Setup
    run git checkout br1
    run create_commit "amend br1" "new content" "file1.txt"
    run git commit --amend --no-edit
    local new_br1_sha; new_br1_sha=$(git rev-parse HEAD)
    
    # Action: Run from the top of the stack
    run git checkout br3
    run "$GSS_CMD" restack

    # Assertions
    assert_success
    assert_output --partial "Detected stack divergence at 'br1'"
    assert_output --partial "Will restack the following branches: br2 br3"

    # --- State Assertions ---
    assert_commit_is_ancestor "$new_br1_sha" br2
    assert_commit_is_ancestor "$new_br1_sha" br3
    local new_br2_sha; new_br2_sha=$(git rev-parse br2)
    assert_commit_is_ancestor "$new_br2_sha" br3

    # Should return to the original branch
    assert_current_branch br3
}

@test "restack: amends middle, runs from top" {
    # SCENARIO: A branch in the middle of the stack is amended.
    # We run 'restack' from the top. It should detect the break at br2
    # and only restack the branches above it (br3).
    
    # Setup
    local br1_sha_before; br1_sha_before=$(git rev-parse br1)
    run git checkout br2
    run create_commit "amend br2" "new content" "file2.txt"
    run git commit --amend --no-edit
    local new_br2_sha; new_br2_sha=$(git rev-parse HEAD)

    # Action: Run from the top
    run git checkout br3
    run "$GSS_CMD" restack

    # Assertions
    assert_success
    assert_output --partial "Detected stack divergence at 'br2'"
    assert_output --partial "Will restack the following branches: br3"

    # --- State Assertions ---
    # br1's SHA should be unchanged.
    local br1_sha_after; br1_sha_after=$(git rev-parse br1)
    assert_equal "$br1_sha_before" "$br1_sha_after"
    # br3 should now be based on the new br2.
    assert_commit_is_ancestor "$new_br2_sha" br3
    assert_current_branch br3
}

@test "restack: amends middle, runs from bottom" {
    # SCENARIO: A branch in the middle is amended, but we run the command
    # from a branch *below* the change. The tool should still find the
    # break and fix the stack above it.
    
    # Setup
    local br1_sha_before; br1_sha_before=$(git rev-parse br1)
    run git checkout br2
    run create_commit "amend br2" "new content" "file2.txt"
    run git commit --amend --no-edit
    local new_br2_sha; new_br2_sha=$(git rev-parse HEAD)

    # Action: Run from the bottom
    run git checkout br1
    run "$GSS_CMD" restack

    # Assertions
    assert_success
    assert_output --partial "Detected stack divergence at 'br2'"

    # --- State Assertions ---
    local br1_sha_after; br1_sha_after=$(git rev-parse br1)
    assert_equal "$br1_sha_before" "$br1_sha_after"
    assert_commit_is_ancestor "$new_br2_sha" br3
    assert_current_branch br1
}

@test "restack: amends top, runs from anywhere" {
    # SCENARIO: The top-most branch is amended. There are no descendants to
    # restack, so the command should detect this and do nothing.
    
    # Setup
    local shas_before; shas_before=$(get_all_branch_shas)
    run git checkout br3
    run create_commit "amend br3" "new content" "file3.txt"
    run git commit --amend --no-edit
    
    # Action
    run "$GSS_CMD" restack

    # Assertions
    assert_success
    # New commit is at the top. Nothing to restack.
    assert_output --partial "Stack is internally consistent. Nothing to restack."

    # --- State Assertions ---
    # Only br3's SHA should have changed.
    assert_not_equal "$shas_before" "$(get_all_branch_shas)"
    assert_current_branch br3
}

@test "restack: interactive rebase drops a commit from middle" {
    # SCENARIO: A more complex history edit where a commit is simply removed
    # from a middle branch. This is a powerful test because the branch still
    # exists, but its history has fundamentally changed.
    
    # Setup
    # 1. Add two distinct commits to br2.
    run git checkout br2
    run create_commit "br2 commit one" "content1" "file2-a.txt"
    local commit_to_drop_sha; commit_to_drop_sha=$(git rev-parse HEAD)
    run create_commit "br2 commit two" "content2" "file2-b.txt"
    # 2. Re-create br3 on top of the new br2
    run git branch -f br3 HEAD
    run git checkout br3
    run create_commit "br3 commit"
    # 3. Go back to br2 and perform the interactive rebase to drop the commit.
    run git checkout br2
    # Use GIT_SEQUENCE_EDITOR to programmatically edit the rebase todo list.
    # `sed -i '/<sha>/d'` deletes the line containing the commit hash.
    GIT_SEQUENCE_EDITOR="sed -i.bak '/${commit_to_drop_sha:0:7}/d'" git rebase -i HEAD~2
    local new_br2_sha; new_br2_sha=$(git rev-parse HEAD)

    # Action: Run restack from br3
    run git checkout br3
    run "$GSS_CMD" restack

    # Assertions
    assert_success
    assert_output --partial "Detected stack divergence at 'br2'"

    # --- State Assertions ---
    assert_commit_is_ancestor "$new_br2_sha" br3
    # We must also prove the dropped commit is GONE from br3's history.
    run git rev-list br3
    refute_output --partial "$commit_to_drop_sha"
}

@test "restack: diverged base of stack" {
    # SCENARIO: The bottom branch of the stack is rebased onto a different
    # commit on main. This is a common scenario when cleaning up history.
    # `restack` should detect the break between `br1` and `br2`.
    
    # Setup
    # 1. Create a new commit on main to rebase onto.
    run git checkout main
    run create_commit "new base for stack"
    local new_main_sha; new_main_sha=$(git rev-parse HEAD)
    # 2. Rebase br1 onto it, but don't touch br2 or br3 yet.
    # This maintains the gss parent config but breaks the ancestry chain.
    run git rebase --onto "$new_main_sha" main~1 br1
    local new_br1_sha; new_br1_sha=$(git rev-parse HEAD)

    # Action: Run from anywhere in the stack
    run git checkout br2
    run "$GSS_CMD" restack

    # Assertions
    assert_success
    # The script correctly finds the *first* broken link, which is between br1 and br2.
    assert_output --partial "Detected stack divergence at 'br1'"

    # --- State Assertions ---
    # The entire stack should be moved.
    assert_commit_is_ancestor "$new_br1_sha" br2
    local new_br2_sha; new_br2_sha=$(git rev-parse br2)
    assert_commit_is_ancestor "$new_br2_sha" br3
}

# --- Tests for 'gss restack' ---
@test "restack: rebases child branches after an amend" {
    # This is the primary use case for `restack`. After amending a commit on a
    # parent branch, the child branches need to be rebased on top of the new commit.
    
    # Setup
    create_stack feature-a feature-b feature-c
    run git checkout feature-b
    # Amend the commit on feature-b
    run create_commit "new content for b" "amended content" "file-b.txt"
    run git add .
    run git commit --amend --no-edit
    local new_b_sha; new_b_sha=$(git rev-parse HEAD)

    # Action
    run "$GSS_CMD" restack

    # Assertions
    assert_success
    
    # --- State Assertions ---
    # 'feature-c' should now have the amended commit from 'feature-b' in its history.
    assert_commit_is_ancestor "$new_b_sha" feature-c
    assert_branch_parent feature-b feature-a
    assert_branch_parent feature-c feature-b
}

@test "restack: works when run from the bottom of a stack" {
    # This test ensures that if you amend the very first branch in a stack,
    # `restack` will correctly update all subsequent branches.
    
    # Setup
    create_stack feature-a feature-b feature-c
    run git checkout feature-a
    run create_commit "new content for a" "amended content" "file-a.txt"
    run git add .
    run git commit --amend --no-edit
    local new_a_sha; new_a_sha=$(git rev-parse HEAD)

    # Action
    run "$GSS_CMD" restack

    # Assertions
    assert_success

    # --- State Assertions ---
    assert_commit_is_ancestor "$new_a_sha" feature-b
    assert_commit_is_ancestor "$new_a_sha" feature-c
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a" # Should return to original branch
}

@test "restack: does nothing when at the top of the stack" {
    # If `restack` is run from the topmost branch, there are no children
    # to rebase, so it should do nothing and exit gracefully.
    
    # Setup
    create_stack feature-a feature-b
    local sha_a_before; sha_a_before=$(git rev-parse feature-a)
    local sha_b_before; sha_b_before=$(git rev-parse feature-b)
    run git checkout feature-b

    # Action
    run "$GSS_CMD" restack

    # Assertions
    assert_success
    assert_output --partial "Stack is internally consistent. Nothing to restack."

    # --- State Assertions ---
    # Hashes should not have changed.
    local sha_a_after; sha_a_after=$(git rev-parse feature-a)
    local sha_b_after; sha_b_after=$(git rev-parse feature-b)
    assert_equal "$sha_a_before" "$sha_a_after"
    assert_equal "$sha_b_before" "$sha_b_after"
}

@test "restack: handles rebase conflict gracefully" {
    # Similar to the 'sync' conflict test, this ensures that if a `restack`
    # operation causes a merge conflict, the script pauses and allows the user
    # to resolve it manually.
    
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-b
    run create_commit "conflicting commit" "line 2" "conflict.txt"
    run git checkout feature-a
    # Amend feature-a to create a conflict
    run create_commit "conflicting amend" "line two" "conflict.txt"
    run git add .
    run git commit --amend --no-edit

    # Action
    run "$GSS_CMD" restack
    
    # Assertions
    assert_failure
    assert_output --partial "Rebase conflict detected"

    # --- State Assertions ---
    assert [ -f ".git/GSS_OPERATION_STATE" ]
    run cat ".git/GSS_OPERATION_STATE"
    assert_output --partial "\"command\": \"restack\""
    assert_output --partial "\"originalBranch\": \"feature-a\""
}

@test "restack: 'continue' resumes after a restack conflict" {
    # This tests the second half of the 'restack' conflict workflow.
    
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-b
    run create_commit "conflicting commit" "line 2" "conflict.txt"
    run git checkout feature-a
    run create_commit "conflicting amend" "line two" "conflict.txt"
    run git add .
    run git commit --amend --no-edit
    local new_a_sha; new_a_sha=$(git rev-parse HEAD)
    # Run restack, which is expected to fail
    run "$GSS_CMD" restack

    # Manual conflict resolution
    echo "resolved" > conflict.txt
    run git add conflict.txt
    GIT_EDITOR=true run git rebase --continue

    # Action
    run "$GSS_CMD" continue

    # Assertions
    assert_success

    # --- State Assertions ---
    refute [ -f ".git/GSS_OPERATION_STATE" ]
    assert_commit_is_ancestor "$new_a_sha" feature-b
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a" # Should return to original branch
}

@test "restack: handles branch that becomes empty after rebase" {
    # This tests what happens if an amend on a parent branch makes a child
    # branch's commit redundant. The rebase should make the child branch
    # "empty" (i.e., point to the same commit as its parent). The script should
    # warn the user about this and continue to rebase subsequent branches correctly.
    
    # Setup
    # 1. Create the stack structure without initial commits from the helper.
    run "$GSS_CMD" create feature-a
    run "$GSS_CMD" create feature-b
    run "$GSS_CMD" create feature-c
    run git checkout feature-b

    # 2. Create the specific commit on feature-b that will be made redundant.
    run create_commit "add file-b" "content" "file-b.txt"

    # 3. Create a normal commit on feature-c.
    run git checkout feature-c
    run create_commit "add file-c" "content" "file-c.txt"
    
    # 4. Go back to feature-a and add a commit with the *exact same changes* as feature-b.
    run git checkout feature-a
    run create_commit "add file-b on parent" "content" "file-b.txt"
    local new_a_sha; new_a_sha=$(git rev-parse HEAD)

    # Action
    run "$GSS_CMD" restack

    # Assertions
    assert_success

    # --- State Assertions ---
    # feature-b should now point to the same commit as the new feature-a.
    local new_b_sha; new_b_sha=$(git rev-parse feature-b)
    assert_equal "$new_a_sha" "$new_b_sha"
    # feature-c should be rebased on top of the (now empty) feature-b.
    assert_commit_is_ancestor "$new_b_sha" feature-c
}