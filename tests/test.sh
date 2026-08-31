#!/usr/bin/env bash

set -uo pipefail

TEST_DIRECTORY="$({ cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P; } || exit 1)"
PROJECT_DIRECTORY="$(dirname "$TEST_DIRECTORY")"
TEST_TEMPORARY="$(mktemp -d "${TMPDIR:-/tmp}/github-auto-tests.XXXXXX")"
TEST_COUNT=0
FAILURE_COUNT=0

cleanup() {
  rm -rf "$TEST_TEMPORARY"
}
trap cleanup EXIT

export HOME="$TEST_TEMPORARY/home"
export NO_COLOR=1
export GITHUB_AUTO_TESTING=1
export GIT_AUTO_PRIVATE_DIRECTORY="$TEST_TEMPORARY/private"
mkdir -p "$HOME/.ssh/config.d"

# shellcheck source=../git-auto.sh
source "$PROJECT_DIRECTORY/git-auto.sh"

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'ok %s - %s\n' "$TEST_COUNT" "$1"
}

fail_test() {
  TEST_COUNT=$((TEST_COUNT + 1))
  FAILURE_COUNT=$((FAILURE_COUNT + 1))
  printf 'not ok %s - %s\n' "$TEST_COUNT" "$1"
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail_test "$label (expected '$expected', got '$actual')"
  fi
}

assert_true() {
  local label="$1"
  shift

  if "$@"; then
    pass "$label"
  else
    fail_test "$label"
  fi
}

test_accounts() {
  assert_equal "0" "$ACCOUNT_COUNT" "new private configuration starts without accounts"
}

test_prompt_values() {
  local value=""

  value="$(prompt_value "test" "recommended" 2>/dev/null <<< "")"
  assert_equal "recommended" "$value" "Enter accepts the recommended value without prompt text contamination"

  value="$(prompt_value "test" "recommended" 2>/dev/null <<< "custom")"
  assert_equal "custom" "$value" "custom input is returned cleanly"
}

test_repository_parser() {
  local value=""
  local variants=(
    "octocat/repo"
    "octocat/repo.git"
    "github.com/octocat/repo"
    "www.github.com/octocat/repo/"
    "https://github.com/octocat/repo.git"
    "https://www.github.com/octocat/repo/tree/main"
    "https://github.com/octocat/repo/blob/main/README.md?plain=1#top"
    "git://github.com/octocat/repo.git"
    "git@github.com:octocat/repo.git"
    "ssh://git@github.com/octocat/repo.git"
    "ssh://git@ssh.github.com:443/octocat/repo.git"
    "git clone https://github.com/octocat/repo.git"
    "gh repo clone octocat/repo"
  )

  for value in "${variants[@]}"; do
    if parse_repository_input "$value"; then
      assert_equal "octocat/repo" "$REPOSITORY_OWNER/$REPOSITORY_NAME" "parses $value"
    else
      fail_test "parses $value"
    fi
  done

  if parse_repository_input "https://gitlab.com/octocat/repo"; then
    fail_test "rejects non-GitHub URL"
  else
    pass "rejects non-GitHub URL"
  fi
}

test_semver() {
  compare_semver "1.2.3" "1.2.2"
  assert_equal "1" "$SEMVER_COMPARISON" "compares patch versions"

  compare_semver "1.2.3-alpha" "1.2.3"
  assert_equal "-1" "$SEMVER_COMPARISON" "stable release beats prerelease"

  compare_semver "10.0.0" "2.0.0"
  assert_equal "1" "$SEMVER_COMPARISON" "compares multi-digit major versions"

  compare_semver "1.2.3+one" "1.2.3+two"
  assert_equal "0" "$SEMVER_COMPARISON" "ignores build metadata"
}

write_changelog() {
  local file="$1"
  local first="$2"
  local second="$3"

  mkdir -p "$(dirname "$file")"
  printf '## %s - 2026-08-31\n\n## %s - 2026-08-01\n' "$first" "$second" > "$file"
}

test_version_resolution() {
  local case_directory=""

  case_directory="$TEST_TEMPORARY/version-package"
  mkdir -p "$case_directory"
  printf '{"version":"4.5.6"}\n' > "$case_directory/package.json"
  write_changelog "$case_directory/CHANGELOG.md" "9.0.0" "8.0.0"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "4.5.6|package.json" "$RELEASE_VERSION|$VERSION_SOURCE" "package.json has highest source priority"
  else
    fail_test "package.json has highest source priority"
  fi

  case_directory="$TEST_TEMPORARY/version-primary"
  mkdir -p "$case_directory"
  write_changelog "$case_directory/CHANGELOG.md" "2.0.0" "1.9.0"
  write_changelog "$case_directory/CHANGELOG.zh-CN.md" "8.0.0" "7.0.0"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "2.0.0|CHANGELOG.md" "$RELEASE_VERSION|$VERSION_SOURCE" "primary changelog wins over language variants"
  else
    fail_test "primary changelog wins over language variants"
  fi

  case_directory="$TEST_TEMPORARY/version-short-package"
  mkdir -p "$case_directory"
  printf '{"version":"4.5"}\n' > "$case_directory/package.json"
  write_changelog "$case_directory/CHANGELOG.md" "4.6" "4.5"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "4.6|CHANGELOG.md" "$RELEASE_VERSION|$VERSION_SOURCE" "invalid short package version falls through while changelog keeps existing format"
  else
    fail_test "invalid short package version falls through while changelog keeps existing format"
  fi

  case_directory="$TEST_TEMPORARY/version-languages"
  mkdir -p "$case_directory"
  write_changelog "$case_directory/CHANGELOG.en.md" "3.1.0" "3.0.0"
  write_changelog "$case_directory/CHANGELOG.zh-CN.md" "3.4.0" "3.3.0"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "3.4.0|CHANGELOG.zh-CN.md" "$RELEASE_VERSION|$VERSION_SOURCE" "language variants use the highest version"
  else
    fail_test "language variants use the highest version"
  fi

  case_directory="$TEST_TEMPORARY/version-recursive"
  mkdir -p "$case_directory/app" "$case_directory/node_modules/dependency"
  write_changelog "$case_directory/app/CHANGELOG.fr.md" "5.0.0" "4.0.0"
  write_changelog "$case_directory/node_modules/dependency/CHANGELOG.md" "99.0.0" "98.0.0"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "5.0.0|app/CHANGELOG.fr.md" "$RELEASE_VERSION|$VERSION_SOURCE" "recursive scan skips dependency directories"
  else
    fail_test "recursive scan skips dependency directories"
  fi

  case_directory="$TEST_TEMPORARY/version-file"
  mkdir -p "$case_directory"
  printf 'Version: v6.7.8\n' > "$case_directory/VERSION.txt"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "6.7.8|VERSION.txt" "$RELEASE_VERSION|$VERSION_SOURCE" "VERSION file remains a fallback"
  else
    fail_test "VERSION file remains a fallback"
  fi

  case_directory="$TEST_TEMPORARY/version-bottom"
  mkdir -p "$case_directory"
  printf '# [1.0.0] – August 1, 2026\n\n# [1.2.0] — August 31, 2026\n' > "$case_directory/CHANGELOG.md"
  GIT_ROOT="$case_directory"
  if resolve_release_version; then
    assert_equal "1.2.0|bottom" "$RELEASE_VERSION|$VERSION_POSITION" "detects oldest-to-newest changelog order and Unicode dashes"
  else
    fail_test "detects oldest-to-newest changelog order and Unicode dashes"
  fi
}

