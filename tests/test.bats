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
    assert_commit_is_ancestor "$main_sha" feature-b
}

@test "sync: syncs with a merged parent branch" {
    # Setup
    create_stack feature-a feature-b
    # Mock PRs: #10 for feature-a, #11 for feature-b
    git config branch.feature-a.pr-number 10
    git config branch.feature-b.pr-number 11
    mock_pr_state 10 MERGED # Mock feature-a's PR as merged
    git checkout feature-b

    # Action: Run sync with --yes
    run "$STGIT_CMD" sync --yes

    # Assertions
    assert_success
    assert_output --partial "Deleted local branch 'feature-a'"

    # --- State Assertions ---
    assert_branch_parent feature-b main
    assert_branch_does_not_exist feature-a
    assert_branch_exists feature-b
}

@test "sync: handles rebase conflict gracefully" {
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
    assert [ -f ".git/STGIT_OPERATION_STATE" ]
    run cat ".git/STGIT_OPERATION_STATE"
    assert_output --partial "COMMAND='sync'"
    assert_output --partial "ORIGINAL_BRANCH='feature-a'"
}

@test "sync: 'continue' resumes after a sync conflict" {
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
    assert_branch_parent feature-d feature-a
    assert_branch_does_not_exist feature-b
    assert_branch_does_not_exist feature-c
    assert_branch_exists feature-a
    assert_branch_exists feature-d
}

@test "sync: syncs when entire stack is merged" {
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
    run git rev-parse --abbrev-ref HEAD
    assert_output "main"
}

@test "sync: detects merged branch without a PR" {
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

