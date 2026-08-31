<!-- Keep this file synchronized with CHANGELOG_zh.md. -->

# Changelog

[Chinese](CHANGELOG_zh.md)

All notable changes to Auto Script for GitHub Setup and Push are documented in this file.

## 2.1.1 - 2026-08-31

### Changed

- Standardized every choose-one menu on consecutive numeric options. Account selection now uses `1`, `2`, `3`, and so on; `0` consistently returns or cancels, while direct confirmations remain explicit yes-or-no questions.
- Replaced the historical-import account menu's letter-based “add another account” option with the next available number.
- Documented the shared input rules in both README versions and added regression checks to prevent letter-based menu options from returning.

## 2.1.0 - 2026-08-31

### Added

- Added an explicit project-state phase that reports the exact repository root and current branch, preserves existing Git history, and stops safely on detached HEAD, unresolved conflicts, or unfinished Git operations.
- Added origin-aware account discovery: SSH remotes such as `git@github800:owner/repository.git` now verify that Host's configured key and GitHub username before considering other accounts.
- Added a pre-staging cancellation boundary, empty-repository handling, read-only update cancellation guarantees, and regression coverage for each of those states.
- Added `git://github.com/owner/repository.git` to the accepted repository address variants.

### Changed

- Reordered the default workflow around project state, origin, account, exact key, destination access, change review, commit, and push.
- Made existing repositories state explicitly that `git init` will not run again and that commits, branches, staged changes, and remotes are preserved.
- Made the tracked root `g.sh` operate on the central repository itself; direct `git-auto.sh` now remains the unambiguous central-management entry.
- Deduplicated SSH checks for multiple Host entries that reference the same private key.
- Reworked English and Chinese interface text to name the exact key, Host, repository, account, file, command, and write boundary involved in each decision.
- Updated both README versions to match the implemented user flow and local-state boundaries.

### Fixed

- Fixed existing repositories with a valid custom GitHub SSH Host being sent through generic account creation or prompted to create another key.
- Fixed Chinese text variables followed by full-width punctuation being parsed as different shell variable names.
- Fixed normal runs rewriting local engine-path settings during read-only detection or update cancellation.
- Fixed the central repository's tracked `g.sh` being treated like an ignored project-only launcher.

## 2.0.0 - 2026-08-31

### Added

- Added `git-auto.sh` as the single complete central engine shared by every project.
- Added a tracked, generic root `g.sh` that can be copied directly from the public repository without containing a personal path or account value.
- Added automatic generation and repair of small project-local `g.sh` launchers that preserve the four-command interface and pass the exact launcher folder as the project root.
- Added a bilingual central management menu for launcher creation, shared account setup and repair, preferences, and advanced tools.
- Added the ignored `private/config.txt` profile for language, display mode, and all shared GitHub account metadata.
- Added owner-only permissions for the private directory and configuration file.
- Added explicit missing-engine guidance when a central folder has moved.

### Changed

- Replaced the duplicated public/personal executable model with one public central engine and one private text configuration.
- Moved all personalized values out of executable code; account updates and preferences no longer modify `git-auto.sh` or project launchers.
- Made the root `g.sh` public and trackable, while project copies created by the central menu remain local through `.git/info/exclude`.
- Moved resolved central paths into each target repository's local `.git/config`, keeping the public launcher generic.
- Separated central engine location, target project location, and private configuration location throughout the implementation.
- Migrated the existing ignored personal accounts into `private/config.txt` without changing SSH keys or repository bindings.
- Rewrote both README versions around the centralized installation and everyday project workflow.

### Removed

- Removed the `dist/` directory and the full personalized script copy.
- Removed account and preference fields from the top of executable scripts.

## 1.2.0 - 2026-08-31

### Added

- Added one-time interface language initialization on the first interactive run, with English as the default and fully localized Chinese as the alternative.
- Added a menu option for changing the saved interface language later.
- Localized the complete standard, update, and advanced workflows so every prompt, explanation, warning, and error follows one consistent saved language.

### Changed

- Renamed the standard public and personal distribution files from `go.sh` to `g.sh`; the script can still be renamed freely after copying.
- Moved interface language and display preferences into clear, human-editable fields at the top of the self-contained script.
- Removed the application-specific preference directory; the script now keeps its own preferences without creating another local configuration folder.
- Made the update and advanced workflows reuse the saved interface language instead of asking independently.

## 1.1.0 - 2026-08-31

### Added

- Added `./g.sh update` as the fourth public command for GitHub username changes, repository renames or transfers, and combined changes.
- Added an English-default, fully localized Chinese guided update flow that asks only for information relevant to the selected change.
- Added pre-write verification of the existing key's new GitHub username and access to the exact new repository.
- Added automatic reuse of the existing account key, collision-safe creation of a new username-based SSH alias, and preservation of the old alias for other local repositories.
- Added automatic migration of the visible account entry, noreply email suggestion, repository-local commit identity, saved strict-key binding, and both fetch and push URLs for `origin`.
- Added personal-owner migration when the repository owner matched the old username, while preserving organization ownership and accepting complete GitHub addresses for moved repositories.

### Fixed

- Fixed false "script is inside another repository" errors on macOS when the script directory and Git reported the same physical folder using different path spelling, case, or an equivalent system prefix.

## 1.0.0 - 2026-08-31

### Added

- Added the three-command interface: `./g.sh`, `./g.sh new`, and `./g.sh menu`.
- Added automatic discovery of existing GitHub SSH identities from `~/.ssh/config` and `Include` files.
- Added one dedicated ED25519 key per GitHub account with automatic `github-USERNAME` alias collision handling.
- Added verification of the actual GitHub username authenticated by a key before saving an account or repository binding.
- Added current-format noreply commit email suggestions derived from the public GitHub account ID.
- Added repository-local binding to one account, email, SSH alias, and private key.
- Added a temporary SSH wrapper that pins every network Git operation to one private key.
- Added support for personal repositories, organization-owned repositories, and repository account switching.
- Added normalization for `owner/repository`, HTTP, HTTPS, SSH, repository-page URLs, and common clone command input.
- Added version discovery from `package.json`, primary changelogs, language changelogs, recursive changelogs, and `VERSION*` files.
- Added changelog support for top-first and bottom-first ordering, multiple date formats, prereleases, build metadata, and Unicode dashes.
- Added automatic dark and light appearance detection with high-contrast and colorless modes.
- Added script renaming, safe self-updates of the account block, and repository-local self-exclusion.
- Kept the script fully self-contained by using Git's tracked state instead of a companion source marker.
- Added a bilingual advanced menu, with English as its default, without adding another public command.
- Added guided reconstruction of linear Git history from complete historical release folders sorted by SemVer.
- Added full-snapshot replacement that preserves hidden and ignored files while excluding `.git` and `.DS_Store` at every depth.
- Added reliable changelog-date reuse, optional lightweight `vX.Y.Z` tags, and explicit handling for identical snapshots.
- Added a direct terminal editor for supplying `.gitignore` content only to historical snapshots that lack it.
- Added preflight detection for sensitive-looking files and files too large for a normal GitHub push.
- Added empty-remote publishing and explicitly confirmed remote `main` replacement with an exact force-with-lease and no automatic backup branch.
- Replaced emoji status symbols with plain text labels throughout the user interface.
- Added an isolated test suite with temporary home directories, Git repositories, simulated SSH transport, and a strict push test.

### Documentation

- Added an en-US `README.md` written for public repository visitors.
- Added a synchronized Chinese `README_zh.md`.
- Added reciprocal language links for both README and changelog files.
