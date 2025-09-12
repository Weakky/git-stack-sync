#!/bin/bash
# stgit - A simple CLI for managing stacked Git branches.
# Inspired by Graphite's workflow and the --update-refs feature.

set -e

# --- Configuration ---
# The base branch against which stacks are created and PRs are targeted.
# You can change this to 'main', 'master', or your project's default branch.
BASE_BRANCH="main"

# --- GitHub Configuration ---
# IMPORTANT: You must change these to your own GitHub username/org and repo name.
GH_USER="weakky"
GH_REPO="stack-branch-test"

# --- Dependency Checks ---
if ! command -v gh &> /dev/null; then
    echo "Error: The GitHub CLI ('gh') is not installed."
    echo "Please install it to use GitHub integration features: https://cli.github.com/"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed."
    echo "Please install it to parse API responses: https://stedolan.github.io/jq/"
    exit 1
fi

# --- Internal Functions ---

# Helper function to check for GitHub CLI authentication.
check_gh_auth() {
    if ! gh auth status &>/dev/null; then
        echo "Error: You are not logged into the GitHub CLI." >&2
        echo "Please run 'gh auth login' to authenticate." >&2
        exit 1
    fi
}


# Helper function to get the current branch name.
get_current_branch() {
    git rev-parse --abbrev-ref HEAD
}

# Helper function to get the parent of a given branch in the stack.
get_parent_branch() {
    local branch_name=$1
    git config --get "branch.${branch_name}.parent" || echo ""
}

# Helper function to set the parent of a given branch.
set_parent_branch() {
    local child_branch=$1
    local parent_branch=$2
    git config "branch.${child_branch}.parent" "$parent_branch"
}

# Helper function to get the PR number for a branch.
get_pr_number() {
    local branch_name=$1
    git config --get "branch.${branch_name}.pr-number" || echo ""
}

# Helper function to set the PR number for a branch.
set_pr_number() {
    local branch_name=$1
    local pr_number=$2
    git config "branch.${branch_name}.pr-number" "$pr_number"
}


# Helper to find the "bottom" of the current stack (the branch that stems from BASE_BRANCH).
get_stack_bottom() {
    local current_branch
    current_branch=$(get_current_branch)
    local parent
    parent=$(get_parent_branch "$current_branch")

    # If the current branch has no parent, it might be the bottom.
    if [[ -z "$parent" ]]; then
        echo "$current_branch"
        return
    fi

    while [[ -n "$parent" && "$parent" != "$BASE_BRANCH" ]]; do
        current_branch=$parent
        parent=$(get_parent_branch "$current_branch")
    done

    echo "$current_branch"
}

# Helper to find the "top" of the current stack by traversing child relationships.
get_stack_top() {
    local current_top
    current_top=$(get_current_branch)
    
    # Keep searching upwards for a child until we can't find one.
    while true; do
      found_child=""
      # Iterate through all local branches to find one that has current_top as its parent.
      for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
        local parent
        parent=$(get_parent_branch "$branch")
        if [[ "$parent" == "$current_top" ]]; then
          found_child="$branch"
          break # Found the child, move up
        fi
      done
      
      if [[ -n "$found_child" ]]; then
        current_top="$found_child"
      else
        break # No child found, current_top is the actual top
      fi
    done

    echo "$current_top"
}

# Helper for making authenticated GitHub API calls.
gh_api_call() {
    local method=$1
    local endpoint=$2
    shift 2 # The rest of the arguments are data fields
    local fields=()
    for field in "$@"; do
        fields+=(-f "$field")
    done
    
    # The 'set -e' at the top of the script will cause it to exit on failure.
    gh api "repos/${GH_USER}/${GH_REPO}/${endpoint}" \
        --method "$method" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${fields[@]}"
}


# --- CLI Commands ---

# Command: stgit create <branch-name>
cmd_create() {
    if [[ -z "$1" ]]; then
        echo "Error: Branch name is required."
        echo "Usage: stgit create <branch-name>"
        exit 1
    fi

    local parent_branch
    parent_branch=$(get_current_branch)
    local new_branch=$1

    git checkout -b "$new_branch"
    set_parent_branch "$new_branch" "$parent_branch"
    echo "Created and checked out new branch '$new_branch' based on '$parent_branch'."
    echo "Parent relationship stored in git config."
}

