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
    # The squash command requires an interactive commit, so we use a mock editor
    # that automatically provides a commit message.
    git config --global core.editor "echo 'Squashed commit' >"
}

teardown() {
    if [ "$BATS_TEST_STATUS" -ne 0 ]; then
        echo "Teardown: Test failed. Dumping state..." >&2
        gss_debug_dump "State at time of failure"
    fi
    cleanup_mock_gh_state
    # Unset the global config to avoid interfering with other test suites
    git config --global --unset core.editor || true
}

# --- Test Suite for 'gss squash' ---

# --- Core Functionality ---

@test "squash: squashes middle branch into parent (default behavior)" {
    # SCENARIO: The most common use case. Squashing a middle branch ('br2')
    # into its parent ('br1') should delete 'br2' and reparent its child ('br3').
    create_stack br1 br2 br3
    run git checkout br2
    
    # Action
    run "$GSS_CMD" squash --yes
    
    # Assertions
    assert_success
    assert_output --partial "Successfully squashed 'br2' into 'br1'"
    assert_output --partial "Run 'gss restack' to update descendant branches"

    # --- State Assertions ---
    assert_branch_does_not_exist br2
    assert_branch_parent br3 br1
    # Check that the content from br2's commit is now on br1
    run git checkout br1
    run git show HEAD --pretty="" --name-only
    assert_output --partial "Commit_for_br2.txt"
}

@test "squash: squashes child into current branch with --into child" {
    # SCENARIO: Running the command from a parent branch with the '--into child' flag
    # should produce the same result as running it from the child with default settings.
    create_stack br1 br2 br3
    run git checkout br1 # Start from the parent
    
    # Action
    run "$GSS_CMD" squash --into child --yes
    
    # Assertions
    assert_success
    assert_output --partial "Successfully squashed 'br2' into 'br1'"

    # --- State Assertions ---
    assert_branch_does_not_exist br2
    assert_branch_parent br3 br1
}

@test "squash: squashes top branch of a stack" {
    # SCENARIO: When squashing the top branch, there are no descendants to reparent,
    # and the command should complete without suggesting a restack.
    create_stack br1 br2
    run git checkout br2
    
    # Action
    run "$GSS_CMD" squash --yes

    # Assertions
    assert_success
    refute_output --partial "Run 'gss restack'"
    assert_output --partial "Run 'gss push'"

    # --- State Assertions ---
    assert_branch_does_not_exist br2
    assert_branch_exists br1
}

# --- Guards and User Interaction ---

@test "squash: fails when trying to squash bottom branch into the base branch" {
    create_stack br1 br2
    run git checkout br1
    
    # Action
    run "$GSS_CMD" squash --yes
    
    # Assertions
    assert_failure
    assert_output --partial "Cannot squash the first branch of a stack"
}

@test "squash: fails with --into child when no child exists" {
    create_stack br1 br2
    run git checkout br2 # We are at the top of the stack
    
    # Action
    run "$GSS_CMD" squash --into child --yes
    
    # Assertions
    assert_failure
    assert_output --partial "No child branch found to squash into"
}

@test "squash: cancels if user answers no to confirmation" {
    create_stack br1 br2
    run git checkout br2
    local shas_before; shas_before=$(get_all_branch_shas)

    # Action: Pipe 'n' into the prompt using a here-string
    run "$GSS_CMD" squash <<< "n"
    
    # Assertions
    assert_success
    assert_output --partial "Squash cancelled"

    # --- State Assertions ---
    local shas_after; shas_after=$(get_all_branch_shas)
    assert_equal "$shas_before" "$shas_after"
    assert_branch_exists br2
}

# --- Complex Scenarios & PR Integration ---

@test "squash: prompts to close PR of squashed branch and user agrees" {
    create_stack br1 br2
    track_pr br2 42
    mock_pr_state 42 OPEN
    run git checkout br2
    
    # Action: Use --yes for the main squash prompt, then 'y' for the PR prompt.
    run "$GSS_CMD" squash --yes <<< "y"
    
    # Assertions
    assert_success
    assert_output --partial "Closing PR #42 on GitHub"
    assert_output --partial "PR #42 closed"

    # --- State Assertions ---
    assert_branch_does_not_exist br2
}

# TODO: Figure out how to accept first prompt but decline second
# @test "squash: does not close PR if user declines" {
#     create_stack br1 br2
#     git config branch.br2.pr-number 42
#     mock_pr_state 42 OPEN
#     run git checkout br2
    
#     # Action: Use --yes for the main squash prompt, then 'n' for the PR prompt.
#     run "$GSS_CMD" squash --yes <<< "y"

    
#     # Assertions
#     assert_success
#     refute_output --partial "Closing PR #42"

#     # --- State Assertions ---
#     assert_branch_does_not_exist br2
# }

@test "squash: aborts cleanly if interactive commit is cancelled" {
    # SCENARIO: If the user saves an empty commit message or aborts their editor,
    # the script must fail gracefully and restore the original state.
    create_stack br1 br2
    run git checkout br2
    local shas_before; shas_before=$(get_all_branch_shas)

    # Use an editor command that fails, simulating an aborted commit.
    GIT_EDITOR=false run "$GSS_CMD" squash --yes
    
    # Assertions
    assert_failure
    assert_output --partial "Commit failed or was aborted. Undoing squash."

    # --- State Assertions ---
    local shas_after; shas_after=$(get_all_branch_shas)
    assert_equal "$shas_before" "$shas_after"
    assert_current_branch br2 # Should have returned to the original branch
    run git status --porcelain
    assert_output "" # Working directory should be clean
}

@test "squash: fails and reports conflict on merge conflict" {
    # SCENARIO: If the changes on the two branches conflict, `git merge --squash`
    # will fail. The script should detect this and exit, leaving the user in
    # the standard git conflict resolution state.
    
    # 1. Create the base branch for the conflict.
    run "$GSS_CMD" create br1
    create_commit "feat: create base file" "version=original" "file.txt"

    # 2. Create the child branch. Now both branches have the same base file.
    run "$GSS_CMD" create br2
    
    # 3. Modify the file on the child branch (br2).
    create_commit "feat: modify file on child" "version=2" "file.txt"
    
    # 4. Go back to the parent (br1) and make a *conflicting* modification.
    run git checkout br1
    create_commit "feat: modify file on parent" "version=1" "file.txt"
    
    # 5. Now, checkout br2 to run the squash command from there.
    run git checkout br2

    # Action
    run "$GSS_CMD" squash --yes
    
    # Assertions
    assert_failure
    assert_output --partial "Automatic merge failed" # Check for git's error message

    # --- State Assertions ---
    # The script should have failed, leaving git's conflict state intact.
    run git status --porcelain
    assert_output --partial "UU file.txt"
    # The branch to be squashed should still exist.
    assert_branch_exists br2
}
