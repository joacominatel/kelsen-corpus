#!/usr/bin/env bash
set -euo pipefail

TEMPLATE=joacominatel/kelsen-corpus
BASIC_MEMORY=basic-memory==0.24.1
SLUG='^[a-z0-9]+(-[a-z0-9]+)*$'
LOGIN='^[A-Za-z0-9-]+$'
PLACEHOLDER=FILL-IN

usage() {
  cat >&2 <<'EOF'
usage: corpus.sh init <owner>/<name> --public|--private --account <bot> [--license <spdx>]
                      [--owners <login,...>] [--as <login>]
       corpus.sh sync <clone>
       corpus.sh propose <clone> <slug>
       corpus.sh search <clone> <query>
       corpus.sh approvals <clone> on|off|status [--as <login>]
EOF
  exit 2
}
die() { printf 'corpus: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

bm() { uvx --quiet --python 3.12 --from "$BASIC_MEMORY" bm "$@"; }

# GH_TOKEN wins over --user, so it is cleared before asking for another account's token.
token() { env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --hostname "$1" --user "$2"; }

# gh's own helper always answers with the active account, so each store pins its own.
helper() {
  printf '!f() { test "$1" = get || exit 0; echo username=%s; echo "password=$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --hostname %s --user %s)"; }; f' \
    "$2" "$1" "$2"
}

setting() { sed -n "s/^$2: *//p" "$1/kelsen.yml"; }
repo_of() { local url; url=$(git -C "$1" config remote.origin.url); url=${url#https://*/}; echo "${url%.git}"; }
project_of() { echo "corpus-$(repo_of "$1" | tr '/A-Z' '-a-z')"; }
default_branch() { local ref; ref=$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD); echo "${ref#origin/}"; }
store() { git -C "$1" rev-parse --is-inside-work-tree > /dev/null 2>&1 && [ -f "$1/kelsen.yml" ] || die "$1 is not a store clone"; }

active_login() { env -u GH_TOKEN -u GITHUB_TOKEN gh api user --jq .login; }

# The pull request rule GitHub applies to the store's default branch, empty when there is none.
review_rule() {
  gh api "repos/$(repo_of "$1")/rules/branches/$(default_branch "$1")" \
    --jq '[.[] | select(.type == "pull_request")][0] // empty'
}
approvals_state() {
  jq -r '.parameters | if .required_approving_review_count > 0 and .require_code_owner_review then "on" else "off" end'
}

warn_when_approvals_are_off() {
  local clone=$1 tok rule
  [ "$(setting "$clone" protection)" != none ] || return 0
  if ! tok=$(token "$(setting "$clone" host)" "$(setting "$clone" account)" 2> /dev/null) \
    || ! rule=$(GH_TOKEN=$tok review_rule "$clone" 2> /dev/null); then
    warn "could not read the review rule of $(repo_of "$clone")"
  elif [ -z "$rule" ] || [ "$(approvals_state <<< "$rule")" = off ]; then
    warn "approvals are off on $(repo_of "$clone"): entries merge without a person's review"
  fi
}

ruleset() {
  jq -n '{
    name: "admission", target: "branch", enforcement: "active", bypass_actors: [],
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "deletion"},
      {type: "non_fast_forward"},
      {type: "pull_request", parameters: {
        required_approving_review_count: 1, require_code_owner_review: true,
        dismiss_stale_reviews_on_push: true, require_last_push_approval: false,
        required_review_thread_resolution: false}},
      {type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: true,
        required_status_checks: [{context: "validate"}, {context: "bm-noop"}, {context: "tools"}]}}
    ]}'
}

write_settings() {
  { say "id: $id"; say "account: $account"; say "host: $host"; say "spec: 1"; say "protection: $1"
    [ -z "$license" ] || say "license: $license"; } > "$dest/kelsen.yml"
}

commit_as_creator() {
  git -C "$dest" add "$@"
  git -C "$dest" commit -q -m "chore: configure store $id"
  git -C "$dest" -c credential.helper= -c credential.helper="$(helper "$host" "$as")" push -q origin HEAD
}

