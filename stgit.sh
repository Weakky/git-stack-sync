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

# Helper function to get the child of a given branch in the stack.
get_child_branch() {
    local parent_branch=$1
    for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
        local parent
        parent=$(get_parent_branch "$branch")
        if [[ "$parent" == "$parent_branch" ]]; then
            echo "$branch"
            return
        fi
    done
    echo "" # No child found
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
      found_child=$(get_child_branch "$current_top")
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

    local original_child
    original_child=$(get_child_branch "$parent_branch")

    # Create the new branch and set its parent.
    git checkout -b "$new_branch"
    set_parent_branch "$new_branch" "$parent_branch"
    echo "Created branch '$new_branch' on top of '$parent_branch'."

    # If there was a child, we need to rebase it and its children onto the new branch.
    if [[ -n "$original_child" ]]; then
        echo "Found subsequent branch '$original_child'. Rebasing it and its descendants onto '$new_branch'..."
        
        # Get the full sub-stack starting from original_child
        local sub_stack=()
        local current_sub_branch="$original_child"
        while [[ -n "$current_sub_branch" ]]; do
            sub_stack+=("$current_sub_branch")
            current_sub_branch=$(get_child_branch "$current_sub_branch")
        done

        # Iteratively rebase the sub-stack
        local new_base="$new_branch"
        for branch in "${sub_stack[@]}"; do
            echo "--- Rebasing '$branch' onto '$new_base' ---"
            git checkout "$branch" >/dev/null 2>&1
            git rebase "$new_base"
            new_base="$branch"
        done

        # Update the parent of the first child
        set_parent_branch "$original_child" "$new_branch"
        echo "Updated parent of '$original_child' to be '$new_branch'."
        
        # Update GitHub PR base
        local pr_number_to_update
        pr_number_to_update=$(get_pr_number "$original_child")
        if [[ -n "$pr_number_to_update" ]]; then
            # We MUST push the new branch to the remote BEFORE we can set it as a PR base.
            echo "Pushing new branch '$new_branch' to remote to enable PR base update..."
            git push origin "$new_branch" >/dev/null 2>&1

            echo "Updating base of PR #${pr_number_to_update} for '$original_child' to '$new_branch'..."
            gh_api_call "PATCH" "pulls/${pr_number_to_update}" "base=$new_branch"
            echo "GitHub PR #${pr_number_to_update} updated."
        fi
        
        # Checkout the new branch at the end for the user
        git checkout "$new_branch" >/dev/null 2>&1
    fi

    echo "Successfully inserted '$new_branch' into the stack."
}

# Command: stgit submit
cmd_submit() {
    check_gh_auth
    echo "Syncing stack with GitHub..."
    
    local stack_branches=()
    local current_branch
    current_branch=$(get_stack_top)

    # Collect all branches in the stack from top to bottom
    while [[ -n "$current_branch" && "$current_branch" != "$BASE_BRANCH" ]]; do
        stack_branches+=("$current_branch")
        current_branch=$(get_parent_branch "$current_branch")
    done
    
    # Iterate from bottom to top (reverse order) to create PRs in order
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

        # Check for new commits before trying to create a PR
        local commit_count
        commit_count=$(git rev-list --count "${parent}".."${branch_name}")
        if [[ "$commit_count" -eq 0 ]]; then
            echo "Skipping PR for '$branch_name': No new commits compared to '$parent'."
            continue
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

    if [[ "$current_branch" == "$BASE_BRANCH" ]]; then
        echo "You are on the base branch ('$BASE_BRANCH'). Cannot go 'next'."
        echo "There could be multiple stacks branching from here. Please check out a specific branch first."
        return
    fi
    
    local child_branch
    child_branch=$(get_child_branch "$current_branch")
    
    if [[ -n "$child_branch" ]]; then
        git checkout "$child_branch"
        echo "Checked out child branch: $child_branch"
    else
        echo "No child branch found for '$current_branch'. You are at the top of the stack."
    fi
}

