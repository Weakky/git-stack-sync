stgit - Stacked Git CLIstgit is a simple command-line interface written in Bash to make working with stacked Git branches easier. It's inspired by the workflow of tools like Graphite and leverages the powerful --update-refs feature introduced in Git 2.38.This tool helps you create dependent branches, keep them in sync, and prepare them for pull requests without the usual hassle of manual rebasing.InstallationDownload the script: Save the stgit file to your computer.Make it executable:chmod +x /path/to/stgit
Place it in your PATH: Move the script to a directory that is in your system's PATH to run it from anywhere.sudo mv /path/to/stgit /usr/local/bin/stgit
Core Conceptstgit works by creating a chain of branches. When you run stgit create <branch-name>, it creates a new branch and remembers its "parent" in your local Git configuration. This allows stgit to understand the entire stack.The magic happens with stgit rebase, which uses git rebase --update-refs to automatically update all branches in your stack when you rebase against your main development branch (e.g., dev or main).Commandsstgit create <branch-name>Creates a new branch as a child of your current branch and checks it out.Example:Imagine you are on a branch called feature-x/part-1.# You are on feature-x/part-1
stgit create feature-x/part-2
This creates a new branch feature-x/part-2 based on feature-x/part-1.stgit prevChecks out the parent branch of your current branch in the stack.Example:If you are on feature-x/part-2, this command will take you to feature-x/part-1.# You are on feature-x/part-2
stgit prev
# Now you are on feature-x/part-1
stgit submitThis is a simulation command. It shows you the pull requests that would be created for your current stack, from the bottom of the stack to the top.Example:If you have a stack dev <- part-1 <- part-2 <- part-3, it will output:Submitting stack for review...
  - PR for 'part-1' to be merged into 'dev'
  - PR for 'part-2' to be merged into 'part-1'
  - PR for 'part-3' to be merged into 'part-2'
Stack submitted.
stgit rebaseThis is the most powerful command. It rebases your entire stack on the latest version of your base branch (dev by default).How it works:It finds the "bottom" branch of your current stack.It fetches the latest changes from your base branch (origin/dev).It runs a single git rebase --update-refs command that replays all the commits from all your stacked branches on top of the base branch and automatically moves each branch pointer to the correct new commit.Usage:For the best results, check out the topmost branch of your stack before running the command.# You are on the top branch, e.g., feature-x/part-3
stgit rebase
This will handle all the intermediate branches (part-1, part-2) for you. After it's done, you will likely need to force-push your branches to the remote.stgit helpDisplays the help message with all available commands.ConfigurationThe default base branch is dev. If you use main or master, you can change the BASE_BRANCH variable at the top of the stgit script.# In the stgit script file
BASE_BRANCH="main"
