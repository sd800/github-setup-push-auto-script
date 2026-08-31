# -----------------------------------------------------------------------------
# Git repository binding and strict push identity
# -----------------------------------------------------------------------------

GIT_ROOT=""
PROJECT_GIT_STATE=""
CURRENT_BRANCH=""
CURRENT_ORIGIN_URL=""
CURRENT_ORIGIN_HOST=""
ORIGIN_VERIFIED_USERNAME=""
ORIGIN_VERIFIED_ALIAS=""
ORIGIN_VERIFIED_IDENTITY_FILE=""
CURRENT_REPOSITORY_OWNER=""
CURRENT_REPOSITORY_NAME=""
BOUND_USERNAME=""
BOUND_EMAIL=""
BOUND_SSH_ALIAS=""
BOUND_IDENTITY_FILE=""
PROJECT_BINDING_REUSED=false

require_core_commands() {
  local missing=""
  local command_name=""

  for command_name in git ssh awk sed find; do
    if ! command_exists "$command_name"; then
      missing="$missing $command_name"
    fi
  done

  if [ -n "$missing" ]; then
    fail \
      "Required tools are missing: $(trim "$missing")" \
      "缺少必要工具：$(trim "$missing")"
  fi
}

locate_project() {
  local initialize="${1:-yes}"
  local existing_root=""

  if existing_root="$(git -C "$SCRIPT_DIRECTORY" rev-parse --show-toplevel 2>/dev/null)"; then
    existing_root="$({ cd "$existing_root" 2>/dev/null && pwd -P; } || return 1)"
    # macOS can spell the same directory with different case or an equivalent
    # physical prefix (for example /var and /private/var). Compare the actual
    # directory objects instead of their displayed path strings.
    if [ ! "$existing_root" -ef "$SCRIPT_DIRECTORY" ]; then
      fail \
        "$SCRIPT_NAME is in $(human_path "$SCRIPT_DIRECTORY"), but the Git repository root is $(human_path "$existing_root"). Place $SCRIPT_NAME in that repository root before running it." \
        "$SCRIPT_NAME 位于 $(human_path "$SCRIPT_DIRECTORY")，但这个 Git 仓库的根目录是 $(human_path "$existing_root")。请把 $SCRIPT_NAME 放到该仓库根目录后再运行。"
    fi
    GIT_ROOT="$existing_root"
    PROJECT_GIT_STATE="existing"
    return 0
  fi

  if [ "$initialize" != "yes" ]; then
    return 1
  fi

  heading "Prepare the local Git repository" "准备本地 Git 仓库"
  warn \
    "No Git repository exists at $(human_path "$SCRIPT_DIRECTORY")." \
    "$(human_path "$SCRIPT_DIRECTORY") 还不是 Git 仓库。"
  muted \
    "The script will run git init in this folder. This creates local .git metadata only; it does not create a GitHub repository or upload files." \
    "接下来只会在这个文件夹中执行 git init，创建本地 .git 记录；此时不会创建 GitHub 仓库，也不会上传文件。"
  if ! git -C "$SCRIPT_DIRECTORY" init >/dev/null; then
    fail "The Git project could not be initialized." "Git 项目初始化失败。"
  fi
  GIT_ROOT="$SCRIPT_DIRECTORY"
  PROJECT_GIT_STATE="initialized"
  success \
    "Created the local Git repository: $(human_path "$GIT_ROOT")" \
    "已创建本地 Git 仓库：$(human_path "$GIT_ROOT")"
}

git_operation_in_progress() {
  local git_directory=""
  local state_name=""

  git_directory="$(git -C "$GIT_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [ -n "$git_directory" ] || return 1
  for state_name in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    [ -e "$git_directory/$state_name" ] && return 0
  done
  for state_name in rebase-merge rebase-apply; do
    [ -d "$git_directory/$state_name" ] && return 0
  done
  return 1
}

describe_and_validate_project_state() {
  local unmerged=""

  CURRENT_BRANCH="$(git -C "$GIT_ROOT" branch --show-current 2>/dev/null || true)"
  heading "Current local project" "当前本地项目"

  if [ "$PROJECT_GIT_STATE" = "existing" ]; then
    success \
      "Existing Git repository detected: $(human_path "$GIT_ROOT")" \
      "已识别现有 Git 仓库：$(human_path "$GIT_ROOT")"
    muted \
      "git init will not run again. Existing commits, branches, staged changes, and remotes will be preserved." \
      "不会再次执行 git init；现有提交记录、分支、暂存内容和远端设置都会保留。"
  else
    success \
      "Using the Git repository just created in $(human_path "$GIT_ROOT")." \
      "将使用刚刚在 $(human_path "$GIT_ROOT") 创建的 Git 仓库。"
  fi

  if [ -n "$CURRENT_BRANCH" ]; then
    muted "Current branch: $CURRENT_BRANCH" "当前分支：$CURRENT_BRANCH"
  elif git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    error_message \
      "HEAD is detached, so there is no current branch to push. Check out the intended branch and run ./$SCRIPT_NAME again." \
      "当前处于 detached HEAD 状态，没有可直接上传的当前分支。请先切换到目标分支，再重新运行 ./${SCRIPT_NAME}。"
    return 1
  else
    muted \
      "This repository has no commits yet; the first branch will be named main." \
      "这个仓库还没有提交记录；首次提交后分支名将统一为 main。"
  fi

  unmerged="$(git -C "$GIT_ROOT" diff --name-only --diff-filter=U 2>/dev/null || true)"
  if [ -n "$unmerged" ]; then
    error_message \
      "Unresolved merge conflicts were found. Resolve the files listed by git status before running this script." \
      "检测到尚未解决的合并冲突。请先按照 git status 列出的文件完成处理，再运行本脚本。"
    git -C "$GIT_ROOT" status --short
    return 1
  fi
  if git_operation_in_progress; then
    error_message \
      "A merge, rebase, cherry-pick, or revert is still in progress. Finish or cancel that Git operation before running this script." \
      "当前还有尚未完成的 merge、rebase、cherry-pick 或 revert。请先完成或取消该 Git 操作，再运行本脚本。"
    return 1
  fi
}

