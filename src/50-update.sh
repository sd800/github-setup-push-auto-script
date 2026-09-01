# -----------------------------------------------------------------------------
# Guided account and repository updates
# -----------------------------------------------------------------------------

UPDATE_OLD_USERNAME=""
UPDATE_OLD_EMAIL=""
UPDATE_OLD_OWNER=""
UPDATE_OLD_REPOSITORY=""
UPDATE_NEW_USERNAME=""
UPDATE_NEW_EMAIL=""
UPDATE_NEW_OWNER=""
UPDATE_NEW_REPOSITORY=""
UPDATE_OLD_ALIAS=""
UPDATE_NEW_ALIAS=""
UPDATE_IDENTITY_FILE=""
UPDATE_ACCOUNT_USERNAME=""
UPDATE_INSTALL_ALIAS=false

update_select_current_account() {
  local saved_username=""
  local index=""

  if index="$(account_index "$CURRENT_REPOSITORY_OWNER")"; then
    UPDATE_ACCOUNT_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    UPDATE_OLD_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    UPDATE_OLD_EMAIL="${ACCOUNT_EMAILS[$index]}"
    return 0
  fi

  saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  advanced_error \
    "This repository belongs to $CURRENT_REPOSITORY_OWNER, but that account is not saved in private/config.txt. Run ./$SCRIPT_NAME first so the repository can be bound to its owner before using update." \
    "当前仓库属于 ${CURRENT_REPOSITORY_OWNER}，但 private/config.txt 中没有保存这个账号。请先运行 ./${SCRIPT_NAME}，把仓库重新绑定到所属账号后，再使用 update。"
  if [ -n "$saved_username" ] &&
     [ "$(lowercase "$saved_username")" != "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ]; then
    advanced_muted \
      "The repository-local account $saved_username was ignored because it does not match the owner." \
      "当前仓库本地保存的账号 ${saved_username} 与仓库所属账号不一致，因此没有采用。"
  fi
  return 1
}

update_prompt_username() {
  local suggested_username="${1:-}"
  local username=""

  while true; do
    username="$(advanced_prompt_value "New GitHub username" "新的 GitHub 用户名" "$suggested_username")" || return 1
    username="$(lowercase "$username")"
    if ! valid_github_username "$username"; then
      advanced_warn \
        "A GitHub username normally contains only letters, numbers, and hyphens." \
        "GitHub 用户名通常只包含字母、数字和连字符，请重新输入。"
      continue
    fi
    if [ "$(lowercase "$username")" = "$(lowercase "$UPDATE_OLD_USERNAME")" ]; then
      advanced_warn \
        "That is the current username. Enter the new username." \
        "这仍是当前用户名，请填写修改后的新用户名。"
      suggested_username=""
      continue
    fi
    printf '%s' "$username"
    return 0
  done
}

update_suggest_email() {
  local username="$1"
  local current_email="$2"

  case "$(lowercase "$current_email")" in
    *@users.noreply.github.com)
      default_email_for_username "$username"
      ;;
    *)
      printf '%s' "$current_email"
      ;;
  esac
}

update_prompt_email() {
  local username="$1"
  local suggested_email=""
  local email=""

  suggested_email="$(update_suggest_email "$username" "$UPDATE_OLD_EMAIL")"
  while true; do
    email="$(advanced_prompt_value "Commit email" "提交邮箱" "$suggested_email")" || return 1
    if valid_email "$email"; then
      printf '%s' "$email"
      return 0
    fi
    advanced_warn "Enter a valid email address." "这个邮箱地址无法识别，请重新输入。"
  done
}

