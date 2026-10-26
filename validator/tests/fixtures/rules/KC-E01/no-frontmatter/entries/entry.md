## Problem

A repository sets `credential.username` to pin one of several logged-in accounts, yet git uses
whichever account is active in `gh`.

## Cause

`gh auth git-credential` asks only for the active account's token and returns a silent error
when git sends a different `username`.

## Solution

Replace the repository's credential helpers with one that runs
`gh auth token --user ACCOUNT` on every request. Merged in
https://github.com/joacominatel/kelsen-corpus/pull/5.

## Applying it elsewhere

Any repository that must always act as one account on a machine where several are logged in.

## Limits

Clear `GH_TOKEN` and `GITHUB_TOKEN` inside the helper, or either one overrides `--user`.
