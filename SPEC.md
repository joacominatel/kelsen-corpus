# kelsen-corpus specification, spec 1

A store admits an entry only when every rule below holds. `kc-validate` checks them and reports
each violation as one line, `<RULE> <path>: <message>`, exiting 1 when there is any. Files are
checked in path order, settings first.

The decision behind this format is ADR-0012 in `joacominatel/kelsen`, the engineering harness
that consumes these stores.

## Store settings: `kelsen.yml`

`kelsen.yml` at the store root holds the store's settings. Its schema is
[`schema/kelsen.schema.json`](schema/kelsen.schema.json).

| Key | Value |
| --- | --- |
| `id` | the store id, lowercase words joined by `-`; the first half of every permalink |
| `account` | the machine account that opens admission PRs |
| `host` | the git host, e.g. `github.com` |
| `spec` | `1`, the version of this specification the store follows |
| `protection` | `ruleset` when the default branch is protected, `none` otherwise |
| `license` | an SPDX identifier for the entries, e.g. `CC-BY-4.0`; required when the store is public |

| Rule | Requirement |
| --- | --- |
| KC-C01 | `kelsen.yml` exists and is a YAML mapping. |
| KC-C02 | `kelsen.yml` matches its schema: every key above except `license` is present, values are valid, and unknown keys are rejected. |
| KC-C03 | A public store declares `license`. The visibility comes from the host, not from `kelsen.yml`: CI passes `--public` for a public repository. |

## Entries

One markdown file per entry, `entries/<slug>.md`. Files starting with `.` are not entries.

### Frontmatter

The entry starts with a YAML frontmatter block between `---` lines. Its schema is
[`schema/entry.schema.json`](schema/entry.schema.json).

| Key | Value |
| --- | --- |
| `permalink` | `<store id>/<slug>`, where `<slug>` is the file stem; immutable |
| `title` | a non-empty string |
| `type` | `knowledge` |
| `status` | `verified`, `stale`, `superseded`, or `retracted` |
| `claim` | the entry's claim in one sentence |

### Body

The body carries these level-2 sections: `## Problem`, `## Cause`, `## Solution`, and
`## Applying it elsewhere`. `## Cause` is the root cause, not the symptom.

### Rules

| Rule | Requirement |
| --- | --- |
| KC-E01 | The entry starts with a `---` delimited frontmatter block that is a YAML mapping. |
| KC-E02 | The frontmatter matches its schema: every key above is present, values are valid, and unknown keys are rejected. |
| KC-E03 | `permalink` equals `<store id>/<file stem>`. |
| KC-E04 | The body has every required section as a `## ` heading. |

## Basic Memory no-op

Admission also requires that indexing `entries/` with Basic Memory 0.24.1 rewrites no file: the
`bm-noop` check runs `bm reindex --search` and requires a clean working tree. Basic Memory adds a
`permalink`, `title`, and `type` to a file without frontmatter, and rewrites a `permalink` it
does not accept, so a valid entry passes and a malformed one does not.

## Planned

Spec 2 adds, each with its own rule IDs:

- `provenance`: project, sources as PR or SHA-pinned commit URLs, author, `recorded_on`;
- `context`: language at its exact version, optional runtime and platform, dependencies at
  exact versions with their ecosystem;
- `evidence`: immutable references, each stating what it `shows`;
- `lifecycle`: `verified_on`, `review_by` within 365 days, supersession links;
- `stats`: optional, each with a named source;
- status transitions, including the reason and evidence a retraction needs;
- the optional `## Limits` section and the link to the merged fix PR in `## Solution`.
