# Git Stack Sync (`gss`) - A Simple CLI for Stacked Git Branches

**Git Stack Sync (`gss`)** is a command-line tool, written in TypeScript, that simplifies working with stacked Git branches. Inspired by the workflows of tools like Graphite, it helps you create, manage, and submit dependent chains of branches without the usual hassle of manual rebasing and pull request management.

It works by maintaining a simple JSON configuration file in your local `.git` directory, allowing it to understand the relationships between your branches. When combined with the GitHub CLI (`gh`), `gss` can automate large parts of your development workflow.

### What does it shine at?

- **Efficiency**: It leverages modern Git features like `git rebase --update-refs` to perform complex stack rebases in a single, fast operation.
- **Automation**: It automates the most tedious parts of stacked branching, such as rebasing an entire stack of branches (`sync`) or intelligently updating children after an amendment (`restack`).
- **GitHub Integration**: It seamlessly uses the `gh` CLI to manage pull requests for your entire stack, creating dependencies and updating them as you restructure your branches.
- **Clarity**: The `status` command gives you a comprehensive overview of your entire stack, showing which branches are out of sync, need pushing, or have merged pull requests.

## Core Concepts

`gss` treats a series of dependent branches as a "stack". When you run `gss create <branch-name>`, it creates a new branch and records its parent in its configuration file.

This simple parent-child metadata is the foundation for all of `gss`'s powerful features. It allows the tool to traverse the stack, understand dependencies, and perform complex operations like rebasing the entire chain with a single command.

## Installation

