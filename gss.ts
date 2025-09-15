#!/usr/bin/env node

import { $, chalk, fs, path, ProcessOutput, question } from 'zx';

$.verbose = false;

// --- Types ---
interface GssState {
  command: string;
  originalBranch: string;
  mergedBranchesToDelete?: string[];
  unmergedBranches?: string[];
  branchesToRestack?: string[];
  restackStartBranch?: string;
  finalBase?: string;
}


// --- State and Configuration ---
let stateFile: string;
let configCacheFile: string;
let autoConfirm = false;

const config = {
  baseBranch: '',
  ghUser: '',
  ghRepo: '',
};

// --- Logging Helpers ---
function logSuccess(message: string) {
  console.log(chalk.green(`🟢 ${message}`));
}

function logError(message: string) {
  console.error(chalk.red(`🔴 Error: ${message}`));
}

function logWarning(message: string) {
  console.warn(chalk.yellow(`🟡 Warning: ${message}`));
}

function logInfo(message: string) {
  console.log(`   ${message}`);
}

function logStep(message: string) {
  console.log(`➡️  ${message}`);
}

function logSuggestion(message: string) {
  console.log(`💡 Next step: ${message}`);
}

// --- Git & System Helpers ---
function getGitRoot(): string | null {
  try {
    return require('child_process').execSync('git rev-parse --show-toplevel').toString().trim();
  } catch (e) {
    return null;
  }
}

async function guardDirtyState(options: { allowStaged?: boolean } = {}) {
  let status = (await $`git status --porcelain`).stdout.trim();
  if (options.allowStaged) {
    // Filter out staged changes (lines starting with A, M, D, R, C followed by a space)
    status = status.split('\n').filter(line => !/^[AMDRC] /.test(line)).join('\n');
  }
  if (status) {
    logError('Command cannot run with uncommitted changes in the working directory.');
    logSuggestion("Please 'git commit' or 'git stash' your changes before proceeding.");
    process.exit(1);
  }
}

async function checkGhAuth() {
  try {
    await $`gh auth status`;
  } catch {
    logError("You are not logged into the GitHub CLI.");
    logSuggestion("Run 'gh auth login' to authenticate.");
    process.exit(1);
  }
}


async function getCurrentBranch(): Promise<string> {
  return (await $`git rev-parse --abbrev-ref HEAD`).stdout.trim();
}

async function getParentBranch(branch: string): Promise<string> {
  try {
    return (await $`git config --get branch.${branch}.parent`).stdout.trim();
  } catch {
    return '';
  }
}

async function getChildBranches(parentBranch: string): Promise<string[]> {
  try {
    const configLines = (await $`git config --get-regexp ^branch\\..*\\.parent$`).stdout.trim();
    return configLines.split('\n')
      .filter(line => line.endsWith(` ${parentBranch}`))
      .map(line => line.match(/^branch\.(.*)\.parent/)?.[1] || '')
      .filter(Boolean);
  } catch {
    return [];
  }
}

async function getStackTop(startBranch?: string): Promise<string> {
  let currentTop = startBranch || await getCurrentBranch();
  while (true) {
    // In a forked stack, this will just pick the first child it finds.
    const children = await getChildBranches(currentTop);
    if (children.length > 0) {
      currentTop = children[0];
    } else {
      break;
    }
  }
  return currentTop;
}

async function getFullStack(startBranch?: string): Promise<string[]> {
  const top = await getStackTop(startBranch);
  const stack: string[] = [];
  let current: string | null = top;
  while (current && current !== config.baseBranch) {
    stack.unshift(current);
    current = await getParentBranch(current);
  }
  return stack;
}

async function setParentBranch(childBranch: string, parentBranch: string) {
  await $`git config branch.${childBranch}.parent ${parentBranch}`;
}

async function unsetParentBranch(childBranch: string) {
  try {
    await $`git config --unset branch.${childBranch}.parent`;
  } catch {
    // ignore if it doesn't exist
  }
}

async function getPrNumber(branch: string): Promise<string> {
  try {
    return (await $`git config --get branch.${branch}.pr-number`).stdout.trim();
  } catch {
    return '';
  }
}

