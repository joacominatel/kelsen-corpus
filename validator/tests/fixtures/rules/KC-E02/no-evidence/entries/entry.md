---
permalink: example/entry
title: gh's git credential helper always uses the active account
type: knowledge
status: verified
claim: With several GitHub accounts logged in to gh, `gh auth git-credential` returns only the host's active account, so a repo-level `credential.username` cannot pin an account.
tags: [git, gh, credentials]
provenance:
  project: joacominatel/kelsen-corpus
  sources:
    - https://github.com/joacominatel/kelsen-corpus/pull/5
  author: joacominatel
  recorded_on: 2026-10-26
context:
  language: {name: bash, version: "3.2.57"}
  runtime: {name: gh, version: "2.100.0"}
  platform: macOS 27.0.1
  dependencies:
    - {ecosystem: other, name: git, version: "2.50.1"}
lifecycle:
  verified_on: 2026-10-26
  review_by: 2027-10-26
stats:
  - name: accounts logged in
    value: 3
    as_of: 2026-10-26
    source: {kind: report, reporter: joacominatel}
---

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