1.  **Dependencies**: Make sure you have the following tools installed and available in your `$PATH`:

    - `git` (version **2.39+ is recommended** for `--update-refs` support)
    - [Node.js](https://nodejs.org/)
    - [GitHub CLI (`gh`)](https://cli.github.com/)

2.  **Install from npm**: You can install `gss` globally from the npm registry.
    ```bash
    npm install -g git-stack-sync
    ```

## Command Reference

Here is a detailed list of all available commands.

### Stack & Branch Management

- #### `gss create <branch-name>`

  Creates a new branch as a child of the currently checked-out branch and switches to it. This is the primary way to extend a stack.

- #### `gss insert [--before] <branch-name>`

  Inserts a new branch into the stack. By default, it inserts _after_ the current branch. The `--before` flag inserts it _before_ the current branch. `gss` will automatically rebase any descendant branches and update their associated pull requests on GitHub.

- #### `gss squash [--into parent|child]`

  Squashes the commits from one branch into another and deletes the squashed branch. By default, it squashes the current branch into its `parent`. Use `--into child` to squash the child branch into the current one. `gss` will prompt to close the pull request of the deleted branch.

- #### `gss track [parent-branch]`

  Manually marks an existing branch as a stacked branch. If `parent-branch` is omitted, the repository's base branch (e.g., `main`) is used.

- #### `gss untrack`
  Removes `gss` metadata from the current branch. This is only allowed if the branch has no unique commits. The child branch will be reparented to the untracked branch's parent.

### Synchronization & History

- #### `gss sync`

  This is the workhorse command for keeping your stack up-to-date. It performs several key operations:

  1.  Fetches the latest changes from `origin`.
  2.  Updates your local base branch (e.g., `main`) to match the remote.
  3.  Checks the status of the pull request for every branch in your stack.
  4.  If any PRs have been **merged**, it automatically removes those branches from the stack, re-parents their children, and prepares for cleanup.
  5.  Rebases the remaining, unmerged branches onto the latest version of the base branch.

- #### `gss restack`

  Intelligently updates your stack after you've modified its history (e.g., with `git commit --amend` or an interactive rebase). It automatically detects the first branch that has diverged from its parent and rebases all of its descendants on top of it.

- #### `gss amend`

  A convenient shortcut. It adds all staged changes to the most recent commit (`git commit --amend --no-edit`) and then automatically runs `gss restack` to update any descendant branches.

- #### `gss push`

  Pushes all branches in the current stack to the remote (`origin`). It uses `--force-with-lease` to safely update remote branches after a `sync` or `restack` has changed their history.

- #### `gss continue`
  Resumes a `sync` or `restack` operation after you have resolved a git rebase conflict.

### Inspection & Navigation

- #### `gss status`

  Displays a detailed, colorful overview of the entire current stack, including parent-child relationships, sync status, and pull request status.

- #### `gss list` (or `ls`)

  Finds and lists all stacks in your local repository.

- #### `gss up` / `gss down`
  Quickly navigate up (`up`) or down (`down`) the branch stack.

### GitHub Integration

- #### `gss submit`

  Creates GitHub pull requests for all branches in the stack that don't have one yet. It automatically sets the base branch for each PR to be its parent in the stack, creating a dependent chain of PRs.

- #### `gss pr`
  Opens the GitHub pull request for the current branch in your web browser.

## Workflows & Examples

### 1. Starting and Submitting a New Stack

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

# 4. Create pull requests for the entire stack
gss submit
# ➡️  Creating PR for 'feat-part-1'...
# 🟢 Created PR #20 for 'feat-part-1': [https://github.com/mock/repo/pull/20](https://github.com/mock/repo/pull/20)
# ➡️  Creating PR for 'feat-part-2'...
# 🟢 Created PR #21 for 'feat-part-2': [https://github.com/mock/repo/pull/21](https://github.com/mock/repo/pull/21)
# 🟢 Stack submission complete.
```

### 2. Handling a Squashed Merged PR (`sync`)

This is the most common and powerful workflow. Imagine your teammate reviewed and squash-merged the first PR (`feat-part-1`). Your local repository is now out of date.

```bash
# 1. Check the status. gss will fetch from the remote and detect changes.
gss status
# ➡️  Gathering stack status...
#
# ➡️  main (🟡 Behind by 1)
#
# ➡️  feat-part-1 (parent: main)
#    ├─ Status: 🟡 Behind 'main' (1 commits)
#    └─ PR:     🟣 #10: MERGED
#
# ➡️  feat-part-2 * (parent: feat-part-1)
#    ├─ Status: 🟢 Synced
#    └─ PR:     🟢 #11: OPEN
#
# 🟡 Warning: The stack contains merged branches or is behind the base branch.
# 💡 Next step: Run 'gss sync' to update the base and rebase the stack.

# 2. Run sync to automatically fix everything.
gss sync --yes
# ➡️  Syncing stack with 'main' and checking for merged branches...
# 🟢 Branch 'feat-part-1' has been merged.
# ➡️  Rebasing remaining stack onto 'main'...
# 🟢 Stack rebased successfully.
# ➡️  Finishing operation...
# 🟢 Deleted local branch 'feat-part-1'.
# 🟢 Operation complete.
# 💡 Next step: Run 'gss push' to update your remote branches.

# 3. Push the rebased branch to update its pull request.
gss push --yes
```

### 3. Inserting a Branch Mid-Stack (After Review)

This workflow demonstrates how to insert a new feature or fix into the middle of an existing stack. This is common when a code review on `feat-part-2` reveals a missing piece that should have been in its own PR, logically before `feat-part-2`.

```bash
# 1. You have a stack: main -> feat-part-1 -> feat-part-2
#    A review on feat-part-2's PR suggests you extract some logic
#    into its own branch/PR.
#
#    First, check out the branch you want to insert *after*.
gss down
# 🟢 Checked out parent branch: feat-part-1

# 2. Use `gss insert` to create the new branch.
#    `gss` will create the new branch and automatically rebase
#    the old descendant (`feat-part-2`) on top of it.
gss insert feat-part-1-fixup
# ➡️  Preparing to insert 'feat-part-1-fixup' after 'feat-part-1'...
# 🟢 Created branch 'feat-part-1-fixup' on top of 'feat-part-1'.
# ➡️  Checking stack integrity to find point of divergence...
# 🟡 Warning: Detected stack divergence at 'feat-part-1-fixup'. Restacking descendants...
#    Will restack the following branches: feat-part-2
# 🟢 Restack complete.
# 🟢 Successfully inserted 'feat-part-1-fixup' into the stack.
# 💡 Next step: Add commits, then run 'gss submit' to create a PR.

# 3. You are now on the new branch. Add your changes and commit.
echo "A fix" > fix.txt
git add . && git commit -m "feat: Add fixup for part 1"

# 4. Your stack is now: main -> feat-part-1 -> feat-part-1-fixup -> feat-part-2
#    Check the status to see the new structure.
gss status
# ➡️  feat-part-1-fixup * (parent: feat-part-1)
#    ├─ Status: ⚪ Not on remote
#    └─ PR:     ⚪ No PR submitted
#
# ➡️  feat-part-2 (parent: feat-part-1-fixup)
#    ├─ Status: 🟡 Needs push (local history has changed)
#    └─ PR:     🟢 #102: OPEN
#
# 🟡 Warning: One or more local branches have changed.
# 💡 Next step: Run 'gss push' to update the remote.

# 5. Submit the new branch and push the changes.
gss submit
gss push --yes
```
### 4. Amending a Commit Mid-Stack (`amend` & `restack`)

This workflow covers the common scenario where you need to modify a commit on a parent branch that already has other branches stacked on top of it. `gss` makes this a safe and simple operation.

Imagine your stack is `main -> feat-part-1 -> feat-part-2`, and you need to make a small fix to the commit on `feat-part-1`.

```bash
# 1. You have a stack and need to edit an earlier branch.
#    First, check out the branch you need to modify.
gss down
# 🟢 Checked out parent branch: feat-part-1

# 2. Make your code change and stage it using git.
echo "A small fix" >> file1.txt
git add file1.txt

# 3. Run `gss amend`.
#    This command will amend your staged changes to the latest commit and
#    then automatically trigger a `restack`. The restack operation detects
#    that `feat-part-1` has changed and rebases its descendant, `feat-part-2`,
#    on top of the new version.
gss amend --yes
# ➡️  Amending changes to the last commit on 'feat-part-1'...
# 🟢 Commit amended successfully.
# ➡️  Checking stack integrity to find point of divergence...
# 🟡 Warning: Detected stack divergence at 'feat-part-1'. Restacking descendants...
#    Will restack the following branches: feat-part-2
# 🟢 Restack complete.
# ➡️  Finishing operation...
# 🟢 Operation complete.
# 💡 Next step: Run 'gss push' to update your remote branches.

# 4. Your entire stack is now consistent. `feat-part-2` is correctly
#    rebased on the amended `feat-part-1`.
#    The final step is to update the PRs on GitHub.
gss push --yes