async function setPrNumber(branch: string, prNumber: string) {
  await $`git config branch.${branch}.pr-number ${prNumber}`;
}

async function confirm(prompt: string): Promise<boolean> {
  if (autoConfirm) return true;
  const answer = await question(`❔ ${prompt} (y/N) `);
  return answer.toLowerCase() === 'y';
}

async function guardContext(commandName: string) {
  const currentBranch = await getCurrentBranch();
  if (currentBranch === config.baseBranch) {
    logError(`The '${commandName}' command cannot be run from the base branch ('${config.baseBranch}').`);
    await cmdList();
    process.exit(1);
  }
  const parent = await getParentBranch(currentBranch);
  if (!parent) {
    logError(`The '${commandName}' command requires a tracked branch.`);
    logInfo(`Branch '${currentBranch}' is not currently tracked by gss.`);
    logSuggestion("To start a new stack, run 'gss create <branch-name>'.");
    process.exit(1);
  }
}

async function readState(): Promise<GssState | null> {
  try {
    const content = await fs.readFile(stateFile, 'utf-8');
    return JSON.parse(content) as GssState;
  } catch {
    return null;
  }
}

async function writeState(state: GssState): Promise<void> {
  await fs.writeFile(stateFile, JSON.stringify(state, null, 2));
}

async function clearState(): Promise<void> {
  try {
    await fs.unlink(stateFile);
  } catch {
    // ignore if not found
  }
}

async function repairStackMetadata(startParent: string, branches: string[]) {
  logStep("Updating gss parent metadata...");
  let currentParent = startParent;
  for (const branch of branches) {
    await setParentBranch(branch, currentParent);
    currentParent = branch;
  }
  logSuccess("Metadata repaired.");
}


async function finishOperation() {
  const state = await readState();
  if (!state) return;

  logStep("Finishing operation...");

  if (state.command === 'sync' && state.mergedBranchesToDelete) {
    for (const branchToDelete of state.mergedBranchesToDelete) {
      if (await confirm(`Do you want to delete the local merged branch '${branchToDelete}'?`)) {
        if (await getCurrentBranch() === branchToDelete) {
          await $`git checkout ${config.baseBranch}`;
        }
        await $`git branch -D ${branchToDelete}`;
        logSuccess(`Deleted local branch '${branchToDelete}'.`);
      }
    }
  }

  try {
    await $`git rev-parse --verify ${state.originalBranch}`;
    if (await getCurrentBranch() !== state.originalBranch) {
      logInfo(`Returning to original branch '${state.originalBranch}'.`);
      await $`git checkout ${state.originalBranch}`;
    }
  } catch {
    logWarning(`Original branch '${state.originalBranch}' no longer exists. Returning to '${config.baseBranch}'.`);
    await $`git checkout ${config.baseBranch}`;
  }

  await clearState();
  logSuccess("Operation complete.");
  if (state.command === 'sync' || state.command === 'restack') {
    logSuggestion("Run 'gss push' to update your remote branches.");
  }
}

// --- Initialization ---
async function initializeConfig() {
  try {
    const cacheContent = await fs.readFile(configCacheFile, 'utf-8');
    const cache = JSON.parse(cacheContent);
    if (cache.baseBranch && cache.ghUser && cache.ghRepo) {
      config.baseBranch = cache.baseBranch;
      config.ghUser = cache.ghUser;
      config.ghRepo = cache.ghRepo;
      return;
    }
  } catch (error) {
    // Cache is invalid or doesn't exist, proceed to fetch
  }

  logStep('Initializing configuration (first run or cache is invalid)...');
  try {
    const { stdout } = await $`gh repo view --json owner,name,defaultBranchRef --jq '{ "owner": .owner.login, "name": .name, "base": .defaultBranchRef.name }'`;
    const repoInfo = JSON.parse(stdout);

    if (!repoInfo.owner || !repoInfo.name || !repoInfo.base) {
      throw new Error("Failed to parse repository details from GitHub.");
    }

    config.ghUser = repoInfo.owner;
    config.ghRepo = repoInfo.name;
    config.baseBranch = repoInfo.base;

    const cachePayload = {
      baseBranch: config.baseBranch,
      ghUser: config.ghUser,
      ghRepo: config.ghRepo,
    };
    await fs.writeFile(configCacheFile, JSON.stringify(cachePayload, null, 2));
    logSuccess('Configuration cached for future runs.');
  } catch (error) {
    logError('Could not determine GitHub repository context.');
    logInfo("Please ensure you are inside a Git repository with a remote named 'origin' pointing to GitHub, and that you have run 'gh auth login'.");
    process.exit(1);
  }
}

