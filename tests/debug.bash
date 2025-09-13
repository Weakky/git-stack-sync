#!/usr/bin/env bash

# Function to print a standardized debug header.
_debug_header() {
    echo >&2 # Add a newline to stderr for spacing
    echo "--- DEBUG: $1 ---" >&2
}

# Dumps current git status, branch info, and stgit config.
# This is extremely useful for seeing the state of the repo before/after a command.
# All output goes to stderr so it doesn't interfere with `assert_output`.
stgit_debug_dump() {
    local message=$1
    _debug_header "$message"
    echo "Current Branch: $(git rev-parse --abbrev-ref HEAD)" >&2
    echo "Git Status:" >&2
    git status --porcelain >&2
    echo "All Branches:" >&2
    git branch -vv >&2
    echo "Stgit Parent Config:" >&2
    git config --get-regexp 'branch\..*\.parent' >&2 || echo "  No parent config found." >&2
    echo "Stgit PR Config:" >&2
    git config --get-regexp 'branch\..*\.pr-number' >&2 || echo "  No PR number config found." >&2
    echo "--- END DEBUG ---" >&2
    echo >&2
}