# Command: stgit insert <branch-name>
cmd_insert() {
    check_gh_auth
    if [[ -z "$1" ]]; then
        echo "Error: Branch name is required."
        echo "Usage: stgit insert <branch-name>"
        exit 1
    fi

    local new_branch=$1
    local parent_branch
    parent_branch=$(get_current_branch)

    # Find the branch that is currently the child of our position.
    local original_child=""
    for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
        local parent
        parent=$(get_parent_branch "$branch")
        if [[ "$parent" == "$parent_branch" ]]; then
            original_child="$branch"
            break
        fi
    done

    # Create the new branch and set its parent.
    git checkout -b "$new_branch"
    set_parent_branch "$new_branch" "$parent_branch"
    echo "Created branch '$new_branch' on top of '$parent_branch'."

    # If there was a child, rebase it and update its PR.
    if [[ -n "$original_child" ]]; then
        echo "Found subsequent branch '$original_child'. Rebasing it onto '$new_branch'..."
        
        git checkout "$original_child" >/dev/null 2>&1
        local top_of_substack
        top_of_substack=$(get_stack_top)
        echo "Rebasing stack from '$original_child' to '$top_of_substack'..."
        
        git checkout "$top_of_substack" >/dev/null 2>&1
        git rebase "$new_branch" --update-refs
        
        set_parent_branch "$original_child" "$new_branch"
        echo "Updated parent of '$original_child' to be '$new_branch'."
        
        # --- GitHub Integration ---
        local pr_number_to_update
        pr_number_to_update=$(get_pr_number "$original_child")
        if [[ -n "$pr_number_to_update" ]]; then
            echo "Updating base of PR #${pr_number_to_update} for '$original_child' to '$new_branch'..."
            gh_api_call "PATCH" "pulls/${pr_number_to_update}" "base=$new_branch"
            echo "GitHub PR #${pr_number_to_update} updated."
        fi
        
        git checkout "$new_branch" >/dev/null 2>&1
    fi

    echo "Successfully inserted '$new_branch' into the stack."
}