# Command: stgit prev
cmd_prev() {
    local current_branch
    current_branch=$(get_current_branch)

    if [[ "$current_branch" == "$BASE_BRANCH" ]]; then
        echo "You are on the base branch ('$BASE_BRANCH'). Cannot go 'prev'."
        return
    fi
    
    local parent
    parent=$(get_parent_branch "$current_branch")

    if [[ -n "$parent" ]]; then
        git checkout "$parent"
        echo "Checked out parent branch: $parent"
    else
        echo "No parent branch found for '$current_branch'. You are at the bottom of the stack."
    fi
}

# Command: stgit rebase
cmd_rebase() {
    local original_branch
    original_branch=$(get_current_branch)
    echo "Current branch is '$original_branch'."

    # Get the full stack in order from bottom to top
    local stack_branches=()
    local current_branch
    current_branch=$(get_stack_top)
    while [[ -n "$current_branch" && "$current_branch" != "$BASE_BRANCH" ]]; do
        stack_branches=("$current_branch" "${stack_branches[@]}") # Prepend to get bottom-to-top
        current_branch=$(get_parent_branch "$current_branch")
    done

    if [ ${#stack_branches[@]} -eq 0 ]; then
        echo "Error: Could not determine stack. Rebasing current branch onto '$BASE_BRANCH'."
        git rebase "origin/$BASE_BRANCH"
        return
    fi
    
    echo "Detected stack: ${stack_branches[*]}"
    echo "Rebasing the entire stack onto the latest '$BASE_BRANCH'..."

    git fetch origin "$BASE_BRANCH" --quiet

    local new_base="origin/$BASE_BRANCH"
    for branch in "${stack_branches[@]}"; do
        echo "--- Rebasing '$branch' onto '$new_base' ---"
        git checkout "$branch" >/dev/null 2>&1
        git rebase "$new_base"
        new_base="$branch" # The next branch will be rebased on top of this one
    done

    echo "Stack rebased successfully!"
    
    # Return to original branch if it still exists
    if git rev-parse --verify "$original_branch" >/dev/null 2>&1; then
      echo "Returning to original branch '$original_branch'."
      git checkout "$original_branch" >/dev/null 2>&1
    fi
    
    echo "Local branches have been updated. Run 'stgit push' to push them to the remote."
}

# Command: stgit restack
cmd_restack() {
    local original_branch
    original_branch=$(get_current_branch)
    echo "Current branch is '$original_branch'."

    # Get the branches above the current one, in order from bottom to top.
    local branches_to_restack=()
    local current_child
    current_child=$(get_child_branch "$original_branch")

    while [[ -n "$current_child" ]]; do
        branches_to_restack+=("$current_child")
        current_child=$(get_child_branch "$current_child") # Keep looking up the chain
    done

    if [ ${#branches_to_restack[@]} -eq 0 ]; then
        echo "You are at the top of the stack. Nothing to restack."
        return
    fi
    
    echo "Detected subsequent stack: ${branches_to_restack[*]}"
    echo "Restacking branches above '$original_branch'..."

    local new_base="$original_branch"
    for branch in "${branches_to_restack[@]}"; do
        echo "--- Rebasing '$branch' onto '$new_base' ---"
        git checkout "$branch" >/dev/null 2>&1
        git rebase "$new_base"
        new_base="$branch"
    done

    echo "Stack successfully restacked on top of '$original_branch'."

    echo "Returning to original branch '$original_branch'."
    git checkout "$original_branch" >/dev/null 2>&1
    
    echo "Local branches have been updated. Run 'stgit push' to push them to the remote."
}

# Command: stgit sync
cmd_sync() {
    check_gh_auth
    local original_branch
    original_branch=$(get_current_branch)
    
    echo "Checking stack for merged parent branches..."
    git fetch origin --quiet

    local stack_branches=()
    local current_branch_for_stack_build
    current_branch_for_stack_build=$(get_stack_top)
    while [[ -n "$current_branch_for_stack_build" && "$current_branch_for_stack_build" != "$BASE_BRANCH" ]]; do
        stack_branches=("$current_branch_for_stack_build" "${stack_branches[@]}") # Prepend to get bottom-to-top
        current_branch_for_stack_build=$(get_parent_branch "$current_branch_for_stack_build")
    done

    if [ ${#stack_branches[@]} -eq 0 ]; then
        echo "Could not determine stack. Nothing to sync."
        return
    fi

    local stack_was_modified=false
    local merged_branches_to_delete=()

    for branch in "${stack_branches[@]}"; do
        local parent
        parent=$(get_parent_branch "$branch")

        if [[ -z "$parent" || "$parent" == "$BASE_BRANCH" ]]; then
            continue
        fi

        local pr_number
        pr_number=$(get_pr_number "$parent")
        local is_merged=false

        if [[ -n "$pr_number" ]]; then
            echo "Checking status of PR #${pr_number} for branch '$parent'..."
            local pr_state
            # Query PR state, handle potential errors if PR doesn't exist (e.g., deleted after merge)
            pr_state=$(gh pr view "$pr_number" --json state --jq .state 2>/dev/null || echo "NOT_FOUND")

            if [[ "$pr_state" == "MERGED" ]]; then
                is_merged=true
            fi
        fi
        
        # Fallback for branches without a tracked PR number or if API fails
        if [[ "$is_merged" == false ]]; then
            if git merge-base --is-ancestor "$parent" "origin/$BASE_BRANCH"; then
                echo "Parent branch '$parent' appears merged based on local commit history."
                is_merged=true
            fi
        fi

        if [[ "$is_merged" == true ]]; then
            stack_was_modified=true
            local grandparent
            grandparent=$(get_parent_branch "$parent")
            if [[ -z "$grandparent" ]]; then
                grandparent="$BASE_BRANCH"
            fi
            
            echo "Parent branch '$parent' has been merged."
            echo "Updating parent of '$branch' to '$grandparent'."
            set_parent_branch "$branch" "$grandparent"
            
            # Add to a list to delete later, avoid modifying branch list while iterating
            merged_branches_to_delete+=("$parent")
        fi
    done

    if [ "$stack_was_modified" = true ]; then
        echo "Stack structure updated. Performing a full rebase to apply changes..."

        # Find the new bottom of the stack to start the rebase from a valid branch
        local new_bottom_branch=""
        for branch in "${stack_branches[@]}"; do
            # Check if this branch was NOT one of the merged ones.
            # The spaces around the variables are important for exact matching.
            if [[ ! " ${merged_branches_to_delete[*]} " =~ " ${branch} " ]]; then
                new_bottom_branch="$branch"
                break
            fi
        done

        if [[ -n "$new_bottom_branch" ]]; then
            echo "Starting rebase from the new bottom of the stack: '$new_bottom_branch'."
            git checkout "$new_bottom_branch" >/dev/null 2>&1
            cmd_rebase
        else
            echo "All branches in the stack were merged. Nothing left to rebase."
        fi

        # Clean up the old, merged branches
        # Use sort -u to only ask for each branch once
        local unique_merged_branches
        unique_merged_branches=$(echo "${merged_branches_to_delete[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')
        
        for branch_to_delete in $unique_merged_branches; do
            read -p "Do you want to delete the local merged branch '$branch_to_delete'? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                # Need to make sure we are not on the branch we are deleting
                if [[ "$(get_current_branch)" == "$branch_to_delete" ]]; then
                    # switch to a safe branch before deleting
                    git checkout "$BASE_BRANCH"
                fi
                git branch -D "$branch_to_delete"
                echo "Deleted local branch '$branch_to_delete'."
            fi
        done
        
        # Finally, return to the original branch if it still exists and we're not on it
        if git rev-parse --verify "$original_branch" >/dev/null 2>&1; then
            # The original branch might have been the one we just deleted
            if [[ ! " ${unique_merged_branches[*]} " =~ " ${original_branch} " ]]; then
                 if [[ "$(get_current_branch)" != "$original_branch" ]]; then
                    echo "Returning to original branch '$original_branch'."
                    git checkout "$original_branch"
                 fi
            fi
        fi

    else
        echo "No merged branches found in the stack. Everything is up to date."
        # Even if no parents were merged, it's good practice to sync with the base branch
        echo "Syncing with latest '$BASE_BRANCH' changes..."
        cmd_rebase
    fi

    echo "Sync complete. Run 'stgit push' to push any updated branches to the remote."
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
    echo "  sync                   Sync the stack after a parent branch has been merged."
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
        sync)
            cmd_sync "$@"
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

