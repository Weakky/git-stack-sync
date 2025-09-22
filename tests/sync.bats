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

# --- Tests for 'gss sync' ---
@test "sync: simple sync with no merged branches" {
    # This test verifies the most basic 'sync' scenario.
    # A stack of branches exists, and the base branch ('main') gets a new commit.
    # 'sync' should rebase the entire stack on top of the new 'main'.
    
    # Setup
    create_stack feature-a feature-b
    run git checkout main
    run create_commit "New commit on main"
    local main_sha; main_sha=$(git rev-parse HEAD) # Get SHA for rebase check
    run git push origin main
    run git checkout feature-b

    # Action
    run "$GSS_CMD" sync
    
    # Assertions
    assert_success
    
    # --- State Assertions ---
    # Verify that the new commit from 'main' is now part of feature-b's history.
    assert_commit_is_ancestor "$main_sha" feature-b
}

@test "sync: syncs with a merged parent branch" {
    # This test ensures that if a branch in the middle of a stack is merged
    # (e.g., via the GitHub UI), 'sync' correctly detects it, removes it,
    # and re-parents its child branch onto its grandparent.
    
    # Setup
    create_stack feature-a feature-b
    # Mock PRs: #10 for feature-a, #11 for feature-b
    track_pr feature-a 10
    track_pr feature-b 11
    mock_pr_state 10 MERGED # Mock feature-a's PR as merged
    git checkout feature-b

    # Action: Run sync with --yes to auto-confirm branch deletion
    run "$GSS_CMD" sync --yes

    # Assertions
    assert_success
    assert_output --partial "Deleted local branch 'feature-a'"

    # --- State Assertions ---
    # feature-b's parent should now be 'main'.
    assert_branch_parent feature-b main
    # The merged branch 'feature-a' should be gone.
    assert_branch_does_not_exist feature-a
    assert_branch_exists feature-b
}

@test "sync: full workflow after a squash merge" {
    # This is an end-to-end test that covers the most common, complex workflow:
    # 1. A parent branch is squash-merged via the GitHub UI.
    # 2. `gss status` correctly diagnoses the stale stack and prescribes `gss sync`.
    # 3. `gss sync` correctly updates the local base branch and the stack.
    # 4. `gss status` now correctly prescribes `gss push`.
    # 5. `gss push` updates the remote.
    # 6. `gss status` confirms the stack is fully clean.

    # Setup
    create_stack br1 br2
    # Set up PRs and push the initial stack to the remote
    track_pr br1 10
    track_pr br2 11
    mock_pr_state 10 OPEN
    mock_pr_state 11 OPEN
    run "$GSS_CMD" push --yes # Push the initial state

    # Now, simulate the squash merge of br1
    mock_pr_state 10 MERGED
    run git checkout main
    local main_sha_before_merge; main_sha_before_merge=$(git rev-parse HEAD)
    run git merge --squash br1
    run git commit -m "Squash merge of br1"
    local new_main_sha; new_main_sha=$(git rev-parse HEAD)
    run git push origin main
    # Reset local main to be behind the remote, creating the condition for the test
    run git reset --hard "$main_sha_before_merge"
    run git checkout br2

    # 1. First status check: Diagnose the problem
    run "$GSS_CMD" status
    assert_success
    assert_output --partial "main (🟡 Behind by 1)"
    assert_output --partial "PR:     🟣 #10: MERGED"
    assert_output --partial "Run 'gss sync' to update the base and rebase the stack."

    # 2. Run sync to fix the stack
    run "$GSS_CMD" sync --yes
    assert_success
    assert_output --partial "Deleted local branch 'br1'"
    assert_output --partial "Next step: Run 'gss push'"
    assert_branch_parent br2 main
    assert_commit_is_ancestor "$new_main_sha" br2

    # 3. Second status check: Diagnose the next step
    run "$GSS_CMD" status
    assert_success
    assert_output --partial "Status: 🟡 Needs push (local history has changed)"
    assert_output --partial "Run 'gss push' to update the remote"
    
    # 4. Push the changes
    run "$GSS_CMD" push --yes
    assert_success
    assert_remote_branch_matches_local br2

    # 5. Final status check: Confirm everything is clean
    run "$GSS_CMD" status
    assert_success
    assert_output --partial "Status: 🟢 Synced"
    assert_output --partial "Stack is up to date"
}


@test "sync: avoids conflicts when parent was squash-merged" {
    # This tests a critical real-world scenario. If a parent branch (`br1`) is
    # squash-merged into `main`, its commits are squashed into a new commit on `main`.
    # `gss sync` must be smart enough to rebase the child (`br2`) onto `main`
    # without trying to re-apply the commits that were already squashed, which would
    # cause a rebase conflict.
    
    # Setup
    create_stack br1 br2
    track_pr br1 10
    mock_pr_state 10 MERGED
    
    # Simulate a squash merge of br1 into main
    run git checkout main
    run git merge --squash br1
    run git commit -m "Squash merge of br1"
    run git push origin main
    run git checkout br2

    # Action
    run "$GSS_CMD" sync --yes

    # Assertions
    assert_success # The key assertion is that this command does not fail.
    
    # --- State Assertions ---
    assert_branch_parent br2 main
    assert_branch_does_not_exist br1
}

