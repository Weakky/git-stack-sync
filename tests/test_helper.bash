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

