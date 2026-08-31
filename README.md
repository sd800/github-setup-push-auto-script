<!-- Keep this file synchronized with README_zh.md. -->

# Auto Script for GitHub Setup and Push

[Chinese](README_zh.md)

Auto Script for GitHub Setup and Push is a centralized Bash utility for anyone who wants a shorter, safer path from local changes to a verified GitHub push. A small `git-auto.sh` dispatcher loads the central implementation from `src/`, while each project uses the same small `g.sh` interface.

The everyday interface stays deliberately small:

- `./g.sh`: Detect the current Git repository, verify its GitHub account and destination, review changes, commit, and push.
- `./g.sh new`: Add or import a GitHub account, then optionally use it for the current project.
- `./g.sh update`: Synchronize local settings after a GitHub username or repository name changes.
- `./g.sh menu`: Open tool menu for account, project verification, preference, and advanced features.

SSH identities, account verification, repository-specific authorship, release commit messages, upstream branches, and strict push identity are handled behind this interface.

## Architecture

The project uses one modular central program, one private profile, and one launcher per working project:

```text
git-auto/
|-- git-auto.sh       small central dispatcher
|-- g.sh              public copy-ready lightweight launcher
|-- src/              central Bash implementation
|   |-- 00-core.sh
|   |-- 10-ssh.sh
|   |-- 20-repository.sh
|   |-- 30-workflow.sh
|   |-- 40-history.sh
|   |-- 50-update.sh
|   `-- 60-menu.sh
|-- README.md
|-- README_zh.md
|-- CHANGELOG.md
|-- CHANGELOG_zh.md
|-- tests/
`-- private/          local only; created automatically and ignored by Git
    `-- config.txt

your-project/
|-- g.sh              generated lightweight launcher; locally ignored
`-- project files...
```

`git-auto.sh` only locates and loads the required modules beside it. The modules divide configuration and interface behavior, SSH identity handling, repository parsing, normal push workflow, historical import, rename synchronization, and menus. Missing modules stop the program before the workflow starts and identify the exact missing file.

The dispatcher and `src/` folder form one central installation and must be moved or copied together. They remain self-contained Bash code with no package dependency, no public/personal script pair, and no duplicated account block inside executable code. Updating this central installation updates the behavior used by every launcher.

## First-time setup

Place the public project wherever you want to keep the central engine, then run:

```bash
chmod +x git-auto.sh
./git-auto.sh
```

The first interactive run asks for the interface language once and records it in `private/config.txt`. The central menu can copy `g.sh` into a selected project. The repository also includes the same public, copy-ready launcher, so a manual copy works too:

```bash
cp g.sh /path/to/your-project/g.sh
```

After that, move to the project and use only the short commands:

```bash
./g.sh
./g.sh new
./g.sh update
./g.sh menu
```

No shell alias, PATH change, package installation, or application-specific home configuration directory is required. Run the tracked root `./g.sh` when this central repository itself needs to be committed and pushed.

## Central management menu

Running `./git-auto.sh` from the central folder opens the management menu. It can:

- Create or repair `g.sh` for a selected project.
- Add a GitHub account to the shared private profile.
- Verify the SSH key used by each saved GitHub account and offer an exact recovery step when verification fails.
- Change the shared interface language or display mode.
- Open advanced tools, including historical release import.

Running `./git-auto.sh new` from the central folder goes directly to account setup. Direct `./git-auto.sh` is reserved for central management; project operations, including operations on the central repository itself, use `./g.sh`.

## Lightweight project launcher

The public `g.sh` contains no GitHub account, SSH, version, commit, or history-building logic. It treats its own folder as the project root and locates the central engine automatically: project-local Git settings first, then the same folder, a neighboring or ancestor-level `git-auto/` folder, common home locations, and `PATH`. Only when all of those choices fail does it ask for the `git-auto.sh` path.

The root `g.sh` is tracked and is never placed in this repository's ignore rules. When the central menu copies it into another project, only that project copy is added to `.git/info/exclude`; the project's shared `.gitignore` is not changed. After a project is configured successfully, the resolved central path is remembered in that project's local `.git/config`. The launcher itself remains generic and contains no personal path.

If the central folder moves, the launcher searches again and can accept a pasted path in English or Chinese. The central menu can also repair project launchers; no project data or account configuration needs to be rebuilt.

## Private configuration

All personalized application state lives in the ignored `private/config.txt` file next to `git-auto.sh`:

```text
language: en
display-theme: auto

username: johnjoe
email: 123456+johnjoe@users.noreply.github.com

username: alice
email: alice@example.com
```

Every field has its own line, and a blank line separates accounts. Each account has only a GitHub username and commit email. Commit display names are always derived from GitHub usernames.

Historical-release version tags are disabled by default. Enabling them under Advanced features adds this optional line:

