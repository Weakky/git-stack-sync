#!/usr/bin/env bats

load 'bats-support/load'
load 'bats-assert/load'
load 'test_helper'

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
    # Clean up mock state after each test
    cleanup_mock_gh_state
}

# --- Tests for 'stgit create' ---
@test "create: creates a new child branch" {
    run "$STGIT_CMD" create feature-a
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-a'"

    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"

    run git config --get branch.feature-a.parent
    assert_output "main"
}

@test "create: creates a nested child branch" {
    # Setup: Create the first branch in the stack
    run "$STGIT_CMD" create feature-a
    assert_success
    
    # Action: Create the nested branch
    run "$STGIT_CMD" create feature-b
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-b'"

    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-b"

    run git config --get branch.feature-b.parent
    assert_output "feature-a"
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
    "$STGIT_CMD" create feature-a
    "$STGIT_CMD" create feature-b
    git checkout main

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
    git checkout main
    create_commit "New commit on main"
    git push origin main >/dev/null
    git checkout feature-b

    # Action
    run "$STGIT_CMD" sync
    
    # Assertions
    assert_success
    assert_output --partial "Rebasing 'feature-a' onto 'origin/main'"
    assert_output --partial "Rebasing 'feature-b' onto 'feature-a'"
    assert_output --partial "Run 'stgit push' to update your remote branches"

    # Verify the commit is now in the history of feature-b
    run git log --oneline feature-b
    assert_output --partial "New commit on main"
}

@test "sync: syncs with a merged parent branch" {
    # Setup
    create_stack feature-a feature-b
    # Mock PRs: #10 for feature-a, #11 for feature-b
    git config branch.feature-a.pr-number 10
    git config branch.feature-b.pr-number 11
    mock_pr_state 10 MERGED # Mock feature-a's PR as merged
    git checkout feature-b

    # Action: Run sync and answer 'y' to the delete prompt
    "$STGIT_CMD" sync --yes

    # Assertions
    assert_success
    assert_output --partial "Parent branch 'feature-a' has been merged"
    assert_output --partial "Updating parent of 'feature-b' to 'main'"
    assert_output --partial "Rebasing 'feature-b' onto 'origin/main'"
    assert_output --partial "Deleted local branch 'feature-a'"

    # Verify new stack structure
    run "$STGIT_CMD" status
    assert_output --partial "➡️  feature-b * (parent: main)"
    refute_output --partial "feature-a"
}

@test "sync: handles rebase conflict gracefully" {
    # Setup
    create_commit "conflict-file" "line 1" "file.txt"
    "$STGIT_CMD" create feature-a >/dev/null
    create_commit "feature-a changes" "line 2" "file.txt"
    git checkout main >/dev/null
    create_commit "main changes" "line one" "file.txt"
    git push origin main >/dev/null
    git checkout feature-a >/dev/null

    # Action
    run "$STGIT_CMD" sync --yes

    # Assertions
    assert_failure
    assert_output --partial "Rebase conflict detected"
    assert_output --partial "run 'stgit continue'"
    
    # Verify state file was created
    assert [ -f ".git/STGIT_OPERATION_STATE" ]
    run cat ".git/STGIT_OPERATION_STATE"
    assert_output --partial "COMMAND='sync'"
    assert_output --partial "ORIGINAL_BRANCH='feature-a'"
}

@test "sync: 'continue' resumes after a sync conflict" {
    # Setup: Create a conflict
    create_commit "conflict-file" "line 1" "file.txt"
    "$STGIT_CMD" create feature-a >/dev/null
    create_commit "feature-a changes" "line 2" "file.txt"
    git checkout main >/dev/null
    create_commit "main changes" "line one" "file.txt"
    git push origin main >/dev/null
    git checkout feature-a >/dev/null
    # Run sync, which is expected to fail
    run -1 "$STGIT_CMD" sync

    # Manual conflict resolution
    echo "resolved" > file.txt
    git add file.txt
    git rebase --continue >/dev/null

    # Action
    run "$STGIT_CMD" continue

    # Assertions
    assert_success
    assert_output --partial "Finishing operation..."
    assert_output --partial "Run 'stgit push' to update your remote branches"
    
    # Verify state file was removed
    refute [ -f ".git/STGIT_OPERATION_STATE" ]
    
    # Verify we are back on the original branch
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"
}