cmd_init() {
  [ $# -gt 0 ] || usage
  local repo=$1 visibility= account= license= owners= as= host=github.com
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --public|--private) visibility=${1#--}; shift ;;
      --account) account=${2:-}; shift 2 ;;
      --license) license=${2:-}; shift 2 ;;
      --owners) owners=${2:-}; shift 2 ;;
      --as) as=${2:-}; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$visibility" ] && [ -n "$account" ] || usage
  [[ $repo =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "expected <owner>/<name>, got '$repo'"
  [ "$visibility" = private ] || [ -n "$license" ] || die "a public store must declare --license <spdx>"

  local id dest
  id=$(echo "${repo/\//-}" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  dest="$HOME/.kelsen/corpus/$repo"
  [ ! -e "$dest" ] || die "$dest already exists"
  if [ -z "$as" ]; then
    as=$(active_login)
    say "Creating the store as $as, gh's active account. Use --as to choose another."
  fi
  owners=${owners:-$as}
  [[ $account =~ $LOGIN && $as =~ $LOGIN ]] || die "accounts must be GitHub logins"
  [[ ,$owners =~ ^(,[A-Za-z0-9-]+)+$ ]] || die "--owners must be comma-separated GitHub logins"
  GH_TOKEN=$(token "$host" "$as") || die "gh has no token for $as; run: gh auth login"
  export GH_TOKEN

  gh repo create "$repo" --template "$TEMPLATE" "--$visibility" > /dev/null
  local tries=0
  until gh api "repos/$repo/branches/main" > /dev/null 2>&1; do
    tries=$((tries + 1)); [ "$tries" -lt 30 ] || die "$repo never got its template content"; sleep 2
  done
  mkdir -p "$(dirname "$dest")"
  git -c credential.helper= -c credential.helper="$(helper "$host" "$as")" clone -q "https://$host/$repo.git" "$dest"

  write_settings ruleset
  mkdir -p "$dest/.github"
  echo "* @$owners" | sed 's/,/ @/g' > "$dest/.github/CODEOWNERS"
  commit_as_creator kelsen.yml .github/CODEOWNERS

  local err created rid
  err=$(mktemp)
  if created=$(ruleset | gh api -X POST "repos/$repo/rulesets" --input - 2> "$err"); then
    rid=$(echo "$created" | jq -r .id)
    gh api "repos/$repo/rulesets/$rid" | jq -e --argjson want "$(ruleset)" \
      '.bypass_actors == [] and contains($want)' > /dev/null \
      || die "ruleset $rid on $repo does not read back as sent; fix it on GitHub before admitting entries"
    say "Protected the default branch with ruleset $rid."
    gh api -X PATCH "repos/$repo" -F allow_auto_merge=true > /dev/null
    [ "$(gh api "repos/$repo" --jq .allow_auto_merge)" = true ] \
      || die "auto-merge on $repo does not read back as enabled; enable it on GitHub before admitting entries"
    say "Enabled auto-merge: an approved PR merges once its checks pass."
  elif [ "$visibility" = private ] && grep -q '(HTTP 403)' "$err"; then
    say "WARNING: this plan cannot protect a private repository, so $repo is unprotected:"
    say "  the checks run but gate nothing, and search labels its results. GitHub Pro or Team fixes it."
    write_settings none
    commit_as_creator kelsen.yml
  else
    die "could not protect $repo: $(cat "$err")"
  fi
  rm -f "$err"

  git -C "$dest" config credential.helper ''
  git -C "$dest" config --add credential.helper "$(helper "$host" "$account")"
  bm project add "$(project_of "$dest")" "$dest/entries" --no-wait > /dev/null
  bm reindex --search -p "$(project_of "$dest")" > /dev/null

  say "Store ready: $dest"
  say ""
  say "The machine account $account opens every admission PR; it merges once a person approves it."
  say "  1. A person signs it up, because GitHub's terms require one: https://github.com/signup"
  if gh api "users/$account" > /dev/null 2>&1; then
    gh api -X PUT "repos/$repo/collaborators/$account" -f permission=push > /dev/null
    say "  2. Invited $account with write access."
  else
    say "  2. Once it exists, invite it with write access:"
    say "       GH_TOKEN=\$(gh auth token --user $as) gh api -X PUT repos/$repo/collaborators/$account -f permission=push"
  fi
  say "  3. As $account, accept the invitation: https://$host/$repo/invitations"
  say "  4. As $account, create a classic token with the repo and read:org scopes:"
  say "     https://$host/settings/tokens/new (a fine-grained token cannot contribute to a"
  say "     repository its account only collaborates on)"
  say "  5. Log it in to gh, then switch back:"
  say "       gh auth login --hostname $host --with-token < token.txt"
  say "       gh auth switch --hostname $host --user $as"
}

cmd_sync() {
  [ $# -eq 1 ] || usage
  local clone=$1 branch
  store "$clone"
  [ -z "$(git -C "$clone" status --porcelain)" ] || die "$clone has local changes; the search clone only fast-forwards"
  branch=$(default_branch "$clone")
  [ "$(git -C "$clone" branch --show-current)" = "$branch" ] || die "$clone is not on $branch"
  git -C "$clone" pull -q --ff-only origin "$branch"
  bm reindex --search -p "$(project_of "$clone")" > /dev/null
  warn_when_approvals_are_off "$clone"
}

scaffold() {
  cat <<EOF
---
permalink: $1
title: $PLACEHOLDER
type: knowledge
status: verified
claim: $PLACEHOLDER one sentence.
---

## Problem

$PLACEHOLDER

## Cause

$PLACEHOLDER the root cause, not the symptom.

## Solution

$PLACEHOLDER link the merged fix PR.

## Applying it elsewhere

$PLACEHOLDER
EOF
}

cmd_propose() {
  [ $# -eq 2 ] || usage
  local clone=$1 slug=$2
  store "$clone"
  [[ $slug =~ $SLUG ]] || die "slug must match $SLUG"
  local repo id account host branch wt entry head
  repo=$(repo_of "$clone"); id=$(setting "$clone" id); account=$(setting "$clone" account)
  host=$(setting "$clone" host); branch=$(default_branch "$clone")
  wt="$clone/.worktrees/$slug"; entry="entries/$slug.md"; head="entry/$slug"

  if [ ! -d "$wt" ]; then
    git -C "$clone" fetch -q origin
    ! git -C "$clone" cat-file -e "origin/$branch:$entry" 2> /dev/null || die "$id/$slug is already admitted"
    git -C "$clone" worktree add -q -b "$head" "$wt" "origin/$branch"
    scaffold "$id/$slug" > "$wt/$entry"
    say "Drafted $wt/$entry"
    say "Replace every $PLACEHOLDER, then run this command again to validate and propose it."
    return
  fi

  ! grep -q "$PLACEHOLDER" "$wt/$entry" || die "$wt/$entry still holds $PLACEHOLDER"
  GH_TOKEN=$(token "$host" "$account") || die "gh has no token for $account; see corpus.sh init's steps"
  export GH_TOKEN
  local public=
  [ "$(gh repo view "$repo" --json isPrivate --jq .isPrivate)" = true ] || public=--public
  (cd "$wt" && uv run --quiet --project validator --locked kc-validate $public .) || die "kc-validate rejected the entry"

  git -C "$wt" add "$entry"
  git -C "$wt" diff --cached --quiet || git -C "$wt" commit -q -m "feat: propose $id/$slug"
  git -C "$wt" push -q -u origin "$head"
  local url title claim
  url=$(gh pr list -R "$repo" --head "$head" --json url --jq '.[0].url // empty')
  if [ -z "$url" ]; then
    title=$(sed -n 's/^title: *//p' "$wt/$entry" | head -1)
    claim=$(sed -n 's/^claim: *//p' "$wt/$entry" | head -1)
    url=$(gh pr create -R "$repo" --base "$branch" --head "$head" --title "$title" \
      --body "Proposes \`$id/$slug\`: $claim")
    gh pr merge "$url" --auto --merge > /dev/null \
      || say "WARNING: auto-merge was refused, so $url stays open for a person to merge after approving it."
  fi
  say "$url"
}

cmd_search() {
  [ $# -ge 2 ] || usage
  local clone=$1 label=
  shift
  store "$clone"
  [ "$(setting "$clone" protection)" != none ] || label=unprotected
  warn_when_approvals_are_off "$clone"
  bm tool search-notes "$*" --project "$(project_of "$clone")" --entity-type entity --json \
    | jq -r --arg dir "$clone/entries" --arg label "$label" \
      '.results[] | [.permalink, .title, "\($dir)/\(.file_path)"] + (if $label == "" then [] else [$label] end) | @tsv'
}

# Only a person at a terminal can type the confirmation; an agent's shell has no /dev/tty.
confirm() {
  local clone=$1 mode=$2 as=$3 repo answer
  repo=$(repo_of "$clone")
  if ! (: <> /dev/tty) 2> /dev/null; then
    printf 'corpus: turning approvals %s needs a person at a terminal. Run this in your own:\n  %q approvals %q %s --as %s\n' \
      "$mode" "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" "$(cd "$clone" && pwd)" "$mode" "$as" >&2
    exit 1
  fi
  exec 3<> /dev/tty
  printf 'Turning approvals %s on %s. Type %s to confirm: ' "$mode" "$repo" "$repo" >&3
  IFS= read -r answer <&3 || answer=
  exec 3>&-
  [ "$answer" = "$repo" ] || die "the confirmation did not match $repo; nothing changed"
}

cmd_approvals() {
  [ $# -ge 2 ] || usage
  local clone=$1 mode=$2 as=
  shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --as) as=${2:-}; shift 2 ;;
      *) usage ;;
    esac
  done
  case $mode in on|off|status) ;; *) usage ;; esac
  store "$clone"
  local repo account rule rid sent
  repo=$(repo_of "$clone"); account=$(setting "$clone" account)
  [ "$(setting "$clone" protection)" != none ] || die "$repo has no ruleset, so it has no approvals to change"
  [ -n "$as" ] || as=$(active_login)
  [[ $as =~ $LOGIN ]] || die "accounts must be GitHub logins"
  [ "$as" != "$account" ] || die "$account is the store's machine account; only a person changes approvals"
  [ "$mode" = status ] || confirm "$clone" "$mode" "$as"
  GH_TOKEN=$(token "$(setting "$clone" host)" "$as") || die "gh has no token for $as; run: gh auth login"
  export GH_TOKEN

  rule=$(review_rule "$clone")
  [ -n "$rule" ] || die "$repo has no pull request rule on its default branch"
  if [ "$mode" = status ]; then
    say "approvals: $(approvals_state <<< "$rule")"
    return
  fi
  rid=$(jq -r .ruleset_id <<< "$rule")
  # Code owner review demands an approval of its own, so off clears it along with the count.
  sent=$(gh api "repos/$repo/rulesets/$rid" | jq --argjson on "$([ "$mode" = on ] && echo true || echo false)" '
    {name, target, enforcement, bypass_actors, conditions, rules}
    | (.rules[] | select(.type == "pull_request").parameters)
      |= (.required_approving_review_count = (if $on then 1 else 0 end) | .require_code_owner_review = $on)')
  gh api -X PUT "repos/$repo/rulesets/$rid" --input - <<< "$sent" > /dev/null
  gh api "repos/$repo/rulesets/$rid" | jq -e --argjson want "$sent" 'contains($want)' > /dev/null \
    || die "ruleset $rid on $repo does not read back as sent; check it on GitHub"
  say "Approvals are $mode on $repo."
}

[ $# -gt 0 ] || usage
command=$1
shift
case $command in
  init|sync|propose|search|approvals) "cmd_$command" "$@" ;;
  *) usage ;;
esac