# Command: stgit submit
cmd_submit() {
    check_gh_auth
    echo "Syncing stack with GitHub..."
    local bottom_branch
    bottom_branch=$(get_stack_bottom)
    
    local stack_branches=()
    local current_branch
    current_branch=$(get_stack_top)

    # Collect all branches in the stack
    while [[ -n "$current_branch" && "$current_branch" != "$BASE_BRANCH" ]]; do
        stack_branches=("${stack_branches[@]}" "$current_branch")
        current_branch=$(get_parent_branch "$current_branch")
    done
    
    # Iterate from bottom to top to create PRs in order
    for (( i=${#stack_branches[@]}-1 ; i>=0 ; i-- )) ; do
        local branch_name="${stack_branches[i]}"
        local pr_number
        pr_number=$(get_pr_number "$branch_name")

        if [[ -n "$pr_number" ]]; then
            echo "PR #${pr_number} already exists for branch '$branch_name'."
            continue
        fi

        local parent
        parent=$(get_parent_branch "$branch_name")
        if [[ -z "$parent" ]]; then
          parent="$BASE_BRANCH"
        fi
        
        echo "Creating PR for '$branch_name' to be merged into '$parent'..."
        # First, ensure the branch exists on the remote
        git push origin "$branch_name" --force-with-lease >/dev/null 2>&1

        local pr_title
        pr_title=$(git log -1 --pretty=%s "$branch_name")
        
        local pr_response
        pr_response=$(gh_api_call "POST" "pulls" "title=$pr_title" "head=$branch_name" "base=$parent")
        
        local new_pr_number
        new_pr_number=$(echo "$pr_response" | jq -r '.number')
        
        if [[ -n "$new_pr_number" && "$new_pr_number" != "null" ]]; then
            set_pr_number "$branch_name" "$new_pr_number"
            echo "Successfully created PR #${new_pr_number} for '$branch_name'."
        else
            echo "Failed to create PR for '$branch_name'."
            echo "Response: $pr_response"
        fi
    done

    echo "Stack submission complete."
}


# Command: stgit next
cmd_next() {
    local current_branch
    current_branch=$(get_current_branch)
    
    for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
      local parent
      parent=$(get_parent_branch "$branch")
      if [[ "$parent" == "$current_branch" ]]; then
        git checkout "$branch"
        echo "Checked out child branch: $branch"
        return
      fi
    done

    echo "No child branch found for '$current_branch'. You might be at the top of the stack."
}

# Command: stgit prev
cmd_prev() {
    local current_branch
    current_branch=$(get_current_branch)
    local parent
    parent=$(get_parent_branch "$current_branch")

    if [[ -n "$parent" ]]; then
        git checkout "$parent"
        echo "Checked out parent branch: $parent"
    else
        echo "No parent branch found for '$current_branch'. You might be at the bottom of the stack."
    fi
}

# Command: stgit rebase
cmd_rebase() {
    local original_branch
    original_branch=$(get_current_branch)
    echo "Current branch is '$original_branch'."
    
    local top_branch
    top_branch=$(get_stack_top)
    local bottom_branch
    bottom_branch=$(get_stack_bottom)
    
    if [[ "$top_branch" == "$bottom_branch" && -z "$(get_parent_branch "$top_branch")" ]]; then
        echo "Error: '$original_branch' is not part of a known stack."
        echo "Rebasing onto '$BASE_BRANCH' directly."
        git rebase "origin/$BASE_BRANCH"
        return
    fi
    
    echo "Detected stack from '$bottom_branch' to '$top_branch'."
    echo "Rebasing the entire stack onto the latest '$BASE_BRANCH'..."

    git fetch origin "$BASE_BRANCH"

    echo "Temporarily checking out '$top_branch' to perform rebase..."
    git checkout "$top_branch"

    git rebase "origin/$BASE_BRANCH" --update-refs

    echo "Stack rebased successfully!"
    
    echo "Returning to original branch '$original_branch'."
    git checkout "$original_branch"
    
    echo "Local branches have been updated. Run 'stgit push' to push them to the remote."
}

# Command: stgit restack
cmd_restack() {
    local original_branch
    original_branch=$(get_current_branch)
    echo "Current branch is '$original_branch'."

    local top_branch
    top_branch=$(get_stack_top)

    if [[ "$original_branch" == "$top_branch" ]]; then
        echo "You are at the top of the stack. Nothing to restack."
        return
    fi
    
    echo "Restacking branches above '$original_branch'..."
    
    # Temporarily check out the top branch to perform the rebase from there
    echo "Temporarily checking out '$top_branch'..."
    git checkout "$top_branch" >/dev/null 2>&1

    # Rebase the top of the stack onto the current branch.
    # --update-refs will handle all intermediate branches.
    git rebase "$original_branch" --update-refs

    echo "Stack successfully restacked on top of '$original_branch'."

    echo "Returning to original branch '$original_branch'."
    git checkout "$original_branch" >/dev/null 2>&1
    
    echo "Local branches have been updated. Run 'stgit push' to push them to the remote."
}

# Command: stgit push
cmd_push() {
    echo "Collecting all branches in the stack..."
    local top_branch
    top_branch=$(get_stack_top)
    
    local branches_to_push=()
    local current_branch="$top_branch"

    while [[ -n "$current_branch" && "$current_branch" != "$BASE_BRANCH" ]]; do
        branches_to_push+=("$current_branch")
        current_branch=$(get_parent_branch "$current_branch")
    done
    
    if [ ${#branches_to_push[@]} -eq 0 ]; then
        echo "No stack branches found to push."
        exit 1
    fi

    echo "Will force-push the following branches:"
    for branch in "${branches_to_push[@]}"; do
        echo "  - $branch"
    done
    
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Push cancelled."
        exit 1
    fi

    echo "Pushing with --force-with-lease..."
    git push origin "${branches_to_push[@]}" --force-with-lease
}

# Command: stgit pr
cmd_pr() {
    check_gh_auth
    local current_branch
    current_branch=$(get_current_branch)
    local pr_number
    pr_number=$(get_pr_number "$current_branch")

    if [[ -n "$pr_number" ]]; then
        echo "Opening PR #${pr_number} for branch '$current_branch' in browser..."
        gh pr view "$pr_number" --web
    else
        echo "No pull request found for branch '$current_branch'."
        echo "You can create one by running 'stgit submit'."
    fi
}


# Command: stgit help
cmd_help() {
    echo "stgit - A tool for managing stacked Git branches with GitHub integration."
    echo ""
    echo "Usage: stgit <command> [options]"
    echo ""
    echo "Commands:"
    echo "  create <branch-name>   Create a new branch on top of the current one."
    echo "  insert <branch-name>   Create and insert a new branch, updating GitHub PRs."
    echo "  submit                 Create GitHub PRs for all branches in the stack."
    echo "  next                   Navigate to the child branch in the stack."
    echo "  prev                   Navigate to the parent branch in the stack."
    echo "  rebase                 Rebase the entire stack on the latest base branch ($BASE_BRANCH)."
    echo "  restack                Update branches above the current one after making changes."
    echo "  push                   Force-push all branches in the current stack to the remote."
    echo "  pr                     Open the GitHub PR for the current branch in your browser."
    echo "  help                   Show this help message."
    echo ""
}

# --- Main Dispatcher ---
main() {
    local cmd=$1
    shift || true

    case "$cmd" in
        create)
            cmd_create "$@"
            ;;
        insert)
            cmd_insert "$@"
            ;;
        submit)
            cmd_submit "$@"
            ;;
        next)
            cmd_next "$@"
            ;;
        prev)
            cmd_prev "$@"
            ;;
        rebase)
            cmd_rebase "$@"
            ;;
        restack)
            cmd_restack "$@"
            ;;
        push)
            cmd_push "$@"
            ;;
        pr)
            cmd_pr "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        "")
            cmd_help
            ;;
        *)
            echo "Unknown command: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"