// --- Commands ---

async function cmdCreate(branchName?: string) {
  if (!branchName) {
    logError('Branch name is required.');
    logInfo('Usage: gss create <branch-name>');
    process.exit(1);
  }

  const parentBranch = await getCurrentBranch();

  try {
    await $`git checkout -b ${branchName}`;
  } catch {
    await guardDirtyState(); // provide a better error message if checkout fails due to dirty state
    logError(`Could not create branch '${branchName}'. It might already exist.`);
    process.exit(1);
  }

  await setParentBranch(branchName, parentBranch);
  logSuccess(`Created and checked out new branch '${branchName}' (parent: '${parentBranch}').`);
  logSuggestion(`Add commits or run 'gss create <next-branch>' to extend the stack.`);
}

async function cmdUp() {
  await guardContext('up');
  await guardDirtyState();
  const children = await getChildBranches(await getCurrentBranch());
  if (children.length > 1) {
    logWarning("Fork detected. Multiple child branches found. Checking out the first one.");
  }
  if (children.length > 0) {
    await $`git checkout ${children[0]}`;
    logSuccess(`Checked out child branch: ${children[0]}`);
  } else {
    logWarning("No child branch found. You are at the top of the stack.");
  }
}

async function cmdDown() {
  await guardContext('down');
  await guardDirtyState();
  const parent = await getParentBranch(await getCurrentBranch());
  if (parent) {
    await $`git checkout ${parent}`;
    logSuccess(`Checked out parent branch: ${parent}`);
  } else {
    logWarning("No parent branch found. You are at the bottom of the stack.");
  }
}

async function cmdPush() {
  await guardContext('push');
  await guardDirtyState();
  logStep("Collecting all branches in the stack...");
  const branchesToPush = (await getFullStack()).reverse();

  if (branchesToPush.length === 0) {
    logError("No stack branches found to push.");
    process.exit(1);
  }

  console.log("Will force-push the following branches:");
  branchesToPush.forEach(b => logInfo(b));

  if (await confirm("Are you sure?")) {
    logStep("Pushing with --force-with-lease...");
    await $`git push origin ${branchesToPush} --force-with-lease`;
    logSuccess("All branches pushed.");
  } else {
    logWarning("Push cancelled.");
  }
}

async function cmdSubmit() {
  await guardContext('submit');
  await checkGhAuth();
  await guardDirtyState();
  logStep("Syncing stack with GitHub...");

  const stack = await getFullStack();

  for (const branchName of stack) {
    const prNumber = await getPrNumber(branchName);
    if (prNumber) {
      logInfo(`PR #${prNumber} already exists for branch '${branchName}'.`);
      continue;
    }

    const parent = await getParentBranch(branchName) || config.baseBranch;
    const commitCount = parseInt((await $`git rev-list --count ${parent}..${branchName}`).stdout);

    if (commitCount === 0) {
      logWarning(`Skipping PR for '${branchName}': No new commits compared to '${parent}'.`);
      continue;
    }

    logStep(`Creating PR for '${branchName}'...`);
    await $`git push origin ${branchName} --force-with-lease`;
    const prTitle = (await $`git log -1 --pretty=%s ${branchName}`).stdout.trim();

    try {
      const prResponse = JSON.parse((await $`gh api repos/${config.ghUser}/${config.ghRepo}/pulls --method POST -f title=${prTitle} -f head=${branchName} -f base=${parent}`).stdout);

      if (prResponse.number) {
        await setPrNumber(branchName, String(prResponse.number));
        logSuccess(`Created PR #${prResponse.number} for '${branchName}': ${prResponse.html_url}`);
      } else {
        throw new Error("Invalid PR creation response");
      }
    } catch (e) {
      logError(`Failed to create PR for '${branchName}'.`);
      if ((e as any).stderr) logError((e as any).stderr);
      process.exit(1);
    }
  }
  logSuccess("Stack submission complete.");
}

