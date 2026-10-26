#!/usr/bin/env bash
# Behavior tests for tools/corpus.sh. GitHub and Basic Memory are faked at the process boundary
# (tests/fakes/gh, tests/fakes/uvx); git and kc-validate run for real.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CORPUS="$ROOT/tools/corpus.sh"
BASE_PATH=$PATH
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

fail() { echo "$*"; exit 1; }
has() { grep -qF -- "$2" "$1" || fail "expected '$2' in $1:$(printf '\n'; sed 's/^/      /' "$1")"; }
lacks() { ! grep -qF -- "$2" "$1" || fail "did not expect '$2' in $1"; }
remote() { git --git-dir="$FAKE/remotes/acme/kb.git" "$@"; }

# fresh: an isolated HOME and git config, the fakes first on PATH, and https://github.com/ served
# from local bare repositories. Accounts alice (active) and kb-bot exist.
fresh() {
  T=$(mktemp -d "$TMP/t.XXXX")
  export HOME="$T/home" FAKE="$T/fake" FAKE_TEMPLATE="$ROOT" PATH="$ROOT/tools/tests/fakes:$BASE_PATH"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset GH_TOKEN GITHUB_TOKEN
  mkdir -p "$HOME" "$FAKE/remotes/acme" "$FAKE/accounts" "$FAKE/logged-out"
  touch "$FAKE/gh.log" "$FAKE/bm.log" "$FAKE/accounts/alice" "$FAKE/accounts/kb-bot"
  echo alice > "$FAKE/active"
  git config --global user.name Tester
  git config --global user.email tester@example.com
  git config --global url."$FAKE/remotes/".insteadOf https://github.com/
  CLONE="$HOME/.kelsen/corpus/acme/kb"
  OUT="$T/out"
}

init_store() { "$CORPUS" init acme/kb --private --account kb-bot --as alice "$@" > "$OUT" 2>&1; }

entry() {
  cat <<'EOF'
---
permalink: acme-kb/yanked-release
title: Yanked release breaks clean builds
type: knowledge
status: verified
claim: A yanked release in the lockfile fails every clean install.
---

## Problem

Builds fail on a clean runner.

## Cause

The lockfile pins a yanked release.

## Solution

Bump the pin, merged in https://github.com/example/app/pull/1.

## Applying it elsewhere

Check the lockfile for yanked releases before debugging the build.
EOF
}

# --- init ----------------------------------------------------------------------------------

test_init_creates_the_store_from_the_template_as_the_creator() {
  init_store || fail "init failed: $(cat "$OUT")"
  has "$FAKE/gh.log" "GH_TOKEN=token-alice repo create acme/kb --template joacominatel/kelsen-corpus --private"
}

test_init_defaults_to_the_active_account_and_names_it() {
  "$CORPUS" init acme/kb --private --account kb-bot > "$OUT" 2>&1 || fail "init failed: $(cat "$OUT")"
  has "$FAKE/gh.log" "GH_TOKEN=token-alice repo create acme/kb"
  has "$OUT" "alice"
}

test_init_commits_settings_and_codeowners() {
  init_store --license CC-BY-4.0 --owners alice,bob || fail "init failed: $(cat "$OUT")"
  remote show main:kelsen.yml > "$T/settings"
  remote show main:.github/CODEOWNERS > "$T/codeowners"
  [ "$(cat "$T/settings")" = "$(printf 'id: acme-kb\naccount: kb-bot\nhost: github.com\nspec: 1\nprotection: ruleset\nlicense: CC-BY-4.0')" ] \
    || fail "unexpected kelsen.yml: $(cat "$T/settings")"
  [ "$(cat "$T/codeowners")" = "* @alice @bob" ] || fail "unexpected CODEOWNERS: $(cat "$T/codeowners")"
}

test_init_settings_pass_the_validator() {
  init_store || fail "init failed: $(cat "$OUT")"
  uv run --quiet --project "$CLONE/validator" --locked kc-validate "$CLONE" > "$T/kc" 2>&1 \
    || fail "kc-validate rejected the new store: $(cat "$T/kc")"
}

test_init_applies_the_admission_ruleset() {
  init_store || fail "init failed: $(cat "$OUT")"
  jq -e '
    .enforcement == "active" and .bypass_actors == []
    and .conditions.ref_name.include == ["~DEFAULT_BRANCH"]
    and ([.rules[].type] | sort) == ["deletion", "non_fast_forward", "pull_request", "required_status_checks"]
    and (.rules[] | select(.type == "pull_request").parameters
         | .required_approving_review_count == 1 and .require_code_owner_review and .dismiss_stale_reviews_on_push)
    and (.rules[] | select(.type == "required_status_checks").parameters
         | .strict_required_status_checks_policy and ([.required_status_checks[].context] | sort) == ["bm-noop", "validate"])
  ' "$FAKE/ruleset.json" > /dev/null || fail "ruleset sent: $(cat "$FAKE/ruleset.json")"
}

test_init_fails_when_the_ruleset_reads_back_different() {
  touch "$FAKE/readback-differs"
  ! init_store || fail "init succeeded with a ruleset that has a bypass actor"
  has "$OUT" "ruleset"
}

