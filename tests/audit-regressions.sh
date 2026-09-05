#!/usr/bin/env bash
# Real Git fixtures only: no GitHub connection or user repository changes.
set -uo pipefail
AUDIT_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AUDIT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/git-auto-audit.XXXXXX")"
trap 'rm -rf "$AUDIT_TMP"' EXIT
export GITHUB_AUTO_TESTING=1 NO_COLOR=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
source "$AUDIT_PROJECT/git-auto.sh"
AUDIT_FAILURES=0
AUDIT_COUNT=0
check() {
  AUDIT_COUNT=$((AUDIT_COUNT + 1))
  if "$@"; then printf 'ok %s - %s\n' "$AUDIT_COUNT" "$1";
  else printf 'not ok %s - %s\n' "$AUDIT_COUNT" "$1"; AUDIT_FAILURES=$((AUDIT_FAILURES + 1)); fi
}
fixture() {
  GIT_ROOT="$AUDIT_TMP/$1"
  mkdir -p "$GIT_ROOT"
  git -C "$GIT_ROOT" init -q
  git -C "$GIT_ROOT" symbolic-ref HEAD refs/heads/main
  git -C "$GIT_ROOT" config user.name tester
  git -C "$GIT_ROOT" config user.email tester@example.com
  git -C "$GIT_ROOT" config commit.gpgSign false
}
baseline() {
  printf 'baseline\n' > "$GIT_ROOT/base.txt"
  git -C "$GIT_ROOT" add -A && git -C "$GIT_ROOT" commit -qm baseline
}
matches_native_add() {
  local before actual expected
  before="$(git -C "$GIT_ROOT" write-tree)"
  prepare_expected_staged_tree || return 1
  expected="$WORKFLOW_EXPECTED_STAGED_TREE"
  [ "$(git -C "$GIT_ROOT" write-tree)" = "$before" ] || return 1
  git -C "$GIT_ROOT" add -A || return 1
  actual="$(git -C "$GIT_ROOT" write-tree)"
  clear_workflow_review_snapshot
  [ "$actual" = "$expected" ]
}
forced_ignored_file() {
  fixture forced && baseline || return 1
  printf 'release.bin\n' > "$GIT_ROOT/.gitignore"
  printf 'intentionally included\n' > "$GIT_ROOT/release.bin"
  git -C "$GIT_ROOT" add -f release.bin
  matches_native_add
}
unborn_forced_ignored_file() {
  fixture unborn || return 1
  printf 'release.bin\n' > "$GIT_ROOT/.gitignore"
  printf 'intentionally included\n' > "$GIT_ROOT/release.bin"
  git -C "$GIT_ROOT" add -f release.bin
  matches_native_add
}
intent_to_add_ignored_file() {
  fixture intent && baseline || return 1
  printf 'release.bin\n' > "$GIT_ROOT/.gitignore"
  printf 'intentionally included\n' > "$GIT_ROOT/release.bin"
  git -C "$GIT_ROOT" add -N -f release.bin
  matches_native_add
}
removed_from_tracking() {
  fixture untrack && baseline || return 1
  printf 'base.txt\n' > "$GIT_ROOT/.gitignore"
  git -C "$GIT_ROOT" rm -q --cached base.txt
  matches_native_add
}
sparse_staged_removal() {
  fixture sparse || return 1
  mkdir -p "$GIT_ROOT/keep" "$GIT_ROOT/omit"
  printf 'keep\n' > "$GIT_ROOT/keep/file"
  printf 'omit\n' > "$GIT_ROOT/omit/file"
  baseline || return 1
  git -C "$GIT_ROOT" sparse-checkout init --cone
  git -C "$GIT_ROOT" sparse-checkout set keep
  git -C "$GIT_ROOT" rm --sparse -q --cached omit/file
  matches_native_add
}
nested_repository_at_depth() {
  fixture nested && baseline || return 1
  local parent="$GIT_ROOT" result=0
  fixture nested/vendor/tool && baseline || return 1
  GIT_ROOT="$parent"
  review_possible_embedded_projects > "$AUDIT_TMP/nested-output" 2>&1 || result=$?
  [ "$result" -eq 2 ] && grep -Fq 'vendor/tool' "$AUDIT_TMP/nested-output" &&
    git -C "$GIT_ROOT" diff --cached --quiet
}
registered_new_submodule() {
  fixture submodule-source && baseline || return 1
  local source="$GIT_ROOT" result=0
  fixture submodule-parent && baseline || return 1
  git -C "$GIT_ROOT" -c protocol.file.allow=always submodule add -q "$source" library || return 1
  review_possible_embedded_projects > "$AUDIT_TMP/submodule-output" 2>&1 || result=$?
  [ "$result" -eq 0 ]
}
confirmed_comment_message() {
  fixture message && baseline || return 1
  git -C "$GIT_ROOT" config commit.cleanup strip
  printf 'changed\n' >> "$GIT_ROOT/base.txt"
  local PROJECT_BINDING_REUSED=true
  ( prompt_commit_message() { COMMIT_MESSAGE='#123 Fix the reported issue'; }
    prepare_and_commit > "$AUDIT_TMP/message-output" 2>&1 &&
      [ "$(git -C "$GIT_ROOT" log -1 --format=%s)" = '#123 Fix the reported issue' ] )
}
ssh_wrapper_with_spaces() {
  fixture ssh-path || return 1
  local TMPDIR="$AUDIT_TMP/temporary space's directory" PATH="$AUDIT_TMP/bin:$PATH"
  export TMPDIR PATH
  mkdir -p "$TMPDIR" "$AUDIT_TMP/bin"
  printf '#!/bin/sh\nprintf "invoked\\n" > "%s"\nexit 1\n' "$AUDIT_TMP/ssh-invoked" > "$AUDIT_TMP/bin/ssh"
  chmod +x "$AUDIT_TMP/bin/ssh"
  run_git_with_identity "$AUDIT_TMP/key" ls-remote git@github-test:tester/repo.git > "$AUDIT_TMP/ssh-output" 2>&1 || true
  [ -f "$AUDIT_TMP/ssh-invoked" ]
}
push_fixture() {
  fixture "$1" && baseline || return 1
  BOUND_USERNAME=tester
  BOUND_SSH_ALIAS=github-tester
  CURRENT_REPOSITORY_OWNER=tester
  CURRENT_REPOSITORY_NAME=repo
  git -C "$GIT_ROOT" remote add origin git@github-tester:tester/repo.git
  AUDIT_REMOTE="$GIT_ROOT/remote.git"
  git init --bare -q "$AUDIT_REMOTE"
  mkdir -p "$AUDIT_TMP/transport"
  printf '#!/bin/sh\nprintf "invoked\\n" >> "$AUDIT_SSH_LOG"\nexec git-receive-pack "$AUDIT_REMOTE"\n' > "$AUDIT_TMP/transport/ssh"
  chmod +x "$AUDIT_TMP/transport/ssh"
  export AUDIT_REMOTE
}
multiple_push_destinations() {
  push_fixture multiple || return 1
  local PATH="$AUDIT_TMP/transport:$PATH" AUDIT_SSH_LOG="$AUDIT_TMP/multiple-log" result=0
  export PATH AUDIT_SSH_LOG
  git -C "$GIT_ROOT" config --add remote.origin.pushurl git@github-tester:tester/repo.git
  git -C "$GIT_ROOT" config --add remote.origin.pushurl git@github-tester:someone/other.git
  run_git_with_identity "$AUDIT_TMP/key" push origin HEAD:refs/heads/main > "$AUDIT_TMP/multiple-output" 2>&1 || result=$?
  [ "$result" -ne 0 ] && [ ! -f "$AUDIT_SSH_LOG" ] &&
    [ -z "$(git --git-dir="$AUDIT_REMOTE" for-each-ref)" ]
}
push_does_not_follow_tags() {
  push_fixture tags || return 1
  local PATH="$AUDIT_TMP/transport:$PATH" AUDIT_SSH_LOG="$AUDIT_TMP/tags-log"
  export PATH AUDIT_SSH_LOG
  git -C "$GIT_ROOT" tag -am 'unrequested tag' existing-tag
  git -C "$GIT_ROOT" config push.followTags true
  run_git_with_identity "$AUDIT_TMP/key" push origin HEAD:refs/heads/main > "$AUDIT_TMP/tags-output" 2>&1 || return 1
  [ "$(git --git-dir="$AUDIT_REMOTE" rev-parse refs/heads/main)" = "$(git -C "$GIT_ROOT" rev-parse HEAD)" ] &&
    [ -z "$(git --git-dir="$AUDIT_REMOTE" tag -l)" ] &&
    [ "$(git -C "$GIT_ROOT" config push.followTags)" = true ]
}
push_ignores_mirror_mode() {
  push_fixture mirror || return 1
  local PATH="$AUDIT_TMP/transport:$PATH" AUDIT_SSH_LOG="$AUDIT_TMP/mirror-log"
  export PATH AUDIT_SSH_LOG
  git -C "$GIT_ROOT" config remote.origin.mirror true
  run_git_with_identity "$AUDIT_TMP/key" push origin HEAD:refs/heads/main > "$AUDIT_TMP/mirror-output" 2>&1 || return 1
  [ "$(git --git-dir="$AUDIT_REMOTE" for-each-ref --format='%(refname)')" = refs/heads/main ] &&
    [ "$(git -C "$GIT_ROOT" config remote.origin.mirror)" = true ]
}
damaged_metadata_is_not_initialized() {
  fixture damaged && baseline || return 1
  local SCRIPT_DIRECTORY="$GIT_ROOT" result=0
  rm "$GIT_ROOT/.git/HEAD"
  ( locate_project yes ) > "$AUDIT_TMP/damaged-output" 2>&1 || result=$?
  [ "$result" -ne 0 ] && [ ! -f "$GIT_ROOT/.git/HEAD" ]
}
unfinished_cherry_pick_sequence() {
  fixture sequence && baseline || return 1
  git -C "$GIT_ROOT" checkout -qb source
  printf 'source\n' > "$GIT_ROOT/base.txt"
  git -C "$GIT_ROOT" commit -qam source
  local picked="$(git -C "$GIT_ROOT" rev-parse HEAD)"
  printf 'second\n' > "$GIT_ROOT/second.txt"
  git -C "$GIT_ROOT" add -A && git -C "$GIT_ROOT" commit -qm second
  local second="$(git -C "$GIT_ROOT" rev-parse HEAD)"
  git -C "$GIT_ROOT" checkout -q main
  printf 'conflict\n' > "$GIT_ROOT/base.txt"
  git -C "$GIT_ROOT" commit -qam conflict
  git -C "$GIT_ROOT" cherry-pick "$picked" "$second" >/dev/null 2>&1 || true
  printf 'resolved\n' > "$GIT_ROOT/base.txt"
  git -C "$GIT_ROOT" add -A && git -C "$GIT_ROOT" commit -qm resolved
  [ ! -e "$GIT_ROOT/.git/CHERRY_PICK_HEAD" ] && [ -d "$GIT_ROOT/.git/sequencer" ] &&
    git_operation_in_progress
}
ordinary_changes_use_one_hint_scan() {
  fixture bulk || return 1
  local n=0 calls=0
  while [ "$n" -lt 150 ]; do
    printf 'old\n' > "$GIT_ROOT/file-$n"
    n=$((n + 1))
  done
  baseline || return 1
  n=0
  while [ "$n" -lt 150 ]; do
    printf 'new\n' > "$GIT_ROOT/file-$n"
    n=$((n + 1))
  done
  prepare_expected_staged_tree || return 1
  ( git() { printf 'call\n' >> "$AUDIT_TMP/bulk-calls"; command git "$@"; }
    prepare_real_index_for_exact_staging ) || return 1
  calls="$(wc -l < "$AUDIT_TMP/bulk-calls" | tr -d ' ')"
  clear_workflow_review_snapshot
  [ "$calls" -eq 1 ]
}
hidden_literal_filenames() {
  fixture literal || return 1
  local path=$'line\nbreak' PROJECT_BINDING_REUSED=true
  printf 'old\n' > "$GIT_ROOT/$path"
  printf 'old\n' > "$GIT_ROOT/[name]*.txt"
  printf 'unrelated\n' > "$GIT_ROOT/name-other.txt"
  baseline || return 1
  git -C "$GIT_ROOT" update-index --assume-unchanged -- "$path" '[name]*.txt' name-other.txt
  printf 'new\n' > "$GIT_ROOT/$path"
  printf 'new\n' > "$GIT_ROOT/[name]*.txt"
  ( prompt_commit_message() { COMMIT_MESSAGE=confirmed; }
    prepare_and_commit > "$AUDIT_TMP/literal-output" 2>&1 ) || return 1
  [ "$(git -C "$GIT_ROOT" show "HEAD:$path")" = new ] &&
    [ "$(git -C "$GIT_ROOT" show 'HEAD:[name]*.txt')" = new ] &&
    [ "$(git -C "$GIT_ROOT" ls-files -v name-other.txt)" = 'h name-other.txt' ]
}
intent_to_add_project_is_reviewed() {
  fixture intended-project && baseline || return 1
  mkdir -p "$GIT_ROOT/library"
  printf 'library/\n' > "$GIT_ROOT/.gitignore"
  printf '{"name":"separate-project"}\n' > "$GIT_ROOT/library/package.json"
  git -C "$GIT_ROOT" add -N -f library/package.json
  local before="$(git -C "$GIT_ROOT" write-tree)" result=0
  prepare_expected_staged_tree || return 1
  review_possible_embedded_projects > "$AUDIT_TMP/intent-review" 2>&1 <<< n || result=$?
  clear_workflow_review_snapshot
  [ "$result" -eq 2 ] && [ "$(git -C "$GIT_ROOT" write-tree)" = "$before" ] &&
    grep -Fq 'library' "$AUDIT_TMP/intent-review"
}
check forced_ignored_file
check unborn_forced_ignored_file
check intent_to_add_ignored_file
check removed_from_tracking
check sparse_staged_removal
check nested_repository_at_depth
check registered_new_submodule
check confirmed_comment_message
check ssh_wrapper_with_spaces
check multiple_push_destinations
check push_does_not_follow_tags
check push_ignores_mirror_mode
check damaged_metadata_is_not_initialized
check unfinished_cherry_pick_sequence
check ordinary_changes_use_one_hint_scan
check hidden_literal_filenames
check intent_to_add_project_is_reviewed
printf '%s checks; %s failures\n' "$AUDIT_COUNT" "$AUDIT_FAILURES"
[ "$AUDIT_FAILURES" -eq 0 ]
