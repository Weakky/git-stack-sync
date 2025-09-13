#!/bin/bash
# stgit - A simple CLI for managing stacked Git branches.
# Inspired by Graphite's workflow and the --update-refs feature.

set -e

# --- Internal State ---
STATE_FILE=".git/STGIT_OPERATION_STATE"
CONFIG_CACHE_FILE=".git/STGIT_CONFIG_CACHE"
AUTO_CONFIRM=false # Global flag for --yes

# --- Logging Helpers ---
log_success() {
    echo "🟢 $1"
}

log_error() {
    echo "🔴 Error: $1" >&2
}

log_warning() {
    echo "🟡 Warning: $1"
}

log_info() {
    echo "   $1"
}

log_step() {
    echo "➡️  $1"
}

log_suggestion() {
    echo "💡 Next step: $1"
}

log_prompt() {
    echo "❔ $1"
}

# --- Dependency Checks ---
if ! command -v gh &> /dev/null; then
    log_error "The GitHub CLI ('gh') is not installed."
    log_info "Please install it to use GitHub integration features: https://cli.github.com/"
    exit 1
fi
if ! command -v jq &> /dev/null; then
    log_error "'jq' is not installed."
    log_info "Please install it to parse API responses: https://stedolan.github.io/jq/"
    exit 1
fi

# --- Auto-Configuration ---
# These variables are now determined automatically and cached.
BASE_BRANCH=""
GH_USER=""
GH_REPO=""