@test "sync: handles rebase conflict gracefully" {
    # This test ensures that if 'git rebase' fails during a sync (due to a merge
    # conflict), the script stops and provides instructions to the user on how
    # to resolve it and continue the operation.
    
    # Setup
    create_commit "conflict-file" "line 1" "file.txt"
    run "$GSS_CMD" create feature-a
    create_commit "feature-a changes" "line 2" "file.txt"
    run git checkout main
    create_commit "main changes" "line one" "file.txt"
    run git push origin main
    run git checkout feature-a

    # Action
    run "$GSS_CMD" sync

    # Assertions
    assert_failure
    assert_output --partial "Rebase conflict detected"
    assert_output --partial "run 'gss continue'"
    
    # --- State Assertions ---
    # A state file should exist to allow 'gss continue' to resume.
    assert [ -f ".git/GSS_OPERATION_STATE" ]
    run cat ".git/GSS_OPERATION_STATE"
    assert_output --partial "\"command\": \"sync\""
    assert_output --partial "\"originalBranch\": \"feature-a\""
}

@test "sync: 'continue' resumes after a sync conflict" {
    # This tests the second half of the conflict resolution workflow: after a
    # user manually resolves a rebase conflict, 'gss continue' should
    # successfully finish the operation.
    
    # Setup: Create a conflict
    create_commit "conflict-file" "line 1" "file.txt"
    run "$GSS_CMD" create feature-a
    create_commit "feature-a changes" "line 2" "file.txt"
    run git checkout main
    create_commit "main changes" "line one" "file.txt"
    local main_sha; main_sha=$(git rev-parse HEAD) # Get SHA for rebase check
    run git push origin main
    run git checkout feature-a
    # Run sync, which is expected to fail
    run "$GSS_CMD" sync

    # Manual conflict resolution
    echo "resolved" > file.txt
    run git add file.txt
    
    # By default, a successful rebase opens an editor for the commit message.
    # In a non-interactive test, this would hang. GIT_EDITOR=true tells Git
    # to use the 'true' command as its editor, which does nothing and exits
    # successfully, allowing the rebase to complete automatically.
    GIT_EDITOR=true run git rebase --continue

    # Action
    run "$GSS_CMD" continue --yes

    # Assertions
    assert_success
    assert_output --partial "Operation complete."
    
    # --- State Assertions ---
    refute [ -f ".git/GSS_OPERATION_STATE" ]
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"
    assert_commit_is_ancestor "$main_sha" feature-a
}

@test "sync: syncs with multiple consecutive merged branches" {
    # This tests a more complex scenario where multiple adjacent branches
    # in the middle of a stack have been merged. 'sync' should correctly
    # "bridge the gap" by reparenting the first unmerged child onto the last
    # unmerged ancestor.
    
    # Setup
    create_stack feature-a feature-b feature-c feature-d
    track_pr feature-b 12
    track_pr feature-c 13
    mock_pr_state 12 MERGED
    mock_pr_state 13 MERGED
    git checkout feature-d

    # Action
    run "$GSS_CMD" sync --yes

    # Assertions
    assert_success
    assert_output --partial "Deleted local branch 'feature-b'"
    assert_output --partial "Deleted local branch 'feature-c'"

    # --- State Assertions ---
    # 'feature-d' should now be parented onto 'feature-a'.
    assert_branch_parent feature-d feature-a
    assert_branch_does_not_exist feature-b
    assert_branch_does_not_exist feature-c
    assert_branch_exists feature-a
    assert_branch_exists feature-d
}

@test "sync: syncs when entire stack is merged" {
    # This tests the edge case where every single branch in the stack has
    # been merged. The command should detect this, clean up all local
    # branches, and not attempt to perform a rebase.
    
    # Setup
    create_stack feature-a feature-b
    track_pr feature-a 10
    track_pr feature-b 11
    mock_pr_state 10 MERGED
    mock_pr_state 11 MERGED
    git checkout feature-b

    # Action
    run "$GSS_CMD" sync --yes
    
    # Assertions
    assert_success
    assert_output --partial "All branches in the stack were merged. Nothing left to rebase."
    assert_output --partial "Deleted local branch 'feature-a'"
    assert_output --partial "Deleted local branch 'feature-b'"
    
    # --- State Assertions ---
    assert_branch_does_not_exist feature-a
    assert_branch_does_not_exist feature-b
    # The current branch should be 'main' after the stack is deleted.
    run git rev-parse --abbrev-ref HEAD
    assert_output "main"
}