test_ssh_config_discovery() {
  printf 'Include %s/config.d/*\n\nHost github-main\n    HostName github.com\n    IdentityFile ~/.ssh/main\n' "$HOME/.ssh" > "$HOME/.ssh/config"
  printf 'Host github-work\n    HostName github.com\n    IdentityFile ~/.ssh/work\n' > "$HOME/.ssh/config.d/work"
  chmod 600 "$HOME/.ssh/config" "$HOME/.ssh/config.d/work"

  SSH_DIRECTORY="$HOME/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
  scan_ssh_aliases
  assert_equal "2" "$DISCOVERED_SSH_ALIAS_COUNT" "discovers aliases through Include files"
  assert_true "recognizes effective GitHub HostName" ssh_alias_is_github "github-work"
  assert_equal \
    "$HOME/.ssh/example" \
    "$(expand_home_path '~/.ssh/example')" \
    "expands SSH tilde paths without retaining a literal tilde"
}

test_alias_allocation() {
  local alias_home="$TEST_TEMPORARY/alias-home"
  local installed_key="$alias_home/.ssh/id_ed25519_github-test-user"

  mkdir -p "$alias_home/.ssh"
  printf 'Host github-johnjoe\n    HostName github.com\n    IdentityFile ~/.ssh/id_ed25519_github-johnjoe\n' > "$alias_home/.ssh/config"
  : > "$alias_home/.ssh/id_ed25519_github-johnjoe-1"

  SSH_DIRECTORY="$alias_home/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
  next_available_alias "JohnJoe"
  assert_equal "github-johnjoe-2" "$NEW_SSH_ALIAS" "increments aliases across config and key collisions"

  : > "$installed_key"
  install_ssh_alias_block "test-user" "github-test-user" "$installed_key"
  if ssh_alias_is_github "github-test-user"; then
    assert_equal \
      "$installed_key" \
      "$(resolve_alias_identity_file 'github-test-user')" \
      "installs a validated SSH alias block"
  else
    fail_test "installs a validated SSH alias block"
  fi
}

test_git_binding_and_commit() {
  local repository="$TEST_TEMPORARY/git-project"
  local bare_repository="$TEST_TEMPORARY/remote.git"
  local fake_bin="$TEST_TEMPORARY/fake-bin"
  local fake_key="$TEST_TEMPORARY/fake-key"
  local remote=""
  local push_remote=""
  local saved_name=""
  local saved_email=""
  local message=""
  local original_path_environment="$PATH"

  mkdir -p "$repository"
  git -C "$repository" init -q
  : > "$fake_key"

  GIT_ROOT="$repository"
  CURRENT_REPOSITORY_OWNER="example-org"
  CURRENT_REPOSITORY_NAME="example-repo"
  BOUND_USERNAME="johnjoe"
  BOUND_EMAIL="johnjoe@example.com"
  BOUND_SSH_ALIAS="github-johnjoe"
  BOUND_IDENTITY_FILE="$fake_key"

  if save_project_binding; then
    remote="$(git -C "$repository" remote get-url origin)"
    push_remote="$(git -C "$repository" remote get-url --push origin)"
    saved_name="$(git -C "$repository" config --local user.name)"
    saved_email="$(git -C "$repository" config --local user.email)"
    assert_equal "git@github-johnjoe:example-org/example-repo.git" "$remote" "normalizes origin to the bound account alias"
    assert_equal "$remote" "$push_remote" "pins the origin push address to the same account alias"
    assert_equal "johnjoe" "$saved_name" "commit display name equals GitHub username"
    assert_equal "johnjoe@example.com" "$saved_email" "stores repository-local account email"
  else
    fail_test "saves project binding"
  fi

  printf 'first\n' > "$repository/file.txt"
  git -C "$repository" add file.txt
  git -C "$repository" commit -q -m "Initial commit"
  printf 'second\n' >> "$repository/file.txt"
  write_changelog "$repository/CHANGELOG.md" "7.8.9" "7.8.8"

  prompt_commit_message() {
    COMMIT_MESSAGE="$1"
  }

  if prepare_and_commit; then
    message="$(git -C "$repository" log -1 --pretty=%s)"
    assert_equal "Release 7.8.9" "$message" "uses resolved version for the proposed commit"
  else
    fail_test "commits staged project changes"
  fi

  create_pinned_ssh_wrapper
  if grep -Fq 'IdentitiesOnly=yes' "$PINNED_SSH_WRAPPER" &&
     grep -Fq 'GITHUB_AUTO_IDENTITY_FILE' "$PINNED_SSH_WRAPPER"; then
    pass "pinned SSH wrapper forces one identity"
  else
    fail_test "pinned SSH wrapper forces one identity"
  fi
  rm -rf "$PINNED_SSH_DIRECTORY"

  git init --bare -q "$bare_repository"
  mkdir -p "$fake_bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for argument in "$@"; do\n'
    printf '  case "$argument" in\n'
    printf '    *git-upload-pack*) exec git-upload-pack "$FAKE_SSH_REPOSITORY" ;;\n'
    printf '    *git-receive-pack*) exec git-receive-pack "$FAKE_SSH_REPOSITORY" ;;\n'
    printf '  esac\n'
    printf 'done\n'
    printf 'exit 1\n'
  } > "$fake_bin/ssh"
  chmod 755 "$fake_bin/ssh"

  export FAKE_SSH_REPOSITORY="$bare_repository"
  PATH="$fake_bin:$PATH"
  export PATH
  if run_git_with_identity "$fake_key" push -u origin main >/dev/null 2>&1; then
    assert_equal \
      "$(git -C "$repository" rev-parse main)" \
      "$(git --git-dir="$bare_repository" rev-parse refs/heads/main)" \
      "strict identity wrapper completes an SSH Git push"
  else
    fail_test "strict identity wrapper completes an SSH Git push"
  fi
  PATH="$original_path_environment"
  export PATH
}