async function cmdSync() {
  await guardContext('sync');
  await checkGhAuth();
  await guardDirtyState();
  const originalBranch = await getCurrentBranch();

  logStep(`Syncing stack with '${config.baseBranch}' and checking for merged branches...`);
  await $`git fetch origin --quiet`;

  logInfo(`Updating local base branch '${config.baseBranch}'...`);
  await $`git checkout ${config.baseBranch}`;
  await $`git pull --ff-only origin ${config.baseBranch}`;
  logSuccess("Local base branch is up to date.");
  await $`git checkout ${originalBranch}`;

  const stack = await getFullStack();
  const mergedBranches: string[] = [];
  const unmergedBranches: string[] = [];

  for (const branch of stack) {
    let isMerged = false;
    const prNumber = await getPrNumber(branch);
    if (prNumber) {
      logInfo(`Checking status of PR #${prNumber} for branch '${branch}'...`);
      const prState = JSON.parse((await $`gh pr view ${prNumber} --json state`).stdout).state;
      if (prState === 'MERGED') {
        isMerged = true;
      }
    }

    if (!isMerged) {
      try {
        // Fallback check: is the branch an ancestor of the remote base?
        await $`git merge-base --is-ancestor ${branch} origin/${config.baseBranch}`;
        isMerged = true;
      } catch {
        // not an ancestor
      }
    }

    if (isMerged) {
      logSuccess(`Branch '${branch}' has been merged.`);
      mergedBranches.push(branch);
    } else {
      unmergedBranches.push(branch);
    }
  }

  if (unmergedBranches.length > 0) {
    logStep(`Rebasing remaining stack onto '${config.baseBranch}' with --update-refs...`);
    const topBranch = unmergedBranches[unmergedBranches.length - 1];
    const bottomBranch = unmergedBranches[0];
    const oldBase = await getParentBranch(bottomBranch) || config.baseBranch;

    await $`git checkout ${topBranch}`;

    const state: GssState = {
      command: 'sync',
      originalBranch,
      mergedBranchesToDelete: mergedBranches,
      unmergedBranches,
      finalBase: config.baseBranch
    };
    await writeState(state);

    try {
      await $`git rebase --update-refs --onto origin/${config.baseBranch} ${oldBase} ${topBranch}`;
      logSuccess("Stack rebased successfully.");
      await repairStackMetadata(config.baseBranch, unmergedBranches);
      await finishOperation();
    } catch {
      logError("Rebase conflict detected. Git has paused the rebase.");
      logInfo("Please resolve the conflicts and run 'git rebase --continue'.");
      logSuggestion("Once the git rebase is complete, run 'gss continue' to finalize.");
      process.exit(1);
    }
  } else {
    logWarning("All branches in the stack were merged. Nothing left to rebase.");
    if (mergedBranches.length > 0) {
      await writeState({ command: 'sync', originalBranch, mergedBranchesToDelete: mergedBranches });
      await finishOperation();
    }
  }
}

