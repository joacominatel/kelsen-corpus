# kelsen-corpus

Template for evidence-gated knowledge stores. A store holds entries that passed review and a
validator, each recording what was learned while fixing a real problem and the context it was
true in. Create your own store from this template; nothing here is a store itself.

## What a store gets

- [`SPEC.md`](SPEC.md): the entry format and every rule, by ID.
- `schema/`: the JSON Schemas for entry frontmatter and `kelsen.yml`.
- `validator/`: `kc-validate`, which prints one line per violation and exits 1 on any.
- `.github/workflows/validate.yml`: the three admission checks, `validate`, `bm-noop`, and `tools`.
- `kelsen.yml`: the store's settings. Replace the example values.
- `entries/`: one markdown file per admitted entry.
- `tools/corpus.sh`: creates a store, proposes entries to it, and searches it.

## Create and use a store

`tools/corpus.sh` needs [gh](https://cli.github.com/), git, jq, and uv. Every GitHub call runs
under an explicit account: the person who creates the store, or the store's machine account,
which opens every admission PR so that a person can approve it.

```sh
tools/corpus.sh init <owner>/<name> --private --account <bot>   # or --public --license <spdx>
tools/corpus.sh propose <clone> <slug>   # drafts the entry; run again to validate and open the PR
tools/corpus.sh sync <clone>             # fast-forward to the admitted entries and reindex
tools/corpus.sh search <clone> <query>   # Basic Memory search over admitted entries only
tools/corpus.sh approvals <clone> on|off|status   # whether admission PRs need a person's approval
```

`init` creates the store from this template, writes `kelsen.yml` and `CODEOWNERS`, protects the
default branch with a ruleset, clones it to `~/.kelsen/corpus/<owner>/<name>` pinned to the
machine account, registers it with Basic Memory, and prints the steps for the machine account
that only a person can take. A private store on a plan without rulesets is created unprotected:
its checks gate nothing, and search labels every result `unprotected`. `--owners` names the
code owners who approve entries; it defaults to the creator. `--as` picks the creating account;
it defaults to gh's active one.

`approvals off` lets admission PRs merge on green checks alone; `approvals on` requires a code
owner's approval again; `status` prints which one holds. A person runs `on` and `off` from their
own terminal, as their own account and never the machine account, and confirms by typing the
store's `<owner>/<name>`. Without a terminal, as in an agent's shell, the command refuses and
prints what to run, so an agent can show the command but not run it. This stops an agent from
driving the script; it does not stop direct GitHub API calls made with the person's token.
While approvals are off, `sync` and `search` print a warning.

## Validate locally

Requires [uv](https://docs.astral.sh/uv/).

```sh
uv run --project validator pytest validator/tests
uv run --project validator kc-validate --public .   # drop --public for a private store
```

## License

The tooling is MIT, see [`LICENSE`](LICENSE). Entries carry the license their store declares in
`kelsen.yml`.