test_guided_updates() {
  local update_root="$TEST_TEMPORARY/guided-update"
  local update_home="$update_root/home"
  local repository="$update_root/repository"
  local fake_key="$update_home/.ssh/existing-account-key"
  local conflicting_key="$update_home/.ssh/another-account-key"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_ssh_directory="$SSH_DIRECTORY"
  local original_ssh_config="$SSH_CONFIG_FILE"
  local original_private_directory="$PRIVATE_DIRECTORY"
  local original_private_config="$PRIVATE_CONFIG_FILE"
  local remote=""
  local push_remote=""

  mkdir -p "$update_home/.ssh" "$repository"
  : > "$fake_key"
  : > "$conflicting_key"

  SCRIPT_DIRECTORY="$repository"
  SCRIPT_NAME="g.sh"
  PRIVATE_DIRECTORY="$update_root/private"
  PRIVATE_CONFIG_FILE="$PRIVATE_DIRECTORY/config.txt"
  ensure_private_config
  SSH_DIRECTORY="$update_home/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"

  printf 'Host github-old-user\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$fake_key" > "$SSH_CONFIG_FILE"
  load_accounts
  add_or_update_account "old-user" "101+old-user@users.noreply.github.com"
  write_accounts_to_private_config

  git -C "$repository" init -q
  GIT_ROOT="$repository"
  CURRENT_REPOSITORY_OWNER="example-org"
  CURRENT_REPOSITORY_NAME="old-repo"
  BOUND_USERNAME="old-user"
  BOUND_EMAIL="101+old-user@users.noreply.github.com"
  BOUND_SSH_ALIAS="github-old-user"
  BOUND_IDENTITY_FILE="$fake_key"
  save_project_binding

  UPDATE_ACCOUNT_USERNAME="old-user"
  UPDATE_OLD_USERNAME="old-user"
  UPDATE_OLD_EMAIL="101+old-user@users.noreply.github.com"
  UPDATE_OLD_OWNER="example-org"
  UPDATE_OLD_REPOSITORY="old-repo"
  UPDATE_NEW_USERNAME="old-user"
  UPDATE_NEW_EMAIL="$UPDATE_OLD_EMAIL"
  UPDATE_NEW_OWNER="example-org"
  UPDATE_NEW_REPOSITORY="new-repo"
  UPDATE_OLD_ALIAS="github-old-user"
  UPDATE_NEW_ALIAS="github-old-user"
  UPDATE_IDENTITY_FILE="$fake_key"
  UPDATE_INSTALL_ALIAS=false
  if update_apply_validated_settings no; then
    remote="$(git -C "$repository" remote get-url origin)"
    push_remote="$(git -C "$repository" remote get-url --push origin)"
    assert_equal "git@github-old-user:example-org/new-repo.git" "$remote" "repository-only update changes the origin repository name"
    assert_equal "$remote" "$push_remote" "repository-only update changes the explicit push address"
    assert_equal "old-user" "$(git -C "$repository" config --local user.name)" "repository-only update keeps the account identity"
  else
    fail_test "repository-only update applies validated settings"
  fi

  printf '\nHost github-new-user\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$conflicting_key" >> "$SSH_CONFIG_FILE"
  UPDATE_OLD_OWNER="old-user"
  UPDATE_OLD_REPOSITORY="new-repo"
  UPDATE_NEW_USERNAME="new-user"
  UPDATE_NEW_EMAIL="101+new-user@users.noreply.github.com"
  UPDATE_NEW_OWNER="new-user"
  UPDATE_NEW_REPOSITORY="new-repo"
  UPDATE_OLD_ALIAS="github-old-user"
  UPDATE_IDENTITY_FILE="$fake_key"
  update_prepare_alias yes
  assert_equal "github-new-user-1" "$UPDATE_NEW_ALIAS" "username update increments a conflicting new alias"
  assert_equal "true" "$UPDATE_INSTALL_ALIAS" "username update prepares a new alias for the existing key"

  if update_apply_validated_settings yes; then
    load_accounts
    assert_equal "1" "$ACCOUNT_COUNT" "username update replaces the visible account instead of adding a second account"
    assert_equal "new-user|101+new-user@users.noreply.github.com" "${ACCOUNT_USERNAMES[0]}|${ACCOUNT_EMAILS[0]}" "username update migrates the visible username and email"
    assert_equal "$fake_key" "$(resolve_alias_identity_file 'github-new-user-1')" "username update reuses the existing private key"
    assert_true "username update keeps the previous SSH alias" ssh_alias_is_github "github-old-user"
    assert_equal "new-user" "$(git -C "$repository" config --local user.name)" "username update changes the repository-local commit display name"
    assert_equal "git@github-new-user-1:new-user/new-repo.git" "$(git -C "$repository" remote get-url origin)" "username update migrates a personal repository owner"
    if [ ! -e "$SSH_DIRECTORY/id_ed25519_github-new-user" ] &&
       [ ! -e "$SSH_DIRECTORY/id_ed25519_github-new-user-1" ]; then
      pass "username update does not create another private key"
    else
      fail_test "username update does not create another private key"
    fi
  else
    fail_test "username-only update applies validated settings"
  fi

  if update_parse_repository_target "https://github.com/new-owner/moved-repo/settings" "new-user"; then
    assert_equal "new-owner/moved-repo" "$UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY" "combined update accepts a full moved-repository URL"
  else
    fail_test "combined update accepts a full moved-repository URL"
  fi
  if update_parse_repository_target "renamed-again.git" "new-user"; then
    assert_equal "new-user/renamed-again" "$UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY" "combined update accepts only a new repository name"
  else
    fail_test "combined update accepts only a new repository name"
  fi

  UPDATE_ACCOUNT_USERNAME="new-user"
  UPDATE_OLD_USERNAME="new-user"
  UPDATE_NEW_USERNAME="final-user"
  UPDATE_NEW_EMAIL="101+final-user@users.noreply.github.com"
  UPDATE_NEW_OWNER="final-user"
  UPDATE_NEW_REPOSITORY="final-repo"
  UPDATE_OLD_ALIAS="github-new-user-1"
  UPDATE_IDENTITY_FILE="$fake_key"
  update_prepare_alias yes
  if update_apply_validated_settings yes; then
    load_accounts
    assert_equal "final-user" "${ACCOUNT_USERNAMES[0]}" "combined update migrates the account entry"
    assert_equal "git@${UPDATE_NEW_ALIAS}:final-user/final-repo.git" "$(git -C "$repository" remote get-url origin)" "combined update changes username and repository together"
    assert_equal "$fake_key" "$(git -C "$repository" config --local --get github-auto.identity-file)" "combined update preserves the strict key binding"
  else
    fail_test "combined username and repository update applies validated settings"
  fi

  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  SSH_DIRECTORY="$original_ssh_directory"
  SSH_CONFIG_FILE="$original_ssh_config"
  PRIVATE_DIRECTORY="$original_private_directory"
  PRIVATE_CONFIG_FILE="$original_private_config"
  load_accounts
}

