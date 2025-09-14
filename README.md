# Git Stack Sync (`gss`) - A Simple CLI for Stacked Git Branches

**Git Stack Sync (`gss`)** is a command-line tool written in Bash that simplifies working with stacked Git branches. Inspired by the workflows of tools like Graphite, it helps you create, manage, and submit dependent chains of branches without the usual hassle of manual rebasing and pull request management.

It works by maintaining a simple set of metadata in your local Git configuration, allowing it to understand the relationships between your branches. When combined with the GitHub CLI (`gh`), `gss` can automate large parts of your development workflow.

### What does it shine at?

  * **Simplicity**: It's a single, dependency-light Bash script. There's no complex installation or background daemon.
  * **Automation**: It automates the most tedious parts of stacked branching, such as rebasing an entire stack of branches (`sync`) or updating children after an amendment (`restack`).
  * **GitHub Integration**: It seamlessly uses the `gh` CLI to manage pull requests for your entire stack, creating dependencies and updating them as you restructure your branches.
  * **Clarity**: The `status` command gives you a comprehensive overview of your entire stack, showing which branches are out of sync, need pushing, or have merged pull requests.

## Core Concepts

`gss` treats a series of dependent branches as a "stack". When you run `gss create <branch-name>`, it creates a new branch and records its parent in your local Git config (e.g., `branch.branch-name.parent=parent-branch`).

This simple parent-child metadata is the foundation for all of `gss`'s powerful features. It allows the tool to traverse the stack, understand dependencies, and perform complex operations like rebasing the entire chain with a single command.

## Installation

