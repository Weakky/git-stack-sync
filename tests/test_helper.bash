#!/usr/bin/env bash

# Creates a temporary directory for tests.
create_temp_dir() {
    mktemp -d
}

# Sets up a clean Git repository in the current directory.
setup_git_repo() {
    cd "$BATS_TMPDIR"
    git init -b main >/dev/null
    git config user.email "test@example.com"
    git config user.name "Test User"
    create_commit "Initial commit"
    
    # Create a fake remote repository to test push/sync
    git init --bare ../remote.git >/dev/null
    git remote add origin ../remote.git >/dev/null
    git push origin main >/dev/null 2>&1
}

# Creates a new commit with a given message.
create_commit() {
    local message=$1
    # Use the message to create a unique filename to avoid conflicts
    local filename
    filename=$(echo "$message" | tr -s ' ' '_')
    echo "$message" > "$filename.txt"
    git add .
    git commit -m "$message" >/dev/null
}