test_update_prompt_flow() {
  local flow_root="$TEST_TEMPORARY/update-prompt-flow"
  local flow_repository="$flow_root/repository"
  local flow_home="$flow_root/home"
  local flow_script="$flow_repository/g.sh"
  local flow_key="$flow_home/.ssh/account-key"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_ssh_directory="$SSH_DIRECTORY"
  local original_ssh_config="$SSH_CONFIG_FILE"
  local original_private_directory="$PRIVATE_DIRECTORY"
  local original_private_config="$PRIVATE_CONFIG_FILE"
  local saved_require_interactive=""
  local saved_identify_key_username=""
  local saved_run_git_with_identity=""
  local original_ui_language="$UI_LANGUAGE"
  local original_advanced_language="${ADVANCED_LANGUAGE:-en}"
  local output=""
  local before_git_config=""
  local before_private_config=""
  local before_ssh_config=""

  mkdir -p "$flow_repository" "$flow_home/.ssh"
  : > "$flow_script"
  chmod 755 "$flow_script"
  : > "$flow_key"
  printf 'Host github-flow-old\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$flow_key" > "$flow_home/.ssh/config"
  git -C "$flow_repository" init -q

  SCRIPT_DIRECTORY="$(cd "$flow_repository" && pwd -P)"
  SCRIPT_NAME="g.sh"
  SSH_DIRECTORY="$flow_home/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
  PRIVATE_DIRECTORY="$flow_root/private"
  PRIVATE_CONFIG_FILE="$PRIVATE_DIRECTORY/config.txt"
  ensure_private_config
  GIT_ROOT="$flow_repository"
  load_accounts
  add_or_update_account "flow-old" "202+flow-old@users.noreply.github.com"
  write_accounts_to_private_config
  CURRENT_REPOSITORY_OWNER="flow-old"
  CURRENT_REPOSITORY_NAME="old-repo"
  BOUND_USERNAME="flow-old"
  BOUND_EMAIL="202+flow-old@users.noreply.github.com"
  BOUND_SSH_ALIAS="github-flow-old"
  BOUND_IDENTITY_FILE="$flow_key"
  save_project_binding

  saved_require_interactive="$(declare -f require_interactive)"
  saved_identify_key_username="$(declare -f identify_key_username)"
  saved_run_git_with_identity="$(declare -f run_git_with_identity)"
  require_interactive() {
    return 0
  }
  identify_key_username() {
    VERIFIED_GITHUB_USERNAME="flow-new"
    return 0
  }
  run_git_with_identity() {
    return 0
  }

  UI_LANGUAGE="zh"
  ADVANCED_LANGUAGE="zh"
  output="$(run_update_command 2>&1 <<< $'3\nflow-new\n\nrenamed-repo\n\n')"
  load_accounts
  assert_equal "flow-new" "${ACCOUNT_USERNAMES[0]}" "guided update collects a new username through the Chinese flow"
  assert_equal "flow-new@users.noreply.github.com" "${ACCOUNT_EMAILS[0]}" "guided update recommends a matching private commit email"
  assert_equal "git@github-flow-new:flow-new/renamed-repo.git" "$(git -C "$flow_repository" remote get-url origin)" "guided update applies username and repository changes after one confirmation"
  if printf '%s\n' "$output" | grep -Fq '已把核对无误的用户名、仓库地址、提交作者、SSH 密钥和 origin 保存到上面列出的本机配置文件中。' &&
     printf '%s\n' "$output" | grep -Fq '原账号密钥会继续使用，不会重复创建新密钥。'; then
    pass "guided update uses naturally localized Chinese explanations"
  else
    fail_test "guided update uses naturally localized Chinese explanations"
  fi

  before_git_config="$(git -C "$flow_repository" config --local --list | sort)"
  before_private_config="$(cat "$PRIVATE_CONFIG_FILE")"
  before_ssh_config="$(cat "$SSH_CONFIG_FILE")"
  output="$(run_update_command 2>&1 <<< $'2\nanother-repository\nn\n')"
  assert_equal "$before_git_config" "$(git -C "$flow_repository" config --local --list | sort)" "canceling update preserves every repository-local Git setting"
  assert_equal "$before_private_config" "$(cat "$PRIVATE_CONFIG_FILE")" "canceling update preserves private account configuration"
  assert_equal "$before_ssh_config" "$(cat "$SSH_CONFIG_FILE")" "canceling update preserves SSH configuration"
  if printf '%s\n' "$output" | grep -Fq '已取消；private/config.txt、~/.ssh/config、当前仓库的 .git/config、项目文件和 GitHub 远端仓库均未修改。'; then
    pass "Chinese update cancellation states the exact no-write result"
  else
    fail_test "Chinese update cancellation states the exact no-write result"
  fi

  eval "$saved_require_interactive"
  eval "$saved_identify_key_username"
  eval "$saved_run_git_with_identity"
  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  SSH_DIRECTORY="$original_ssh_directory"
  SSH_CONFIG_FILE="$original_ssh_config"
  PRIVATE_DIRECTORY="$original_private_directory"
  PRIVATE_CONFIG_FILE="$original_private_config"
  UI_LANGUAGE="$original_ui_language"
  ADVANCED_LANGUAGE="$original_advanced_language"
  load_accounts
}

test_private_configuration() {
  local config_root="$TEST_TEMPORARY/private-configuration"
  local original_private_directory="$PRIVATE_DIRECTORY"
  local original_private_config="$PRIVATE_CONFIG_FILE"
  local original_ui_language="$UI_LANGUAGE"
  local original_theme="$THEME"
  local engine_checksum_before=""
  local engine_checksum_after=""

  engine_checksum_before="$(cksum "$PROJECT_DIRECTORY/git-auto.sh")"
  PRIVATE_DIRECTORY="$config_root/private"
  PRIVATE_CONFIG_FILE="$PRIVATE_DIRECTORY/config.txt"
  ensure_private_config
  load_accounts

  assert_equal "" "$(read_saved_language)" "new private config starts without a saved language"
  if choose_interface_language no >/dev/null 2>&1 <<< "2"; then
    assert_equal "zh" "$(read_saved_language)" "first language choice is written into private config"
  else
    fail_test "first language choice is written into private config"
  fi
  UI_LANGUAGE="en"
  initialize_language
  assert_equal "zh" "$UI_LANGUAGE" "later runs reuse the language stored in private config"

  save_theme_preference "dark"
  assert_equal "dark" "$(read_saved_theme)" "display preference is written into private config"
  if [ ! -e "$HOME/.config/github-auto" ]; then
    pass "preferences create no application config directory"
  else
    fail_test "preferences create no application config directory"
  fi

  add_or_update_account "test-user" "test-user@example.com"
  write_accounts_to_private_config
  load_accounts

  assert_equal "1" "$ACCOUNT_COUNT" "private config stores a shared account"
  assert_equal "600" "$(file_mode "$PRIVATE_CONFIG_FILE")" "private config is readable only by its owner"
  assert_equal "700" "$(file_mode "$PRIVATE_DIRECTORY")" "private directory is accessible only by its owner"
  if grep -Fxq 'username: test-user' "$PRIVATE_CONFIG_FILE" &&
     grep -Fxq 'email: test-user@example.com' "$PRIVATE_CONFIG_FILE"; then
    pass "private account fields remain human-editable"
  else
    fail_test "private account fields remain human-editable"
  fi

  engine_checksum_after="$(cksum "$PROJECT_DIRECTORY/git-auto.sh")"
  assert_equal "$engine_checksum_before" "$engine_checksum_after" "saving private settings never modifies the central engine"

  PRIVATE_DIRECTORY="$original_private_directory"
  PRIVATE_CONFIG_FILE="$original_private_config"
  UI_LANGUAGE="$original_ui_language"
  apply_theme "$original_theme"
  load_accounts
}

test_central_distribution() {
  if [ ! -f "$PROJECT_DIRECTORY/git-auto.sh" ]; then
    fail_test "central git-auto.sh exists"
    return
  fi
  pass "central git-auto.sh exists"

  if ! grep -Fq '# >>> GITHUB ACCOUNTS >>>' "$PROJECT_DIRECTORY/git-auto.sh" &&
     ! grep -Fq '# interface-language:' "$PROJECT_DIRECTORY/git-auto.sh"; then
    pass "central engine contains no personalized account or preference block"
  else
    fail_test "central engine contains no personalized account or preference block"
  fi

  if grep -Fxq 'private/' "$PROJECT_DIRECTORY/.gitignore"; then
    pass "private is ignored by the public repository"
  else
    fail_test "private is ignored by the public repository"
  fi

  if [ ! -e "$PROJECT_DIRECTORY/dist" ] && [ -f "$PROJECT_DIRECTORY/g.sh" ]; then
    pass "central project includes one public copy-ready launcher and no personal script copy"
  else
    fail_test "central project includes one public copy-ready launcher and no personal script copy"
  fi

  if ! grep -Eq '^/?g\.sh/?$' "$PROJECT_DIRECTORY/.gitignore" &&
     [ "$(find "$PROJECT_DIRECTORY" -maxdepth 1 -type f -name '*.sh' | wc -l | tr -d ' ')" -eq 2 ] &&
     grep -Fq 'run_project_flow()' "$PROJECT_DIRECTORY/git-auto.sh" &&
     ! grep -Fq 'run_project_flow()' "$PROJECT_DIRECTORY/g.sh"; then
    pass "g.sh is public while git-auto.sh remains the only complete engine"
  else
    fail_test "g.sh is public while git-auto.sh remains the only complete engine"
  fi
}