async function cmdList() {
  logStep("Finding all available stacks...");
  let allConfigs = '';

  try {
    allConfigs = (await $`git config --get-regexp '^branch\..*\.parent$'`).stdout.trim();
  } catch (err: unknown) {
    // Check if err is ProcessOutput
    if (err instanceof ProcessOutput) {
      // If it throws, check if it's the expected "not found" error
      if (err.exitCode !== 1) {
        // This is an unexpected error, so we should re-throw it.
        throw err;
      }
    }
  }

  if (allConfigs.length === 0) {
    logWarning("No gss stacks found.");
    return;
  }

  const childrenMap = new Map<string, string[]>();

  allConfigs.split('\n').forEach(line => {
    const match = line.match(/^branch\.(.*)\.parent (.*)$/);

    if (match) {
      const child = match[1];
      const parent = match[2];

      if (!childrenMap.has(parent)) {
        childrenMap.set(parent, []);
      }
      childrenMap.get(parent)!.push(child);
    }
  });

  const bottoms = childrenMap.get(config.baseBranch) || [];

  // Check if any stacks has a children.
  // If so, log "Found stack(s)" with all stacks having more than one children
  let foundStacks = 0;

  for (const bottom of bottoms) {
    let count = 1;
    let currentBranch = bottom;

    while (true) {
      const children = childrenMap.get(currentBranch);

      if (children) {
        currentBranch = children[0];
        count += 1;
      } else {
        break;
      }
    }

    if (count > 1) {
      if (foundStacks == 0) {
        logSuccess("Found stack(s):")
      }

      foundStacks += 1;
      logInfo(`- ${bottom} (${count} branches)`);
    }
  }

  if (foundStacks == 0) {
    logWarning("No gss stacks found.")
    logSuggestion("Run 'gss create <branch-name>' from '$BASE_BRANCH' or an existing branch to start a new stack.")
  } else {
    logSuggestion("Run 'git checkout <branch>' to switch to a stack and see its status.")
  }
}

async function cmdStatus() {
  await guardContext('status');
  await checkGhAuth();
  logStep("Gathering stack status...");
  await $`git fetch origin --quiet`;

  const stack = await getFullStack();

  console.log("");
  let needsSync = false;
  let needsPush = false;
  let needsRestack = false;

  for (const branch of stack) {
    const parent = await getParentBranch(branch) || config.baseBranch;
    const isCurrent = (await getCurrentBranch()) === branch ? ' *' : '';
    console.log(`➡️  ${branch}${isCurrent} (parent: ${parent})`);

    // Status
    let statusMessage = '';
    try {
      await $`git merge-base --is-ancestor ${parent} ${branch}`;
    } catch {
      statusMessage = chalk.yellow(`Behind '${parent}'`);
      if (parent === config.baseBranch) needsSync = true;
      else needsRestack = true;
    }

    if (!statusMessage) {
      try {
        const remoteSha = (await $`git rev-parse --quiet --verify origin/${branch}`).stdout.trim();
        const localSha = (await $`git rev-parse ${branch}`).stdout.trim();
        if (remoteSha && localSha !== remoteSha) {
          statusMessage = chalk.yellow('Needs push');
          needsPush = true;
        } else {
          statusMessage = chalk.green('Synced');
        }
      } catch {
        statusMessage = 'Not on remote';
        needsPush = true;
      }
    }
    console.log(`   ├─ Status: ${statusMessage}`);

    // PR Status
    const prNumber = await getPrNumber(branch);
    let prStatus = '';
    if (prNumber) {
      try {
        const prInfo = JSON.parse((await $`gh pr view ${prNumber} --json state,url`).stdout);
        switch (prInfo.state) {
          case 'OPEN': prStatus = chalk.green(`🟢 #${prNumber}: OPEN`); break;
          case 'MERGED': prStatus = chalk.magenta(`🟣 #${prNumber}: MERGED`); needsSync = true; break;
          case 'CLOSED': prStatus = chalk.red(`🔴 #${prNumber}: CLOSED`); break;
        }
      } catch {
        prStatus = chalk.yellow(`🟡 Could not fetch status for PR #${prNumber}`);
      }
    } else {
      prStatus = '⚪ No PR submitted';
    }
    console.log(`   └─ PR:     ${prStatus}\n`);
  }

  if (needsSync) {
    logSuggestion("Run 'gss sync' to update the base and rebase the stack.");
  } else if (needsRestack) {
    logSuggestion("Run 'gss restack' from the out-of-date branch.");
  } else if (needsPush) {
    logSuggestion("Run 'gss push' to update the remote.");
  } else {
    logSuccess("Stack is up to date.");
  }
}