ensure_script_excluded() {
  local exclude_file=""
  local temporary_file=""
  local line=""
  local skipping=false
  local marker_start="# >>> github-auto script >>>"
  local marker_end="# <<< github-auto script <<<"

  # The public launcher in the central repository is intentionally tracked.
  # Only standalone project copies belong in the repository-local exclude file.
  if git -C "$GIT_ROOT" ls-files --error-unmatch -- "$SCRIPT_NAME" >/dev/null 2>&1; then
    return 0
  fi

  exclude_file="$(git -C "$GIT_ROOT" rev-parse --git-path info/exclude)"
  case "$exclude_file" in
    /*)
      ;;
    *)
      exclude_file="$GIT_ROOT/$exclude_file"
      ;;
  esac

  mkdir -p "$(dirname "$exclude_file")" || fail \
    "The local Git exclusion settings could not be prepared." \
    "无法准备 Git 本地排除设置。"
  [ -f "$exclude_file" ] || : > "$exclude_file"
  if grep -Fqx "$marker_start" "$exclude_file" 2>/dev/null &&
     grep -Fqx "/$SCRIPT_NAME" "$exclude_file" 2>/dev/null &&
     grep -Fqx "$marker_end" "$exclude_file" 2>/dev/null; then
    return 0
  fi
  temporary_file="$(safe_mktemp_file "$(dirname "$exclude_file")" "exclude")" ||
    fail \
      "The local Git exclusion settings could not be updated." \
      "无法更新 Git 本地排除设置。"

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$marker_start" ]; then
      skipping=true
      continue
    fi
    if [ "$skipping" = true ]; then
      if [ "$line" = "$marker_end" ]; then
        skipping=false
      fi
      continue
    fi
    printf '%s\n' "$line" >> "$temporary_file"
  done < "$exclude_file"

  if [ -s "$temporary_file" ]; then
    printf '\n' >> "$temporary_file"
  fi
  printf '%s\n/%s\n%s\n' "$marker_start" "$SCRIPT_NAME" "$marker_end" >> "$temporary_file"
  mv "$temporary_file" "$exclude_file" || fail \
    "The local Git exclusion settings could not be saved." \
    "无法保存 Git 本地排除设置。"
}

read_origin_repository() {
  local url=""

  ORIGIN_VERIFIED_USERNAME=""
  ORIGIN_VERIFIED_ALIAS=""
  ORIGIN_VERIFIED_IDENTITY_FILE=""
  if ! url="$(git -C "$GIT_ROOT" remote get-url origin 2>/dev/null)"; then
    return 1
  fi
  if ! parse_repository_input "$url"; then
    return 1
  fi

  CURRENT_ORIGIN_URL="$url"
  CURRENT_ORIGIN_HOST="$REPOSITORY_INPUT_HOST"
  CURRENT_REPOSITORY_OWNER="$REPOSITORY_OWNER"
  CURRENT_REPOSITORY_NAME="$REPOSITORY_NAME"
  return 0
}

identify_origin_ssh_account() {
  local key=""

  [ -n "$CURRENT_ORIGIN_HOST" ] || return 1
  ssh_alias_is_github "$CURRENT_ORIGIN_HOST" || return 1
  key="$(resolve_alias_identity_file "$CURRENT_ORIGIN_HOST" || true)"
  [ -f "$key" ] || return 1

  info \
    "The existing origin uses SSH Host $CURRENT_ORIGIN_HOST. Asking GitHub which account accepts its key; saved account and repository settings will not be changed." \
    "现有 origin 使用 SSH 主机名 ${CURRENT_ORIGIN_HOST}。正在向 GitHub 核对该主机名所用密钥对应的账号；这一步不会修改已保存账号或仓库设置。"
  if ! identify_key_username "$key"; then
    warn \
      "GitHub did not confirm the key currently referenced by origin SSH Host $CURRENT_ORIGIN_HOST." \
      "GitHub 暂时没有确认 origin 的 SSH 主机名 ${CURRENT_ORIGIN_HOST} 所引用的密钥。"
    if [ -n "${SSH_VERIFICATION_OUTPUT:-}" ]; then
      muted \
        "SSH result: ${SSH_VERIFICATION_OUTPUT##*$'\n'}" \
        "SSH 返回信息：${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    fi
    return 1
  fi

  ORIGIN_VERIFIED_USERNAME="$VERIFIED_GITHUB_USERNAME"
  ORIGIN_VERIFIED_ALIAS="$CURRENT_ORIGIN_HOST"
  ORIGIN_VERIFIED_IDENTITY_FILE="$key"
  return 0
}

select_verified_origin_account() {
  local allow_registration="${1:-yes}"
  local index=""
  local email=""

  if [ -z "$ORIGIN_VERIFIED_USERNAME" ]; then
    identify_origin_ssh_account || return 1
  fi

  if [ -n "${CURRENT_REPOSITORY_OWNER:-}" ] &&
     [ "$(lowercase "$ORIGIN_VERIFIED_USERNAME")" != "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ]; then
    warn \
      "The origin key authenticates as $ORIGIN_VERIFIED_USERNAME, but this repository belongs to $CURRENT_REPOSITORY_OWNER. The origin account will not be selected." \
      "origin 使用的密钥登录账号是 ${ORIGIN_VERIFIED_USERNAME}，但当前仓库属于 ${CURRENT_REPOSITORY_OWNER}。脚本不会选择这个 origin 账号。"
    return 1
  fi

  if index="$(account_index "$ORIGIN_VERIFIED_USERNAME")"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
    info \
      "The existing origin authenticates as saved account $BOUND_USERNAME, so that account was selected." \
      "现有 origin 使用的密钥已验证为已保存账号 ${BOUND_USERNAME}，因此本次直接使用该账号。"
    return 0
  fi

  [ "$allow_registration" = "yes" ] || return 1
  heading "Use the account already connected to this repository" "使用当前仓库已经连接的账号"
  success \
    "GitHub confirmed that origin SSH Host $ORIGIN_VERIFIED_ALIAS authenticates as $ORIGIN_VERIFIED_USERNAME." \
    "GitHub 已确认 origin 的 SSH 主机名 ${ORIGIN_VERIFIED_ALIAS} 使用账号 ${ORIGIN_VERIFIED_USERNAME}。"
  muted \
    "Only the commit email is still needed. The existing SSH key will be reused, and Git will not be initialized again." \
    "现在只需确认提交邮箱。脚本会继续使用现有 SSH 密钥，也不会重新初始化 Git 仓库。"
  email="$(prompt_account_email "$ORIGIN_VERIFIED_USERNAME")" || return 1
  register_account_and_identity \
    "$ORIGIN_VERIFIED_USERNAME" \
    "$email" \
    "$ORIGIN_VERIFIED_ALIAS" \
    "$ORIGIN_VERIFIED_IDENTITY_FILE"
  BOUND_USERNAME="$SELECTED_USERNAME"
  BOUND_EMAIL="$SELECTED_EMAIL"
  return 0
}

select_account_for_repository() {
  local owner="$1"
  local preferred_username="${2:-}"
  local saved_username=""
  local index=""
  local email=""

  saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  if [ -n "$saved_username" ] &&
     [ "$(lowercase "$saved_username")" != "$(lowercase "$owner")" ]; then
    warn \
      "This repository was previously saved with account $saved_username, but its GitHub owner is $owner. The mismatched binding will not be used." \
      "当前仓库以前保存的账号是 ${saved_username}，但 GitHub 仓库属于 ${owner}。脚本不会继续使用这个不匹配的账号。"
  fi

  if [ -n "$preferred_username" ] &&
     [ "$(lowercase "$preferred_username")" != "$(lowercase "$owner")" ]; then
    warn \
      "Account $preferred_username was supplied by an earlier setup step, but this repository belongs to $owner. Only account $owner can be used for this repository." \
      "前面的设置步骤提供了账号 ${preferred_username}，但当前仓库属于 ${owner}。这个仓库只能使用账号 ${owner}。"
  fi

  if index="$(account_index "$owner")"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
    info \
      "The repository owner matches saved account $BOUND_USERNAME, so that account was selected." \
      "仓库所属用户名与已保存账号 $BOUND_USERNAME 一致，因此本次使用该账号。"
    return 0
  fi

  heading \
    "Set up the account that owns this repository" \
    "配置当前仓库所属的 GitHub 账号"
  muted \
    "The destination is $owner/${CURRENT_REPOSITORY_NAME}. To prevent accounts from being mixed, this repository must use GitHub account $owner." \
    "目标仓库是 ${owner}/${CURRENT_REPOSITORY_NAME}。为避免多个账号相互串用，当前仓库必须使用 GitHub 账号 ${owner}。"
  muted \
    "Only the commit email is needed. The script uses a local SSH Host named for $owner, or creates a separate one when none exists." \
    "现在只需确认提交邮箱。脚本会使用按账号 ${owner} 命名的本机 SSH 主机；没有对应配置时，再为该账号创建独立密钥。"
  email="$(prompt_account_email "$owner")" || return 1
  setup_or_reuse_account "$owner" "$email" || return 1
  BOUND_USERNAME="$SELECTED_USERNAME"
  BOUND_EMAIL="$SELECTED_EMAIL"
}

repository_account_matches_owner() {
  [ -n "${BOUND_USERNAME:-}" ] &&
    [ -n "${CURRENT_REPOSITORY_OWNER:-}" ] &&
    [ "$(lowercase "$BOUND_USERNAME")" = "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ]
}

require_repository_account_match() {
  if repository_account_matches_owner; then
    return 0
  fi
  error_message \
    "Stopped because account ${BOUND_USERNAME:-<none>} does not match repository owner ${CURRENT_REPOSITORY_OWNER:-<unknown>}. No remote operation was attempted." \
    "操作已停止：当前账号 ${BOUND_USERNAME:-<未选择>} 与仓库所属账号 ${CURRENT_REPOSITORY_OWNER:-<无法识别>} 不一致。脚本没有执行任何远端操作。"
  return 1
}

load_established_project_binding() {
  local saved_username=""
  local saved_alias=""
  local saved_key=""
  local alias_key=""
  local push_url=""
  local canonical_saved_key=""
  local canonical_alias_key=""
  local index=""

  PROJECT_BINDING_REUSED=false
  saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  [ -n "$saved_username" ] || return 1
  [ "$(lowercase "$saved_username")" = "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ] || return 1
  index="$(account_index "$CURRENT_REPOSITORY_OWNER" 2>/dev/null)" || return 1

  saved_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  saved_key="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
  saved_key="$(expand_home_path "$saved_key")"
  saved_key="${saved_key//%d/${HOME:-}}"
  [ -n "$saved_alias" ] && [ -f "$saved_key" ] || return 1
  ssh_alias_is_github "$saved_alias" || return 1
  alias_key="$(resolve_alias_identity_file "$saved_alias" || true)"
  [ -f "$alias_key" ] || return 1
  canonical_saved_key="$(canonical_existing_file "$saved_key" || true)"
  canonical_alias_key="$(canonical_existing_file "$alias_key" || true)"
  [ -n "$canonical_saved_key" ] && [ "$canonical_saved_key" = "$canonical_alias_key" ] || return 1

  push_url="$(git -C "$GIT_ROOT" remote get-url --push origin 2>/dev/null || true)"
  [ -n "$push_url" ] || return 1
  parse_repository_input "$push_url" || return 1
  [ "$(lowercase "$REPOSITORY_OWNER")" = "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ] || return 1
  [ "$(lowercase "$REPOSITORY_NAME")" = "$(lowercase "$CURRENT_REPOSITORY_NAME")" ] || return 1

  BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
  BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
  BOUND_SSH_ALIAS="$saved_alias"
  BOUND_IDENTITY_FILE="$saved_key"
  PROJECT_BINDING_REUSED=true
  return 0
}

ensure_bound_identity_with_github_verification() {
  local preferred_alias=""
  local saved_key=""
  local verification_detail=""

  preferred_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  saved_key="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
  saved_key="$(expand_home_path "$saved_key")"
  saved_key="${saved_key//%d/${HOME:-}}"

  if [ -n "$ORIGIN_VERIFIED_USERNAME" ] &&
     [ "$(lowercase "$ORIGIN_VERIFIED_USERNAME")" = "$(lowercase "$BOUND_USERNAME")" ] &&
     [ -f "$ORIGIN_VERIFIED_IDENTITY_FILE" ]; then
    BOUND_SSH_ALIAS="$ORIGIN_VERIFIED_ALIAS"
    BOUND_IDENTITY_FILE="$ORIGIN_VERIFIED_IDENTITY_FILE"
    success \
      "GitHub account confirmed: $BOUND_USERNAME." \
      "已确认本次使用 GitHub 账号：${BOUND_USERNAME}。"
    technical_detail \
      normal \
      "SSH Host $BOUND_SSH_ALIAS uses key $(human_path "$BOUND_IDENTITY_FILE")." \
      "SSH 主机名 ${BOUND_SSH_ALIAS} 使用密钥 $(human_path "$BOUND_IDENTITY_FILE")。"
    return 0
  fi

  if [ -z "$preferred_alias" ] && [ -n "$CURRENT_ORIGIN_HOST" ]; then
    case "$(lowercase "$CURRENT_ORIGIN_HOST")" in
      github.com|www.github.com|ssh.github.com)
        ;;
      *)
        if ssh_alias_is_github "$CURRENT_ORIGIN_HOST"; then
          preferred_alias="$CURRENT_ORIGIN_HOST"
          technical_detail \
            normal \
            "The existing origin uses SSH Host $preferred_alias; that existing key will be checked first." \
            "现有 origin 使用 SSH 主机名 ${preferred_alias}，将优先核对它指定的现有密钥。"
        fi
        ;;
    esac
  fi

  if [ -n "$saved_key" ] && [ -f "$saved_key" ]; then
    if identify_key_username "$saved_key" &&
       [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$BOUND_USERNAME")" ]; then
      BOUND_IDENTITY_FILE="$saved_key"
      if find_github_alias_for_identity_file "$saved_key" "$preferred_alias"; then
        BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
      else
        next_available_alias "$BOUND_USERNAME" || fail \
          "An unused SSH Host name could not be selected for this repository's existing key." \
          "无法为当前仓库已有的密钥找到不冲突的 SSH 主机名。"
        BOUND_SSH_ALIAS="$NEW_SSH_ALIAS"
        info \
          "The saved key has no usable GitHub SSH Host entry. Adding $BOUND_SSH_ALIAS to ~/.ssh/config for this existing key." \
          "当前仓库保存的密钥还没有可用的 GitHub SSH 主机配置。将把 ${BOUND_SSH_ALIAS} 添加到 ~/.ssh/config，并继续使用这把现有密钥。"
        install_ssh_alias_block "$BOUND_USERNAME" "$BOUND_SSH_ALIAS" "$BOUND_IDENTITY_FILE"
      fi
      success \
        "GitHub account confirmed: $BOUND_USERNAME." \
        "已确认本次使用 GitHub 账号：${BOUND_USERNAME}。"
      technical_detail \
        normal \
        "SSH Host $BOUND_SSH_ALIAS uses key $(human_path "$BOUND_IDENTITY_FILE")." \
        "SSH 主机名 ${BOUND_SSH_ALIAS} 使用密钥 $(human_path "$BOUND_IDENTITY_FILE")。"
      return 0
    fi
  fi

  if find_verified_identity_for_username "$BOUND_USERNAME" "$preferred_alias"; then
    BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
    BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    success \
      "GitHub account confirmed: $BOUND_USERNAME." \
      "已确认本次使用 GitHub 账号：${BOUND_USERNAME}。"
    technical_detail \
      normal \
      "SSH Host $BOUND_SSH_ALIAS uses key $(human_path "$BOUND_IDENTITY_FILE")." \
      "SSH 主机名 ${BOUND_SSH_ALIAS} 使用密钥 $(human_path "$BOUND_IDENTITY_FILE")。"
    return 0
  fi

  heading "GitHub SSH identity" "核对 GitHub SSH 身份"
  if [ -n "$FOUND_UNVERIFIED_IDENTITY_FILE" ]; then
    warn \
      "An existing key was found at $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE"), but GitHub did not confirm it for account $BOUND_USERNAME." \
      "找到了现有密钥 $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE")，但暂时无法确认它属于 GitHub 账号 ${BOUND_USERNAME}。"
    verification_detail="${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    if [ -n "$verification_detail" ]; then
      muted "SSH result: $verification_detail" "SSH 返回信息：$verification_detail"
    fi
    muted \
      "This can mean the network cannot reach GitHub, or that this public key is not registered with the account." \
      "这通常表示当前网络无法连接 GitHub，或这把密钥的公钥尚未添加到该账号。"
    if ui_prompt_yes_no \
      "Verify this existing key with GitHub again before creating anything?" \
      "要先重新验证这把现有密钥，再决定是否创建新密钥吗？" \
      "yes"; then
      if identify_key_username "$FOUND_UNVERIFIED_IDENTITY_FILE" &&
         [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$BOUND_USERNAME")" ]; then
        BOUND_SSH_ALIAS="$FOUND_UNVERIFIED_SSH_ALIAS"
        BOUND_IDENTITY_FILE="$FOUND_UNVERIFIED_IDENTITY_FILE"
        success \
          "GitHub confirmed that the existing key belongs to account $BOUND_USERNAME." \
          "GitHub 已确认这把现有密钥属于账号 ${BOUND_USERNAME}。"
        return 0
      fi
      warn \
        "GitHub still did not confirm this key for account $BOUND_USERNAME." \
        "GitHub 仍未确认这把密钥属于账号 ${BOUND_USERNAME}。"
    fi
  else
    warn \
      "No SSH private key accepted by GitHub for account $BOUND_USERNAME was found in ~/.ssh/config or its Include files." \
      "在 ~/.ssh/config 及其 Include 文件中，没有找到可由 GitHub 确认为账号 $BOUND_USERNAME 的现有私钥。"
  fi

  next_available_alias "$BOUND_USERNAME" || fail \
    "An unused SSH Host name and key filename could not be selected." \
    "无法为新密钥找到不冲突的 SSH 主机名和文件名。"
  muted \
    "Continuing will create $(human_path "$NEW_IDENTITY_FILE") and add SSH Host $NEW_SSH_ALIAS to ~/.ssh/config." \
    "如果继续，脚本将创建 $(human_path "$NEW_IDENTITY_FILE")，并在 ~/.ssh/config 中加入 SSH 主机名 ${NEW_SSH_ALIAS}。"
  muted \
    "The public key will be shown for you to add to GitHub. This advanced path verifies the new key before it returns." \
    "随后会显示公钥，供你添加到 GitHub。这条高级流程会在返回前联网核对新密钥。"
  if ! ui_prompt_yes_no \
    "Create and configure this separate SSH key now?" \
    "现在创建并配置这把独立的 SSH 密钥吗？" \
    "yes"; then
    warn \
      "Stopped before creating a key, changing the repository's account settings, committing, or pushing." \
      "操作已停止；没有创建新密钥，也没有修改当前仓库的账号设置、提交或上传。"
    return 1
  fi

  if create_new_identity "$BOUND_USERNAME" "$BOUND_EMAIL" &&
     verify_key_matches_username "$FOUND_IDENTITY_FILE" "$BOUND_USERNAME"; then
    BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
    BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    return 0
  fi
  return 1
}

ensure_bound_identity() {
  local saved_username=""
  local preferred_alias=""

  saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  if [ "$(lowercase "$saved_username")" = "$(lowercase "$BOUND_USERNAME")" ]; then
    preferred_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  fi

  if find_local_identity_for_username "$BOUND_USERNAME" "$preferred_alias"; then
    BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
    BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    info \
      "Using the local SSH key assigned to account $BOUND_USERNAME. No online identity precheck is run; git push will return GitHub's actual result." \
      "正在使用本机为账号 ${BOUND_USERNAME} 指定的 SSH 密钥。这里不会提前联网核对；执行 git push 时，再以 GitHub 的实际返回结果为准。"
    return 0
  fi

  setup_or_reuse_account "$BOUND_USERNAME" "$BOUND_EMAIL" || return 1
  BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
  BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
  return 0
}

save_project_binding() {
  local remote_url=""

  require_repository_account_match || return 1
  remote_url="git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"

  git -C "$GIT_ROOT" config --local user.name "$BOUND_USERNAME" || return 1
  git -C "$GIT_ROOT" config --local user.email "$BOUND_EMAIL" || return 1
  git -C "$GIT_ROOT" config --local github-auto.username "$BOUND_USERNAME" || return 1
  git -C "$GIT_ROOT" config --local github-auto.ssh-alias "$BOUND_SSH_ALIAS" || return 1
  git -C "$GIT_ROOT" config --local github-auto.identity-file "$BOUND_IDENTITY_FILE" || return 1
  git -C "$GIT_ROOT" config --local github-auto.engine "$ENGINE_PATH" || return 1

  if git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$GIT_ROOT" remote set-url origin "$remote_url" || return 1
  else
    git -C "$GIT_ROOT" remote add origin "$remote_url" || return 1
  fi
  git -C "$GIT_ROOT" config --local --replace-all remote.origin.pushurl "$remote_url" || return 1

  return 0
}

create_pinned_ssh_wrapper() {
  PINNED_SSH_DIRECTORY="$(safe_mktemp_directory)" || return 1
  PINNED_SSH_WRAPPER="$PINNED_SSH_DIRECTORY/ssh"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec ssh -F /dev/null '
    printf '%s ' \
      '-o HostName=github.com' \
      '-o User=git' \
      '-o IdentitiesOnly=yes' \
      '-o PreferredAuthentications=publickey' \
      '-o PasswordAuthentication=no' \
      '-o ConnectTimeout=8' \
      '-o ConnectionAttempts=1'
    printf '%s ' '-i "$GITHUB_AUTO_IDENTITY_FILE"'
    printf '"$@"\n'
  } > "$PINNED_SSH_WRAPPER"
  chmod 700 "$PINNED_SSH_WRAPPER"
}

run_git_with_identity() {
  local private_key="$1"
  shift

  create_pinned_ssh_wrapper || return 1
  GITHUB_AUTO_IDENTITY_FILE="$private_key" \
    GIT_SSH_COMMAND="$PINNED_SSH_WRAPPER" \
    GIT_SSH_VARIANT=ssh \
    git -C "$GIT_ROOT" "$@"
  local status=$?
  rm -rf "$PINNED_SSH_DIRECTORY"
  return "$status"
}

verify_repository_access() {
  local retry="${1:-yes}"
  local target="${2:-origin}"
  local output=""
  local detail=""

  require_repository_account_match || return 1
  while true; do
    info \
      "Checking ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} with the SSH key verified for its owner, $BOUND_USERNAME. This does not upload or change the repository." \
      "正在使用已确认为仓库所属账号 ${BOUND_USERNAME} 的 SSH 密钥，检查 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}；这一步不会上传或修改仓库。"
    output="$(run_git_with_identity "$BOUND_IDENTITY_FILE" ls-remote "$target" HEAD 2>&1)" && {
      success \
        "The repository responded to the SSH key verified for account $BOUND_USERNAME. Upload permission will be confirmed when git push runs." \
        "仓库已响应账号 ${BOUND_USERNAME} 的已验证 SSH 密钥。实际上传权限将在执行 git push 时得到最终确认。"
      return 0
    }

    error_message \
      "Could not read remote information for ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} with account $BOUND_USERNAME." \
      "无法使用账号 ${BOUND_USERNAME} 读取 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} 的远端信息。"
    detail="${output##*$'\n'}"
    if [ -n "$detail" ]; then
      muted "Git result: $detail" "Git 返回信息：$detail"
    fi
    muted \
      "Check the network, confirm that the repository exists, and confirm that this exact account has access." \
      "请检查网络，并确认仓库确实存在且这个账号拥有访问权限。"
    muted \
      "Create a repository: https://github.com/new" \
      "创建仓库：https://github.com/new"

    if [ "$retry" != "yes" ] ||
       ! ui_prompt_yes_no \
         "Run the same read-only access check again?" \
         "要再次执行同一项只读访问检查吗？" \
         "yes"; then
      return 1
    fi
  done
}

configure_project() {
  local preferred_username="${1:-}"
  local purpose="${2:-push}"
  local proposed_remote_url=""

  if read_origin_repository; then
    technical_detail \
      normal \
      "Recognized the existing origin as ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}." \
      "已从现有 origin 识别出 GitHub 仓库：${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
    technical_detail \
      normal \
      "Current origin: $CURRENT_ORIGIN_URL" \
      "当前 origin：$CURRENT_ORIGIN_URL"
  else
    warn \
      "This local Git repository has no origin that identifies a GitHub repository." \
      "这个本地 Git 仓库还没有能够识别为 GitHub 仓库的 origin。"
    muted \
      "Paste the GitHub repository that should receive this existing local history. Nothing is uploaded until the final git push." \
      "请粘贴这个现有本地仓库应当上传到的 GitHub 仓库地址；只有最后执行 git push 时才会上传。"
    if ! prompt_repository; then
      return 1
    fi
    CURRENT_REPOSITORY_OWNER="$REPOSITORY_OWNER"
    CURRENT_REPOSITORY_NAME="$REPOSITORY_NAME"
    CURRENT_ORIGIN_URL=""
    CURRENT_ORIGIN_HOST="$REPOSITORY_INPUT_HOST"
  fi

  if load_established_project_binding; then
    if [ -n "$preferred_username" ] &&
       [ "$(lowercase "$preferred_username")" != "$(lowercase "$CURRENT_REPOSITORY_OWNER")" ]; then
      warn \
        "Account $preferred_username was requested, but this repository belongs to $CURRENT_REPOSITORY_OWNER. The saved owner account will be used." \
        "前一步选择了账号 ${preferred_username}，但当前仓库属于 ${CURRENT_REPOSITORY_OWNER}。本次仍使用已经保存的仓库所属账号。"
    fi
    github_target_summary \
      normal \
      "$BOUND_USERNAME" \
      "$CURRENT_REPOSITORY_OWNER" \
      "$CURRENT_REPOSITORY_NAME" \
      "$BOUND_USERNAME" \
      "$BOUND_EMAIL" \
      "$BOUND_IDENTITY_FILE" \
      "git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"
    if [ "$purpose" = "push" ]; then
      info \
        "Using the saved owner account and SSH key. This run will go directly to add, commit, and push." \
        "使用已经保存的仓库所属账号和 SSH 密钥；本次直接执行暂存、提交和上传。"
    else
      success \
        "This project is already bound to its GitHub owner and exact SSH key." \
        "当前项目已经绑定到仓库所属账号及其指定 SSH 密钥，无需修改。"
    fi
    return 0
  fi

  select_account_for_repository \
    "$CURRENT_REPOSITORY_OWNER" \
    "$preferred_username" || return $?
  if ! ensure_bound_identity; then
    return 1
  fi

  proposed_remote_url="git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"

  heading "Confirm the GitHub upload target" "确认 GitHub 上传目标"
  github_target_summary \
    normal \
    "$BOUND_USERNAME" \
    "$CURRENT_REPOSITORY_OWNER" \
    "$CURRENT_REPOSITORY_NAME" \
    "$BOUND_USERNAME" \
    "$BOUND_EMAIL" \
    "$BOUND_IDENTITY_FILE" \
    "$proposed_remote_url"

  if [ -n "$CURRENT_ORIGIN_URL" ] && [ "$CURRENT_ORIGIN_URL" != "$proposed_remote_url" ]; then
    technical_detail \
      normal \
      "origin will change from $CURRENT_ORIGIN_URL to $proposed_remote_url so future fetches and pushes use the selected owner account." \
      "origin 将从 ${CURRENT_ORIGIN_URL} 更新为 ${proposed_remote_url}，以后拉取和推送都会使用所选的仓库所属账号。"
  elif [ -z "$CURRENT_ORIGIN_URL" ]; then
    technical_detail \
      normal \
      "origin will be added as $proposed_remote_url." \
      "将新增 origin：${proposed_remote_url}。"
  else
    technical_detail \
      normal \
      "The existing origin already uses the selected owner account and will not change." \
      "现有 origin 已经使用所选的仓库所属账号，不需要修改。"
  fi

  if ! save_project_binding; then
    fail \
      "The account settings for this project could not be saved." \
      "无法保存当前项目的账号设置。"
  fi
  success \
    "Saved this GitHub account and repository for the current project." \
    "已为当前项目保存上述 GitHub 账号和仓库。"
  technical_detail \
    normal \
    "The repository-local settings include the commit author, exact SSH key, and origin address." \
    "当前仓库的本地设置还包括提交作者、指定 SSH 密钥和 origin 地址。"
}

prompt_commit_message() {
  local proposed="$1"
  local entered=""

  heading "Confirm commit" "确认提交"
  muted "Suggested commit message: $proposed" "建议的提交说明：$proposed"
  entered="$(ui_prompt_value \
    "Press Enter to use it, type another message, or enter :cancel to stop before staging" \
    "直接按 Enter 使用建议内容；也可以输入其他说明，或输入 :cancel 在暂存前停止" \
    "$proposed")" || return 1
  if [ "$(lowercase "$entered")" = ":cancel" ]; then
    return 2
  fi
  COMMIT_MESSAGE="$entered"
}

show_staged_changes() {
  heading "Changes in this commit" "本次改动"
  git -C "$GIT_ROOT" diff --cached --stat
}

prepare_and_commit() {
  local has_commits=true
  local proposed="$DEFAULT_COMMIT_MESSAGE"

  if ! git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    has_commits=false
  fi

  if [ -z "$(git -C "$GIT_ROOT" status --porcelain 2>/dev/null)" ]; then
    if [ "$has_commits" = false ]; then
      warn \
        "This repository has no commit and no project files available to commit. Nothing was pushed." \
        "当前仓库还没有提交记录，也没有可提交的项目文件，因此本次不会上传。"
      return 3
    fi
    info \
      "The working tree has no uncommitted changes. No commit will be created; any existing local commits will still be considered for push." \
      "工作区没有尚未提交的改动，因此不会创建新提交；如果本地已有尚未上传的提交，后续仍会尝试推送。"
    return 0
  fi

  if resolve_release_version; then
    proposed="${RELEASE_PREFIX}${RELEASE_VERSION}"
    info \
      "Detected version ${RELEASE_VERSION} (${VERSION_SOURCE})" \
      "识别到版本 ${RELEASE_VERSION}（${VERSION_SOURCE}）"
    case "$VERSION_POSITION" in
      bottom)
        warn \
          "This changelog is ordered oldest to newest, so the bottom version was used." \
          "这个 CHANGELOG 按旧版本到新版本排列，已采用底部版本。"
        ;;
      single)
        muted \
          "Only one version was found in this changelog." \
          "这个 CHANGELOG 中只识别到一个版本。"
        ;;
    esac
  elif [ "$has_commits" = false ]; then
    proposed="$INITIAL_COMMIT_MESSAGE"
    muted \
      "No release version was found, so the first commit message will be used." \
      "没有发现版本号，将使用首次提交说明。"
  else
    muted \
      "No release version was found, so a general commit message will be used." \
      "没有发现版本号，将使用通用提交说明。"
  fi

  if [ "$PROJECT_BINDING_REUSED" = true ]; then
    COMMIT_MESSAGE="$proposed"
    info \
      "git add -A; git commit -m \"$COMMIT_MESSAGE\"; git push" \
      "git add -A；git commit -m \"$COMMIT_MESSAGE\"；git push"
  else
    heading "Review changes before committing" "提交前检查改动"
    muted \
      "The following output is from git status --short. A means added, M modified, D deleted, and ?? an untracked file." \
      "下面是 git status --short 的结果：A 表示新增，M 表示修改，D 表示删除，?? 表示尚未跟踪的新文件。"
    git -C "$GIT_ROOT" status --short
    muted \
      "After the commit message is confirmed, git add -A will include every change shown above, including deletions." \
      "确认提交说明后，脚本会执行 git add -A，把上面显示的全部改动一并纳入提交，其中也包括删除的文件。"

    prompt_commit_message "$proposed"
    case "$?" in
      0)
        ;;
      2)
        warn \
          "Commit canceled before git add -A. This step did not stage, commit, or push any files." \
          "已在执行 git add -A 前取消；这一步没有暂存、提交或上传任何文件。"
        return 2
        ;;
      *)
        return 1
        ;;
    esac
  fi

  if ! git -C "$GIT_ROOT" add -A; then
    error_message \
      "git add -A failed. Git may have staged some paths before stopping; inspect git status. No commit or push was attempted." \
      "git add -A 执行失败。Git 可能已经暂存了部分文件，请用 git status 检查；脚本没有继续提交或上传。"
    return 1
  fi
  if [ "$PROJECT_BINDING_REUSED" != true ]; then
    show_staged_changes
  fi

  if ! git -C "$GIT_ROOT" commit -m "$COMMIT_MESSAGE"; then
    error_message \
      "The commit failed. The selected changes remain staged for inspection, and no push was attempted." \
      "提交失败。本次选择的改动仍保留在暂存区，便于检查；脚本没有执行上传。"
    return 1
  fi
  success "Committed: $COMMIT_MESSAGE" "已提交：$COMMIT_MESSAGE"

  if [ "$has_commits" = false ]; then
    git -C "$GIT_ROOT" branch -M main || fail \
      "The initial branch could not be named main." \
      "无法把初始分支设置为 main。"
  fi
}

push_current_branch() {
  local branch=""
  local output=""
  local push_status=0

  require_repository_account_match || return 1
  branch="$(git -C "$GIT_ROOT" branch --show-current)"
  if [ -z "$branch" ]; then
    fail \
      "The repository is in detached HEAD state, so a branch cannot be selected safely." \
      "当前处于 detached HEAD 状态，无法安全判断要推送的分支。"
  fi

  heading "Push to GitHub" "上传到 GitHub"
  github_target_summary \
    normal \
    "$BOUND_USERNAME" \
    "$CURRENT_REPOSITORY_OWNER" \
    "$CURRENT_REPOSITORY_NAME" \
    "$BOUND_USERNAME" \
    "$BOUND_EMAIL" \
    "$BOUND_IDENTITY_FILE" \
    "git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git" \
    "$branch"
  technical_detail \
    normal \
    "The script will run git push -u origin $branch with only $(human_path "$BOUND_IDENTITY_FILE"). It will not force-push." \
    "接下来只使用密钥 $(human_path "$BOUND_IDENTITY_FILE") 执行 git push -u origin ${branch}；不会强制推送。"

  if git -C "$GIT_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
    output="$(run_git_with_identity "$BOUND_IDENTITY_FILE" push 2>&1)" || push_status=$?
  else
    output="$(run_git_with_identity "$BOUND_IDENTITY_FILE" push -u origin "$branch" 2>&1)" || push_status=$?
  fi
  if [ "$push_status" -ne 0 ]; then
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    explain_push_failure "$output" "$branch"
    return 1
  fi
  [ -z "$output" ] || printf '%s\n' "$output"
  success \
    "Upload completed with account $BOUND_USERNAME to ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}." \
    "已使用账号 $BOUND_USERNAME 上传到 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
  technical_detail \
    normal \
    "Uploaded local branch $branch." \
    "已上传本地分支 ${branch}。"
}

explain_push_failure() {
  local output="$1"
  local branch="$2"
  local normalized=""

  normalized="$(lowercase "$output")"
  error_message \
    "The push did not complete. No force push was used, no remote history was overwritten, and any new commit remains safely in this local repository." \
    "本次上传没有完成。脚本没有强制推送，也没有覆盖远端历史；刚刚创建的提交仍安全保留在当前本地仓库中。"
  case "$normalized" in
    *non-fast-forward*|*fetch\ first*|*updates\ were\ rejected*)
      muted \
        "GitHub has commits on $branch that are not in this local branch. Review and integrate the remote changes before pushing again; the script did not merge or rewrite either history automatically." \
        "GitHub 上的 ${branch} 分支包含本地尚未拥有的提交。请先查看并整合远端改动，再重新上传；脚本没有擅自合并或改写任何一方的历史。"
      ;;
    *permission\ denied*|*publickey*|*repository\ not\ found*|*write\ access*)
      muted \
        "GitHub rejected this repository or SSH identity. Open ./$SCRIPT_NAME menu, choose Advanced features, then verify the current project; also confirm that ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} exists under account $BOUND_USERNAME." \
        "GitHub 拒绝了当前仓库或 SSH 身份。请运行 ./${SCRIPT_NAME} menu，进入“高级功能”后选择“联网核对当前项目”，并确认 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} 确实位于账号 ${BOUND_USERNAME} 名下。"
      ;;
    *could\ not\ resolve\ hostname*|*connection\ timed\ out*|*connection\ reset*|*network\ is\ unreachable*|*remote\ end\ hung\ up*)
      muted \
        "The connection to GitHub was interrupted or unavailable. Check the network and run ./$SCRIPT_NAME again; the existing local commit will be reused rather than recreated." \
        "本次连接 GitHub 时网络不可用或连接中断。请检查网络后重新运行 ./${SCRIPT_NAME}；现有本地提交会直接继续使用，不会重复创建。"
      ;;
    *)
      muted \
        "The Git output above contains the exact failure reported by the remote. Correct that condition and run ./$SCRIPT_NAME again; the script will not duplicate the local commit." \
        "上方 Git 返回信息包含远端报告的具体原因。处理后重新运行 ./${SCRIPT_NAME} 即可；脚本不会重复创建本地提交。"
      ;;
  esac
}

run_project_flow() {
  local preferred_username="${1:-}"
  local account_status=0
  local commit_status=0

  require_interactive
  require_core_commands
  locate_project yes
  describe_and_validate_project_state || return 1
  ensure_script_excluded

  configure_project "$preferred_username" || account_status=$?
  if [ "$account_status" -eq 2 ]; then
    return 0
  elif [ "$account_status" -ne 0 ]; then
    return 1
  fi
  prepare_and_commit || commit_status=$?
  if [ "$commit_status" -eq 2 ]; then
    return 0
  elif [ "$commit_status" -eq 3 ]; then
    return 0
  elif [ "$commit_status" -ne 0 ]; then
    return 1
  fi
  push_current_branch
}