test_init_enables_auto_merge_and_reads_it_back() {
  init_store || fail "init failed: $(cat "$OUT")"
  has "$FAKE/gh.log" "GH_TOKEN=token-alice api -X PATCH repos/acme/kb -F allow_auto_merge=true"
  has "$FAKE/gh.log" "GH_TOKEN=token-alice api repos/acme/kb --jq .allow_auto_merge"
}

test_init_fails_when_auto_merge_reads_back_disabled() {
  touch "$FAKE/auto-merge-ignored"
  ! init_store || fail "init succeeded with auto-merge disabled"
  has "$OUT" "auto-merge"
}

test_init_on_a_plan_without_rulesets_records_no_protection_and_continues() {
  touch "$FAKE/plan-refuses"
  init_store || fail "init failed: $(cat "$OUT")"
  remote show main:kelsen.yml > "$T/settings"
  has "$T/settings" "protection: none"
  has "$OUT" "unprotected"
  [ -d "$CLONE/.git" ] || fail "no clone after an unprotected init"
}

test_init_fails_when_a_public_store_cannot_be_protected() {
  touch "$FAKE/plan-refuses"
  ! "$CORPUS" init acme/kb --public --license MIT --account kb-bot --as alice > "$OUT" 2>&1 \
    || fail "a public store was left unprotected"
}

test_init_refuses_a_public_store_without_a_license() {
  ! "$CORPUS" init acme/kb --public --account kb-bot --as alice > "$OUT" 2>&1 || fail "init succeeded"
  lacks "$FAKE/gh.log" "repo create"
}

test_init_clone_authenticates_as_the_machine_account() {
  init_store || fail "init failed: $(cat "$OUT")"
  printf 'protocol=https\nhost=github.com\npath=acme/kb.git\n\n' \
    | GIT_TERMINAL_PROMPT=0 GH_TOKEN=token-alice git -C "$CLONE" credential fill > "$T/cred" 2>&1
  has "$T/cred" "username=kb-bot"
  has "$T/cred" "password=token-kb-bot"
}

test_init_registers_and_indexes_the_search_project() {
  init_store || fail "init failed: $(cat "$OUT")"
  has "$FAKE/bm.log" "project add corpus-acme-kb $CLONE/entries --no-wait"
  has "$FAKE/bm.log" "reindex --search -p corpus-acme-kb"
}

test_init_invites_an_existing_machine_account_with_write_access() {
  init_store || fail "init failed: $(cat "$OUT")"
  has "$FAKE/gh.log" "GH_TOKEN=token-alice api -X PUT repos/acme/kb/collaborators/kb-bot -f permission=push"
  has "$OUT" "gh auth login"
}

test_init_guides_the_signup_of_a_missing_machine_account() {
  rm "$FAKE/accounts/kb-bot"
  init_store || fail "init failed: $(cat "$OUT")"
  lacks "$FAKE/gh.log" "collaborators/kb-bot"
  has "$OUT" "https://github.com/signup"
  has "$OUT" "repos/acme/kb/collaborators/kb-bot -f permission=push"
}

test_init_refuses_an_account_that_is_not_a_login() {
  ! "$CORPUS" init acme/kb --private --account 'bot; touch pwned' --as alice > "$OUT" 2>&1 || fail "init succeeded"
  lacks "$FAKE/gh.log" "repo create"
}

# --- sync ----------------------------------------------------------------------------------

test_sync_fast_forwards_and_reindexes() {
  init_store || fail "init failed: $(cat "$OUT")"
  git clone -q https://github.com/acme/kb.git "$T/other"
  entry > "$T/other/entries/yanked-release.md"
  git -C "$T/other" add entries/yanked-release.md
  git -C "$T/other" commit -q -m "admit"
  git -C "$T/other" push -q origin main
  : > "$FAKE/bm.log"
  "$CORPUS" sync "$CLONE" > "$OUT" 2>&1 || fail "sync failed: $(cat "$OUT")"
  [ -f "$CLONE/entries/yanked-release.md" ] || fail "the admitted entry did not arrive"
  has "$FAKE/bm.log" "reindex --search -p corpus-acme-kb"
}

test_sync_refuses_a_dirty_tree() {
  init_store || fail "init failed: $(cat "$OUT")"
  echo draft > "$CLONE/entries/draft.md"
  : > "$FAKE/bm.log"
  ! "$CORPUS" sync "$CLONE" > "$OUT" 2>&1 || fail "sync ran on a dirty tree"
  lacks "$FAKE/bm.log" "reindex"
}

test_sync_refuses_a_branch_other_than_the_default() {
  init_store || fail "init failed: $(cat "$OUT")"
  git -C "$CLONE" switch -q -c elsewhere
  ! "$CORPUS" sync "$CLONE" > "$OUT" 2>&1 || fail "sync ran off the default branch"
}

# --- propose -------------------------------------------------------------------------------