async function cmdContinue() {
  const rebaseInProgress = await fs.exists(path.join(getGitRoot()!, '.git/rebase-merge'));
  if (rebaseInProgress) {
    logError("A git rebase is still in progress.");
    logSuggestion("Run 'git rebase --continue' until it is complete, then run 'gss continue'.");
    process.exit(1);
  }

  const state = await readState();
  if (!state) {
    logWarning("No gss operation to continue. Nothing to do.");
    return;
  }

  logStep(`Resuming '${state.command}' operation...`);
  if (state.command === 'sync' && state.unmergedBranches && state.finalBase) {
    await repairStackMetadata(state.finalBase, state.unmergedBranches);
  }
  if (state.command === 'restack' && state.branchesToRestack && state.restackStartBranch) {
    await repairStackMetadata(state.restackStartBranch, state.branchesToRestack);
  }
  await finishOperation();
}

async function cmdClean() {
  logWarning("This will permanently delete all gss metadata (cache, state).");
  if (await confirm("Are you sure?")) {
    await fs.rm(configCacheFile, { force: true });
    await fs.rm(stateFile, { force: true });
    logSuccess("gss metadata cleaned.");
  } else {
    logWarning("Clean cancelled.");
  }
}

async function cmdAmend() {
  await guardContext('amend');
  // Amend is a special case that should operate on staged changes
  await guardDirtyState({ allowStaged: true });

  logWarning("You are about to amend the last commit.");
  if (await confirm("Are you sure you want to continue?")) {
    logStep("Amending changes...");
    await $`git add .`;
    await $`git commit --amend --no-edit`;
    logSuccess("Commit amended successfully.");
    await cmdRestack();
  } else {
    logWarning("Amend cancelled.");
  }
}

async function cmdRestack() {
  await guardContext('restack');
  await guardDirtyState();
  const originalBranch = await getCurrentBranch();
  logStep("Checking stack integrity...");

  const fullStack = await getFullStack(originalBranch);
  let restackStartBranch: string | null = null;
  const branchesToRestack: string[] = [];
  let parentBranch = await getParentBranch(fullStack[0]) || config.baseBranch;
  let divergenceFound = false;

  for (const childBranch of fullStack) {
    if (divergenceFound) {
      branchesToRestack.push(childBranch);
      continue;
    }
    try {
      await $`git merge-base --is-ancestor ${parentBranch} ${childBranch}`;
      parentBranch = childBranch;
    } catch {
      divergenceFound = true;
      restackStartBranch = parentBranch;
      branchesToRestack.push(childBranch);
    }
  }

  if (!divergenceFound || branchesToRestack.length === 0) {
    logSuccess("Stack is internally consistent. Nothing to restack.");
    return;
  }

  logWarning(`Detected stack divergence at '${restackStartBranch}'. Restacking descendants...`);
  logInfo(`Will restack: ${branchesToRestack.join(' ')}`);

  const topBranch = branchesToRestack[branchesToRestack.length - 1];
  await $`git checkout ${topBranch}`;

  const state: GssState = { command: 'restack', originalBranch, branchesToRestack, restackStartBranch: restackStartBranch! };
  await writeState(state);

  try {
    await $`git rebase --update-refs --onto ${restackStartBranch} ${restackStartBranch} ${topBranch}`;
    logSuccess("Restack complete.");
    await repairStackMetadata(restackStartBranch!, branchesToRestack);
    await finishOperation();
  } catch {
    logError("Rebase conflict detected.");
    logSuggestion("Resolve conflicts, run 'git rebase --continue', then 'gss continue'.");
    process.exit(1);
  }
}

async function cmdPr() {
  await guardContext('pr');
  await checkGhAuth();
  const prNumber = await getPrNumber(await getCurrentBranch());
  if (prNumber) {
    logStep(`Opening PR #${prNumber} in browser...`);
    await $`gh pr view ${prNumber} --web`;
  } else {
    logError("No pull request found for the current branch.");
    logSuggestion("Run 'gss submit' to create one.");
  }
}

