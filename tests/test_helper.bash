#!/usr/bin/env bash

# Creates a temporary directory for tests.
create_temp_dir() {
    mktemp -d
}

# Sets up a clean Git repository in a unique subdirectory for each test.
setup_git_repo() {
    # Use BATS_TEST_TMPDIR, a unique directory created by Bats for each test.
    # This guarantees perfect isolation and is automatically cleaned up.
    local test_dir="$BATS_TEST_TMPDIR"
    
    # 1. Initialize a standard local repository first.
    git init -b main "$test_dir/local" >/dev/null 2>&1
    
    # 2. Navigate into the local repository.
    cd "$test_dir/local"

    # 3. Configure the repository for testing.
    git config user.email "test@example.com"
    git config user.name "Test User"
    git config --local credential.helper "" # Disable credential helpers

    # 4. Create the first commit so HEAD is valid *before* any other operations.
    create_commit "Initial commit"

    # 5. Now that a commit exists, set up the remote.
    git init --bare "$test_dir/remote.git" >/dev/null 2>&1
    git remote add origin "$test_dir/remote.git" >/dev/null 2>&1
    git push -u origin main >/dev/null 2>&1
}

# Creates a new commit with a given message.
# Can optionally take a content and filename argument.
create_commit() {
    local message=$1
    local content=${2:-$message}
    local filename=${3:-$(echo "$message" | tr -s ' ' '_').txt}
    
    echo "$content" > "$filename"
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

# Mocks a failure response for a PR creation call.
mock_pr_create_failure() {
    local mock_state_dir="/tmp/stgit_mock_gh_state"
    mkdir -p "$mock_state_dir"
    # A simple flag file is enough to trigger the failure mode in the mock.
    touch "$mock_state_dir/pr_create_fail"
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
        run git checkout "$parent"
        run "$STGIT_CMD" create "$branch_name"
        run create_commit "Commit for $branch_name"
        parent="$branch_name"
    done
    # Checkout the last branch created
    run git checkout "$parent"
}

# Returns a sorted list of all local branches and their current commit SHAs.
# This provides a reliable "snapshot" of the repository state.
get_all_branch_shas() {
    git for-each-ref --format='%(refname:short) %(objectname)' refs/heads | sort
}

# --- Custom State Assertions ---

# Asserts that a branch's parent is set to a specific branch in stgit config.
assert_branch_parent() {
    local child_branch=$1
    local expected_parent=$2
    run git config --get "branch.${child_branch}.parent"
    assert_success
    assert_output "$expected_parent"
}

# Asserts that a branch's PR number is set in the stgit config.
assert_branch_pr_number() {
    local branch_name=$1
    local expected_pr_number=$2
    run git config --get "branch.${branch_name}.pr-number"
    assert_success
    assert_output "$expected_pr_number"
}

# Asserts that a branch does NOT have a PR number set.
assert_branch_has_no_pr_number() {
    local branch_name=$1
    run git config --get "branch.${branch_name}.pr-number"
    assert_failure
}

# Asserts that a local branch exists.
# Usage: assert_branch_exists <branch_name>
assert_branch_exists() {
    local branch=$1
    run git rev-parse --verify "$branch"
    assert_success "Expected branch '$branch' to exist, but it does not."
}

# Asserts that a local branch does not exist.
# Usage: assert_branch_does_not_exist <branch_name>
assert_branch_does_not_exist() {
    local branch=$1
    run git rev-parse --verify "$branch"
    assert_failure "Expected branch '$branch' to not exist, but it does."
}

# Asserts that one commit is an ancestor of another. Useful for verifying rebases.
# Usage: assert_commit_is_ancestor <ancestor_commitish> <descendant_commitish>
assert_commit_is_ancestor() {
    local ancestor=$1
    local descendant=$2
    # `git merge-base --is-ancestor` exits with 0 if true, 1 if false.
    run git merge-base --is-ancestor "$ancestor" "$descendant"
    assert_success "Expected commit '$ancestor' to be an ancestor of '$descendant'."
}

# Asserts that the content of an old commit (pre-rebase) is still present
# in the history of a branch by checking for its commit message. This is
# useful because the commit SHA will change after a rebase.
# Usage: assert_commit_is_reachable <old_commit_sha> <branch_name>
assert_commit_is_reachable() {
    local commit_sha=$1
    local branch_name=$2
    # `git branch --contains` will list the branch if the commit is in its history.
    run git branch --contains "$commit_sha"
    assert_output --partial "$branch_name"
}

# Asserts that a local branch and its remote counterpart point to the same commit.
# Usage: assert_remote_branch_matches_local <branch_name>
assert_remote_branch_matches_local() {
    local branch=$1
    # Fetch the latest updates from the remote without merging
    run git fetch origin
    
    local remote_sha
    remote_sha=$(git rev-parse "origin/$branch")
    assert_success "Expected remote branch 'origin/$branch' to exist."

    local local_sha
    local_sha=$(git rev-parse "$branch")
    assert_success "Expected local branch '$branch' to exist."

    assert_equal "$local_sha" "$remote_sha" "Expected local branch '$branch' to match 'origin/$branch'."
}