```text
add-tags-to-historical-release: enabled
```

Turning the setting off removes the entire line from `private/config.txt`.

The central engine creates `private/` with owner-only directory permissions and `config.txt` with owner-only file permissions. It writes changes atomically and never places private keys, passphrases, access tokens, or passwords in this file.

Every user of the public project gets an independent ignored `private/` folder. Personalized executable copies are not needed.

## Simple input rules

- Menus with eight or fewer items use `1` through `8`.
- Longer lists keep `1` through `8`, then use `a b c d e f g h j k m n p r`. GitHub accounts are sorted alphabetically without regard to letter case before these labels are assigned.
- When a list needs more than one page, use `x` for the previous page and `y` for the next page. The letters `s` and `w` are reserved for future features; `i`, `l`, `o`, `q`, `t`, `u`, and `v` are never used as choices.
- In an account list, "Add another account" uses `9` while there are eight or fewer saved accounts and `z` after that.
- Enter `0`, always shown last, to return or cancel without selecting an item.
- When the script asks whether to perform one clearly described action, answer the displayed yes-or-no question instead of memorizing another menu number.

## What happens when you run g.sh

The default workflow follows the state of the project:

1. Treat the folder containing `g.sh` as the exact project root.
2. Detect an existing Git repository before doing anything else. Existing commits, branches, staged changes, and remotes are preserved, and `git init` is not run again. If no repository exists, the script explains that `git init` creates local metadata only, then initializes it.
3. Stop before changing files when HEAD is detached, merge conflicts remain, or a merge, rebase, cherry-pick, or revert is unfinished.
4. Read `origin` to determine the exact GitHub `owner/repository`. Ask for a repository address only when `origin` does not identify one.
5. Use only the account whose username matches the repository owner. A mismatched saved account, default `github.com` key, or earlier account choice is ignored and corrected; if the owner account has not been configured, request only its commit email and finish its SSH setup.
6. Show the owner account followed by the destination repository, check the endpoint with that account's verified key, then save the repository-local settings. The script explains that this read-only response is not a separate proof of push permission; `git push` provides the final permission check.
7. Show `git status --short` before staging. The user can accept the suggested commit message, replace it, or enter `:cancel`. Only after that decision does the script run `git add -A`.
8. Create the commit, show what it contains, and push the current branch with the one verified key. Ordinary pushes never use force.

A clean repository creates no unnecessary commit. An empty repository with no project files stops without attempting a push. Canceling at the commit prompt happens before `git add -A` and preserves any changes that were already staged.

## GitHub account setup

Inside a project with a recognizable GitHub `origin`, `./g.sh new` derives the required username from the repository owner and never offers another account. Outside such a project, the central account menu can add any personal account. SSH setup follows these rules:

1. In a project, request only the owner account's commit email when that account is not already saved.
2. Scan `~/.ssh/config` and its `Include` files for concrete entries whose effective `HostName` is `github.com`.
3. Resolve each distinct candidate key once and ask GitHub which username it authenticates as.
4. Reuse a key only when the verified username exactly matches the required account.
5. If no reusable identity exists, show the exact key path and SSH Host that would be added.
6. Create a dedicated ED25519 key only after confirmation, guide the user through adding its public key to the correct GitHub account, and verify the returned username before saving the account.

New SSH Host names use `github-USERNAME`. Collisions are handled automatically with `-1`, `-2`, and later numbers. Each newly created account receives a different private key; an existing key is reused only after GitHub confirms the exact username. A failed network check does not silently create a replacement key: the result is shown and the user can retry first.

The suggested private commit email uses GitHub's current `ID+USERNAME@users.noreply.github.com` form. Any email already verified by GitHub can be entered instead.

## Multiple-account protection

The shared private profile makes configured accounts available to every project, but each repository uses only the account whose username matches the repository owner.

Repository-specific values remain only in that repository's `.git/config`: username, email, SSH alias, identity file, and normalized `origin`. Before each network operation, a temporary SSH wrapper enables `IdentitiesOnly=yes` and pins the selected private key. Other agent-loaded keys cannot silently become fallback identities.

This strict owner-account workflow intentionally stops when `owner/repository` belongs to a different username. It never treats the ability to read a public repository as permission to bind or push it from another configured account.

## Repository address input

Repository prompts accept and normalize common GitHub forms:

```text
owner/repository
owner/repository.git
github.com/owner/repository
https://github.com/owner/repository
https://github.com/owner/repository/tree/main
https://github.com/owner/repository/blob/main/README.md
git@github.com:owner/repository.git
ssh://git@github.com/owner/repository.git
git://github.com/owner/repository.git
git clone https://github.com/owner/repository.git
gh repo clone owner/repository
```

Query strings, fragments, trailing slashes, `.git`, and repository page paths are removed. Non-GitHub URLs are rejected rather than rewritten silently.

