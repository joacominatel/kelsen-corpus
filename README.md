# kelsen-corpus

Template for evidence-gated knowledge stores. A store holds entries that passed review and a
validator, each recording what was learned while fixing a real problem and the context it was
true in. Create your own store from this template; nothing here is a store itself.

## What a store gets

- [`SPEC.md`](SPEC.md): the entry format and every rule, by ID.
- `schema/`: the JSON Schemas for entry frontmatter and `kelsen.yml`.
- `validator/`: `kc-validate`, which prints one line per violation and exits 1 on any.
- `.github/workflows/validate.yml`: the two admission checks, `validate` and `bm-noop`.
- `kelsen.yml`: the store's settings. Replace the example values.
- `entries/`: one markdown file per admitted entry.

## Validate locally

Requires [uv](https://docs.astral.sh/uv/).

```sh
uv run --project validator pytest validator/tests
uv run --project validator kc-validate --public .   # drop --public for a private store
```

## License

The tooling is MIT, see [`LICENSE`](LICENSE). Entries carry the license their store declares in
`kelsen.yml`.
