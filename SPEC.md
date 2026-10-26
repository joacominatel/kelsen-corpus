# kelsen-corpus specification, spec 2

A store admits an entry only when every rule below holds. `kc-validate` checks them and reports
each violation as one line, `<RULE> <path>: <message>`, exiting 1 when there is any. Files are
checked in path order, settings first. A file that breaks several rules reports each of them.

```sh
kc-validate [root] [--public] [--base <git ref>]
```

`--public` marks the store as public (KC-C03). `--base` names the commit the change is judged
against, normally the PR's base branch; the KC-X04 and KC-T rules run only when it is given.

The decision behind this format is ADR-0012 in `joacominatel/kelsen`, the engineering harness
that consumes these stores.

## Store settings: `kelsen.yml`

`kelsen.yml` at the store root holds the store's settings. Its schema is
[`schema/kelsen.schema.json`](schema/kelsen.schema.json).

| Key | Value |
| --- | --- |
| `id` | the store id, lowercase words joined by `-`; the first half of every permalink. `corpus.sh init` sets it to `<owner>-<name>`, so a permalink is unique across stores and a `Knowledge: <permalink>` citation names exactly one entry. It never changes |
| `account` | the machine account that opens admission PRs |
| `host` | the git host every reference points at, e.g. `github.example.com`; optional, `github.com` when absent |
| `spec` | `2`, the version of this specification the store follows |
| `protection` | `ruleset` when the default branch is protected, `none` otherwise |
| `license` | an SPDX identifier for the entries, e.g. `CC-BY-4.0`; required when the store is public |

| Rule | Requirement | A failing fixture |
| --- | --- | --- |
| KC-C01 | `kelsen.yml` exists and is a YAML mapping. | no `kelsen.yml`; a YAML list |
| KC-C02 | `kelsen.yml` matches its schema: every key above except `host` and `license` is present, values are valid, and unknown keys are rejected. | an unknown key `mode: fast`; no `account` |
| KC-C03 | A public store declares `license`. The visibility comes from the host, not from `kelsen.yml`: CI passes `--public` for a public repository. | `--public` with no `license` |
| KC-C04 | `spec` is `2`. A newer value means the validator is older than the store and must not judge it; an older one means the store must migrate. | `spec: 3`; `spec: 1` |

## Entries

One markdown file per entry, `entries/<slug>.md`, where `<slug>` is lowercase words joined by
`-`. Files starting with `.` are not entries.

### Reading an entry

The entry starts with a YAML frontmatter block between `---` lines, followed by the markdown
body.

- The frontmatter is read with YAML's safe types, except that timestamps stay strings:
  `recorded_on: 2026-10-26` is the string `"2026-10-26"`.
- A duplicate key at any depth is a violation (KC-S02), never a silent overwrite.
- The frontmatter's schema is [`schema/entry.schema.json`](schema/entry.schema.json). Each
  schema violation is reported under the `x-rule` of the innermost subschema on its schema path
  that carries one, following `$ref`. The root carries `KC-E02`, so a missing or unknown
  top-level key is KC-E02 while an unknown key inside `provenance` is KC-F-PROVENANCE.
- `format: date` is asserted, not just annotated.
- Schema patterns write the store's host as `<host>`. The validator replaces it with the
  regex-escaped `host` from `kelsen.yml`, or `github.com` when absent, before compiling the schema.
- "Today" is the current date in UTC when the validator runs.
- A body section runs from its `## ` heading line to the next line starting with `# ` or `## `,
  or to the end of the file.

### Frontmatter

Unknown keys are rejected at every depth. Optional keys are marked; every other key is
required.

| Key | Value |
| --- | --- |
| `permalink` | `<store id>/<slug>`, where `<slug>` is the file stem; immutable |
| `title` | 8 to 120 characters |
| `type` | `knowledge` |
| `status` | `verified`, `stale`, `superseded`, or `retracted` |
| `claim` | the entry's claim in one sentence, at most 280 characters |
| `tags` | optional: a list of distinct strings without whitespace |
| `provenance.project` | where the finding was made: `owner/repo`, or a label for a project without one |
| `provenance.sources` | at least one URL of the merged fix: a PR, or a commit pinned to its 40-hex SHA |
| `provenance.author` | the GitHub login of the person who recorded the entry |
| `provenance.recorded_on` | the date the entry was recorded |
| `context.language` | `{name, version}`: the language the finding holds in, at its exact version |
| `context.runtime` | optional: `{name, version}`, same rules |
| `context.platform` | optional: the operating system or platform, one line |
| `context.dependencies` | a list, empty when there are none, of `{ecosystem, name, version}`; `ecosystem` is `npm`, `pypi`, `go`, `cargo`, `maven`, `nuget`, `gem`, or `other` |
| `evidence` | at least one `{kind, ref, shows}`: `kind` is `test`, `run`, `pr`, `commit`, `issue`, or `doc`; `ref` is an immutable reference; `shows` says in at most 200 characters what it proves |
| `lifecycle.verified_on` | the date the claim was last verified |
| `lifecycle.review_by` | the date by which it must be verified again |
| `lifecycle.superseded_by` | the permalink of the entry that replaces this one; present exactly when `status` is `superseded` |
| `lifecycle.supersedes` | optional: the permalinks of the entries this one replaces |
| `lifecycle.retracted` | `{reason, ref}`: why the entry was wrong and an immutable reference to the evidence; present exactly when `status` is `retracted` |
| `stats` | optional: a list of `{name, value, unit, as_of, source}`; `unit` is optional; `source` is `{kind, ref, reporter}` with `kind` one of `report`, `measurement`, `job` |

