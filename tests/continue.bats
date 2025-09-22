#!/usr/bin/env bats

load 'bats-support/load'
load 'bats-assert/load'
load 'test_helper'
load 'debug'

# --- Variables and Pre-run Checks ---
GSS_CMD_BASE="$BATS_TEST_DIRNAME/../dist/index.js"
GSS_CMD=""

if [[ -f "$GSS_CMD_BASE" ]]; then
    GSS_CMD="$GSS_CMD_BASE"
else
    echo "🔴 Error: Could not find the gss script. Looked for '$GSS_CMD_BASE'." >&2
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

# --- Test Suite for 'gss continue' and Pending Operation Guards ---

# --- Guard Logic Tests ---

@test "guard: blocks other commands when a rebase is in progress" {
    # SCENARIO: A sync operation hits a conflict, pausing the rebase. The user
    # should be blocked from running other gss commands until it's resolved.
    
    # Setup: Create a conflict
    create_commit "base" "version=1" "file.txt"
    run "$GSS_CMD" create br1
    create_commit "br1 changes" "version=2" "file.txt"
    run git checkout main
    create_commit "main changes" "version=3" "file.txt"
    run git push origin main
    run git checkout br1
    
    # Start the sync, which will fail and leave a state file + rebase-merge dir
    run "$GSS_CMD" sync --yes
    assert_failure "Expected initial sync to fail"

    # Action & Assertions: Check that all relevant commands are blocked
    local commands_to_block=(
        create up down push submit sync list ls status amend restack pr
        track insert squash
    )

    for cmd in "${commands_to_block[@]}"; do
        echo "--- Checking blocked command: $cmd ---"
        run "$GSS_CMD" "$cmd"
        assert_failure "Command '$cmd' should have been blocked"
        assert_output --partial "A gss operation is paused because of a Git rebase conflict"
        assert_output --partial "run 'git rebase --continue'"
        assert_output --partial "run 'gss continue' to finalize"
    done
}

@test "guard: blocks commands after a rebase has been aborted" {
    # SCENARIO: A sync operation hits a conflict, but the user runs `git rebase --abort`.
    # The guard should still block other commands because the gss state file remains.
    
    # Setup: Create a conflict and start a failing sync
    create_commit "base" "version=1" "file.txt"
    run "$GSS_CMD" create br1
    create_commit "br1 changes" "version=2" "file.txt"
    run git checkout main
    create_commit "main changes" "version=3" "file.txt"
    run git push origin main
    run git checkout br1
    run "$GSS_CMD" sync
    assert_failure "Expected initial sync to fail"

    # Abort the rebase manually
    run git rebase --abort
    assert_success

    # Action & Assertions: Check that all relevant commands are blocked
    local commands_to_block=(
        create up down push submit sync list ls status amend restack pr
        track insert squash
    )

    for cmd in "${commands_to_block[@]}"; do
        echo "--- Checking blocked command: $cmd ---"
        run "$GSS_CMD" "$cmd"
        assert_failure "Command '$cmd' should have been blocked"
        assert_output --partial "A previous gss operation is pending completion"
        assert_output --partial "Run 'gss continue' to finalize and clean up"
    done
}

@test "guard: blocks commands after a rebase has succeeded but before continue" {
    # SCENARIO: A sync operation hits a conflict, the user resolves it and runs
    # `git rebase --continue`. The git part is done, but the gss operation is not
    # yet finalized. The guard must still block other commands.

    # Setup: Create a conflict, start a failing sync, then resolve it.
    create_commit "base" "version=1" "file.txt"
    run "$GSS_CMD" create br1
    create_commit "br1 changes" "version=2" "file.txt"
    run git checkout main
    create_commit "main changes" "version=3" "file.txt"
    run git push origin main
    run git checkout br1
    run "$GSS_CMD" sync
    assert_failure "Expected initial sync to fail"

    # Manually resolve the rebase
    echo "resolved" > file.txt
    git add file.txt
    GIT_EDITOR=true run git rebase --continue
    assert_success

    # Action & Assertions: Check that all relevant commands are blocked
    local commands_to_block=(
        create up down push submit sync list ls status amend restack pr
        track insert squash
    )

    for cmd in "${commands_to_block[@]}"; do
        echo "--- Checking blocked command: $cmd ---"
        run "$GSS_CMD" "$cmd"
        assert_failure "Command '$cmd' should have been blocked"
        assert_output --partial "A previous gss operation is pending completion"
        assert_output --partial "Run 'gss continue' to finalize and clean up"
    done
}


# --- Successful Rebase Flow ---

@test "continue: successfully resumes a 'sync' after conflict resolution" {
    # SCENARIO: A sync hits a conflict, the user fixes it, and `gss continue`
    # finalizes the operation, repairing metadata and cleaning up correctly.
    
    # Setup
    create_stack br1 br2
    # Mock br1 as merged
    track_pr br1 10
    mock_pr_state 10 MERGED
    # Create a conflict for br2
    run git checkout main
    create_commit "main changes" "version=main" "file.txt"
    run git push origin main
    run git checkout br2
    create_commit "br2 changes" "version=2" "file.txt"
    
    # 1. Start the sync, which should fail on the rebase of br2
    run "$GSS_CMD" sync --yes
    assert_failure
    assert_output --partial "Rebase conflict detected"
    
    # 2. Manually resolve the conflict
    echo "resolved content" > file.txt
    git add file.txt
    GIT_EDITOR=true run git rebase --continue
    assert_success "Expected git rebase --continue to succeed"
    
    # 3. Run gss continue to finalize
    run "$GSS_CMD" continue --yes
    
    # Assertions
    assert_success
    assert_output --partial "Resuming 'sync' operation..."
    assert_output --partial "Metadata repaired"
    assert_output --partial "Deleted local branch 'br1'"
    assert_output --partial "Operation complete"

    # --- Final State Assertions ---
    refute [ -f ".git/GSS_OPERATION_STATE" ] "State file should be cleaned up"
    assert_branch_parent br2 main
    assert_branch_does_not_exist br1
    assert_current_branch br2 # Should return to the original branch
}