valid_repository_name() {
  local name="$1"

  [ -n "$name" ] || return 1
  [ "$name" != "." ] && [ "$name" != ".." ] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

update_parse_repository_target() {
  local value=""
  local default_owner="$2"

  UPDATE_NEW_OWNER=""
  UPDATE_NEW_REPOSITORY=""
  value="$(trim "$1")"
  value="$(strip_optional_quotes "$value")"

  if [[ "$value" != */* ]] && [[ "$value" != *:* ]]; then
    case "$(lowercase "$value")" in
      *.git)
        value="${value%.*}"
        ;;
    esac
    if valid_repository_name "$value"; then
      UPDATE_NEW_OWNER="$default_owner"
      UPDATE_NEW_REPOSITORY="$value"
      return 0
    fi
    return 1
  fi

  if parse_repository_input "$value"; then
    if [ "$(lowercase "$REPOSITORY_OWNER")" != "$(lowercase "$default_owner")" ]; then
      return 1
    fi
    UPDATE_NEW_OWNER="$REPOSITORY_OWNER"
    UPDATE_NEW_REPOSITORY="$REPOSITORY_NAME"
    return 0
  fi
  return 1
}

update_prompt_repository() {
  local default_owner="$1"
  local value=""

  advanced_muted \
    "Enter only the new repository name, or paste a GitHub address under account $default_owner." \
    "只填写新的仓库名即可，也可以粘贴账号 ${default_owner} 名下的 GitHub 仓库地址。"
  while true; do
    value="$(advanced_prompt_value "New repository name or address" "新的仓库名或地址" "$UPDATE_OLD_REPOSITORY")" || return 1
    if update_parse_repository_target "$value" "$default_owner"; then
      return 0
    fi
    advanced_warn \
      "That repository was not recognized under account $default_owner. This workflow does not mix one account with another account's repository." \
      "没有识别出账号 ${default_owner} 名下的有效仓库。这个流程不会让一个账号读写另一个账号名下的仓库。"
  done
}

update_resolve_identity_file() {
  local expected_username="$1"
  local saved_key=""
  local saved_alias=""

  UPDATE_IDENTITY_FILE=""
  UPDATE_OLD_ALIAS=""
  saved_key="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
  saved_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  if [ -z "$saved_alias" ] && [ -n "$CURRENT_ORIGIN_HOST" ] &&
     ssh_alias_is_github "$CURRENT_ORIGIN_HOST"; then
    saved_alias="$CURRENT_ORIGIN_HOST"
  fi

  if [ -n "$saved_key" ]; then
    saved_key="$(expand_home_path "$saved_key")"
    saved_key="${saved_key//%d/${HOME:-}}"
  fi
  if [ -n "$saved_key" ] && [ -f "$saved_key" ]; then
    UPDATE_IDENTITY_FILE="$saved_key"
    if update_alias_points_to_key "$saved_alias" "$saved_key"; then
      UPDATE_OLD_ALIAS="$saved_alias"
    fi
    return 0
  fi

  advanced_info \
    "Looking for the account key already configured on this computer..." \
    "正在查找这台电脑上已经配置好的账号密钥……"
  if find_local_identity_for_username "$expected_username"; then
    UPDATE_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    UPDATE_OLD_ALIAS="$FOUND_SSH_ALIAS"
    return 0
  fi

  advanced_error \
    "No existing private key for this account was found through the repository settings, origin SSH Host, or ~/.ssh/config." \
    "从当前仓库设置、origin 使用的 SSH 主机名以及 ~/.ssh/config 中，都没有找到这个账号原来使用的私钥。"
  advanced_muted \
    "Run ./$SCRIPT_NAME first so the project can save its local owner and SSH key binding, then retry update." \
    "请先运行 ./${SCRIPT_NAME}，让当前项目保存仓库所属账号与 SSH 密钥的本机绑定，再重试 update。"
  return 1
}

update_verify_identity() {
  local expected_username="$1"

  while true; do
    advanced_info \
      "Asking GitHub which username now accepts the existing private key $(human_path "$UPDATE_IDENTITY_FILE")..." \
      "正在用现有私钥 $(human_path "$UPDATE_IDENTITY_FILE") 向 GitHub 核对更名后的用户名……"
    if identify_key_username "$UPDATE_IDENTITY_FILE"; then
      if [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$expected_username")" ]; then
        advanced_success \
          "GitHub account confirmed: $VERIFIED_GITHUB_USERNAME" \
          "已确认 GitHub 账号：$VERIFIED_GITHUB_USERNAME"
        return 0
      fi
      advanced_error \
        "This key currently authenticates as $VERIFIED_GITHUB_USERNAME, not $expected_username." \
        "这个密钥目前登录的是 ${VERIFIED_GITHUB_USERNAME}，并不是 ${expected_username}。"
    else
      advanced_error \
        "GitHub did not accept the key previously used by this project." \
        "GitHub 没有接受这个项目原来使用的密钥。"
    fi

    advanced_muted \
      "If the username was just changed, wait for GitHub to finish the change and make sure the key is still attached to that account." \
      "如果刚刚修改用户名，请稍等片刻，并确认这个密钥仍然添加在同一个 GitHub 账号中。"
    advanced_muted \
      "GitHub account settings: https://github.com/settings/admin" \
      "GitHub 账号设置：https://github.com/settings/admin"
    if ! advanced_prompt_yes_no \
      "Verify the same existing key with GitHub again?" \
      "要再次用这把现有密钥向 GitHub 核对用户名吗？" \
      "yes"; then
      return 1
    fi
  done
}

update_alias_points_to_key() {
  local alias="$1"
  local expected_key="$2"
  local alias_key=""

  [ -n "$alias" ] || return 1
  ssh_alias_is_github "$alias" || return 1
  alias_key="$(resolve_alias_identity_file "$alias" || true)"
  same_existing_file "$alias_key" "$expected_key"
}

update_find_named_alias_for_key() {
  local username_lc=""
  local alias=""
  local index=0

  username_lc="$(lowercase "$1")"
  scan_ssh_aliases || return 1
  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    alias="${DISCOVERED_SSH_ALIASES[$index]}"
    index=$((index + 1))
    case "$(lowercase "$alias")" in
      "github-$username_lc"|"github-$username_lc-"[0-9]*)
        if update_alias_points_to_key "$alias" "$UPDATE_IDENTITY_FILE"; then
          UPDATE_NEW_ALIAS="$alias"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

update_find_any_alias_for_key() {
  local alias=""
  local index=0

  scan_ssh_aliases || return 1
  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    alias="${DISCOVERED_SSH_ALIASES[$index]}"
    index=$((index + 1))
    if update_alias_points_to_key "$alias" "$UPDATE_IDENTITY_FILE"; then
      UPDATE_NEW_ALIAS="$alias"
      return 0
    fi
  done
  return 1
}

update_next_available_alias() {
  local base="github-$(lowercase "$1")"
  local candidate="$base"
  local suffix=0

  scan_ssh_aliases || return 1
  while ssh_alias_exists "$candidate"; do
    suffix=$((suffix + 1))
    candidate="$base-$suffix"
  done
  UPDATE_NEW_ALIAS="$candidate"
}

update_prepare_alias() {
  local username_changed="$1"

  UPDATE_NEW_ALIAS=""
  UPDATE_INSTALL_ALIAS=false

  if [ "$username_changed" != "yes" ] &&
     update_alias_points_to_key "$UPDATE_OLD_ALIAS" "$UPDATE_IDENTITY_FILE"; then
    UPDATE_NEW_ALIAS="$UPDATE_OLD_ALIAS"
    return 0
  fi

  if [ "$username_changed" = "yes" ]; then
    if update_find_named_alias_for_key "$UPDATE_NEW_USERNAME"; then
      return 0
    fi
  elif update_find_any_alias_for_key; then
    return 0
  fi

  update_next_available_alias "$UPDATE_NEW_USERNAME" || return 1
  UPDATE_INSTALL_ALIAS=true
  return 0
}

update_verify_repository() {
  local remote_url="git@github.com:${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY}.git"
  local output=""
  local detail=""

  if [ "$(lowercase "$UPDATE_NEW_USERNAME")" != "$(lowercase "$UPDATE_NEW_OWNER")" ]; then
    advanced_error \
      "Stopped because account $UPDATE_NEW_USERNAME does not match repository owner $UPDATE_NEW_OWNER." \
      "操作已停止：账号 ${UPDATE_NEW_USERNAME} 与仓库所属账号 ${UPDATE_NEW_OWNER} 不一致。"
    return 1
  fi
  while true; do
    advanced_info \
      "Reading ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY} with account $UPDATE_NEW_USERNAME; this check does not change the repository." \
      "正在用账号 $UPDATE_NEW_USERNAME 读取 ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY} 的远端信息；这一步不会修改仓库。"
    output="$(run_git_with_identity "$UPDATE_IDENTITY_FILE" ls-remote "$remote_url" HEAD 2>&1)" && {
      advanced_success \
        "The repository responded to the SSH key verified for account $UPDATE_NEW_USERNAME. No local or remote setting has been changed yet." \
        "仓库已响应账号 ${UPDATE_NEW_USERNAME} 的已验证 SSH 密钥；此时尚未修改任何本机或远端设置。"
      return 0
    }

    advanced_error \
      "$UPDATE_NEW_USERNAME cannot access ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY} yet." \
      "$UPDATE_NEW_USERNAME 目前还无法访问 ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY}。"
    detail="${output##*$'\n'}"
    if [ -n "$detail" ]; then
      advanced_muted "Git result: $detail" "Git 返回信息：$detail"
    fi
    advanced_muted \
      "GitHub may still be processing the change. Also make sure this account can access the repository." \
      "GitHub 可能仍在同步刚才的更名，也请确认这个账号拥有该仓库的访问权限。"
    advanced_muted \
      "Current repository settings: https://github.com/${UPDATE_OLD_OWNER}/${UPDATE_OLD_REPOSITORY}/settings" \
      "当前仓库设置：https://github.com/${UPDATE_OLD_OWNER}/${UPDATE_OLD_REPOSITORY}/settings"
    if ! advanced_prompt_yes_no \
      "Run the same read-only access check again?" \
      "要再次执行同一项只读访问检查吗？" \
      "yes"; then
      return 1
    fi
  done
}

remove_account_at_index() {
  local remove_index="$1"
  local index="$remove_index"
  local last_index=""

  while [ "$index" -lt $((ACCOUNT_COUNT - 1)) ]; do
    ACCOUNT_USERNAMES[$index]="${ACCOUNT_USERNAMES[$((index + 1))]}"
    ACCOUNT_EMAILS[$index]="${ACCOUNT_EMAILS[$((index + 1))]}"
    index=$((index + 1))
  done
  if [ "$ACCOUNT_COUNT" -gt 0 ]; then
    last_index=$((ACCOUNT_COUNT - 1))
    unset "ACCOUNT_USERNAMES[$last_index]"
    unset "ACCOUNT_EMAILS[$last_index]"
    ACCOUNT_COUNT=$((ACCOUNT_COUNT - 1))
  fi
}

update_account_entry() {
  local old_username="$1"
  local new_username="$2"
  local new_email="$3"
  local old_index=""
  local new_index=""

  old_index="$(account_index "$old_username" 2>/dev/null || true)"
  new_index="$(account_index "$new_username" 2>/dev/null || true)"

  if [ -n "$old_index" ] && [ -n "$new_index" ] && [ "$old_index" != "$new_index" ]; then
    ACCOUNT_USERNAMES[$new_index]="$new_username"
    ACCOUNT_EMAILS[$new_index]="$new_email"
    remove_account_at_index "$old_index"
  elif [ -n "$old_index" ]; then
    ACCOUNT_USERNAMES[$old_index]="$new_username"
    ACCOUNT_EMAILS[$old_index]="$new_email"
  else
    add_or_update_account "$new_username" "$new_email"
  fi
}

update_apply_validated_settings() {
  local username_changed="$1"

  if [ "$UPDATE_INSTALL_ALIAS" = true ]; then
    install_ssh_alias_block "$UPDATE_NEW_USERNAME" "$UPDATE_NEW_ALIAS" "$UPDATE_IDENTITY_FILE"
  fi

  if [ "$username_changed" = "yes" ]; then
    update_account_entry "$UPDATE_ACCOUNT_USERNAME" "$UPDATE_NEW_USERNAME" "$UPDATE_NEW_EMAIL"
    write_accounts_to_private_config
  fi

  CURRENT_REPOSITORY_OWNER="$UPDATE_NEW_OWNER"
  CURRENT_REPOSITORY_NAME="$UPDATE_NEW_REPOSITORY"
  BOUND_USERNAME="$UPDATE_NEW_USERNAME"
  BOUND_EMAIL="$UPDATE_NEW_EMAIL"
  BOUND_SSH_ALIAS="$UPDATE_NEW_ALIAS"
  BOUND_IDENTITY_FILE="$UPDATE_IDENTITY_FILE"

  save_project_binding
}

run_update_command() (
  local choice=""
  local selection_status=0
  local username_changed="no"
  local repository_changed="no"
  local default_owner=""

  require_interactive
  ADVANCED_LANGUAGE="$UI_LANGUAGE"

  require_core_commands
  if ! locate_project no; then
    advanced_error \
      "This folder is not a Git project. Place $SCRIPT_NAME in the project root and run ./$SCRIPT_NAME first." \
      "当前文件夹还不是 Git 项目。请把 ${SCRIPT_NAME} 放到项目根目录，并先运行 ./${SCRIPT_NAME}。"
    return 1
  fi
  acquire_workflow_lock || return 1
  install_workflow_cleanup_traps
  advanced_success \
    "Existing Git repository detected: $(human_path "$GIT_ROOT"). git init will not run." \
    "已识别现有 Git 仓库：$(human_path "$GIT_ROOT")。不会执行 git init。"
  if ! read_origin_repository; then
    advanced_error \
      "The current project does not have a recognizable GitHub origin." \
      "当前项目还没有可识别的 GitHub 远端仓库。"
    advanced_muted \
      "Run ./$SCRIPT_NAME first and provide the GitHub repository address when prompted." \
      "请先运行 ./${SCRIPT_NAME}，并在提示时填写这个项目对应的 GitHub 仓库地址。"
    return 1
  fi

  UPDATE_OLD_OWNER="$CURRENT_REPOSITORY_OWNER"
  UPDATE_OLD_REPOSITORY="$CURRENT_REPOSITORY_NAME"
  update_select_current_account || selection_status=$?
  if [ "$selection_status" -eq 2 ]; then
    return 0
  elif [ "$selection_status" -ne 0 ]; then
    return 1
  fi
  advanced_heading "Current project" "当前项目信息"
  advanced_muted \
    "Account: $UPDATE_OLD_USERNAME" \
    "GitHub 账号：$UPDATE_OLD_USERNAME"
  advanced_muted \
    "Repository: ${UPDATE_OLD_OWNER}/${UPDATE_OLD_REPOSITORY}" \
    "仓库：${UPDATE_OLD_OWNER}/${UPDATE_OLD_REPOSITORY}"
  advanced_muted \
    "This flow assumes the change is already complete on GitHub and now synchronizes this computer." \
    "这里会按照 GitHub 上已经完成的更名，同步这台电脑上的设置。"

  advanced_heading "What changed?" "需要同步哪项改名？"
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    printf '  1) GitHub username\n'
    printf '  2) Repository name\n'
    printf '  3) Both username and repository\n'
    printf '  0) Cancel\n'
  else
    printf '  1) GitHub 用户名\n'
    printf '  2) 仓库名称\n'
    printf '  3) 用户名和仓库都变了\n'
    printf '  0) 取消\n'
  fi
  while true; do
    choice="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        username_changed="yes"
        break
        ;;
      2)
        repository_changed="yes"
        break
        ;;
      3)
        username_changed="yes"
        repository_changed="yes"
        break
        ;;
      0)
        return 0
        ;;
      *)
        advanced_warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done

  UPDATE_NEW_USERNAME="$UPDATE_OLD_USERNAME"
  UPDATE_NEW_EMAIL="$UPDATE_OLD_EMAIL"
  if [ "$username_changed" = "yes" ]; then
    UPDATE_NEW_USERNAME="$(update_prompt_username)" || return 1
    UPDATE_NEW_EMAIL="$(update_prompt_email "$UPDATE_NEW_USERNAME")" || return 1
  fi

  default_owner="$UPDATE_NEW_USERNAME"
  UPDATE_NEW_OWNER="$default_owner"
  UPDATE_NEW_REPOSITORY="$UPDATE_OLD_REPOSITORY"
  if [ "$repository_changed" = "yes" ]; then
    while true; do
      update_prompt_repository "$default_owner" || return 1
      if [ "$(lowercase "$UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY")" != \
           "$(lowercase "$UPDATE_OLD_OWNER/$UPDATE_OLD_REPOSITORY")" ]; then
        break
      fi
      advanced_warn \
        "That is still the current repository. Enter the new name or address." \
        "这仍是当前仓库，请填写改名后的仓库名或地址。"
    done
  fi

  # A GitHub username change keeps the same account key. If the repository's
  # exact key binding is incomplete, search by the former username and alias.
  update_resolve_identity_file "$UPDATE_OLD_USERNAME" || return 1
  update_prepare_alias "$username_changed" || {
    advanced_error \
      "An unused SSH Host name for the existing key could not be selected." \
      "无法为现有密钥找到不冲突的 SSH 主机名。"
    return 1
  }
  advanced_info \
    "No online precheck is run during update. This command changes only local settings; the next git push will return GitHub's actual account and repository result." \
    "update 不会提前联网核对。这个命令只修改本机设置；下次执行 git push 时，再以 GitHub 对账号和仓库返回的实际结果为准。"

  advanced_heading "Review the local settings that will change" "核对即将修改的本机设置"
  advanced_muted \
    "Account: $UPDATE_OLD_USERNAME -> $UPDATE_NEW_USERNAME" \
    "GitHub 账号：$UPDATE_OLD_USERNAME -> $UPDATE_NEW_USERNAME"
  advanced_muted \
    "Repository: $UPDATE_OLD_OWNER/$UPDATE_OLD_REPOSITORY -> $UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY" \
    "仓库：$UPDATE_OLD_OWNER/$UPDATE_OLD_REPOSITORY -> $UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY"
  if [ "$username_changed" = "yes" ]; then
    advanced_muted \
      "Commit email: $UPDATE_NEW_EMAIL" \
      "提交邮箱：$UPDATE_NEW_EMAIL"
    advanced_muted \
      "The existing account key will be reused. No new key will be created." \
      "原账号密钥会继续使用，不会重复创建新密钥。"
    advanced_muted \
      "private/config.txt: replace the saved username and commit email." \
      "private/config.txt：更新已保存的用户名和提交邮箱。"
  fi
  if [ "$UPDATE_INSTALL_ALIAS" = true ]; then
    advanced_muted \
      "~/.ssh/config: add SSH Host $UPDATE_NEW_ALIAS for the existing private key; the previous Host entry will remain." \
      "~/.ssh/config：为现有私钥新增 SSH 主机名 ${UPDATE_NEW_ALIAS}；原来的主机配置会继续保留。"
  fi
  advanced_muted \
    ".git/config: update the repository-local commit author, selected account, exact private key, and origin fetch/push address." \
    ".git/config：更新当前仓库的提交作者、所选账号、指定私钥以及 origin 的拉取和推送地址。"
  advanced_muted \
    "Project files, commits, branches, and the GitHub repository will not be changed or pushed." \
    "项目文件、提交记录、分支和 GitHub 远端仓库都不会被修改，也不会执行推送。"

  if ! advanced_prompt_yes_no "Apply these updates?" "确认更新本机设置？" "yes"; then
    advanced_warn \
      "Canceled. private/config.txt, ~/.ssh/config, this repository's .git/config, project files, and the GitHub repository were not changed." \
      "已取消；private/config.txt、~/.ssh/config、当前仓库的 .git/config、项目文件和 GitHub 远端仓库均未修改。"
    return 0
  fi

  if ! update_apply_validated_settings "$username_changed"; then
    advanced_error \
      "The project settings could not be saved completely. Run this command again to finish the update." \
      "项目设置未能全部保存。请重新运行这个命令完成更新。"
    return 1
  fi

  advanced_success \
    "Saved the requested username, repository address, commit author, SSH key, and origin in the local configuration files shown above." \
    "已把指定的用户名、仓库地址、提交作者、SSH 密钥和 origin 保存到上面列出的本机配置文件中。"
  if [ "$username_changed" = "yes" ] && [ -n "$UPDATE_OLD_ALIAS" ]; then
    advanced_muted \
      "The previous SSH Host entry was kept so other local projects that reference it continue to work." \
      "原来的 SSH 主机配置已保留，避免影响仍在引用它的其他本地项目。"
  fi
)