An **immutable reference** is a `https://<host>/<owner>/<repo>/` URL, `<host>` being the store's,
followed by one of:
`commit/<sha>`, `blob/<sha>/<path>`, `tree/<sha>/<path>`, `pull/<n>`, `issues/<n>`, or
`actions/runs/<n>`, where `<sha>` is 40 lowercase hex characters; a `#fragment` may follow. A
`doc` evidence item may instead use any `https` URL off `<host>`. A URL on `<host>` that is not
in this list, such as `blob/main/...`, is mutable and rejected everywhere.

### Body

The body carries these level-2 sections, each once and none empty: `## Problem`, `## Cause`,
`## Solution`, and `## Applying it elsewhere`. `## Limits` is optional, and when present it is
also once and non-empty. Other sections are allowed.

`## Cause` is the root cause, not the symptom. `## Solution` links the merged fix: a PR URL or a
SHA-pinned commit URL, as in `provenance.sources`. The validator checks the link's shape; the
reviewer checks that it merged.

### Example

```markdown
---
permalink: example/gh-credential-helper-ignores-username
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
evidence:
  - kind: doc
    ref: https://github.com/cli/cli/blob/4f2cfe92e3499f8581bf39db77e0a1431fa7b55c/pkg/cmd/auth/gitcredential/helper.go#L123-L152
    shows: The helper only asks for the active account's token and fails silently on a username mismatch.
  - kind: pr
    ref: https://github.com/joacominatel/kelsen-corpus/pull/5
    shows: A per-repository helper that calls gh auth token --user cloned and pushed as the pinned account.
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
```

## Rules

Each rule names a failing fixture: the smallest change to a valid store that breaks it.

### Structure

| Rule | Requirement | A failing fixture |
| --- | --- | --- |
| KC-S01 | `entries/` is one flat directory: it holds no subdirectory, and every file not starting with `.` is `<slug>.md`. | `entries/git/a.md`; `entries/notes.txt`; `entries/Bad_Name.md` |
| KC-E01 | The entry starts with a `---` delimited frontmatter block that is a YAML mapping. | no frontmatter; frontmatter that is not YAML; a YAML list |
| KC-S02 | The frontmatter has no duplicate key at any depth. | `title` twice; `name` twice inside `context.language` |
| KC-E02 | Every required top-level key is present and no unknown top-level key is. | no `evidence`; an extra `summary:` |
| KC-E03 | `permalink` equals `<store id>/<file stem>`. | `permalink: example/other-slug` in `entries/slug.md` |
| KC-E04 | The body has every required section as a `## ` heading. | no `## Cause` |
| KC-S03 | Each required section and `## Limits` appears at most once, and each one present has non-whitespace content. | `## Cause` directly followed by `## Solution`; `## Problem` twice; an empty `## Limits` |
| KC-S04 | `## Solution` contains a PR URL or a SHA-pinned commit URL, in the shape of `provenance.sources`. | a `## Solution` with no link, or linking only `blob/main/...` |

### Fields

Rules named after a key own every violation inside that key, including unknown and missing
nested keys. KC-F-VER, KC-F-REF, and KC-F-DATE own the values they name wherever they appear.

