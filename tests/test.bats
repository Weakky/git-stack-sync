#!/usr/bin/env bats

# Load helper libraries
load 'bats-support/load'
load 'bats-assert/load'
load 'test_helper'

# This setup function runs before each test.
setup() {
    # Create a temporary directory for our test repository.
    BATS_TMPDIR="$(create_temp_dir)"
    
    # Set up our mock 'gh' command to be found first in the PATH.
    # This intercepts any calls that stgit makes to 'gh'.
    export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
    
    # Initialize a clean git repository for the test.
    setup_git_repo
}

# This teardown function runs after each test.
teardown() {
    # Clean up the temporary directory.
    rm -rf "$BATS_TMPDIR"
}

@test "create: creates a new child branch" {
    run stgit create feature-a
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-a'"
    
    # Verify the branch was actually created and is the current branch
    run git rev-parse --abbrev-ref HEAD
    assert_output "feature-a"
    
    # Verify the parent was set correctly in the git config
    run git config branch.feature-a.parent
    assert_output "main"
}

@test "create: creates a nested child branch" {
    run stgit create feature-a
    assert_success
    
    run stgit create feature-b
    assert_success
    assert_output --partial "Created and checked out new branch 'feature-b'"
    
    # Verify the parent of the nested branch
    run git config branch.feature-b.parent
    assert_output "feature-a"
}

@test "next: fails when run on the base branch" {
    run stgit next
    assert_failure
    assert_output --partial "command cannot be run from the base branch"
}

@test "status: fails when run on the base branch and lists stacks" {
    # Setup a stack to be found
    stgit create feature-a
    stgit create feature-b
    git checkout main

    run stgit next
    assert_failure
    assert_output --partial "Found 1 stack(s)"
    assert_output --partial "- feature-a"
}
