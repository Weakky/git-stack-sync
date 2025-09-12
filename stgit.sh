#!/bin/bash
# stgit - A simple CLI for managing stacked Git branches.
# Inspired by Graphite's workflow and the --update-refs feature.

set -e

# --- Configuration ---
# The base branch against which stacks are created and PRs are targeted.
# You can change this to 'main', 'master', or your project's default branch.
BASE_BRANCH="main"

# --- Internal Functions ---

# Helper function to get the current branch name.
get_current_branch() {
    git rev-parse --abbrev-ref HEAD
}

# Helper function to get the parent of a given branch in the stack.
# Stgit stores the parent in the git config.
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

    # If there was a child, rebase it and its descendants.
    if [[ -n "$original_child" ]]; then
        echo "Found subsequent branch '$original_child'. Rebasing it onto '$new_branch'..."
        
        # To find the top of the stack that needs rebasing, we check out the
        # original child and then use get_stack_top.
        git checkout "$original_child" >/dev/null 2>&1
        local top_of_substack
        top_of_substack=$(get_stack_top)
        echo "Rebasing stack from '$original_child' to '$top_of_substack'..."
        
        # Checkout the top of that substack and rebase it all onto our new branch.
        git checkout "$top_of_substack" >/dev/null 2>&1
        git rebase "$new_branch" --update-refs
        
        # Crucially, update the parent pointer of the original child.
        set_parent_branch "$original_child" "$new_branch"
        echo "Updated parent of '$original_child' to be '$new_branch'."
        
        # Go back to the new branch to leave the user in a good state.
        git checkout "$new_branch" >/dev/null 2>&1
    fi

    echo "Successfully inserted '$new_branch' into the stack."
}

# Command: stgit submit
# In a real tool, this would create a PR on GitHub/GitLab.
# Here, we'll just show what PRs would be created.
cmd_submit() {
    echo "Submitting stack for review..."
    local current_branch
    current_branch=$(get_current_branch)
    local parent
    parent=$(get_parent_branch "$current_branch")
    local pr_stack=()

    while [[ -n "$parent" ]]; do
        pr_stack=("${pr_stack[@]}" "PR for '$current_branch' to be merged into '$parent'")
        current_branch=$parent
        parent=$(get_parent_branch "$current_branch")
    done
     pr_stack=("${pr_stack[@]}" "PR for '$current_branch' to be merged into '$BASE_BRANCH'")

    # Print in reverse order
    for (( i=${#pr_stack[@]}-1 ; i>=0 ; i-- )) ; do
        echo "  - ${pr_stack[i]}"
    done

    echo "Stack submitted."
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

    # Fetch latest changes from the base branch
    git fetch origin "$BASE_BRANCH"

    # Checkout the top of the stack to run the rebase
    echo "Temporarily checking out '$top_branch' to perform rebase..."
    git checkout "$top_branch"

    # Use the --update-refs magic! This rebases the top branch and all its
    # ancestors until the common base, updating all intermediate branch refs.
    git rebase "origin/$BASE_BRANCH" --update-refs

    echo "Stack rebased successfully!"
    echo "The following branches were updated:"
    # A simple way to show the stack is to list branches with the same prefix.
    # A more robust method would traverse the parent chain again.
    git branch --list "$(dirname "$top_branch")/*"
    
    echo "Returning to original branch '$original_branch'."
    git checkout "$original_branch"
    
    echo "You may need to force-push the updated branches."
}


# Command: stgit help
cmd_help() {
    echo "stgit - A tool for managing stacked Git branches."
    echo ""
    echo "Usage: stgit <command> [options]"
    echo ""
    echo "Commands:"
    echo "  create <branch-name>   Create a new branch on top of the current one."
    echo "  insert <branch-name>   Create and insert a new branch at the current position."
    echo "  submit                 Simulate submitting the current stack of branches as PRs."
    echo "  next                   Navigate to the child branch in the stack."
    echo "  prev                   Navigate to the parent branch in the stack."
    echo "  rebase                 Rebase the entire stack on the latest base branch ($BASE_BRANCH)."
    echo "                         Works from any branch within the stack."
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

