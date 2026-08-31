<!-- Keep this file synchronized with README_zh.md. -->

# Auto Script for GitHub Setup and Push

[Chinese](README_zh.md)

Auto Script for GitHub Setup and Push is a centralized Bash utility for anyone who wants a shorter, safer path from local changes to a verified GitHub push. One `git-auto.sh` engine handles the detailed workflow, while each project uses the same small `g.sh` interface.

The everyday interface stays deliberately small:

- `./g.sh`: Detect the current Git repository, verify its GitHub account and destination, review changes, commit, and push.
- `./g.sh new`: Add or import a GitHub account, then optionally use it for the current project.
- `./g.sh update`: Synchronize local settings after a GitHub username, repository name, or repository owner changes.
- `./g.sh menu`: Open account, project verification, preference, and advanced tools.

SSH identities, account verification, repository-specific authorship, release commit messages, upstream branches, and strict push identity are handled behind this interface.

## Architecture

The project uses one engine, one private profile, and one launcher per working project:

```text
git-auto/
|-- git-auto.sh
|-- g.sh              public copy-ready lightweight launcher
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

`git-auto.sh` is the only full implementation. There is no public/personal script pair and no duplicated account block inside executable code. Updating the central engine updates the behavior used by every launcher.

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

The central engine creates `private/` with owner-only directory permissions and `config.txt` with owner-only file permissions. It writes changes atomically and never places private keys, passphrases, access tokens, or passwords in this file.

Every user of the public project gets an independent ignored `private/` folder. Personalized executable copies are not needed.

## Simple input rules

- When the script asks you to choose one item from a list, enter its displayed number: `1`, `2`, `3`, and so on.
- Enter `0` to return or cancel without selecting an item.
- When the script asks whether to perform one clearly described action, answer the displayed yes-or-no question instead of memorizing another menu number.

## What happens when you run g.sh

The default workflow follows the state of the project:

1. Treat the folder containing `g.sh` as the exact project root.
2. Detect an existing Git repository before doing anything else. Existing commits, branches, staged changes, and remotes are preserved, and `git init` is not run again. If no repository exists, the script explains that `git init` creates local metadata only, then initializes it.
3. Stop before changing files when HEAD is detached, merge conflicts remain, or a merge, rebase, cherry-pick, or revert is unfinished.
4. Read `origin`. If it uses an SSH Host such as `github800`, verify that Host's exact key and GitHub username first. Ask for a repository address only when `origin` does not identify one.
5. Prefer the repository's saved account, then a verified origin account, then an unambiguous owner match. Show a username choice only when no safe automatic match exists.
6. Confirm read access to the exact destination with the selected private key, then save only repository-local author, identity, engine path, and `origin` settings.
7. Show `git status --short` before staging. The user can accept the suggested commit message, replace it, or enter `:cancel`. Only after that decision does the script run `git add -A`.
8. Create the commit, show what it contains, and push the current branch with the one verified key. Ordinary pushes never use force.

A clean repository creates no unnecessary commit. An empty repository with no project files stops without attempting a push. Canceling at the commit prompt happens before `git add -A` and preserves any changes that were already staged.

## GitHub account setup

`./g.sh new` and the central account menu use the same account rules:

1. When the current project has an SSH `origin` whose verified account has not been saved yet, check that Host and key first. If GitHub confirms the account, only the commit email is requested.
2. Otherwise scan `~/.ssh/config` and its `Include` files for concrete entries whose effective `HostName` is `github.com`.
3. Resolve each distinct candidate key once and ask GitHub which username it authenticates as.
4. Offer to save a verified account that is not yet in `private/config.txt`.
5. If no reusable identity exists, ask for the GitHub username and commit email, then show the exact key path and SSH Host that would be added.
6. Create a dedicated ED25519 key only after confirmation, guide the user through adding its public key to the correct GitHub account, and verify the returned username before saving the account.

New SSH Host names use `github-USERNAME`. Collisions are handled automatically with `-1`, `-2`, and later numbers. Each newly created account receives a different private key; an existing key is reused only after GitHub confirms the exact username. A failed network check does not silently create a replacement key: the result is shown and the user can retry first.

The suggested private commit email uses GitHub's current `ID+USERNAME@users.noreply.github.com` form. Any email already verified by GitHub can be entered instead.

## Multiple-account protection

The shared private profile makes configured accounts available to every project, but each repository still uses exactly one account for a push.

Repository-specific values remain only in that repository's `.git/config`: username, email, SSH alias, identity file, and normalized `origin`. Before each network operation, a temporary SSH wrapper enables `IdentitiesOnly=yes` and pins the selected private key. Other agent-loaded keys cannot silently become fallback identities.

Organization repositories are bound to a selected personal account; the organization name is never treated as a login identity.

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

After completing a username change, repository rename, or repository transfer on GitHub, run `./g.sh update` in the affected project.

The flow assumes the change is already complete on GitHub. It asks what changed and requests only the relevant new information. Before writing anything, it verifies that the existing key now authenticates as the new username and that the account can read the exact renamed or transferred repository. A final review lists every local file and Git setting that will change.

Username changes reuse the existing key, create a collision-safe username-based SSH Host when needed, preserve the previous Host for other projects, update the shared private account entry, and synchronize this repository's author and both `origin` URLs. Project files, branches, commits, and the GitHub repository are not modified or pushed. Canceling the final review leaves `private/config.txt`, `~/.ssh/config`, and the repository's `.git/config` unchanged.

## Commit messages and release versions

Every real commit remains user-confirmed. The engine shows the working-tree status and proposes a message before it stages all changes. After confirmation it runs `git add -A`, shows the staged summary, and creates the commit.

For an existing repository, release versions are discovered in this order:

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

The flow checks for sensitive-looking and oversized files, offers lightweight version tags, displays `git log --oneline --reverse`, and verifies the selected GitHub identity before publishing. Replacing an existing remote `main` requires explicit confirmation and an exact `--force-with-lease`. No backup branch is created, and other remote branches are unchanged.

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