@test "sync: detects merged branch without a PR" {
    # This tests the fallback mechanism for detecting merged branches. If a
    # branch was merged directly into the base branch without a PR (or if gss
    # doesn't know the PR number), it should still be detected as merged and
    # cleaned up.
    
    # Setup
    create_stack feature-a feature-b
    # Manually merge feature-a into main to simulate a merge without a PR
    run git checkout main
    run git merge --no-ff feature-a
    run git push origin main
    run git checkout feature-b

    # Action
    run "$GSS_CMD" sync --yes

    # Assertions
    assert_success
    assert_output --partial "Deleted local branch 'feature-a'"

    # --- State Assertions ---
    assert_branch_parent feature-b main
    assert_branch_does_not_exist feature-a
}

@test "sync: correctly handles non-consecutive merged branches (REGRESSION)" {
    # This regression test is designed to fail with the old sync logic.
    # The old logic only checked the status of a branch's parent, not the branch
    # itself. This meant it would fail to detect that `feature-c` was merged
    # because its parent, `feature-b`, was not.
    
    # Setup
    create_stack feature-a feature-b feature-c
    track_pr feature-a 10
    track_pr feature-c 12
    mock_pr_state 10 MERGED # feature-a is merged
    mock_pr_state 12 MERGED # feature-c is merged
    git checkout feature-c

    # Action
    run "$GSS_CMD" sync --yes

    # Assertions
    assert_success
    assert_output --partial "Deleted local branch 'feature-a'"
    assert_output --partial "Deleted local branch 'feature-c'"

    # --- State Assertions ---
    # The only remaining branch should be feature-b, parented on main.
    assert_branch_parent feature-b main
    assert_branch_does_not_exist feature-a
    assert_branch_does_not_exist feature-c
    # The current branch should be 'main' because the original branch was deleted.
    run git rev-parse --abbrev-ref HEAD
    assert_output "main"
}

@test "sync: deletes a merged branch whose parent is not merged (REGRESSION)" {
    # This regression test is critical. It ensures that the sync logic checks
    # the status of *each branch individually*, not just its parent.
    # The old logic would fail here because it would check feature-b, see that its
    # parent (feature-a) was not merged, and incorrectly do nothing, leaving
    # the merged feature-b branch behind.
    
    # Setup
    create_stack feature-a feature-b
    track_pr feature-b 11
    mock_pr_state 11 MERGED # Only feature-b is merged
    git checkout feature-b

    # Action
    run "$GSS_CMD" sync --yes

    # Assertions
    assert_success
    assert_output --partial "Deleted local branch 'feature-b'"

    # --- State Assertions ---
    assert_branch_does_not_exist feature-b
    assert_branch_exists feature-a
    # The current branch should be 'main' because the original branch was deleted.
    run git rev-parse --abbrev-ref HEAD
    assert_output "main"
}

@test "sync: runs correctly when started from the middle of a stack" {
    # This test verifies that the `sync` command works correctly regardless
    # of which branch in the stack is currently checked out. The script should
    # be smart enough to find the top of the stack and sync all branches.
    
    # Setup
    create_stack feature-a feature-b feature-c
    track_pr feature-a 10
    mock_pr_state 10 MERGED
    git checkout feature-b # Start from the middle

    # Action
    run "$GSS_CMD" sync --yes

    # Assertions
    assert_success
    assert_output --partial "Deleted local branch 'feature-a'"

    # --- State Assertions ---
    assert_branch_parent feature-b main
    assert_branch_parent feature-c feature-b
    assert_branch_does_not_exist feature-a
    # The script should return the user to their original branch.
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b" 
}

@test "sync: runs correctly on a single-branch stack" {
    # This test covers the simplest stack: a single feature branch off 'main'.
    # 'sync' should just perform a standard rebase against the updated base branch.
    
    # Setup
    run "$GSS_CMD" create feature-a
    run create_commit "commit for feature-a"
    run git checkout main
    run create_commit "new base commit"
    local main_sha; main_sha=$(git rev-parse HEAD)
    run git push origin main
    run git checkout feature-a

    # Action
    run "$GSS_CMD" sync --yes

    # Assertions
    assert_success
    
    # --- State Assertions ---
    assert_commit_is_ancestor "$main_sha" feature-a
    assert_branch_parent feature-a main
}