test_project_launcher() {
  local project_directory="$TEST_TEMPORARY/project launcher"
  local launcher_file="$project_directory/g.sh"
  local output=""
  local resolved_target=""
  local status=0

  mkdir -p "$project_directory"
  git -C "$project_directory" init -q
  if write_project_launcher "$project_directory"; then
    pass "central engine creates a lightweight project launcher"
  else
    fail_test "central engine creates a lightweight project launcher"
    return
  fi

  assert_true "generated launcher has valid Bash syntax" bash -n "$launcher_file"
  assert_equal "755" "$(file_mode "$launcher_file")" "generated launcher is executable"
  if [ "$(wc -l < "$launcher_file" | tr -d ' ')" -le 80 ] &&
     launcher_is_managed "$launcher_file"; then
    pass "generated g.sh stays intentionally small"
  else
    fail_test "generated g.sh stays intentionally small"
  fi
  if cmp -s "$PROJECT_DIRECTORY/g.sh" "$launcher_file"; then
    pass "generated launcher is an exact copy of the public root g.sh"
  else
    fail_test "generated launcher is an exact copy of the public root g.sh"
  fi
  assert_equal "$PROJECT_DIRECTORY/git-auto.sh" "$(git -C "$project_directory" config --local --get github-auto.engine)" "launcher creation remembers the central engine only in local Git config"
  if git -C "$project_directory" check-ignore -q g.sh; then
    pass "generated launcher is excluded only in the local repository"
  else
    fail_test "generated launcher is excluded only in the local repository"
  fi

  output="$(GITHUB_AUTO_TESTING=0 "$launcher_file" invalid-command 2>&1)" || status=$?
  if [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep -Fq './g.sh menu'; then
    pass "launcher forwards commands while preserving the g.sh interface name"
  else
    fail_test "launcher forwards commands while preserving the g.sh interface name"
  fi

  resolved_target="$(
    GIT_AUTO_PROJECT_ROOT="$project_directory" \
    GIT_AUTO_LAUNCHER_NAME="g.sh" \
    GIT_AUTO_LAUNCHER_ACTIVE=1 \
    GIT_AUTO_TESTING=1 \
    GIT_AUTO_PRIVATE_DIRECTORY="$GIT_AUTO_PRIVATE_DIRECTORY" \
      bash -c 'source "$1"; printf "%s" "$SCRIPT_DIRECTORY"' bash "$PROJECT_DIRECTORY/git-auto.sh"
  )"
  assert_equal "$(cd "$project_directory" && pwd -P)" "$resolved_target" "central engine uses the launcher folder as the exact project root"
}

test_public_documentation() {
  local product_name="Auto Script for GitHub Setup and Push"
  local file=""
  local english_sections=""
  local chinese_sections=""
  local english_versions=""
  local chinese_versions=""

  if grep -Fxq '[Chinese](README_zh.md)' "$PROJECT_DIRECTORY/README.md" &&
     ! grep -Fq '[English](' "$PROJECT_DIRECTORY/README.md"; then
    pass "English README links only to Chinese"
  else
    fail_test "English README links only to Chinese"
  fi

  if grep -Fxq '[English](README.md)' "$PROJECT_DIRECTORY/README_zh.md" &&
     ! grep -Fq '[Chinese](' "$PROJECT_DIRECTORY/README_zh.md"; then
    pass "Chinese README links only to English"
  else
    fail_test "Chinese README links only to English"
  fi

  if grep -Fxq '[Chinese](CHANGELOG_zh.md)' "$PROJECT_DIRECTORY/CHANGELOG.md" &&
     ! grep -Fq '[English](' "$PROJECT_DIRECTORY/CHANGELOG.md"; then
    pass "English changelog links only to Chinese"
  else
    fail_test "English changelog links only to Chinese"
  fi

  if grep -Fxq '[English](CHANGELOG.md)' "$PROJECT_DIRECTORY/CHANGELOG_zh.md" &&
     ! grep -Fq '[Chinese](' "$PROJECT_DIRECTORY/CHANGELOG_zh.md"; then
    pass "Chinese changelog links only to English"
  else
    fail_test "Chinese changelog links only to English"
  fi

  if LC_ALL=C grep -q '[^ -~[:space:]]' "$PROJECT_DIRECTORY/README.md"; then
    fail_test "primary README contains en-US ASCII prose only"
  else
    pass "primary README contains en-US ASCII prose only"
  fi

  for file in \
    "$PROJECT_DIRECTORY/git-auto.sh" \
    "$PROJECT_DIRECTORY/g.sh" \
    "$PROJECT_DIRECTORY/README.md" \
    "$PROJECT_DIRECTORY/README_zh.md" \
    "$PROJECT_DIRECTORY/CHANGELOG.md" \
    "$PROJECT_DIRECTORY/CHANGELOG_zh.md"; do
    if ! grep -Fq "$product_name" "$file"; then
      fail_test "uses the unified product name in ${file#"$PROJECT_DIRECTORY"/}"
      continue
    fi
    pass "uses the unified product name in ${file#"$PROJECT_DIRECTORY"/}"
  done

  english_sections="$(grep -c '^## ' "$PROJECT_DIRECTORY/README.md")"
  chinese_sections="$(grep -c '^## ' "$PROJECT_DIRECTORY/README_zh.md")"
  assert_equal "$english_sections" "$chinese_sections" "README language versions keep the same section count"

  english_versions="$(grep '^## [0-9]' "$PROJECT_DIRECTORY/CHANGELOG.md" | sed 's/[[:space:]]*$//')"
  chinese_versions="$(grep '^## [0-9]' "$PROJECT_DIRECTORY/CHANGELOG_zh.md" | sed 's/[[:space:]]*$//')"
  assert_equal "$english_versions" "$chinese_versions" "changelog language versions keep the same releases"
}

test_project_root_identity() {
  local repository="$TEST_TEMPORARY/root-identity/repository"
  local equivalent_path="$TEST_TEMPORARY/root-identity/equivalent-path"
  local nested_directory="$repository/nested"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_root="${GIT_ROOT:-}"

  mkdir -p "$repository" "$nested_directory"
  git -C "$repository" init -q
  ln -s "$repository" "$equivalent_path"

  SCRIPT_DIRECTORY="$equivalent_path"
  SCRIPT_NAME="g.sh"
  if locate_project no && [ "$GIT_ROOT" -ef "$repository" ]; then
    pass "project-root detection accepts an equivalent path to the same directory"
  else
    fail_test "project-root detection accepts an equivalent path to the same directory"
  fi

  if (SCRIPT_DIRECTORY="$nested_directory"; locate_project no >/dev/null 2>&1); then
    fail_test "project-root detection still rejects a genuinely nested directory"
  else
    pass "project-root detection still rejects a genuinely nested directory"
  fi

  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  GIT_ROOT="$original_root"
}

