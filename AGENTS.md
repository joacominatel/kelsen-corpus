# kelsen-corpus

The template for evidence-gated knowledge stores. A store admits an entry only through a pull
request that passes `kc-validate` and `bm-noop` and is approved by a human, so nothing wrong is
ever returned as precedent.

## Before any change

`.claude/charter.md` carries the operational facts: branches, prefixes, lanes, shared critical
files, validation commands, and the review dimensions every PR must clear. **Read it first.**

`SPEC.md` is the source of truth for what a store admits. When it and the validator disagree,
`SPEC.md` wins; correct both in the same change. When a decision has no reference in `SPEC.md`
or ADR-0012 of `joacominatel/kelsen`, ask.

## Workflow

Issue, branch from `main`, `.worktrees/` worktree, commits by responsibility, PR into `main`.
Nothing is pushed to `main` directly. Only the CEO merges.

## Rules that hold here

- Every rule has an ID in `SPEC.md`, a check in the validator, and a failing fixture.
- `entries/` is store content. The template ships it empty.
- The Basic Memory pin changes only deliberately, with `bm-noop` rerun against it.
