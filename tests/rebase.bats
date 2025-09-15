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
setup() {
    setup_git_repo
}

teardown() {
    cleanup_mock_gh_state
}

# --- Tests ---

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
    git config branch.br1.pr-number 10
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
    git config branch.br1.pr-number 10
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