test_existing_repository_state() {
  local repository="$TEST_TEMPORARY/existing-repository-state"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_root="${GIT_ROOT:-}"
  local original_state="${PROJECT_GIT_STATE:-}"
  local original_language="$UI_LANGUAGE"
  local before_config=""
  local after_config=""
  local output=""
  local git_directory=""

  mkdir -p "$repository"
  git -C "$repository" init -q
  git -C "$repository" config user.name tester
  git -C "$repository" config user.email tester@example.com
  printf 'existing\n' > "$repository/file.txt"
  git -C "$repository" add file.txt
  git -C "$repository" commit -qm existing
  git -C "$repository" branch -M main

  SCRIPT_DIRECTORY="$repository"
  SCRIPT_NAME="g.sh"
  UI_LANGUAGE="en"
  before_config="$(git -C "$repository" config --local --list | sort)"
  if locate_project no; then
    output="$(describe_and_validate_project_state 2>&1)"
    after_config="$(git -C "$repository" config --local --list | sort)"
    assert_equal "existing" "$PROJECT_GIT_STATE" "existing repository is classified before any setup"
    assert_equal "$before_config" "$after_config" "read-only project detection does not rewrite local Git configuration"
    if printf '%s\n' "$output" | grep -Fq 'Existing Git repository detected:' &&
       printf '%s\n' "$output" | grep -Fq 'git init will not run again.' &&
       printf '%s\n' "$output" | grep -Fq 'Current branch: main'; then
      pass "existing repository explanation distinguishes detection from initialization"
    else
      fail_test "existing repository explanation distinguishes detection from initialization"
    fi
  else
    fail_test "existing repository is classified before any setup"
    fail_test "read-only project detection does not rewrite local Git configuration"
    fail_test "existing repository explanation distinguishes detection from initialization"
  fi

  git -C "$repository" checkout -q --detach
  if describe_and_validate_project_state >/dev/null 2>&1; then
    fail_test "detached HEAD stops the normal push flow before changes"
  else
    pass "detached HEAD stops the normal push flow before changes"
  fi
  git -C "$repository" checkout -q main

  git_directory="$(git -C "$repository" rev-parse --absolute-git-dir)"
  mkdir -p "$git_directory/rebase-merge"
  if describe_and_validate_project_state >/dev/null 2>&1; then
    fail_test "an unfinished Git operation stops the normal push flow"
  else
    pass "an unfinished Git operation stops the normal push flow"
  fi
  rmdir "$git_directory/rebase-merge"

  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  GIT_ROOT="$original_root"
  PROJECT_GIT_STATE="$original_state"
  UI_LANGUAGE="$original_language"
}

test_origin_alias_identity_selection() {
  local case_root="$TEST_TEMPORARY/origin-alias-identity"
  local repository="$case_root/repository"
  local fake_home="$case_root/home"
  local fake_key="$fake_home/.ssh/id_ed25519_github800"
  local original_ssh_directory="$SSH_DIRECTORY"
  local original_ssh_config="$SSH_CONFIG_FILE"
  local original_root="${GIT_ROOT:-}"
  local original_language="$UI_LANGUAGE"
  local saved_identify_key_username=""
  local before_config=""

  mkdir -p "$repository" "$fake_home/.ssh"
  git -C "$repository" init -q
  : > "$fake_key"
  printf 'Host github800\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$fake_key" > "$fake_home/.ssh/config"
  git -C "$repository" remote add origin git@github800:sd800/example.git

  SSH_DIRECTORY="$fake_home/.ssh"
  SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
  GIT_ROOT="$repository"
  UI_LANGUAGE="en"
  BOUND_USERNAME="sd800"
  BOUND_EMAIL="sd800@users.noreply.github.com"
  before_config="$(cat "$SSH_CONFIG_FILE")"
  saved_identify_key_username="$(declare -f identify_key_username)"
  identify_key_username() {
    VERIFIED_GITHUB_USERNAME="sd800"
    SSH_VERIFICATION_OUTPUT=""
    return 0
  }

  if read_origin_repository && ensure_bound_identity; then
    assert_equal "github800" "$CURRENT_ORIGIN_HOST" "existing origin preserves its SSH Host name as an identity hint"
    assert_equal "github800|$fake_key" "$BOUND_SSH_ALIAS|$BOUND_IDENTITY_FILE" "existing origin alias selects its exact verified account key"
    assert_equal "$before_config" "$(cat "$SSH_CONFIG_FILE")" "verified origin alias is reused without creating another SSH key or Host entry"
  else
    fail_test "existing origin preserves its SSH Host name as an identity hint"
    fail_test "existing origin alias selects its exact verified account key"
    fail_test "verified origin alias is reused without creating another SSH key or Host entry"
  fi

  eval "$saved_identify_key_username"
  SSH_DIRECTORY="$original_ssh_directory"
  SSH_CONFIG_FILE="$original_ssh_config"
  GIT_ROOT="$original_root"
  UI_LANGUAGE="$original_language"
}

test_commit_cancellation_boundary() {
  local repository="$TEST_TEMPORARY/commit-cancellation"
  local empty_repository="$TEST_TEMPORARY/empty-repository"
  local original_root="${GIT_ROOT:-}"
  local original_language="$UI_LANGUAGE"
  local before_cached=""
  local after_cached=""
  local before_head=""
  local output=""
  local status=0

  mkdir -p "$repository"
  git -C "$repository" init -q
  git -C "$repository" config user.name tester
  git -C "$repository" config user.email tester@example.com
  printf 'one\n' > "$repository/staged.txt"
  printf 'one\n' > "$repository/unstaged.txt"
  git -C "$repository" add staged.txt unstaged.txt
  git -C "$repository" commit -qm baseline

  printf 'two\n' >> "$repository/staged.txt"
  git -C "$repository" add staged.txt
  printf 'two\n' >> "$repository/unstaged.txt"
  GIT_ROOT="$repository"
  UI_LANGUAGE="en"
  before_cached="$(git -C "$repository" diff --cached)"
  before_head="$(git -C "$repository" rev-parse HEAD)"
  output="$(prepare_and_commit 2>&1 <<< ':cancel')" || status=$?
  after_cached="$(git -C "$repository" diff --cached)"

  assert_equal "2" "$status" "commit cancellation returns the dedicated clean-stop status"
  assert_equal "$before_cached" "$after_cached" "commit cancellation preserves pre-existing staged changes"
  assert_equal "$before_head" "$(git -C "$repository" rev-parse HEAD)" "commit cancellation creates no commit"
  if ! git -C "$repository" diff --quiet -- unstaged.txt &&
     printf '%s\n' "$output" | grep -Fq 'Commit canceled before git add -A.'; then
    pass "commit cancellation occurs before staging all working-tree changes"
  else
    fail_test "commit cancellation occurs before staging all working-tree changes"
  fi

  mkdir -p "$empty_repository"
  git -C "$empty_repository" init -q
  GIT_ROOT="$empty_repository"
  status=0
  output="$(prepare_and_commit 2>&1)" || status=$?
  assert_equal "3" "$status" "an empty repository stops cleanly without attempting a push"
  if printf '%s\n' "$output" | grep -Fq 'no commit and no project files available to commit'; then
    pass "an empty repository explains why there is nothing to upload"
  else
    fail_test "an empty repository explains why there is nothing to upload"
  fi

  GIT_ROOT="$original_root"
  UI_LANGUAGE="$original_language"
}