test_propose_scaffolds_a_draft_outside_the_indexed_entries() {
  init_store || fail "init failed: $(cat "$OUT")"
  "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "propose failed: $(cat "$OUT")"
  draft="$CLONE/.worktrees/yanked-release/entries/yanked-release.md"
  [ -f "$draft" ] || fail "no draft at $draft"
  [ ! -e "$CLONE/entries/yanked-release.md" ] || fail "the draft landed in the indexed entries"
  for line in "permalink: acme-kb/yanked-release" "title:" "type: knowledge" "status: verified" "claim:" \
              "## Problem" "## Cause" "## Solution" "## Applying it elsewhere"; do
    has "$draft" "$line"
  done
  lacks "$FAKE/gh.log" "pr create"
}

test_propose_refuses_a_draft_still_holding_placeholders() {
  init_store || fail "init failed: $(cat "$OUT")"
  "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "scaffold failed: $(cat "$OUT")"
  ! "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "proposed an unfilled draft"
  lacks "$FAKE/gh.log" "pr create"
}

test_propose_opens_the_pull_request_as_the_machine_account() {
  init_store || fail "init failed: $(cat "$OUT")"
  "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "scaffold failed: $(cat "$OUT")"
  entry > "$CLONE/.worktrees/yanked-release/entries/yanked-release.md"
  "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "propose failed: $(cat "$OUT")"
  remote cat-file -e entry/yanked-release:entries/yanked-release.md || fail "the entry was not pushed"
  has "$FAKE/gh.log" "GH_TOKEN=token-kb-bot pr create -R acme/kb --base main --head entry/yanked-release"
  has "$OUT" "https://github.com/acme/kb/pull/7"
}

test_propose_enables_auto_merge_as_the_machine_account() {
  init_store || fail "init failed: $(cat "$OUT")"
  "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "scaffold failed: $(cat "$OUT")"
  entry > "$CLONE/.worktrees/yanked-release/entries/yanked-release.md"
  "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "propose failed: $(cat "$OUT")"
  has "$FAKE/gh.log" "GH_TOKEN=token-kb-bot pr merge https://github.com/acme/kb/pull/7 --auto --merge"
  lacks "$OUT" "WARNING"
}

test_propose_only_warns_when_auto_merge_is_refused() {
  init_store || fail "init failed: $(cat "$OUT")"
  touch "$FAKE/auto-merge-refuses"
  "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "scaffold failed: $(cat "$OUT")"
  entry > "$CLONE/.worktrees/yanked-release/entries/yanked-release.md"
  "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "propose failed on a refused auto-merge: $(cat "$OUT")"
  has "$OUT" "WARNING"
  has "$OUT" "https://github.com/acme/kb/pull/7"
}

test_propose_stops_on_a_validator_rejection() {
  init_store || fail "init failed: $(cat "$OUT")"
  "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "scaffold failed: $(cat "$OUT")"
  entry | sed '/^## Cause$/d' > "$CLONE/.worktrees/yanked-release/entries/yanked-release.md"
  ! "$CORPUS" propose "$CLONE" yanked-release > "$OUT" 2>&1 || fail "proposed an invalid entry"
  has "$OUT" "KC-E04"
  ! remote rev-parse -q --verify entry/yanked-release > /dev/null || fail "an invalid entry was pushed"
  lacks "$FAKE/gh.log" "pr create"
}

test_propose_refuses_an_invalid_slug() {
  init_store || fail "init failed: $(cat "$OUT")"
  ! "$CORPUS" propose "$CLONE" Yanked_Release > "$OUT" 2>&1 || fail "accepted an invalid slug"
  [ ! -d "$CLONE/.worktrees" ] || fail "created a worktree for an invalid slug"
}

# --- search --------------------------------------------------------------------------------

search_result() {
  echo '{"results":[{"title":"Yanked release breaks clean builds","permalink":"acme-kb/yanked-release","file_path":"yanked-release.md"}]}' \
    > "$FAKE/search.json"
}

test_search_queries_the_store_project() {
  init_store || fail "init failed: $(cat "$OUT")"
  search_result
  "$CORPUS" search "$CLONE" yanked lockfile > "$OUT" 2>&1 || fail "search failed: $(cat "$OUT")"
  has "$FAKE/bm.log" "tool search-notes yanked lockfile --project corpus-acme-kb"
  has "$OUT" "acme-kb/yanked-release"
  has "$OUT" "$CLONE/entries/yanked-release.md"
  lacks "$OUT" "unprotected"
}

test_search_labels_results_of_an_unprotected_store() {
  touch "$FAKE/plan-refuses"
  init_store || fail "init failed: $(cat "$OUT")"
  search_result
  "$CORPUS" search "$CLONE" yanked > "$OUT" 2>&1 || fail "search failed: $(cat "$OUT")"
  grep -q 'acme-kb/yanked-release.*unprotected' "$OUT" || fail "unlabeled result: $(cat "$OUT")"
}

for t in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
  if (fresh; "$t") > "$TMP/result" 2>&1; then
    PASS=$((PASS+1)); printf '  ok    %s\n' "${t#test_}"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "${t#test_}"; sed 's/^/        /' "$TMP/result"
  fi
done
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
