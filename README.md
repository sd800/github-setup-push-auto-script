<!-- Keep this file synchronized with README_zh.md. -->

# Auto Script for GitHub Setup and Push

[Chinese](README_zh.md)

Auto Script for GitHub Setup and Push is a centralized Bash utility for anyone who wants a shorter, safer path from local changes to a verified GitHub push. One `git-auto.sh` engine manages the full workflow, while each project needs only a tiny local `g.sh` launcher.

The everyday interface stays deliberately small:

- `./g.sh`: Set up the current project when needed, then commit and push.
- `./g.sh new`: Add or import a GitHub account, then optionally connect the current project.
- `./g.sh update`: Synchronize local settings after a GitHub username, repository name, or repository owner changes.
- `./g.sh menu`: Open account, repair, preference, and advanced tools.

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

`git-auto.sh` is the only full implementation. There is no public/personal script pair and no duplicated account block inside executable code. Updating the central engine updates the behavior used by every generated launcher.

## First-time setup

Place the public project wherever you want to keep the central engine, then run:

```bash
chmod +x git-auto.sh
./git-auto.sh
```

The first interactive run asks for the interface language once and creates `private/config.txt`. The central menu can create a project's lightweight `g.sh` automatically. The repository also includes a public, copy-ready `g.sh`, so manual copy and paste works too:

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

No shell alias, PATH change, package installation, or application-specific home configuration directory is required.

## Central management menu

Running `./git-auto.sh` from the central folder opens the management menu. It can:

- Create or repair `g.sh` for a selected project.
- Add a GitHub account to the shared private profile.
- Check and repair configured GitHub SSH identities.
- Change the shared interface language or display mode.
- Open advanced tools, including historical release import.

Running `./git-auto.sh new` from the central folder goes directly to account setup. Project-specific operations remain on the local `g.sh` interface.

## Lightweight project launcher

The public `g.sh` contains no GitHub account, SSH, version, commit, or history-building logic. It determines its own project folder and locates the central engine automatically: project-local Git settings first, then a neighboring or ancestor-level `git-auto/` folder, common home locations, and `PATH`. Only when all automatic choices fail does it ask for the `git-auto.sh` path.

The root `g.sh` is part of this public repository and is not ignored. When the central menu copies it into another project, that project copy is added to `.git/info/exclude` without changing the project's shared `.gitignore`. The resolved central path is remembered only in that project's local `.git/config`; the launcher itself remains generic and safe to publish.

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

## What happens when you run g.sh

The default workflow is ordered around decisions a user understands:

1. Use the launcher folder as the exact project root.
2. Initialize Git if the folder is not already a repository.
3. Load shared accounts from the central private profile.
4. Ask for a repository only when no recognizable `origin` exists.
5. Select an obvious matching account automatically or show only configured usernames.
6. Verify the exact private key, authenticated GitHub username, and repository access before saving a binding.
7. Stage changes and show a proposed commit message.
8. Create a commit only after confirmation.
9. Push the current branch with the verified account and key.

Completed setup is recognized and skipped. A canceled or failed identity check does not write a partial repository binding.

## GitHub account setup

`./g.sh new` and the central account menu follow the same guided process:

1. Scan `~/.ssh/config` and its `Include` files for entries whose effective `HostName` is `github.com`.
2. Resolve each candidate key and ask GitHub which username it authenticates as.
3. Offer to import a verified account that is not yet in `private/config.txt`.
4. If no reusable identity exists, ask only for the GitHub username and commit email.
5. Create a dedicated ED25519 key and collision-safe SSH entry.
6. Guide the user through adding the public key to the correct GitHub account.
7. Verify GitHub authentication before saving the account.

New aliases use `github-USERNAME`. Collisions are handled automatically with `-1`, `-2`, and later numbers. Each newly created account receives a different private key; an existing verified key is reused instead of duplicated.

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
git clone https://github.com/owner/repository.git
gh repo clone owner/repository
```

Query strings, fragments, trailing slashes, `.git`, and repository page paths are removed. Non-GitHub URLs are rejected rather than rewritten silently.

## Username or repository changes

After completing a username change, repository rename, or repository transfer on GitHub, run `./g.sh update` in the affected project.

The flow asks what changed and requests only the relevant new information. It verifies that the existing key now authenticates as the new username and that the account can access the exact new repository. Username changes reuse the existing key, create a collision-safe new alias, preserve the old alias for other projects, update the shared private account entry, and synchronize this repository's author and both `origin` URLs.

Project files, branches, and commit history are not modified by this update flow.

## Commit messages and release versions

Every real commit remains user-confirmed. The engine proposes a message after showing the staged summary.

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

Private keys are never copied into the central project or `private/config.txt`. Ordinary pushes never use force. Source release folders are never changed by historical import.

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