test_central_root_launcher_dispatch() {
  local saved_initialize_language=""
  local saved_run_project_flow=""
  local saved_run_central_menu=""
  local original_script_directory="$SCRIPT_DIRECTORY"
  local original_running="$RUNNING_FROM_LAUNCHER"
  local output=""

  saved_initialize_language="$(declare -f initialize_language)"
  saved_run_project_flow="$(declare -f run_project_flow)"
  saved_run_central_menu="$(declare -f run_central_menu)"
  initialize_language() { return 0; }
  run_project_flow() { printf 'project-flow\n'; }
  run_central_menu() { printf 'central-menu\n'; }
  SCRIPT_DIRECTORY="$ENGINE_DIRECTORY"

  RUNNING_FROM_LAUNCHER=1
  output="$(main)"
  assert_equal "project-flow" "$output" "root g.sh operates on the central repository as a normal project"

  RUNNING_FROM_LAUNCHER=0
  output="$(main)"
  assert_equal "central-menu" "$output" "direct git-auto.sh keeps the central management menu"

  eval "$saved_initialize_language"
  eval "$saved_run_project_flow"
  eval "$saved_run_central_menu"
  SCRIPT_DIRECTORY="$original_script_directory"
  RUNNING_FROM_LAUNCHER="$original_running"
}

test_self_exclusion_modes() {
  local source_repository="$TEST_TEMPORARY/source-repository"
  local copied_repository="$TEST_TEMPORARY/copied-repository"
  local original_directory="$SCRIPT_DIRECTORY"
  local original_name="$SCRIPT_NAME"
  local original_root="${GIT_ROOT:-}"

  mkdir -p "$source_repository" "$copied_repository"
  git -C "$source_repository" init -q
  git -C "$copied_repository" init -q
  : > "$source_repository/helper.sh"
  git -C "$source_repository" add helper.sh

  SCRIPT_NAME="helper.sh"
  SCRIPT_DIRECTORY="$source_repository"
  GIT_ROOT="$source_repository"
  ensure_script_excluded
  if git -C "$source_repository" ls-files --error-unmatch -- helper.sh >/dev/null 2>&1 &&
     ! grep -Fq '/helper.sh' "$source_repository/.git/info/exclude"; then
    pass "a tracked source script remains tracked and is not locally excluded"
  else
    fail_test "a tracked source script remains tracked and is not locally excluded"
  fi

  : > "$copied_repository/helper.sh"
  SCRIPT_DIRECTORY="$copied_repository"
  GIT_ROOT="$copied_repository"
  ensure_script_excluded
  if git -C "$copied_repository" check-ignore -q helper.sh &&
     ! git -C "$copied_repository" ls-files --error-unmatch -- helper.sh >/dev/null 2>&1; then
    pass "an untracked standalone script excludes itself locally"
  else
    fail_test "an untracked standalone script excludes itself locally"
  fi

  SCRIPT_DIRECTORY="$original_directory"
  SCRIPT_NAME="$original_name"
  GIT_ROOT="$original_root"
}

test_historical_release_import() {
  local releases="$TEST_TEMPORARY/historical releases"
  local first="$releases/project-1.0.0"
  local second="$releases/project-2.0.0"
  local remote="$TEST_TEMPORARY/history-remote.git"
  local fake_key="$TEST_TEMPORARY/history-fake-key"
  local messages=""
  local first_tree=""
  local final_tree=""
  local saved_prompt_function=""
  local remote_head=""
  local local_head=""
  local head_count=""
  local unrelated_commit=""
  local original_max="$HISTORY_MAX_FILE_BYTES"

  mkdir -p "$first/.git" "$second/nested/.git" "$releases/notes"
  printf '# first\n' > "$first/README.md"
  printf 'old\n' > "$first/old.txt"
  printf 'included despite ignore\n' > "$first/debug.log"
  printf '*.log\n' > "$first/.gitignore"
  printf 'metadata\n' > "$first/.DS_Store"
  printf 'must not be imported\n' > "$first/.git/config"
  printf '## 1.0.0 - 2024-01-02\n' > "$first/CHANGELOG.md"

  printf '# second\n' > "$second/README.md"
  printf 'new\n' > "$second/new.txt"
  printf 'must not be imported\n' > "$second/nested/.git/config"
  printf '## 2.0.0 - August 3, 2025\n' > "$second/CHANGELOG.md"
  printf 'token=value\n' > "$second/.env"

  if normalize_history_directory_input "file://${releases// /%20}"; then
    assert_equal "$(cd "$releases" && pwd -P)" "$HISTORY_NORMALIZED_DIRECTORY" "normalizes dragged file URLs for release folders"
  else
    fail_test "normalizes dragged file URLs for release folders"
  fi

  reset_history_releases
  history_scan_parent_directory "$releases"
  history_sort_releases
  assert_equal "2" "$HISTORY_RELEASE_COUNT" "discovers versioned release folders and skips unrelated folders"
  assert_equal "1.0.0|2.0.0" "${HISTORY_RELEASE_VERSIONS[0]}|${HISTORY_RELEASE_VERSIONS[1]}" "sorts historical releases by semantic version"
  assert_equal "2024-01-02|2025-08-03" "${HISTORY_RELEASE_DATES[0]}|${HISTORY_RELEASE_DATES[1]}" "uses reliable changelog dates for reconstructed commits"
  assert_equal "no|yes" "${HISTORY_RELEASE_NEEDS_GITIGNORE[0]}|${HISTORY_RELEASE_NEEDS_GITIGNORE[1]}" "detects releases missing a root gitignore"

  ADVANCED_LANGUAGE="en"
  if history_collect_gitignore_content <<< $'node_modules/\n\n*.log\n:done'; then
    assert_equal $'node_modules/\n\n*.log' "$HISTORY_GITIGNORE_CONTENT" "accepts multiline gitignore content directly from the terminal"
  else
    fail_test "accepts multiline gitignore content directly from the terminal"
  fi

  HISTORY_MAX_FILE_BYTES=5
  history_scan_risks
  if [ "$HISTORY_LARGE_COUNT" -gt 0 ]; then
    pass "detects files above the configured push limit"
  else
    fail_test "detects files above the configured push limit"
  fi
  if [ "$HISTORY_SENSITIVE_COUNT" -gt 0 ]; then
    pass "detects sensitive-looking files before history construction"
  else
    fail_test "detects sensitive-looking files before history construction"
  fi
  HISTORY_MAX_FILE_BYTES="$original_max"

  git init --bare -q "$remote"
  : > "$fake_key"
  BOUND_USERNAME="history-user"
  BOUND_EMAIL="history-user@example.com"
  BOUND_SSH_ALIAS="github-history-user"
  BOUND_IDENTITY_FILE="$fake_key"
  HISTORY_REMOTE_URL="$remote"
  HISTORY_ADD_GITIGNORE=true
  HISTORY_GITIGNORE_CONTENT="*.tmp
.cache/"
  HISTORY_CREATE_TAGS=true
  ADVANCED_LANGUAGE="en"

  if history_build_repository; then
    pass "builds a temporary historical release repository"
  else
    fail_test "builds a temporary historical release repository"
    return
  fi

  messages="$(git -C "$HISTORY_WORK_DIRECTORY" log --format=%s --reverse | paste -sd '|' -)"
  assert_equal "Release 1.0.0|Release 2.0.0" "$messages" "creates one ordered release commit per complete snapshot"
  assert_equal "main" "$(git -C "$HISTORY_WORK_DIRECTORY" branch --show-current)" "normalizes rebuilt history to the main branch"
  assert_true "creates a version tag for the first release" git -C "$HISTORY_WORK_DIRECTORY" rev-parse -q --verify refs/tags/v1.0.0
  assert_true "creates a version tag for the latest release" git -C "$HISTORY_WORK_DIRECTORY" rev-parse -q --verify refs/tags/v2.0.0
  assert_equal "2024-01-02" "$(git -C "$HISTORY_WORK_DIRECTORY" log --reverse --format=%cs | sed -n '1p')" "preserves a reliable release date"

  first_tree="$(git -C "$HISTORY_WORK_DIRECTORY" ls-tree -r --name-only refs/tags/v1.0.0)"
  final_tree="$(git -C "$HISTORY_WORK_DIRECTORY" ls-tree -r --name-only HEAD)"
  if printf '%s\n' "$first_tree" | grep -Fxq '.gitignore' &&
     printf '%s\n' "$first_tree" | grep -Fxq 'debug.log'; then
    pass "complete snapshots include gitignore files and files they ignore"
  else
    fail_test "complete snapshots include gitignore files and files they ignore"
  fi
  if ! printf '%s\n' "$first_tree" | grep -Fq '.DS_Store' &&
     ! printf '%s\n' "$first_tree" | grep -Fq '.git/' &&
     ! printf '%s\n' "$final_tree" | grep -Fxq 'old.txt'; then
    pass "snapshot replacement removes old files and excludes Git metadata"
  else
    fail_test "snapshot replacement removes old files and excludes Git metadata"
  fi
  assert_equal "*.tmp|.cache/" "$(git -C "$HISTORY_WORK_DIRECTORY" show HEAD:.gitignore | paste -sd '|' -)" "adds supplied gitignore content only to missing snapshots"
  if [ ! -e "$second/.gitignore" ] && [ -f "$second/.env" ]; then
    pass "historical source folders remain unchanged"
  else
    fail_test "historical source folders remain unchanged"
  fi

  if history_publish_repository; then
    remote_head="$(git --git-dir="$remote" rev-parse refs/heads/main)"
    local_head="$(git -C "$HISTORY_WORK_DIRECTORY" rev-parse main)"
    assert_equal "$local_head" "$remote_head" "publishes rebuilt history to an empty remote without force"
  else
    fail_test "publishes rebuilt history to an empty remote without force"
  fi

  unrelated_commit="$(
    printf 'Release 3.0.0\n' |
      git -C "$HISTORY_WORK_DIRECTORY" commit-tree \
        "$(git -C "$HISTORY_WORK_DIRECTORY" rev-parse 'HEAD^{tree}')"
  )"
  git -C "$HISTORY_WORK_DIRECTORY" update-ref refs/heads/main "$unrelated_commit"
  saved_prompt_function="$(declare -f advanced_prompt_yes_no)"
  advanced_prompt_yes_no() {
    return 0
  }
  HISTORY_CREATE_TAGS=false
  if history_publish_repository; then
    remote_head="$(git --git-dir="$remote" rev-parse refs/heads/main)"
    local_head="$(git -C "$HISTORY_WORK_DIRECTORY" rev-parse main)"
    assert_equal "$local_head" "$remote_head" "replaces an existing remote main with an exact force-with-lease"
  else
    fail_test "replaces an existing remote main with an exact force-with-lease"
  fi
  eval "$saved_prompt_function"

  head_count="$(git --git-dir="$remote" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')"
  assert_equal "1" "$head_count" "history replacement does not create a backup branch"

  history_remove_temporary_directory "$HISTORY_WORK_DIRECTORY" history || true
  HISTORY_WORK_DIRECTORY=""
  HISTORY_MAX_FILE_BYTES="$original_max"
}

