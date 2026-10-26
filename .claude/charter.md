# Charter

## Identity

- **Repository**: kelsen-corpus
- **Owned by the CEO**: yes
- **What it is**: the public template every evidence-gated knowledge store is created from: spec,
  schemas, validator, and admission checks.
- **Source of truth for domain and decisions**: `SPEC.md`; decisions live in ADR-0012 of
  `joacominatel/kelsen`.
- **Store settings**: `kelsen.yml` owns them; this charter does not restate them.

## Branches

- **Base branch** (where work starts and PRs land): `main`
- **Protected** (agents never push or merge here): `main`
- **Branch naming**: `<prefix>/issue-<n>-<slug>`, where `<prefix>` is a commit prefix
- **Promotion**: only the CEO merges into `main`. Nothing is pushed to `main` directly; every
  change goes through a branch, a `.worktrees/` worktree, and a PR.

## Commits

- **Prefixes**: `feat` `fix` `docs` `updt` `test` `chore`
- **Granularity**: one logical responsibility per commit; documentation may be grouped.
- **Forbidden**: `--amend`, `rebase`, `reset`, `add -A`, `add .`, attribution trailers.

## Issues and labels

- **Tracker**: GitHub
- **Agent-created issues carry**: none
- **Label dimensions**: none yet

## Lanes

| Lane | May write | Must not touch |
| --- | --- | --- |
| spec | `SPEC.md`, `schema/**` | `validator/**`, `.github/**` |
| validator | `validator/**` | `SPEC.md`, `schema/**`, `.github/**` |
| ci | `.github/**` | `SPEC.md`, `schema/**`, `validator/**` |

Cross-lane edits require explicit authorization in the dispatch prompt, and the commit message
records it. A new rule usually spans spec and validator; dispatch it as one unit with both lanes.

## Shared critical files

A unit touching any of these forces serial execution.

- `schema/entry.schema.json`, `schema/kelsen.schema.json`: read by the validator.
- `validator/uv.lock`
- `kelsen.yml`

## Validation

Run all of these from the worktree before opening a PR:

```sh
uv run --project validator --locked pytest validator/tests
uv run --project validator --locked kc-validate --public .
```

CI runs both in `validate`, plus `bm-noop`: Basic Memory 0.24.1 indexes `entries/` and the
working tree must stay clean. Run it locally only when changing the pin or the entry format:

```sh
export BASIC_MEMORY_CONFIG_DIR="$(mktemp -d)"
uvx --python 3.12 --from basic-memory==0.24.1 bm project add corpus "$PWD/entries" --no-wait
uvx --python 3.12 --from basic-memory==0.24.1 bm reindex --search -p corpus
git status --porcelain   # must print nothing
```

## Testing

- **Commands**: `uv run --project validator pytest validator/tests` · `... pytest validator/tests -k <name>` · coverage not measured
- **Test paths**: `validator/tests/**`
- **Suite shape**: one pytest module drives `kc-validate` against a temporary store built from
  `validator/tests/fixtures/`: one failing fixture per rule ID, plus valid ones.
- **Coverage floor**: none
- **Doubles**: none; the validator runs for real on the filesystem.

## Review dimensions

Every PR must clear all of these, and the PR body must address each one:

1. **Correctness**: it does what it claims, with tests that prove it.
2. **Security**: the workflow keeps `contents: read`, no secrets, and SHA-pinned actions.
3. **Over-engineering**: no dead code, speculative abstraction, or hand-rolled stdlib.
4. **Store compatibility**: stores do not follow this template. A change to `SPEC.md`,
   `schema/`, or the Basic Memory pin states what existing stores must do, and whether it bumps
   `spec`.

## Documentation

- **Decision records**: ADR-0012 and successors in `joacominatel/kelsen`.
- **User-facing surface**: `README.md` and `SPEC.md`, updated for any change to how a store is
  created or what it admits.
- **Living project page**: https://claude.ai/artifact/CumNXfBPHnSAsTnFFn7oWY

## Exceptions to global defaults

- Base and protected branch are the same, `main`: there is no integration branch.