| Rule | Requirement | A failing fixture |
| --- | --- | --- |
| KC-F-PERMALINK | `permalink` is a string `<slug>/<slug>`. | `permalink: Example/Foo` |
| KC-F-TITLE | `title` is a string of 8 to 120 characters. | `title: Short`; a 121-character title |
| KC-F-TYPE | `type` is `knowledge`. | `type: note` |
| KC-F-STATUS | `status` is `verified`, `stale`, `superseded`, or `retracted`. | `status: draft` |
| KC-F-CLAIM | `claim` is one line of at most 280 characters with no `.`, `!`, or `?` followed by whitespace. | `claim: It fails. Pin it.`; a 281-character claim |
| KC-F-TAGS | `tags`, when present, is a list of distinct strings without whitespace. | `tags: git`; `tags: [git, git]` |
| KC-F-PROVENANCE | `provenance` has exactly `project` (one line), `sources` (at least one, distinct), `author` (a GitHub login), and `recorded_on`. | `sources: []`; `author: Jane Doe`; an extra `provenance.team` |
| KC-F-CONTEXT | `context` has `language` and `dependencies`, may have `runtime` and `platform`, and nothing else; `language` and `runtime` are exactly `{name, version}`; each dependency is exactly `{ecosystem, name, version}` with a listed ecosystem. | no `dependencies`; `ecosystem: apt` |
| KC-F-EVIDENCE | `evidence` is a list of at least one item, each exactly `{kind, ref, shows}`, with a listed `kind` and a one-line `shows` of at most 200 characters. | `evidence: []`; `kind: screenshot`; a 201-character `shows` |
| KC-F-LIFECYCLE | `lifecycle` has `verified_on` and `review_by`, with `review_by` after `verified_on` and at most 365 days after it; `superseded_by` is present exactly when `status` is `superseded`; `retracted` is `{reason, ref}` and present exactly when `status` is `retracted`; `supersedes`, when present, is a non-empty list of distinct permalinks. | `review_by` 366 days after `verified_on`; `status: superseded` without `superseded_by`; a `retracted` block on a verified entry |
| KC-F-STATS | `stats`, when present, is a list of `{name, value, unit?, as_of, source}`: `value` is a number; `source.kind` is listed; a `report` names its `reporter`; a `measurement` or `job` has a `ref`; no `name` is `citations`, which the maintenance job owns. | a `report` without `reporter`; a `job` without `ref`; `value: "12"`; `name: citations` |
| KC-F-VER | Every `version` is written as a quoted YAML string in the source, is one line, starts with a non-space, contains none of `^ ~ < > *`, and has no `x` or `X` dot-separated component. | `version: 3.12` (unquoted); `version: "^1.2.0"`; `version: "1.x"` |
| KC-F-REF | Every `evidence[].ref`, `lifecycle.retracted.ref`, and `stats[].source.ref` is an immutable reference, off `<host>` only for `doc` evidence; every `provenance.sources` item is a PR or SHA-pinned commit URL on `<host>`. | `ref: https://github.com/o/r/blob/main/x.py`; an off-host `ref` on `kind: test`; a PR on another host than `kelsen.yml`'s; a source `https://github.com/o/r/issues/1` |
| KC-F-DATE | `recorded_on`, `verified_on`, `review_by`, and `as_of` are real calendar dates written `YYYY-MM-DD`; none but `review_by` is after today. | `verified_on: 2026-02-30`; `recorded_on: 26/10/2026`; `as_of: 2999-01-01` |

### Cross-file

| Rule | Requirement | A failing fixture |
| --- | --- | --- |
| KC-X01 | No two entries share a `permalink`. | two files whose frontmatter both claim `example/a` |
| KC-X02 | `superseded_by` names an existing entry of this store that is not `retracted` and whose `supersedes` lists this entry. | a target that does not exist; a retracted target; a target without the back-link |
| KC-X03 | Every permalink in `supersedes` names an entry of this store whose `status` is `superseded` and whose `superseded_by` is this entry. | `supersedes` naming a verified entry |
| KC-X04 | With `--base`, `kelsen.yml`'s `id` equals the base's. | base `id: example`, head `id: renamed` |

### Transitions

With `--base`, each entry is compared with its version at the base. When the base has no
`kelsen.yml`, or declares a different `spec`, only KC-T01 runs: a migration rewrites every entry
at once and is judged by the field rules alone.

| Rule | Requirement | A failing fixture |
| --- | --- | --- |
| KC-T01 | Every entry file at the base exists at the same path. Entries are never deleted or renamed. | an entry deleted; an entry renamed |
| KC-T02 | An entry absent at the base has `status: verified`. | a new entry with `status: stale` |
| KC-T03 | `permalink` and `provenance` equal the base's. | `provenance.author` changed |
| KC-T04 | A status change is one of: verified→stale, verified→superseded, stale→superseded, verified→retracted, stale→retracted, stale→verified. `superseded` and `retracted` are terminal. | retracted→verified; superseded→stale; stale→stale is no change and passes |
| KC-T05 | stale→verified needs a `verified_on` later than the base's and at least one `evidence` item whose `ref` is not in the base's evidence. | stale→verified with the base's evidence |
| KC-T06 | When `claim`, `context`, or `evidence` differs from the base, `verified_on` is later than the base's. | an edited `claim` with the base's `verified_on` |

## Basic Memory no-op

Admission also requires that indexing `entries/` with Basic Memory 0.24.1 rewrites no file: the
`bm-noop` check runs `bm reindex --search` and requires a clean working tree. Basic Memory adds a
`permalink`, `title`, and `type` to a file without frontmatter, and rewrites a `permalink` it
does not accept, so a valid entry passes and a malformed one does not.

## Migrating from spec 1

Spec 1 entries fail spec 2. Migrate a store in one PR:

1. Set `spec: 2` in `kelsen.yml`, and copy this template's `schema/` and validator.
2. Give every entry `provenance`, `context`, `evidence`, and `lifecycle`.
3. Check what spec 1 did not: `title` of 8 to 120 characters, a one-sentence `claim` of at most
   280, quoted `version` values, a merged-fix link in `## Solution`, and no empty section.

Because the PR changes `spec`, KC-T02 to KC-T06 do not run against it.