@test "continue: successfully resumes a 'restack' after conflict resolution" {
    # SCENARIO: An amend causes a restack, which hits a conflict. The user
    # fixes it, and `gss continue` finalizes the operation.
    
    # Setup
    create_stack br1 br2
    run git checkout br2
    create_commit "br2 changes" "version=2" "conflict.txt"
    run git checkout br1
    # Amend br1 to create a conflict with br2
    create_commit "br1 conflict" "version=1" "conflict.txt"
    git commit --amend --no-edit

    # 1. Start the restack, which should fail
    run "$GSS_CMD" restack --yes
    assert_failure
    assert_output --partial "Rebase conflict detected"

    # 2. Manually resolve the conflict
    echo "resolved" > conflict.txt
    git add conflict.txt
    GIT_EDITOR=true run git rebase --continue
    assert_success
    
    # 3. Run gss continue to finalize
    run "$GSS_CMD" continue --yes
    
    # Assertions
    assert_success
    assert_output --partial "Resuming 'restack' operation"
    
    # --- Final State Assertions ---
    refute [ -f ".git/GSS_OPERATION_STATE" ]
    assert_branch_parent br2 br1
    assert_commit_is_ancestor br1 br2
    assert_current_branch br1
}


# --- Aborted Rebase Flow ---

@test "continue: correctly handles an aborted 'sync' rebase" {
    # SCENARIO: A sync hits a conflict, the user runs `git rebase --abort`.
    # `gss continue` should detect this, clean up the state file, and NOT
    # modify the stack's metadata.
    
    # Setup
    create_stack br1 br2
    track_pr br1 10
    mock_pr_state 10 MERGED
    run git checkout main
    create_commit "main changes" "version=main" "file.txt"
    run git push origin main
    run git checkout br2
    create_commit "br2 changes" "version=2" "file.txt"
    
    # 1. Get a snapshot of the state before the failed operation
    local sha_br2_before; sha_br2_before=$(git rev-parse br2)
    
    # 2. Start the sync, which will fail
    run "$GSS_CMD" sync --yes
    assert_failure

    # 3. Manually abort the rebase
    run git rebase --abort
    assert_success

    # 4. Run gss continue
    run "$GSS_CMD" continue --yes
    
    # Assertions
    assert_success
    assert_output --partial "Detected that the previous Git rebase was likely aborted or failed"
    assert_output --partial "Pending operation has been cleaned up"
    refute_output --partial "Metadata repaired" # Must not repair metadata

    # --- Final State Assertions ---
    refute [ -f ".git/GSS_OPERATION_STATE" ]
    # Metadata should be UNCHANGED
    assert_branch_parent br2 br1
    # Branch SHA should be UNCHANGED
    local sha_br2_after; sha_br2_after=$(git rev-parse br2)
    assert_equal "$sha_br2_before" "$sha_br2_after"
    assert_branch_exists br1
    assert_current_branch br2
}

@test "continue: correctly handles an aborted 'restack' rebase" {
    # SCENARIO: A restack hits a conflict, the user aborts. `gss continue`
    # should clean up without changing metadata.
    
    # Setup
    create_stack br1 br2
    run git checkout br2
    create_commit "br2 changes" "version=2" "conflict.txt"
    run git checkout br1
    create_commit "br1 conflict" "version=1" "conflict.txt"
    git commit --amend --no-edit

    # 1. Get a snapshot of the state before the failed operation
    local sha_br2_before; sha_br2_before=$(git rev-parse br2)
    
    # 2. Start the restack, which will fail
    run "$GSS_CMD" restack --yes
    assert_failure

    # 3. Manually abort the rebase
    run git rebase --abort
    assert_success

    # 4. Run gss continue
    run "$GSS_CMD" continue --yes
    
    # Assertions
    assert_success
    assert_output --partial "Detected that the previous Git rebase was likely aborted"

    # --- Final State Assertions ---
    refute [ -f ".git/GSS_OPERATION_STATE" ]
    # Metadata should be UNCHANGED
    assert_branch_parent br2 br1
    # Branch SHA should be UNCHANGED
    local sha_br2_after; sha_br2_after=$(git rev-parse br2)
    assert_equal "$sha_br2_before" "$sha_br2_after"
    assert_current_branch br1
}

# --- Edge Cases ---

@test "continue: does nothing when no operation is in progress" {
    # The 'continue' command should only work when a state file exists.
    # If run at any other time, it should inform the user and exit cleanly.
    
    # Action
    run "$GSS_CMD" continue

    # Assertions
    assert_success
    assert_output --partial "No gss operation to continue. Nothing to do."
}