## Username or repository changes

After completing a username change or repository rename on GitHub, run `./g.sh update` in the affected project.

The flow assumes the change is already complete on GitHub. It asks what changed and requests only the relevant new information. The repository owner is always kept equal to the account username; a pasted URL under another owner is rejected. Before writing anything, it verifies that the existing key now authenticates as the new username and that the renamed repository responds to that key. A final review lists every local file and Git setting that will change.

Username changes reuse the existing key, create a collision-safe username-based SSH Host when needed, preserve the previous Host for other projects, update the shared private account entry, and synchronize this repository's author and both `origin` URLs. Project files, branches, commits, and the GitHub repository are not modified or pushed. Canceling the final review leaves `private/config.txt`, `~/.ssh/config`, and the repository's `.git/config` unchanged.

## Commit messages and release versions

Every real commit remains user-confirmed. The engine shows the working-tree status and proposes a message before it stages all changes. A detected release version always produces `Release X.Y.Z`, including when the repository has no earlier commit; `Initial commit` is used only when that first snapshot has no detectable version. After confirmation the script runs `git add -A`, shows the staged summary, and creates the commit.

For every commit, including the first one, release versions are discovered in this order:

1. A valid root `package.json` version.
2. Root `CHANGELOG`, `CHANGELOG.md`, or `CHANGELOG.txt`.
3. Other root `CHANGELOG*` language variants, using the highest valid version when they disagree.
4. When no usable root changelog exists, recursive project-owned `CHANGELOG*` files, using the highest valid version.
5. Root `VERSION*` files.
6. Recursive `VERSION*` files.
7. The fallback message `Update`.

Parsing supports newest-first and oldest-first changelogs, common English and Chinese dates, prereleases, build metadata, optional `v` prefixes, brackets, and Unicode dash variants. Dependency, cache, environment, build, and coverage directories are excluded from recursive changelog discovery.

## Historical release import

The advanced menu can reconstruct linear Git history from complete release folders that do not have useful Git history.

It discovers or accepts version mappings, sorts them by SemVer, and builds one complete `Release X.Y.Z` snapshot commit per version in a temporary repository. Files removed by a later release disappear from that later snapshot. Normal hidden files and ignored files are preserved, while `.git` and `.DS_Store` are excluded at every depth.

When archived releases lack a root `.gitignore`, the user can paste one shared set of rules directly into the terminal. It is added only to missing reconstructed snapshots and never written back to the source folders.

The flow checks for sensitive-looking and oversized files, displays `git log --oneline --reverse`, and verifies the selected GitHub identity before publishing. Reconstructed commit timestamps use reliable detected release dates by default. The user can decline; in that case, no historical dates are assigned and each commit keeps the local system time that Git records automatically when creating it.

Matching lightweight `vX.Y.Z` tags are disabled by default. They can be enabled under Advanced features, appear on GitHub's Tags page, and do not change file contents. Replacing an existing remote `main` requires explicit confirmation and an exact `--force-with-lease`. No backup branch is created, and other remote branches are unchanged.

The engine implements snapshot copying itself and does not depend on `rsync`.

## Language, display, and accessibility

English is the first-run default; Chinese is fully localized. The selected language applies consistently to project commands, central management, update flows, advanced tools, explanations, warnings, and errors. It can be changed from either menu.

Display mode supports automatic, dark, light, and colorless output. Automatic mode uses terminal background information and the macOS appearance setting when available. `NO_COLOR` and noninteractive output disable color.

The interface uses plain text status labels and no emoji symbols.

## Security and local state

The engine writes only to locations required by the requested workflow:

- `private/config.txt` for shared personal preferences and account metadata.
- `~/.ssh` for GitHub SSH keys and configuration.
- The selected repository's `.git/config` and `.git/info/exclude` for local binding and launcher exclusion.
- Temporary directories for strict SSH wrappers and historical reconstruction.

The script does not use any other application-specific configuration directory. It creates or edits `~/.ssh` only when SSH identity work is explicitly part of the selected flow, and it shows the exact new key and Host before creation. Private keys are never copied into the central project or `private/config.txt`. Ordinary pushes never use force. Source release folders are never changed by historical import.

## Requirements and testing

- Bash 3.2 or later.
- Git and OpenSSH tools: `git`, `ssh`, and `ssh-keygen`.
- Standard POSIX/macOS utilities used by the single Bash engine.
- Network access to GitHub for identity and repository verification.

Run the isolated test suite with:

```bash
./tests/test.sh
```

Tests use temporary home folders, private profiles, Git repositories, SSH configuration, and simulated SSH transport. They do not use the real private profile or modify real GitHub repositories.

## License

No license has been declared yet. Add one before assuming reuse rights beyond what copyright law permits.