async function cmdTrack(subcommand: string, parent?: string) {
  const currentBranch = await getCurrentBranch();
  if (subcommand === 'set') {
    const parentBranch = parent || config.baseBranch;
    try {
      await $`git rev-parse --verify ${parentBranch}`;
    } catch {
      logError(`Parent branch '${parentBranch}' does not exist.`);
      process.exit(1);
    }
    try {
      await $`git merge-base --is-ancestor ${parentBranch} ${currentBranch}`;
    } catch {
      logError(`Invalid parent: '${parentBranch}' is not an ancestor of '${currentBranch}'.`);
      process.exit(1);
    }
    await setParentBranch(currentBranch, parentBranch);
    logSuccess(`Set parent of '${currentBranch}' to '${parentBranch}'.`);
  } else if (subcommand === 'remove') {
    await guardContext('track remove');
    const parentBranch = await getParentBranch(currentBranch);

    // Safeguard: only allow removal if the branch has no unique commits.
    const commitCount = parseInt((await $`git rev-list --count ${parentBranch}..${currentBranch}`).stdout);
    if (commitCount > 0) {
      logError(`Cannot untrack '${currentBranch}' because it contains unique commits.`);
      logSuggestion("Consider running 'gss squash' to integrate its changes.");
      process.exit(1);
    }

    await unsetParentBranch(currentBranch);
    logSuccess(`Stopped tracking '${currentBranch}'.`);
    const childBranches = await getChildBranches(currentBranch);

    for (const childBranch of childBranches) {
      logInfo(`Reparing stack: setting parent of ${childBranch} to ${parentBranch}`)
      setParentBranch(childBranch, parentBranch)
    }
  } else {
    logError(`Unknown subcommand for track: ${subcommand}. Use 'set' or 'remove'.`);
    printHelp();
    process.exit(1);
  }
}

async function cmdInsert(branchName: string, { before }: { before?: boolean } = {}) {
  if (!branchName) {
    logError("Branch name is required for insert.");
    process.exit(1);
  }
  await guardContext('insert');
  await guardDirtyState();

  const currentBranch = await getCurrentBranch();
  const parent = await getParentBranch(currentBranch);

  const insertionPoint = before ? parent : currentBranch;
  const childToReparent = before ? currentBranch : (await getChildBranches(currentBranch))[0];

  await $`git checkout -b ${branchName} ${insertionPoint}`;
  await setParentBranch(branchName, insertionPoint);
  logSuccess(`Created branch '${branchName}' on top of '${insertionPoint}'.`);

  if (childToReparent) {
    logStep(`Re-parenting and rebasing descendants of '${childToReparent}'...`);
    await setParentBranch(childToReparent, branchName);
    await cmdRestack();
  }
  await $`git checkout ${branchName}`;
}

async function cmdSquash({ into }: { into?: 'parent' | 'child' } = {}) {
  await guardContext('squash');
  await guardDirtyState();

  const direction = into || 'parent';
  const currentBranch = await getCurrentBranch();
  const parentBranch = await getParentBranch(currentBranch);
  const childBranches = await getChildBranches(currentBranch);
  const childBranch = childBranches[0]; // Assuming no forks for squash

  const targetBranch = direction === 'parent' ? parentBranch : currentBranch;
  const branchToSquash = direction === 'parent' ? currentBranch : childBranch;

  if (!targetBranch || !branchToSquash) {
    logError("Could not determine branches for squash operation.");
    process.exit(1);
  }

  logStep(`Squashing '${branchToSquash}' into '${targetBranch}'...`);
  if (await confirm("This will delete the squashed branch. Continue?")) {
    await $`git checkout ${targetBranch}`;
    await $`git merge --squash ${branchToSquash}`;

    logInfo("Please provide a commit message for the squashed changes.");
    try {
      // This is tricky to do non-interactively. We'll rely on the user having a configured editor.
      await $`git commit`;
    } catch {
      logError("Commit aborted. Undoing squash.");
      await $`git reset --hard HEAD`;
      await $`git checkout ${currentBranch}`;
      return;
    }

    const prToClose = await getPrNumber(branchToSquash);
    if (prToClose && await confirm(`Close associated PR #${prToClose} for deleted branch?`)) {
      await $`gh pr close ${prToClose}`;
    }

    const grandChild = (await getChildBranches(branchToSquash))[0];
    if (grandChild) {
      await setParentBranch(grandChild, targetBranch);
    }

    await $`git branch -D ${branchToSquash}`;
    await unsetParentBranch(branchToSquash);
    logSuccess("Squash complete.");
    if (grandChild) logSuggestion("Run 'gss restack' to update descendants.");
  } else {
    logWarning("Squash cancelled.");
  }
}