1.  **Dependencies**: Make sure you have the following tools installed and available in your `$PATH`:

      * `git` (version 2.38+ recommended)
      * [GitHub CLI (`gh`)](https://www.google.com/search?q=%5Bhttps://cli.github.com/%5D\(https://cli.github.com/\))
      * [jq](https://stedolan.github.io/jq/)

2.  **Download the script**: Save the script file (e.g., `gss.sh`) to your computer.

3.  **Make it executable**:

    ```bash
    chmod +x /path/to/gss.sh
    ```

4.  **Place it in your PATH**: For easy access, move the script to a directory in your system's `PATH` and rename it.

    ```bash
    # For example:
    sudo mv /path/to/gss.sh /usr/local/bin/gss
    ```

## Command Reference

Here is a detailed list of all available commands.

### Stack & Branch Management

  * #### `gss create <branch-name>`

    Creates a new branch as a child of the currently checked-out branch and switches to it. This is the primary way to extend a stack.

    ```bash
    # You are on 'main'
    gss create feature-a

    # You are now on 'feature-a', whose parent is 'main'.
    gss create feature-b

    # You are now on 'feature-b', whose parent is 'feature-a'.
    ```

  * #### `gss insert [--before] <branch-name>`

    Inserts a new branch into the stack. By default, it inserts *after* the current branch. The `--before` flag inserts it *before* the current branch. `gss` will automatically rebase any descendant branches and update their associated pull requests on GitHub.

    ```bash
    # In a stack main -> feature-a -> feature-c
    # You are on 'feature-a'
    gss insert feature-b

    # The new stack is main -> feature-a -> feature-b -> feature-c
    # and you are now on 'feature-b'.
    ```

  * #### `gss squash [--into parent|child]`

    Squashes the commits from one branch into another and deletes the squashed branch. By default, it squashes the current branch into its `parent`. Use `--into child` to squash the child branch into the current one. `gss` will prompt to close the pull request of the deleted branch.

  * #### `gss track <set|remove> [parent-branch]`

    Manually manages stack metadata.

      * `track set [parent-branch]`: Marks an existing branch as a stacked branch. If `parent-branch` is omitted, the repository's base branch (e.g., `main`) is used.
      * `track remove`: Removes `gss` metadata from the current branch.

### Synchronization & History

  * #### `gss sync`

    This is the workhorse command for keeping your stack up-to-date. It performs several key operations:

    1.  Fetches the latest changes from `origin`.
    2.  Updates your local base branch (e.g., `main`) to match the remote.
    3.  Checks the status of the pull request for every branch in your stack.
    4.  If any PRs have been **merged**, it automatically removes those branches from the stack, re-parents their children, and prepares for cleanup.
    5.  Rebases the remaining, unmerged branches onto the latest version of the base branch.

  * #### `gss restack`

    Updates all descendant (child) branches after you've modified the current branch's history (e.g., with `git commit --amend` or `git rebase`). It performs a cascading rebase on all children.

  * #### `gss amend`

    A convenient shortcut. It adds all staged changes to the most recent commit (`git commit --amend --no-edit`) and then automatically runs `gss restack` if the current branch has children.

  * #### `gss push`

    Pushes all branches in the current stack to the remote (`origin`). It uses `--force-with-lease` to safely update remote branches after a `sync` or `restack` has changed their history.

  * #### `gss continue`

    Resumes a `sync` or `restack` operation after you have resolved a git rebase conflict.

### Inspection & Navigation

  * #### `gss status`

    Displays a detailed, colorful overview of the entire current stack, including:

      * Parent-child relationships.
      * Sync status relative to parent branches and the remote.
      * Pull request status (e.g., `OPEN`, `MERGED`, `CLOSED`).
      * A helpful summary and a suggestion for the next command to run.

  * #### `gss list` (or `ls`)

    Finds and lists all stacks in your local repository.

  * #### `gss next` / `gss prev`

    Quickly navigate up (`next`) or down (`prev`) the branch stack.

### GitHub Integration

  * #### `gss submit`

    Creates GitHub pull requests for all branches in the stack that don't have one yet. It automatically sets the base branch for each PR to be its parent in the stack, creating a dependent chain of PRs.

  * #### `gss pr`

    Opens the GitHub pull request for the current branch in your web browser.

## Workflows & Examples

### 1\. Starting and Submitting a New Stack

This workflow shows how to start a new feature and submit it for review as a stack of dependent pull requests.

```bash
# 1. Start on your base branch (e.g., main)
git checkout main

# 2. Create the first branch in your stack and add a commit
gss create feat-part-1
echo "Initial work" > file1.txt
git add . && git commit -m "feat: Implement part 1"

# 3. Create a second, dependent branch and add another commit
gss create feat-part-2
echo "More work" > file2.txt
git add . && git commit -m "feat: Implement part 2"

# 4. Push the entire stack to the remote
gss push --yes

# 5. Create pull requests for the entire stack
gss submit
# ➡️  Creating PR for 'feat-part-1'...
# 🟢 Created PR #101 for 'feat-part-1'.
# ➡️  Creating PR for 'feat-part-2'...
# 🟢 Created PR #102 for 'feat-part-2'.
# 🟢 Stack submission complete.
```

On GitHub, you will now have two pull requests: one for `feat-part-2` targeting `feat-part-1`, and one for `feat-part-1` targeting `main`.

### 2\. Handling a Squash Merged PR (`sync`)

This is the most common and powerful workflow. Imagine your teammate reviewed and squash-merged the first PR (`feat-part-1`) from the example above. Your local repository is now out of date.

```bash
# 1. Check the status. `gss` will fetch from the remote and detect changes.
gss status

# ➡️  Gathering stack status...
#
# ➡️  main (🟡 Behind by 1)
#
# ➡️  feat-part-1 (parent: main)
#    ├─ Status: 🟡 Behind 'main' (1 commits)
#    └─ PR:     🟣 #101: MERGED
#
# ➡️  feat-part-2 * (parent: feat-part-1)
#    ├─ Status: 🟢 Synced
#    └─ PR:     🟢 #102: OPEN
#
# 🟡 Warning: The stack contains merged branches or is behind the base branch.
# 💡 Next step: Run 'gss sync' to clean up and rebase the stack.

# 2. Run `sync` to automatically fix everything.
gss sync --yes
# ➡️  Syncing stack with 'main' and checking for merged branches...
# 🟢 Branch 'feat-part-1' has been merged.
# ➡️  Rebasing remaining stack onto 'main'...
# ➡️  Rebasing 'feat-part-2' onto 'origin/main'...
# ➡️  Finishing operation...
# 🟢 Deleted local branch 'feat-part-1'.
# 🟢 Operation complete.
# 💡 Next step: Run 'gss push' to update your remote branches.

# 3. The local `feat-part-1` branch is gone, and `feat-part-2` is now
#    rebased directly on top of the latest `main`. Check the status again.
gss status
# ➡️  feat-part-2 * (parent: main)
#    ├─ Status: 🟡 Needs push (local history has changed)
#    └─ PR:     🟢 #102: OPEN
#
# 🟡 Warning: One or more local branches have changed.
# 💡 Next step: Run 'gss push' to update the remote.

# 4. Push the rebased branch to update its pull request.
gss push --yes
```

Your stack is now clean, up-to-date, and consists of a single branch (`feat-part-2`) based on `main`.

### 3\. Amending a Commit in a Stack (`restack`)

Imagine you need to fix something in `feat-part-1` while `feat-part-2` already depends on it.

```bash
# 1. You have a stack: main -> feat-part-1 -> feat-part-2
#    Check out the branch you need to edit.
git checkout feat-part-1

# 2. Make your changes and amend them to the last commit.
echo "a fix" >> file1.txt
git add file1.txt
git commit --amend --no-edit
# Alternatively, you can just run `gss amend` after adding the file.

# 3. Your commit hash for `feat-part-1` has now changed, making
#    `feat-part-2` out of date. Run `restack`.
gss restack
# ➡️  Restacking branches on top of 'feat-part-1'...
#    Detected subsequent stack: feat-part-2
# ➡️  Rebasing 'feat-part-2' onto 'feat-part-1'...
# ➡️  Finishing operation...
# 🟢 Operation complete.

# 4. Both branches are now updated locally. Force-push to update the remote.
gss push --yes
```