test_user_interface_symbols() {
  local script_file="$PROJECT_DIRECTORY/git-auto.sh"
  local launcher_file="$PROJECT_DIRECTORY/g.sh"

  if ! grep -Fq 'ℹ' "$script_file" &&
     ! grep -Fq '✓' "$script_file" &&
     ! grep -Fq '✗' "$script_file" &&
     ! grep -Fq '✅' "$script_file" &&
     ! grep -Fq '❌' "$script_file" &&
     ! grep -Fq '🚀' "$script_file" &&
     ! grep -Fq '✅' "$launcher_file" &&
     ! grep -Fq '❌' "$launcher_file"; then
    pass "script user interfaces contain no emoji status symbols"
  else
    fail_test "script user interfaces contain no emoji status symbols"
  fi

  if grep -Fq "printf '  8) 高级功能" "$script_file" &&
     grep -Fq "printf '  8) Advanced features" "$script_file" &&
     grep -Fq "printf '  6) 界面语言" "$script_file" &&
     grep -Fq "printf '  6) Interface language" "$script_file"; then
    pass "menu exposes language selection and advanced features in both interfaces"
  else
    fail_test "menu exposes language selection and advanced features in both interfaces"
  fi

  if grep -Fq '    update)' "$script_file" &&
     grep -Fq 'New GitHub username' "$script_file" &&
     grep -Fq '新的 GitHub 用户名' "$script_file"; then
    pass "update is a public command with English and localized Chinese interfaces"
  else
    fail_test "update is a public command with English and localized Chinese interfaces"
  fi

  if ! grep -Fq 'rsync' "$script_file"; then
    pass "historical import adds no rsync dependency"
  else
    fail_test "historical import adds no rsync dependency"
  fi

  if ! grep -Fq 'theme_settings_file' "$script_file" &&
     ! grep -Fq 'XDG_CONFIG_HOME' "$script_file" &&
     ! grep -Fq '.config/github-auto' "$script_file"; then
    pass "script stores its preferences without an application config directory"
  else
    fail_test "script stores its preferences without an application config directory"
  fi

  if ! grep -Eiq 'now automatically set up|set it up automatically now|secure connection|connection is ready|现在自动设置|自动配置\?|安全连接|连接正常|账号.*已准备好' "$script_file"; then
    pass "user interface avoids vague setup and connection status wording"
  else
    fail_test "user interface avoids vague setup and connection status wording"
  fi

  if grep -Fq 'Existing Git repository detected:' "$script_file" &&
     grep -Fq '已识别现有 Git 仓库：' "$script_file" &&
     grep -Fq 'Create and configure this separate SSH key now?' "$script_file" &&
     grep -Fq '现在创建并配置这把独立的 SSH 密钥吗？' "$script_file"; then
    pass "critical repository and SSH decisions have explicit English and Chinese copy"
  else
    fail_test "critical repository and SSH decisions have explicit English and Chinese copy"
  fi
}

printf 'TAP version 13\n'
test_accounts
test_prompt_values
test_repository_parser
test_semver
test_version_resolution
test_ssh_config_discovery
test_alias_allocation
test_private_configuration
test_central_distribution
test_project_launcher
test_public_documentation
test_project_root_identity
test_existing_repository_state
test_origin_alias_identity_selection
test_commit_cancellation_boundary
test_central_root_launcher_dispatch
test_self_exclusion_modes
test_git_binding_and_commit
test_guided_updates
test_update_prompt_flow
test_historical_release_import
test_user_interface_symbols
printf '1..%s\n' "$TEST_COUNT"

if [ "$FAILURE_COUNT" -gt 0 ]; then
  printf '%s test(s) failed\n' "$FAILURE_COUNT" >&2
  exit 1
fi

printf 'All tests passed.\n'