_initialize_config() {
    # Try to load from cache first.
    if [[ -f "$CONFIG_CACHE_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_CACHE_FILE"
        if [[ -n "$BASE_BRANCH" && -n "$GH_USER" && -n "$GH_REPO" ]]; then
            return 0 # Successfully loaded from cache
        fi
    fi
    
    log_step "Initializing configuration (first run or cache is invalid)..."
    local repo_info
    # Attempt to get repo info from the GitHub CLI.
    # The '2>/dev/null' suppresses gh's errors so we can provide our own.
    if ! repo_info=$(gh repo view --json owner,name,defaultBranchRef --jq '{owner: .owner.login, name: .name, base: .defaultBranchRef.name}' 2>/dev/null); then
        log_error "Could not determine GitHub repository context."
        log_info "Please ensure you are inside a Git repository with a remote named 'origin' pointing to GitHub, and that you have run 'gh auth login'."
        exit 1
    fi

    # Use JQ to parse the JSON and export variables
    GH_USER=$(echo "$repo_info" | jq -r '.owner')
    GH_REPO=$(echo "$repo_info" | jq -r '.name')
    BASE_BRANCH=$(echo "$repo_info" | jq -r '.base')

    # Validate that all variables were parsed correctly.
    if [[ -z "$GH_USER" || "$GH_USER" == "null" || -z "$GH_REPO" || "$GH_REPO" == "null" || -z "$BASE_BRANCH" || "$BASE_BRANCH" == "null" ]]; then
        log_error "Failed to parse repository details from GitHub."
        log_info "Please check your 'gh' CLI authentication and repository configuration."
        exit 1
    fi

    # Write to cache file for next time
    echo "BASE_BRANCH='$BASE_BRANCH'" > "$CONFIG_CACHE_FILE"
    echo "GH_USER='$GH_USER'" >> "$CONFIG_CACHE_FILE"
    echo "GH_REPO='$GH_REPO'" >> "$CONFIG_CACHE_FILE"
    log_success "Configuration cached for future runs."
}


# --- Internal Functions ---

# Helper function to check for GitHub CLI authentication.
check_gh_auth() {
    if ! gh auth status &>/dev/null; then
        log_error "You are not logged into the GitHub CLI."
        log_suggestion "Run 'gh auth login' to authenticate."
        exit 1
    fi
}


# Helper function to get the current branch name.
get_current_branch() {
    git rev-parse --abbrev-ref HEAD
}

# Helper function to get the parent of a given branch in the stack.
# It now ONLY reads from the git config.
get_parent_branch() {
    local branch_name=$1
    git config --get "branch.${branch_name}.parent" || echo ""
}

# Helper function to get the child of a given branch in the stack.
get_child_branch() {
    local parent_branch=$1
    for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
        # Skip the parent branch itself to avoid self-parenting issues in weird repo states
        if [[ "$branch" == "$parent_branch" ]]; then
            continue
        fi
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

# Helper function to unset the parent of a given branch.
unset_parent_branch() {
    local child_branch=$1
    git config --unset "branch.${child_branch}.parent" || true
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

# Helper to find all stack bottom branches.
get_all_stack_bottoms() {
    local bottoms=()
    for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
        # Exclude the base branch itself
        if [[ "$branch" == "$BASE_BRANCH" ]]; then
            continue
        fi

        local parent
        parent=$(get_parent_branch "$branch")
        # A branch is the bottom of a STACK if its parent is the base branch.
        if [[ "$parent" == "$BASE_BRANCH" ]]; then
            bottoms+=("$branch")
        fi
    done
    echo "${bottoms[@]}"
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

# Internal function to perform the core rebase loop and handle conflicts.
# This function is now responsible for saving the state of the operation.
_perform_iterative_rebase() {
    # State parameters
    local command=$1
    local original_branch=$2
    local merged_branches_to_delete=$3
    
    # Rebase parameters
    local new_base=$4
    shift 4
    local branches_to_rebase=("$@")

    # Save the state BEFORE starting the potentially failing operation.
    echo "COMMAND='$command'" > "$STATE_FILE"
    echo "ORIGINAL_BRANCH='$original_branch'" >> "$STATE_FILE"
    if [[ -n "$merged_branches_to_delete" ]]; then
        echo "MERGED_BRANCHES_TO_DELETE='$merged_branches_to_delete'" >> "$STATE_FILE"
    fi

    for branch in "${branches_to_rebase[@]}"; do
        log_step "Rebasing '$branch' onto '$new_base'..."
        git checkout "$branch" >/dev/null 2>&1
        if ! git rebase "$new_base"; then
            echo ""
            log_error "Rebase conflict detected while rebasing '$branch'."
            log_info "Please follow these steps to resolve:"
            log_info "1. Open the conflicting files and resolve the issues."
            log_info "2. Run 'git add <resolved-files>'."
            log_info "3. Run 'git rebase --continue'."
            log_info "4. Once the git rebase process is fully complete, run 'stgit continue'."
            exit 1
        fi
        
        # Check if the rebase resulted in an empty branch and warn the user.
        local commit_count
        commit_count=$(git rev-list --count "${new_base}".."${branch}")
        if [[ "$commit_count" -eq 0 ]]; then
            local pr_number_to_check
            pr_number_to_check=$(get_pr_number "$branch")
            log_warning "After rebasing, branch '$branch' has no new changes compared to '$new_base'."
            if [[ -n "$pr_number_to_check" ]]; then
                log_info "This can happen if changes from this branch were also introduced into its parent."
                log_info "Pushing this update may cause GitHub to automatically close PR #${pr_number_to_check}."
            fi
        fi

        new_base="$branch"
    done
}

# Internal helper to handle the complex logic of reparenting, rebasing a sub-stack, and updating PRs.
_rebase_sub_stack_and_update_pr() {
    local new_parent_branch=$1
    local child_branch_to_reparent=$2

    if [[ -z "$child_branch_to_reparent" ]]; then
        return 0 # Nothing to do
    fi

    log_step "Rebasing descendant branches onto '$new_parent_branch'..."
    
    local sub_stack=()
    local current_sub_branch="$child_branch_to_reparent"
    while [[ -n "$current_sub_branch" ]]; do
        sub_stack+=("$current_sub_branch")
        current_sub_branch=$(get_child_branch "$current_sub_branch")
    done

    local new_rebase_base="$new_parent_branch"
    for branch_to_rebase in "${sub_stack[@]}"; do
        log_info "Rebasing '$branch_to_rebase'..."
        git checkout "$branch_to_rebase" >/dev/null 2>&1
        git rebase "$new_rebase_base" >/dev/null 2>&1
        new_rebase_base="$branch_to_rebase"
    done
    log_success "Sub-stack successfully rebased."

    set_parent_branch "$child_branch_to_reparent" "$new_parent_branch"
    log_success "Updated parent of '$child_branch_to_reparent' to be '$new_parent_branch'."
    
    local pr_to_update
    pr_to_update=$(get_pr_number "$child_branch_to_reparent")
    if [[ -n "$pr_to_update" ]]; then
        log_step "Updating GitHub PR for '$child_branch_to_reparent'..."
        log_info "Pushing new branch '$new_parent_branch' to remote..."
        git push origin "$new_parent_branch" >/dev/null 2>&1

        log_info "Setting base of PR #${pr_to_update} to '$new_parent_branch'..."
        gh_api_call "PATCH" "pulls/${pr_to_update}" "base=$new_parent_branch" >/dev/null
        log_success "GitHub PR #${pr_to_update} updated."
    fi
}


# Internal function to finalize an operation, called by successful commands AND by 'continue'.
_finish_operation() {
    if [ ! -f "$STATE_FILE" ]; then
        return
    fi
    
    # shellcheck source=/dev/null
    source "$STATE_FILE"

    log_step "Finishing operation..."

    if [[ "${COMMAND}" == "sync" && -n "${MERGED_BRANCHES_TO_DELETE}" ]]; then
        for branch_to_delete in ${MERGED_BRANCHES_TO_DELETE}; do
            local confirmed=false
            if [[ "$AUTO_CONFIRM" == true ]]; then
                confirmed=true
            # The prompt is now part of `read -p` and goes to stderr.
            elif read -r -n 1 -p "❔ Do you want to delete the local merged branch '$branch_to_delete'? (y/N) " REPLY && [[ "$REPLY" =~ ^[Yy]$ ]]; then
                confirmed=true
                echo # Add a newline after the user input for cleaner output
            else
                # Also echo a newline if the user enters 'n' or anything else
                echo
            fi

            if [[ "$confirmed" == true ]]; then
                if [[ "$(get_current_branch)" == "$branch_to_delete" ]]; then
                    git checkout "$BASE_BRANCH" >/dev/null 2>&1
                fi
                git branch -D "$branch_to_delete" >/dev/null 2>&1
                log_success "Deleted local branch '$branch_to_delete'."
            fi
        done
    fi

    if git rev-parse --verify "$ORIGINAL_BRANCH" >/dev/null 2>&1; then
        if [[ "$(get_current_branch)" != "$ORIGINAL_BRANCH" ]]; then
            log_info "Returning to original branch '$ORIGINAL_BRANCH'."
            git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1
        fi
    else
      log_warning "Original branch '$ORIGINAL_BRANCH' no longer exists. Returning to '$BASE_BRANCH'."
      git checkout "$BASE_BRANCH" >/dev/null 2>&1
    fi

    rm -f "$STATE_FILE"
    log_success "Operation complete."
    log_suggestion "Run 'stgit push' to update your remote branches."
}

# (New) A centralized guard for commands that require a tracked branch.
_guard_context() {
    local command_name=$1
    local current_branch
    current_branch=$(get_current_branch)

    if [[ "$current_branch" == "$BASE_BRANCH" ]]; then
        log_error "The '$command_name' command cannot be run from the base branch ('$BASE_BRANCH')."
        cmd_list # Call the list command to provide context
        exit 1
    fi

    local parent
    parent=$(git config --get "branch.${current_branch}.parent" || echo "")
    if [[ -z "$parent" ]]; then
        log_error "The '$command_name' command requires a tracked branch."
        log_info "Branch '$current_branch' is not currently tracked by stgit."
        log_suggestion "To start a new stack, run 'stgit create <branch-name>'."
        log_suggestion "To track an existing branch, run 'stgit track set <parent-branch>'."
        exit 1
    fi
}


# --- CLI Commands ---

_cmd_track_set() {
    local current_branch
    current_branch=$(get_current_branch)
    if [[ "$current_branch" == "$BASE_BRANCH" ]]; then
        log_error "Cannot track the base branch ('$BASE_BRANCH')."
        exit 1
    fi

    local parent_branch=$1
    if [[ -z "$parent_branch" ]]; then
        parent_branch="$BASE_BRANCH"
    fi

    if ! git rev-parse --verify "$parent_branch" >/dev/null 2>&1; then
        log_error "Parent branch '$parent_branch' does not exist."
        exit 1
    fi

    # Safeguard: ensure the parent is actually an ancestor of the current branch.
    if ! git merge-base --is-ancestor "$parent_branch" "$current_branch"; then
        log_error "Invalid parent: '$parent_branch' is not an ancestor of '$current_branch'."
        log_info "A branch's parent must be a commit in its history."
        exit 1
    fi

    set_parent_branch "$current_branch" "$parent_branch"
    log_success "Set parent of '$current_branch' to '$parent_branch'."

    # Check for an existing PR for this branch.
    log_info "Checking for existing pull request for '$current_branch'..."
    local pr_number
    pr_number=$(gh pr list --head "$current_branch" --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null)

    if [[ -n "$pr_number" ]]; then
        set_pr_number "$current_branch" "$pr_number"
        log_success "Found and tracked existing PR #${pr_number}."
    else
        log_info " -> No open PR found for '$current_branch'."
    fi
}

_cmd_track_remove() {
    _guard_context "track remove"
    local current_branch
    current_branch=$(get_current_branch)

    local parent
    parent=$(get_parent_branch "$current_branch")
    
    # Safeguard: only allow removal if the branch has no unique commits.
    local commit_count
    commit_count=$(git rev-list --count "${parent}".."${current_branch}")
    if [[ "$commit_count" -gt 0 ]]; then
        log_error "Cannot untrack '$current_branch' because it contains unique commits."
        log_suggestion "To integrate these changes, consider running 'stgit squash'."
        exit 1
    fi
    
    local child
    child=$(get_child_branch "$current_branch")

    unset_parent_branch "$current_branch"
    log_success "Stopped tracking '$current_branch'. It is no longer part of a stack."

    # If the removed branch was in the middle of a stack, repair the metadata chain.
    if [[ -n "$child" ]]; then
        log_info "Repairing stack: setting parent of '$child' to '$parent'."
        set_parent_branch "$child" "$parent"
    fi
}

cmd_track() {
    local sub_command=$1
    shift || true
    
    case "$sub_command" in
        set) _cmd_track_set "$@";;
        remove) _cmd_track_remove "$@";;
        "")
            log_error "A sub-command is required for 'track'."
            log_info "Usage: stgit track <set|remove> [options]"
            cmd_help
            exit 1
            ;;
        *)
            log_error "Unknown sub-command for 'track': $sub_command"
            cmd_help
            exit 1
            ;;
    esac
}


cmd_amend() {
    _guard_context "amend"
    local current_branch
    current_branch=$(get_current_branch)

    # Check if there are any changes (staged or unstaged)
    if [[ -z $(git status --porcelain) ]]; then
        log_warning "No changes (staged or unstaged) to amend."
        exit 0
    fi

    log_step "Amending changes to the last commit on '$current_branch'..."
    git add .
    git commit --amend --no-edit
    log_success "Commit amended successfully."

    local child_branch
    child_branch=$(get_child_branch "$current_branch")
    if [[ -n "$child_branch" ]]; then
        # If there are descendants, they need to be rebased. The restack command handles this.
        cmd_restack
    else
        log_suggestion "Run 'stgit push' to update the remote."
    fi
}

cmd_squash() {
    _guard_context "squash"
    local current_branch
    current_branch=$(get_current_branch)

    local parent
    parent=$(get_parent_branch "$current_branch")
    if [[ -z "$parent" ]]; then
        log_error "Cannot determine parent of '$current_branch'. Is it part of a stack?"
        exit 1
    fi

    local commit_count
    commit_count=$(git rev-list --count "$parent..$current_branch")
    if [[ "$commit_count" -le 1 ]]; then
        log_warning "Branch '$current_branch' has only one commit. Nothing to squash."
        exit 0
    fi

    log_step "Starting interactive rebase to squash commits on '$current_branch'..."
    log_info "Your editor will now open. To squash commits, change 'pick' to 's' or 'squash' for the commits you wish to merge into the one above it."
    
    # This is an interactive command, the script will pause here.
    if git rebase -i "$parent"; then
        log_success "Commits squashed successfully."
        # Now, restack any children
        local child_branch
        child_branch=$(get_child_branch "$current_branch")
        if [[ -n "$child_branch" ]]; then
            cmd_restack
        else
            log_suggestion "Run 'stgit push' to update the remote."
        fi
    else
        log_error "Interactive rebase failed or was aborted."
        exit 1
    fi
}

cmd_clean() {
    log_warning "You are about to permanently delete all stgit metadata for this repository."
    log_info "This includes the configuration cache and any saved state for interrupted commands."
    log_info "This will NOT delete your branches or commits."

    if [[ "$AUTO_CONFIRM" != true ]]; then
        log_prompt "Are you sure you want to continue?"
        read -p "(y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_warning "Clean cancelled."
            exit 0
        fi
    fi

    log_step "Cleaning stgit metadata..."
    if [[ -f "$CONFIG_CACHE_FILE" ]]; then
        rm -f "$CONFIG_CACHE_FILE"
        log_info "Removed configuration cache."
    fi
    if [[ -f "$STATE_FILE" ]]; then
        rm -f "$STATE_FILE"
        log_info "Removed operation state file."
    fi
    log_success "Clean complete. Configuration will be re-initialized on the next run."
}


cmd_create() {
    if [[ -z "$1" ]]; then
        log_error "Branch name is required."
        log_info "Usage: stgit create <branch-name>"
        exit 1
    fi

    local parent_branch
    parent_branch=$(get_current_branch)
    local new_branch=$1

    git checkout -b "$new_branch" >/dev/null 2>&1
    set_parent_branch "$new_branch" "$parent_branch"
    log_success "Created and checked out new branch '$new_branch' (parent: '$parent_branch')."
    log_suggestion "Add commits or run 'stgit create <next-branch>' to extend the stack."
}

cmd_insert() {
    check_gh_auth
    _guard_context "insert"
    local before_flag=false
    if [[ "$1" == "--before" ]]; then
        before_flag=true
        shift # remove --before from the arguments
    fi

    if [[ -z "$1" ]]; then
        log_error "Branch name is required."
        log_info "Usage: stgit insert [--before] <branch-name>"
        exit 1
    fi
    local new_branch_name=$1

    local insertion_point_branch=""
    local branch_to_reparent=""
    local current_branch
    current_branch=$(get_current_branch)

    if [[ "$before_flag" == true ]]; then
        insertion_point_branch=$(get_parent_branch "$current_branch")
        if [[ -z "$insertion_point_branch" ]]; then
            log_error "Cannot determine parent of '$current_branch'. Is it part of a stack?"
            exit 1
        fi
        branch_to_reparent="$current_branch"
        log_step "Preparing to insert '$new_branch_name' before '$current_branch'..."
    else # Default "after" logic
        insertion_point_branch="$current_branch"
        branch_to_reparent=$(get_child_branch "$current_branch")
        log_step "Preparing to insert '$new_branch_name' after '$current_branch'..."
    fi

    # Core logic for creating the branch
    git checkout "$insertion_point_branch" >/dev/null 2>&1
    git checkout -b "$new_branch_name" >/dev/null 2>&1
    
    set_parent_branch "$new_branch_name" "$insertion_point_branch"
    log_success "Created branch '$new_branch_name' on top of '$insertion_point_branch'."

    # Delegate reparenting, rebasing, and PR updates to the helper
    _rebase_sub_stack_and_update_pr "$new_branch_name" "$branch_to_reparent"

    git checkout "$new_branch_name" >/dev/null 2>&1
    log_success "Successfully inserted '$new_branch_name' into the stack."
    log_suggestion "Add commits, then run 'stgit submit' to create a PR."
}

cmd_submit() {
    _guard_context "submit"
    check_gh_auth
    log_step "Syncing stack with GitHub..."
    
    local stack_branches=()
    local current_branch
    current_branch=$(get_stack_top)

    while [[ -n "$current_branch" && "$current_branch" != "$BASE_BRANCH" ]]; do
        stack_branches+=("$current_branch")
        current_branch=$(get_parent_branch "$current_branch")
    done
    
    for (( i=${#stack_branches[@]}-1 ; i>=0 ; i-- )) ; do
        local branch_name="${stack_branches[i]}"
        local pr_number
        pr_number=$(get_pr_number "$branch_name")

        if [[ -n "$pr_number" ]]; then
            log_info "PR #${pr_number} already exists for branch '$branch_name'."
            continue
        fi

        local parent
        parent=$(get_parent_branch "$branch_name")
        if [[ -z "$parent" ]]; then parent="$BASE_BRANCH"; fi

        local commit_count
        commit_count=$(git rev-list --count "${parent}".."${branch_name}")
        if [[ "$commit_count" -eq 0 ]]; then
            log_warning "Skipping PR for '$branch_name': No new commits compared to '$parent'."
            continue
        fi
        
        log_step "Creating PR for '$branch_name'..."
        git push origin "$branch_name" --force-with-lease >/dev/null 2>&1

        local pr_title
        pr_title=$(git log -1 --pretty=%s "$branch_name")
        
        local pr_response
        # Manually check for gh failure since `set -e` won't catch it in a command substitution.
        if ! pr_response=$(gh_api_call "POST" "pulls" "title=$pr_title" "head=$branch_name" "base=$parent"); then
             log_error "Failed to create PR for '$branch_name'. GitHub API call failed."
             exit 1
        fi
        
        local new_pr_number
        new_pr_number=$(echo "$pr_response" | jq -r '.number')
        
        if [[ -n "$new_pr_number" && "$new_pr_number" != "null" ]]; then
            set_pr_number "$branch_name" "$new_pr_number"
            log_success "Created PR #${new_pr_number} for '$branch_name'."
        else
            log_error "Failed to create PR for '$branch_name'."
            log_info "Response from GitHub: $pr_response"
            exit 1 # Exit with failure if PR number is null
        fi
    done

    log_success "Stack submission complete."
}


cmd_next() {
    _guard_context "next"
    local current_branch
    current_branch=$(get_current_branch)
    
    local child_branch
    child_branch=$(get_child_branch "$current_branch")
    
    if [[ -n "$child_branch" ]]; then
        git checkout "$child_branch" >/dev/null 2>&1
        log_success "Checked out child branch: $child_branch"
    else
        log_warning "No child branch found. You are at the top of the stack."
    fi
}

cmd_prev() {
    _guard_context "prev"
    local current_branch
    current_branch=$(get_current_branch)
    
    local parent
    parent=$(get_parent_branch "$current_branch")

    if [[ -n "$parent" ]]; then
        git checkout "$parent" >/dev/null 2>&1
        log_success "Checked out parent branch: $parent"
    else
        log_warning "No parent branch found. You are at the bottom of the stack."
    fi
}

cmd_restack() {
    _guard_context "restack"
    local original_branch
    original_branch=$(get_current_branch)
    log_step "Restacking branches on top of '$original_branch'..."

    local branches_to_restack=()
    local current_child
    current_child=$(get_child_branch "$original_branch")

    while [[ -n "$current_child" ]]; do
        branches_to_restack+=("$current_child")
        current_child=$(get_child_branch "$current_child")
    done

    if [ ${#branches_to_restack[@]} -eq 0 ]; then
        log_warning "You are at the top of the stack. Nothing to restack."
        return
    fi
    
    log_info "Detected subsequent stack: ${branches_to_restack[*]}"
    _perform_iterative_rebase "restack" "$original_branch" "" "$original_branch" "${branches_to_restack[@]}"
    
    _finish_operation
}

cmd_continue() {
    if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
        log_error "A git rebase is still in progress."
        log_suggestion "Run 'git rebase --continue' until it is complete, then run 'stgit continue'."
        exit 1
    fi
    
    if [ ! -f "$STATE_FILE" ]; then
        log_warning "No stgit operation to continue. Nothing to do."
        return
    fi

    _finish_operation
}


cmd_sync() {
    _guard_context "sync"
    check_gh_auth
    local original_branch
    original_branch=$(get_current_branch)
    
    log_step "Syncing stack with '$BASE_BRANCH' and checking for merged branches..."
    git fetch origin --quiet

    local stack_branches=()
    local current_branch_for_stack_build
    current_branch_for_stack_build=$(get_stack_top)
    while [[ -n "$current_branch_for_stack_build" && "$current_branch_for_stack_build" != "$BASE_BRANCH" ]]; do
        stack_branches=("$current_branch_for_stack_build" "${stack_branches[@]}")
        current_branch_for_stack_build=$(get_parent_branch "$current_branch_for_stack_build")
    done

    if [ ${#stack_branches[@]} -eq 0 ]; then
        log_warning "Could not determine stack. Nothing to sync."
        return
    fi

    local merged_branches=()
    local unmerged_branches=()
    
    # First pass: identify all merged branches in the stack
    for branch in "${stack_branches[@]}"; do
        local is_merged=false
        local pr_number
        pr_number=$(get_pr_number "$branch")

        if [[ -n "$pr_number" ]]; then
            log_info "Checking status of PR #${pr_number} for branch '$branch'..."
            local pr_state
            pr_state=$(gh pr view "$pr_number" --json state --jq .state 2>/dev/null || echo "NOT_FOUND")
            if [[ "$pr_state" == "MERGED" ]]; then
                is_merged=true
            fi
        fi
        
        if [[ "$is_merged" == false ]]; then
            # Fallback for branches merged without a PR
            if git merge-base --is-ancestor "$branch" "origin/$BASE_BRANCH"; then
                is_merged=true
            fi
        fi

        if [[ "$is_merged" == true ]]; then
            log_success "Branch '$branch' has been merged."
            merged_branches+=("$branch")
        else
            unmerged_branches+=("$branch")
        fi
    done

    # Second pass: Update parentage of remaining branches
    local last_unmerged_ancestor="$BASE_BRANCH"
    for branch in "${unmerged_branches[@]}"; do
        local original_parent
        original_parent=$(get_parent_branch "$branch")
        
        # If the original parent was merged, we need to find the new parent.
        # Otherwise, the new parent is the last unmerged branch we've seen.
        if [[ " ${merged_branches[*]} " =~ " ${original_parent} " ]]; then
            log_info "Updating parent of '$branch' to '$last_unmerged_ancestor'."
            set_parent_branch "$branch" "$last_unmerged_ancestor"
        fi
        last_unmerged_ancestor="$branch"
    done

    # Third pass: Rebase the remaining (unmerged) stack
    if [ ${#unmerged_branches[@]} -gt 0 ]; then
        log_step "Rebasing remaining stack onto '$BASE_BRANCH'..."
        
        local new_base="origin/$BASE_BRANCH"
        
        _perform_iterative_rebase "sync" "$original_branch" "${merged_branches[*]}" "$new_base" "${unmerged_branches[@]}"
        
        _finish_operation

    else
        log_warning "All branches in the stack were merged. Nothing left to rebase."
        if [[ ${#merged_branches[@]} -gt 0 ]]; then
            echo "COMMAND='sync'" > "$STATE_FILE"
            echo "ORIGINAL_BRANCH='$original_branch'" >> "$STATE_FILE"
            echo "MERGED_BRANCHES_TO_DELETE='${merged_branches[*]}'" >> "$STATE_FILE"
        fi
        _finish_operation
    fi
}


cmd_push() {
    _guard_context "push"
    log_step "Collecting all branches in the stack..."
    local top_branch
    top_branch=$(get_stack_top)
    
    local branches_to_push=()
    local current_branch="$top_branch"

    while [[ -n "$current_branch" && "$current_branch" != "$BASE_BRANCH" ]]; do
        branches_to_push+=("$current_branch")
        current_branch=$(get_parent_branch "$current_branch")
    done
    
    if [ ${#branches_to_push[@]} -eq 0 ]; then
        log_error "No stack branches found to push."
        exit 1
    fi

    echo "Will force-push the following branches:"
    for branch in "${branches_to_push[@]}"; do
        log_info "$branch"
    done
    
    if [[ "$AUTO_CONFIRM" != true ]]; then
        log_prompt "Are you sure?"
        read -p "(y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_warning "Push cancelled."
            exit 0 # Exit with success on user cancellation.
        fi
    fi

    log_step "Pushing with --force-with-lease..."
    git push origin "${branches_to_push[@]}" --force-with-lease
    log_success "All branches pushed."
}

cmd_pr() {
    _guard_context "pr"
    check_gh_auth
    local current_branch
    current_branch=$(get_current_branch)
    local pr_number
    pr_number=$(get_pr_number "$current_branch")

    if [[ -n "$pr_number" ]]; then
        log_step "Opening PR #${pr_number} for branch '$current_branch' in browser..."
        gh pr view "$pr_number" --web
    else
        log_error "No pull request found for branch '$current_branch'."
        log_suggestion "Run 'stgit submit' to create one."
    fi
}

cmd_delete() {
    _guard_context "delete"
    check_gh_auth
    local branch_to_delete
    branch_to_delete=$(get_current_branch)

    local parent
    parent=$(get_parent_branch "$branch_to_delete")
    local child
    child=$(get_child_branch "$branch_to_delete")

    if [[ -z "$parent" ]]; then
        log_error "Cannot determine parent of '$branch_to_delete'. Is it part of a stack?"
        exit 1
    fi

    log_warning "You are about to permanently delete branch '$branch_to_delete'."
    if [[ "$AUTO_CONFIRM" != true ]]; then
        log_prompt "This action cannot be undone. Are you sure you want to continue?"
        read -p "(y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_warning "Deletion cancelled."
            exit 0
        fi
    fi
    
    # Reparent and rebase the child stack if it exists
    if [[ -n "$child" ]]; then
        _rebase_sub_stack_and_update_pr "$parent" "$child"
    fi

    local pr_number
    pr_number=$(get_pr_number "$branch_to_delete")
    if [[ -n "$pr_number" ]]; then
        local close_pr=false
        if [[ "$AUTO_CONFIRM" == true ]]; then
            close_pr=true
        else
            log_prompt "Do you want to close the associated GitHub PR #${pr_number}?"
            read -p "(y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                close_pr=true
            fi
        fi

        if [[ "$close_pr" == true ]]; then
            log_step "Closing PR #${pr_number} on GitHub..."
            gh pr close "$pr_number"
            log_success "PR #${pr_number} closed."
        fi
    fi

    log_step "Deleting branch '$branch_to_delete' locally and on remote..."
    git checkout "$parent" >/dev/null 2>&1
    git branch -D "$branch_to_delete" >/dev/null 2>&1
    git push origin --delete "$branch_to_delete" >/dev/null 2>&1
    log_success "Branch '$branch_to_delete' deleted successfully."
}

cmd_list() {
    log_step "Finding all available stacks..."
    
    local bottoms
    bottoms=($(get_all_stack_bottoms))
    
    if [ ${#bottoms[@]} -eq 0 ]; then
        log_warning "No stgit stacks found."
        log_suggestion "Run 'stgit create <branch-name>' from '$BASE_BRANCH' to start a new stack."
        return
    fi

    log_success "Found ${#bottoms[@]} stack(s):"
    for bottom in "${bottoms[@]}"; do
        local count=1
        local current_branch="$bottom"
        while true; do
            current_branch=$(get_child_branch "$current_branch")
            if [[ -n "$current_branch" ]]; then
                ((count++))
            else
                break
            fi
        done
        log_info "- $bottom ($count branches)"
    done
    log_suggestion "Run 'git checkout <branch>' to switch to a stack and see its status."
}


cmd_status() {
    _guard_context "status"
    check_gh_auth

    log_step "Gathering stack status..."
    git fetch origin --quiet

    local stack_branches=()
    local current_branch_for_stack_build
    current_branch_for_stack_build=$(get_stack_top)
    while [[ -n "$current_branch_for_stack_build" && "$current_branch_for_stack_build" != "$BASE_BRANCH" ]]; do
        stack_branches=("$current_branch_for_stack_build" "${stack_branches[@]}")
        current_branch_for_stack_build=$(get_parent_branch "$current_branch_for_stack_build")
    done

    if [ ${#stack_branches[@]} -eq 0 ]; then
        log_warning "Not currently in a stack. Nothing to show."
        log_suggestion "Run 'stgit create <branch-name>' to start a new stack."
        return
    fi

    echo "" # Add a newline for better formatting
    
    # Display the base branch status first for context
    local base_behind
    base_behind=$(git rev-list --count "$BASE_BRANCH..origin/$BASE_BRANCH")
    local base_ahead
    base_ahead=$(git rev-list --count "origin/$BASE_BRANCH..$BASE_BRANCH")
    local base_status="🟢 Up to date with origin"
    if [[ "$base_behind" -gt 0 ]]; then
        base_status="🟡 Behind by $base_behind"
    elif [[ "$base_ahead" -gt 0 ]]; then
        base_status="🟡 Ahead by $base_ahead"
    fi
    echo "➡️  $BASE_BRANCH ($base_status)"
    echo ""

    local stack_needs_push=false
    local stack_needs_restack=false
    local stack_is_out_of_sync_with_base=false
    local stack_needs_submit=false

    for branch in "${stack_branches[@]}"; do
        local parent_branch
        parent_branch=$(get_parent_branch "$branch")
        if [[ -z "$parent_branch" ]]; then parent_branch="$BASE_BRANCH"; fi

        local is_current_branch=$([[ "$(get_current_branch)" == "$branch" ]] && echo " *" || echo "")
        echo "➡️  $branch$is_current_branch (parent: $parent_branch)"

        # --- Status Line Logic ---
        local status_message=""
        
        # Determine the correct comparison point for the parent.
        local parent_for_comparison
        if [[ "$parent_branch" == "$BASE_BRANCH" ]]; then
            parent_for_comparison="$BASE_BRANCH"
        else
            parent_for_comparison="$parent_branch"
        fi

        # Priority 1: Behind parent (This handles the base case correctly now)
        local commits_behind_parent
        commits_behind_parent=$(git rev-list --count "$branch..$parent_for_comparison")
        if [[ "$commits_behind_parent" -gt 0 ]]; then
            status_message="🟡 Behind '$parent_branch' ($commits_behind_parent commits)"
            if [[ "$parent_branch" == "$BASE_BRANCH" ]]; then
                stack_is_out_of_sync_with_base=true
            else
                stack_needs_restack=true
            fi
        fi
            
        # Priority 2: Needs push (if no other issues found yet)
        if [[ -z "$status_message" ]]; then
            local remote_sha
            remote_sha=$(git rev-parse --quiet --verify "origin/$branch" 2>/dev/null || echo "")
            local local_sha
            local_sha=$(git rev-parse "$branch")
            if [[ -n "$remote_sha" && "$local_sha" != "$remote_sha" ]]; then
                status_message="🟡 Needs push (local history has changed)"
                stack_needs_push=true
            elif [[ -z "$remote_sha" ]]; then
                status_message="⚪ Not on remote"
                stack_needs_push=true
            fi
        fi

        # Priority 3: All good
        if [[ -z "$status_message" ]]; then
             status_message="🟢 Synced"
        fi
        echo "   ├─ Status: $status_message"

        # --- PR Line Logic ---
        local pr_number
        pr_number=$(get_pr_number "$branch")
        local pr_status=""
        if [[ -n "$pr_number" ]]; then
            local pr_info
            pr_info=$(gh pr view "$pr_number" --json state,url --jq '{state: .state, url: .url}' 2>/dev/null || echo "{}")
            local pr_state
            pr_state=$(echo "$pr_info" | jq -r '.state')
            local pr_url
            pr_url=$(echo "$pr_info" | jq -r '.url')

            if [[ "$pr_state" == "OPEN" ]]; then
                pr_status="🟢 #${pr_number}: OPEN - $pr_url"
            elif [[ "$pr_state" == "MERGED" ]]; then
                pr_status="🟣 #${pr_number}: MERGED"
            elif [[ "$pr_state" == "CLOSED" ]]; then
                pr_status="🔴 #${pr_number}: CLOSED"
            else
                 pr_status="🟡 Could not fetch status for PR #${pr_number}"
            fi
        else
            pr_status="⚪ No PR submitted"
            stack_needs_submit=true
        fi
        echo "   └─ PR:     $pr_status"
        echo ""
    done
    
    # --- Final Summary Logic ---
    if [[ "$stack_is_out_of_sync_with_base" == true ]]; then
        log_warning "The stack is behind '$BASE_BRANCH'."
        log_suggestion "Run 'stgit sync' to update the entire stack."
    elif [[ "$stack_needs_restack" == true ]]; then
        log_warning "A branch in the stack is behind its parent."
        log_suggestion "Run 'stgit restack' from the out-of-date branch or 'stgit sync' for the whole stack."
    elif [[ "$stack_needs_push" == true ]]; then
        log_warning "One or more local branches have changed."
        log_suggestion "Run 'stgit push' to update the remote."
    elif [[ "$stack_needs_submit" == true ]]; then
        log_warning "One or more branches are missing a pull request."
        log_suggestion "Run 'stgit submit' to create them."
    else
        log_success "Stack is up to date with '$BASE_BRANCH' and remote."
    fi
}

# --- Help and Main Dispatcher ---
cmd_help() {
    echo "stgit - A tool for managing stacked Git branches with GitHub integration."
    echo ""
    echo "Usage: stgit [options] <command> [args]"
    echo ""
    echo "Options:"
    echo "  -y, --yes              Automatically answer 'yes' to all prompts."
    echo "  -h, --help             Show this help message."
    echo ""
    echo "Commands:"
    echo "  amend                  Amend staged changes to the last commit and restack."
    echo "  clean                  Remove all stgit metadata from the repository."
    echo "  create <branch-name>   Create a new branch on top of the current one."
    echo "  delete                 Delete the current branch and repair the stack."
    echo "  insert [--before] <branch-name>"
    echo "                         Insert a new branch. By default, inserts after the"
    echo "                         current branch. Use --before to insert before it."
    echo "  list|ls                List all available stacks."
    echo "  squash                 Squash commits on the current branch and restack."
    echo "  submit                 Create GitHub PRs for all branches in the stack."
    echo "  sync                   Syncs the stack: rebases onto the latest base branch"
    echo "                         and cleans up any merged parent branches."
    echo "  status                 Display the status of the current branch stack."
    echo "  track <set|remove> [args]"
    echo "                         Manage stack metadata. 'set' assigns a parent, 'remove' untracks a branch."
    echo "  next                   Navigate to the child branch in the stack."
    echo "  prev                   Navigate to the parent branch in the stack."
    echo "  restack                Update branches above the current one after making changes."
    echo "  push                   Force-push all branches in the current stack to the remote."
    echo "  pr                     Open the GitHub PR for the current branch in your browser."
    echo "  continue               Resume and finalize an stgit operation after a rebase conflict."
    echo "  help                   Show this help message."
    echo ""
}

main() {
    # This robust, two-pass parser prevents issues with `shift` and `set -e`.
    
    # 1. First, parse all global options that can appear anywhere.
    # We build a new array `all_args` that excludes the global options.
    local all_args=()
    for arg in "$@"; do
        case "$arg" in
            -y|--yes)
                AUTO_CONFIRM=true
                ;;
            -h|--help)
                cmd_help
                exit 0
                ;;
            # Keep all other arguments
            *)
                all_args+=("$arg")
                ;;
        esac
    done

    # 2. Now, the command is the first element of the remaining arguments.
    # The `-` prevents an error if `all_args` is empty.
    local command=${all_args[0]-}
    
    # 3. The rest are the command's specific arguments.
    # This uses slicing to get all elements from index 1 onwards.
    local cmd_args=("${all_args[@]:1}")

    # If no command was provided (e.g., only `stgit --yes`), show help and exit.
    if [[ -z "$command" ]]; then
        cmd_help
        exit 0
    fi

    _initialize_config

    # --- Command Dispatch ---
    # Pass the command-specific arguments to the command function.
    case "$command" in
        amend) cmd_amend "${cmd_args[@]}";;
        clean) cmd_clean "${cmd_args[@]}";;
        create) cmd_create "${cmd_args[@]}";;
        delete) cmd_delete "${cmd_args[@]}";;
        insert) cmd_insert "${cmd_args[@]}";;
        squash) cmd_squash "${cmd_args[@]}";;
        submit) cmd_submit "${cmd_args[@]}";;
        sync) cmd_sync "${cmd_args[@]}";;
        status) cmd_status "${cmd_args[@]}";;
        track) cmd_track "${cmd_args[@]}";;
        next) cmd_next "${cmd_args[@]}";;
        prev) cmd_prev "${cmd_args[@]}";;
        restack) cmd_restack "${cmd_args[@]}";;
        continue) cmd_continue "${cmd_args[@]}";;
        push) cmd_push "${cmd_args[@]}";;
        pr) cmd_pr "${cmd_args[@]}";;
        list|ls) cmd_list "${cmd_args[@]}";;
        help) cmd_help;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"

