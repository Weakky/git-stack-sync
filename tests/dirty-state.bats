#!/usr/bin/env bats

load 'bats-support/load'
load 'bats-assert/load'
load 'test_helper'

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

# --- Helper to create a dirty state ---
create_dirty_state() {
    echo "dirty content" > dirty_file.txt
    git add dirty_file.txt # Stage the change
}

create_untracked_file() {
    echo "untracked content" > untracked_file.txt
}

# --- Tests ---

@test "sync: fails with dirty state and provides instructions" {
    # Setup
    create_stack feature-a
    create_dirty_state
    
    # Action
    run "$GSS_CMD" sync
    
    # Assertions
    assert_failure
    assert_output --partial "Command cannot run with uncommitted changes"
    assert_output --partial "Please 'git commit' or 'git stash' your changes before proceeding."

    # --- State Assertions ---
    # The working directory should still be dirty.
    run git status --porcelain
    assert_output --partial "A  dirty_file.txt"
}

@test "sync: fails with untracked files" {
    # Setup
    create_stack feature-a
    create_untracked_file
    
    # Action
    run "$GSS_CMD" sync
    
    # Assertions
    assert_failure
    assert_output --partial "Command cannot run with uncommitted changes"
}

@test "restack: fails with dirty state and provides instructions" {
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-a
    create_commit "amend-me"
    create_dirty_state

    # Action
    run "$GSS_CMD" restack
    
    # Assertions
    assert_failure
    assert_output --partial "Command cannot run with uncommitted changes"

    # --- State Assertions ---
    run git status --porcelain
    assert_output --partial "A  dirty_file.txt"
}

@test "create: works if dirty changes don't conflict" {
    # Setup
    create_dirty_state

    # Action
    run "$GSS_CMD" create feature-a

    # Assertions
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-a'"

    # --- State Assertions ---
    run git status --porcelain
    assert_output --partial "A  dirty_file.txt"
    # Ensure the new branch was NOT created
    assert_branch_exists feature-a
}

@test "up: fails with dirty state and provides instructions" {
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-a
    create_dirty_state

    # Action
    run "$GSS_CMD" up

    # Assertions
    assert_failure
    assert_output --partial "Command cannot run with uncommitted changes"

    # --- State Assertions ---
    # Should still be on the original branch
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"
    run git status --porcelain
    assert_output --partial "A  dirty_file.txt"
}

@test "down: fails with dirty state and provides instructions" {
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-b
    create_dirty_state

    # Action
    run "$GSS_CMD" down

    # Assertions
    assert_failure
    assert_output --partial "Command cannot run with uncommitted changes"
}

@test "insert: fails with dirty state and provides instructions" {
    # Setup
    create_stack feature-a
    create_dirty_state

    # Action
    run "$GSS_CMD" insert feature-b

    # Assertions
    assert_failure
    assert_output --partial "Command cannot run with uncommitted changes"
}

@test "squash: fails with dirty state and provides instructions" {
    # Setup
    create_stack feature-a feature-b
    run git checkout feature-b
    create_dirty_state

    # Action
    run "$GSS_CMD" squash

    # Assertions
    assert_failure
    assert_output --partial "Command cannot run with uncommitted changes"
}

@test "submit: fails with dirty state and provides instructions" {
    # Setup
    create_stack feature-a
    create_dirty_state

    # Action
    run "$GSS_CMD" submit

    # Assertions
    assert_failure
    assert_output --partial "Command cannot run with uncommitted changes"
}

@test "push: fails with dirty state and provides instructions" {
    # Setup
    create_stack feature-a
    create_dirty_state

    # Action
    run "$GSS_CMD" push --yes

    # Assertions
    assert_failure
    assert_output --partial "Command cannot run with uncommitted changes"
}

@test "track remove: works with dirty state" {
    # Setup
    run "$GSS_CMD" create feature-a
    create_dirty_state

    # Action
    # This should fail because 'track remove' now has the guard.
    # We are not creating unique commits, so the *other* guard won't trigger.
    run "$GSS_CMD" track remove

    # Assertions
    assert_success
}

@test "amend: succeeds with staged changes (exception to the rule)" {
    # Setup
    create_stack feature-a
    create_commit "initial commit"
    # Create staged changes, which is what 'amend' is for
    echo "new content" > new_file.txt
    git add new_file.txt
    local original_sha; original_sha=$(git rev-parse HEAD)

    # Action
    # This should succeed because 'amend' should bypass the dirty check.
    run "$GSS_CMD" amend --yes

    # Assertions
    assert_success
    assert_output --partial "Commit amended successfully"

    # --- State Assertions ---
    local new_sha; new_sha=$(git rev-parse HEAD)
    assert_not_equal "$original_sha" "$new_sha"
    run git status --porcelain
    assert_output "" # Working directory should be clean after amend.
}