function printHelp() {
  console.log(`
gss - A tool for managing stacked Git branches with GitHub integration.

Usage: gss [options] <command> [args]

Options:
  -y, --yes              Automatically answer 'yes' to all prompts.
  -h, --help             Show this help message.

Stack & Branch Management:
  create <branch-name>   Create a new branch on top of the current one.
  track <set|remove> [parent]
                         Manually manage stack metadata.
  insert [--before] <name>
                         Insert a new branch into the stack.
  squash [--into parent|child]
                         Squash commits from one branch into another.
  up                     Navigate to the child branch in the stack.
  down                   Navigate to the parent branch in the stack.

History & Synchronization:
  amend                  Amend staged changes and restack descendants.
  restack                Update branches above after history changes.
  sync                   Syncs stack with base branch and cleans up merged branches.
  push                   Force-push all branches in the current stack to the remote.
  continue               Resume an operation after a rebase conflict.

Inspection & GitHub:
  status                 Display the status of the current branch stack.
  list|ls                List all available stacks.
  submit                 Create GitHub PRs for all branches in the stack.
  pr                     Open the GitHub PR for the current branch in your browser.

Housekeeping:
  clean                  Remove all gss metadata from the repository.
  help                   Show this help message.
    `);
}

// --- Main Execution ---
async function main() {
  const gitRoot = getGitRoot();
  if (!gitRoot) {
    logError('Not a git repository. Please run gss from within a git repository.');
    process.exit(1);
  }
  stateFile = path.join(gitRoot, '.git', 'GSS_OPERATION_STATE');
  configCacheFile = path.join(gitRoot, '.git', 'GSS_CONFIG_CACHE');

  let args = process.argv.slice(2);

  const yesFlagIndex = args.findIndex(arg => arg === '-y' || arg === '--yes');
  if (yesFlagIndex !== -1) {
    autoConfirm = true;
    args.splice(yesFlagIndex, 1);
  }

  const command = args[0];
  const commandArgs = args.slice(1);


  if (command && !['clean', 'help', '--help', '-h'].includes(command)) {
    await initializeConfig();
  }

  switch (command) {
    case 'create': await cmdCreate(commandArgs[0]); break;
    case 'up': await cmdUp(); break;
    case 'down': await cmdDown(); break;
    case 'push': await cmdPush(); break;
    case 'submit': await cmdSubmit(); break;
    case 'sync': await cmdSync(); break;
    case 'list': case 'ls': await cmdList(); break;
    case 'status': await cmdStatus(); break;
    case 'continue': await cmdContinue(); break;
    case 'clean': await cmdClean(); break;
    case 'amend': await cmdAmend(); break;
    case 'restack': await cmdRestack(); break;
    case 'pr': await cmdPr(); break;
    case 'track': await cmdTrack(commandArgs[0], commandArgs[1]); break;
    case 'insert':
      const before = commandArgs.includes('--before');
      const branchName = commandArgs.find(a => !a.startsWith('--'));
      if (branchName) await cmdInsert(branchName, { before });
      else logError("Branch name required for insert.");
      break;
    case 'squash':
      const into = commandArgs.includes('--into') ? commandArgs[commandArgs.indexOf('--into') + 1] as any : 'parent';
      await cmdSquash({ into });
      break;
    case 'help': case '--help': case '-h': case undefined:
      printHelp();
      break;
    default:
      logError(`Unknown command: ${command}`);
      printHelp();
      process.exit(1);
  }
}

main().catch(err => {
  if (err.stderr) {
    logError(err.stderr.trim());
  } else {
    logError(err.message);
  }
  process.exit(1);
});

