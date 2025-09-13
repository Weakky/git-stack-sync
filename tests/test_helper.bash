#!/usr/bin/env bash

# Creates a temporary directory for tests.
create_temp_dir() {
    mktemp -d
}

# Sets up a clean Git repository in a unique subdirectory for each test.
setup_git_repo() {
    # Use BATS_TEST_TMPDIR, a unique directory created by Bats for each test.
    # This guarantees perfect isolation and is automatically cleaned up.
    cd "$BATS_TEST_TMPDIR"

    # Initialize the local repository
    git init -b main >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    git config --local credential.helper "" # Disable credential helpers

    # Create the first commit so HEAD is valid.
    create_commit "Initial commit"

    # Set up the bare remote repository in the same test-specific temp dir
    git init --bare remote.git >/dev/null 2>&1
    
    # Link the local and remote and push the initial state
    git remote add origin remote.git >/dev/null 2>&1
    git push -u origin main >/dev/null 2>&1
}

# Creates a new commit with a given message.
create_commit() {
    local message=$1
    # Use the message to create a unique filename to avoid conflicts
    local filename
    filename=$(echo "$message" | tr -s ' ' '_').txt
    echo "$message" > "$filename"
    git add .
    git commit -m "$message" >/dev/null
}

# Sets up a mock PR response for the 'gh' mock.
# Usage: mock_pr_state <pr_number> <state: OPEN|MERGED|CLOSED>
mock_pr_state() {
    local pr_number=$1
    local state=$2
    local mock_state_dir="/tmp/stgit_mock_gh_state"
    mkdir -p "$mock_state_dir"
    echo "$state" > "$mock_state_dir/pr_${pr_number}_state"
}

# Cleans up any state files created by the mock gh CLI.
cleanup_mock_gh_state() {
    rm -rf /tmp/stgit_mock_gh_state
}

# Creates a stack of branches for testing.
# Usage: create_stack branch1 branch2 branch3 ...
create_stack() {
    local parent="main"
    for branch_name in "$@"; do
        git checkout "$parent" >/dev/null
        "$STGIT_CMD" create "$branch_name" >/dev/null
        create_commit "Commit for $branch_name"
        parent="$branch_name"
    done
    # Checkout the last branch created
    git checkout "$parent" >/dev/null
}
