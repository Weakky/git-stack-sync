#!/usr/bin/env bats

load 'bats-support/load'
load 'bats-assert/load'
load 'test_helper'
load 'debug' # Load the new debug helper

# --- Variables and Pre-run Checks ---
STGIT_CMD_BASE="$BATS_TEST_DIRNAME/../stgit"
STGIT_CMD=""

# Auto-detect whether the script is named 'stgit' or 'stgit.sh'
if [[ -f "$STGIT_CMD_BASE" ]]; then
    STGIT_CMD="$STGIT_CMD_BASE"
elif [[ -f "${STGIT_CMD_BASE}.sh" ]]; then
    STGIT_CMD="${STGIT_CMD_BASE}.sh"
else
    echo "🔴 Error: Could not find the stgit script. Looked for '$STGIT_CMD_BASE' and '${STGIT_CMD_BASE}.sh'." >&2
    exit 1
fi

# Check if the found script is executable
if [[ ! -x "$STGIT_CMD" ]]; then
    echo "🔴 Error: The stgit script found at '$STGIT_CMD' is not executable." >&2
    echo "💡 Please run 'chmod +x ${STGIT_CMD##*/}' to fix this." >&2
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
        stgit_debug_dump "State at time of failure"
        
        echo "--- MOCK GH STATE ---" >&2
        if [ -d "/tmp/stgit_mock_gh_state" ] && [ -n "$(ls -A /tmp/stgit_mock_gh_state)" ]; then
            ls -l /tmp/stgit_mock_gh_state/ >&2
            cat /tmp/stgit_mock_gh_state/* >&2
        else
            echo "  (no mock state found)" >&2
        fi
        echo "--- END MOCK GH STATE ---" >&2
    fi
    # Clean up mock state after each test
    cleanup_mock_gh_state
}

# --- Tests for 'stgit create' ---
@test "create: creates a new child branch" {
    run "$STGIT_CMD" create feature-a
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-a'"

    # --- State Assertions ---
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"
    assert_branch_parent feature-a main
}

@test "create: creates a nested child branch" {
    # Setup: Create the first branch in the stack
    run "$STGIT_CMD" create feature-a
    assert_success
    
    # Action: Create the nested branch
    run "$STGIT_CMD" create feature-b
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-b'"

    # --- State Assertions ---
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b"
    assert_branch_parent feature-b feature-a
}

# --- Tests for commands on the base branch ---
@test "next: fails when run on the base branch" {
    # Setup: We are on 'main' by default
    run "$STGIT_CMD" next
    assert_failure
    assert_output --partial "command cannot be run from the base branch"
}

@test "status: fails when run on the base branch and lists stacks" {
    # Setup a stack to be listed
    run "$STGIT_CMD" create feature-a
    run "$STGIT_CMD" create feature-b
    run git checkout main

    # Action
    run "$STGIT_CMD" status
    assert_failure
    assert_output --partial "Found 1 stack(s):"
    assert_output --partial "- feature-a (2 branches)"
}

# --- Tests for 'stgit sync' ---
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
    run "$STGIT_CMD" sync
    
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
    git config branch.feature-a.pr-number 10
    git config branch.feature-b.pr-number 11
    mock_pr_state 10 MERGED # Mock feature-a's PR as merged
    git checkout feature-b

    # Action: Run sync with --yes to auto-confirm branch deletion
    run "$STGIT_CMD" sync --yes

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

@test "sync: handles rebase conflict gracefully" {
    # This test ensures that if 'git rebase' fails during a sync (due to a merge
    # conflict), the script stops and provides instructions to the user on how
    # to resolve it and continue the operation.
    
    # Setup
    create_commit "conflict-file" "line 1" "file.txt"
    run "$STGIT_CMD" create feature-a
    create_commit "feature-a changes" "line 2" "file.txt"
    run git checkout main
    create_commit "main changes" "line one" "file.txt"
    run git push origin main
    run git checkout feature-a

    # Action
    run "$STGIT_CMD" sync

    # Assertions
    assert_failure
    assert_output --partial "Rebase conflict detected"
    assert_output --partial "run 'stgit continue'"
    
    # --- State Assertions ---
    # A state file should exist to allow 'stgit continue' to resume.
    assert [ -f ".git/STGIT_OPERATION_STATE" ]
    run cat ".git/STGIT_OPERATION_STATE"
    assert_output --partial "COMMAND='sync'"
    assert_output --partial "ORIGINAL_BRANCH='feature-a'"
}

@test "sync: 'continue' resumes after a sync conflict" {
    # This tests the second half of the conflict resolution workflow: after a
    # user manually resolves a rebase conflict, 'stgit continue' should
    # successfully finish the operation.
    
    # Setup: Create a conflict
    create_commit "conflict-file" "line 1" "file.txt"
    run "$STGIT_CMD" create feature-a
    create_commit "feature-a changes" "line 2" "file.txt"
    run git checkout main
    create_commit "main changes" "line one" "file.txt"
    local main_sha; main_sha=$(git rev-parse HEAD) # Get SHA for rebase check
    run git push origin main
    run git checkout feature-a
    # Run sync, which is expected to fail
    run "$STGIT_CMD" sync

    # Manual conflict resolution
    echo "resolved" > file.txt
    run git add file.txt
    
    # By default, a successful rebase opens an editor for the commit message.
    # In a non-interactive test, this would hang. GIT_EDITOR=true tells Git
    # to use the 'true' command as its editor, which does nothing and exits
    # successfully, allowing the rebase to complete automatically.
    GIT_EDITOR=true run git rebase --continue

    # Action
    run "$STGIT_CMD" continue --yes

    # Assertions
    assert_success
    assert_output --partial "Operation complete."
    
    # --- State Assertions ---
    refute [ -f ".git/STGIT_OPERATION_STATE" ]
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
    git config branch.feature-b.pr-number 12
    git config branch.feature-c.pr-number 13
    mock_pr_state 12 MERGED
    mock_pr_state 13 MERGED
    git checkout feature-d

    # Action
    run "$STGIT_CMD" sync --yes

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
    git config branch.feature-a.pr-number 10
    git config branch.feature-b.pr-number 11
    mock_pr_state 10 MERGED
    mock_pr_state 11 MERGED
    git checkout feature-b

    # Action
    run "$STGIT_CMD" sync --yes
    
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
    # branch was merged directly into the base branch without a PR (or if stgit
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
    run "$STGIT_CMD" sync --yes

    # Assertions
    assert_success
    assert_output --partial "Deleted local branch 'feature-a'"

    # --- State Assertions ---
    assert_branch_parent feature-b main
    assert_branch_does_not_exist feature-a
}

@test "sync: runs correctly when started from the middle of a stack" {
    # This test verifies that the `sync` command works correctly regardless
    # of which branch in the stack is currently checked out. The script should
    # be smart enough to find the top of the stack and sync all branches.
    
    # Setup
    create_stack feature-a feature-b feature-c
    git config branch.feature-a.pr-number 10
    mock_pr_state 10 MERGED
    git checkout feature-b # Start from the middle

    # Action
    run "$STGIT_CMD" sync --yes

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
    run "$STGIT_CMD" create feature-a
    run create_commit "commit for feature-a"
    run git checkout main
    run create_commit "new base commit"
    local main_sha; main_sha=$(git rev-parse HEAD)
    run git push origin main
    run git checkout feature-a

    # Action
    run "$STGIT_CMD" sync --yes

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
    run "$STGIT_CMD" sync --yes

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

# --- Tests for 'stgit restack' ---
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
    run "$STGIT_CMD" restack

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
    run "$STGIT_CMD" restack

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
    run "$STGIT_CMD" restack

    # Assertions
    assert_success
    assert_output --partial "You are at the top of the stack. Nothing to restack."

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
    run "$STGIT_CMD" restack
    
    # Assertions
    assert_failure
    assert_output --partial "Rebase conflict detected"

    # --- State Assertions ---
    assert [ -f ".git/STGIT_OPERATION_STATE" ]
    run cat ".git/STGIT_OPERATION_STATE"
    assert_output --partial "COMMAND='restack'"
    assert_output --partial "ORIGINAL_BRANCH='feature-a'"
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
    run "$STGIT_CMD" restack

    # Manual conflict resolution
    echo "resolved" > conflict.txt
    run git add conflict.txt
    GIT_EDITOR=true run git rebase --continue

    # Action
    run "$STGIT_CMD" continue

    # Assertions
    assert_success

    # --- State Assertions ---
    refute [ -f ".git/STGIT_OPERATION_STATE" ]
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
    run "$STGIT_CMD" create feature-a
    run "$STGIT_CMD" create feature-b
    run "$STGIT_CMD" create feature-c
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
    run "$STGIT_CMD" restack

    # Assertions
    assert_success
    assert_output --partial "branch 'feature-b' has no new changes"

    # --- State Assertions ---
    # feature-b should now point to the same commit as the new feature-a.
    local new_b_sha; new_b_sha=$(git rev-parse feature-b)
    assert_equal "$new_a_sha" "$new_b_sha"
    # feature-c should be rebased on top of the (now empty) feature-b.
    assert_commit_is_ancestor "$new_b_sha" feature-c
}

@test "continue: does nothing when no operation is in progress" {
    # The 'continue' command should only work when a state file exists.
    # If run at any other time, it should inform the user and exit cleanly.
    
    # Action
    run "$STGIT_CMD" continue

    # Assertions
    assert_success
    assert_output --partial "No stgit operation to continue. Nothing to do."
}

# --- Tests for 'stgit insert' ---
@test "insert: inserts a branch in the middle of a stack" {
    # This test verifies that inserting a new branch (`feature-b`) between two
    # existing branches (`feature-a` and `feature-c`) correctly updates the
    # parentage and rebases the descendant branch (`feature-c`).
    
    # Setup
    create_stack feature-a feature-c
    run git checkout feature-c
    run create_commit "commit for c"
    local c_sha_before; c_sha_before=$(git rev-parse HEAD)
    run git checkout feature-a

    # Action
    run "$STGIT_CMD" insert feature-b

    # Assertions
    assert_success
    assert_output --partial "Successfully inserted 'feature-b' into the stack"

    # --- State Assertions ---
    assert_branch_parent feature-b feature-a
    assert_branch_parent feature-c feature-b
    # The original commit on 'c' should still be reachable from the new 'c'.
    assert_commit_is_reachable "$c_sha_before" feature-c
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b"
}

@test "insert: inserts a branch at the end of a stack" {
    # This tests inserting a new branch when checked out on the top-most
    # branch of a stack. It should simply extend the stack.
    
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-b

    # Action
    run "$STGIT_CMD" insert feature-c

    # Assertions
    assert_success

    # --- State Assertions ---
    assert_branch_parent feature-c feature-b
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-c"
}

@test "insert: inserts --before a branch in the middle of a stack" {
    # This test verifies the `--before` flag. Inserting `feature-b` before
    # `feature-c` should place it between `feature-a` and `feature-c`.
    
    # Setup
    create_stack feature-a feature-c
    run git checkout feature-c
    run create_commit "commit for c"
    local c_sha_before; c_sha_before=$(git rev-parse HEAD)

    # Action
    run "$STGIT_CMD" insert --before feature-b

    # Assertions
    assert_success

    # --- State Assertions ---
    assert_branch_parent feature-b feature-a
    assert_branch_parent feature-c feature-b
    assert_commit_is_reachable "$c_sha_before" feature-c
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b"
}

@test "insert: inserts --before at the beginning of a stack" {
    # This tests inserting a branch before the very first branch of a stack.
    # The new branch should become the new "bottom" of the stack.
    
    # Setup
    create_stack feature-b feature-c
    run git checkout feature-b
    run create_commit "commit for b"
    local b_sha_before; b_sha_before=$(git rev-parse HEAD)

    # Action
    run "$STGIT_CMD" insert --before feature-a

    # Assertions
    assert_success

    # --- State Assertions ---
    assert_branch_parent feature-a main
    assert_branch_parent feature-b feature-a
    assert_commit_is_reachable "$b_sha_before" feature-b
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"
}

@test "insert: inserts a branch with an existing PR" {
    # If the branch that is being re-parented has a PR, `insert` should
    # update the base of that PR on GitHub.
    
    # Setup
    create_stack feature-a feature-c
    git config branch.feature-c.pr-number 15
    mock_pr_state 15 OPEN
    run git checkout feature-a

    # Action
    run "$STGIT_CMD" insert feature-b

    # Assertions
    assert_success
    # The mock for `gh api` doesn't produce output, but we can check the logs.
    assert_output --partial "Updating GitHub PR for 'feature-c'"

    # --- State Assertions ---
    assert_branch_parent feature-c feature-b
}

# --- Tests for 'stgit push' ---
@test "push: pushes a multi-branch stack" {
    # This is the standard use case: push all local branches in the current
    # stack to the remote.
    
    # Setup
    create_stack feature-a feature-b
    local a_sha; a_sha=$(git rev-parse feature-a)
    local b_sha; b_sha=$(git rev-parse feature-b)
    run git checkout feature-b

    # Action
    run "$STGIT_CMD" push --yes

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
    run "$STGIT_CMD" create feature-a
    run create_commit "commit-a"
    local a_sha; a_sha=$(git rev-parse feature-a)

    # Action
    run "$STGIT_CMD" push --yes

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
    run "$STGIT_CMD" push --yes # Initial push
    run git checkout main
    run create_commit "new base commit"
    run git push origin main
    run git checkout feature-b
    run "$STGIT_CMD" sync # This rebases feature-a and feature-b
    local new_a_sha; new_a_sha=$(git rev-parse feature-a)
    local new_b_sha; new_b_sha=$(git rev-parse feature-b)

    # Action
    run "$STGIT_CMD" push --yes

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
    
    # Action: Pipe 'n' to the confirmation prompt.
    run echo "n" | "$STGIT_CMD" push
    
    # Assertions
    assert_success
    assert_output --partial "Push cancelled"

    # --- State Assertions ---
    # The remote branch should not have been created.
    run git rev-parse origin/feature-a
    assert_failure
}