@test "sync: does nothing when already up-to-date" {
    # If the stack is already perfectly in sync with the remote base branch,
    # the command should complete successfully without making any changes.
    
    # Setup
    create_stack feature-a feature-b
    local sha_a_before; sha_a_before=$(git rev-parse feature-a)
    local sha_b_before; sha_b_before=$(git rev-parse feature-b)
    git checkout feature-b

    # Action
    run "$GSS_CMD" sync --yes

    # Assertions
    assert_success
    
    # --- State Assertions ---
    # Verify that the commit hashes for the branches have not changed.
    local sha_a_after; sha_a_after=$(git rev-parse feature-a)
    local sha_b_after; sha_b_after=$(git rev-parse feature-b)
    assert_equal "$sha_a_before" "$sha_a_after"
    assert_equal "$sha_b_before" "$sha_b_after"
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b"
}


@test "sync: avoids conflict with a true squash merge on the same file (REGRESSION)" {
    # This test simulates a real-world squash merge scenario where multiple
    # commits on the merged branch modify the same file. `gss sync` must be
    # able to rebase the dependent branch (`br2`) without conflicts.

    # Setup
    # 1. Create a stack where `br1` has multiple commits modifying the same file.
    run "$GSS_CMD" create br1
    create_commit "feat: create file" "line 1" "file.txt"
    # Use `echo -e` to handle newlines correctly
    create_commit "feat: add line 2" "$(echo -e "line 1\nline 2")" "file.txt"
    run "$GSS_CMD" create br2
    create_commit "feat: add line 3" "$(echo -e "line 1\nline 2\nline 3")" "file.txt"

    # 2. Mock the PR for br1 as merged.
    track_pr br1 10
    mock_pr_state 10 MERGED
    
    # 3. Perform a true squash merge of br1 into main.
    run git checkout main
    # This combines the two commits from br1 into the staging area.
    run git merge --squash br1
    # Create the single squash commit.
    run git commit -m "Squash merge of br1"
    run git push origin main
    
    # 4. Return to the top of the stack.
    run git checkout br2

    # Action
    # With the `--fork-point` strategy, this should succeed without conflict.
    run "$GSS_CMD" sync --yes

    # Assertions
    # The command should succeed without any rebase conflicts.
    assert_success "Expected sync to complete without conflicts."

    # --- State Assertions ---
    # `br2` should now be parented on `main`.
    assert_branch_parent br2 main
    # `br1` should have been deleted.
    assert_branch_does_not_exist br1
    # Verify the final, correct content of the file on `br2`.
    run cat file.txt
    assert_output "$(echo -e "line 1\nline 2\nline 3")"
}

@test "sync: handles multiple conflicts across a stack correctly" {
    # This test ensures the state file is updated correctly during an
    # iterative rebase, allowing the user to resolve multiple conflicts
    # one by one and have the metadata be correct at the end.

    # Setup
    # 1. Create a stack br1 -> br2 -> br3, where each branch modifies
    #    the same line in a different file.
    run "$GSS_CMD" create br1
    create_commit "br1 commit" "version=1" "file1.txt"
    create_commit "br1 commit 2" "version=1" "file2.txt"

    run "$GSS_CMD" create br2
    create_commit "br2 commit" "version=2" "file1.txt"

    run "$GSS_CMD" create br3
    create_commit "br3 commit" "version=3" "file2.txt"

    # 2. Mock br1 as merged and create a conflicting squash on main.
    track_pr br1 10
    mock_pr_state 10 MERGED
    run git checkout main
    run git merge --squash br1
    run git commit -m "Squash merge of br1"

    # 3. Create a commit on main that will conflict with both br2 and br3.
    create_commit "main conflict" "version=main" "file1.txt"
    create_commit "main conflict 2" "version=main" "file2.txt"
    run git push origin main

    # 4. Return to the top of the stack
    run git checkout br3

    # Action 1: Run sync, which should fail on br2
    run "$GSS_CMD" sync --yes
    assert_failure

    # Resolution 1: Fix conflict for br2. This rebase finishes successfully.
    echo "version=2-resolved" > file1.txt
    run git add file1.txt
    GIT_EDITOR=true run git rebase --continue
    assert_failure
    
    # Action 2: Run gss continue. The tool should pick up where it left off
    # and now fail on the rebase of br3.
    run "$GSS_CMD" continue --yes
    assert_failure

    # Resolution 2: First, it conflicts on file1.txt from br1's history.
    echo "version=3-resolved" > file2.txt
    run git add file2.txt
    GIT_EDITOR=true run git rebase --continue
    assert_success

    # At this point, the git rebase operation is fully complete.

    # Action 3: Now that all git operations are done, run gss continue to finalize.
    run "$GSS_CMD" continue --yes
    assert_success

    # --- Final State Assertions ---
    # The state file should be gone.
    refute [ -f ".git/GSS_OPERATION_STATE" ]
    # The stack should be correctly reparented.
    assert_branch_parent br2 main
    assert_branch_parent br3 br2
    # The content of the files should be correct.
    run cat file1.txt
    assert_output "version=2-resolved"
    run cat file2.txt
    assert_output "version=3-resolved"
}
