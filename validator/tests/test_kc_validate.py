import copy
import itertools
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

from kelsen_corpus_validator.cli import main

FIXTURES = Path(__file__).parent / "fixtures"
REPO = Path(__file__).parents[2]
SCHEMA = REPO / "schema"
SPEC = (REPO / "SPEC.md").read_text()
TODAY = "2026-10-26"

RULE_CASES = sorted(FIXTURES.glob("rules/*/*"))
VALID_CASES = sorted((FIXTURES / "valid").iterdir())
SPEC_RULES = set(re.findall(r"^\| (KC-[A-Z0-9-]+) \|", SPEC, re.MULTILINE))


def git(root, *args):
    return subprocess.run(
        ["git", "-c", "user.name=kelsen-test", "-c", "user.email=test@example.com",
         "-c", "commit.gpgsign=false", *args],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout.strip()


def place(snapshot, root):
    (root / "kelsen.yml").unlink(missing_ok=True)
    shutil.rmtree(root / "entries", ignore_errors=True)
    shutil.copytree(snapshot, root, dirs_exist_ok=True)


def run(case, root, capsys, public=True):
    shutil.copytree(SCHEMA, root / "schema")
    argv = [str(root), "--today", TODAY, *(["--public"] if public else [])]
    if (case / "base").is_dir():
        git(root, "init", "-q")
        place(case / "base", root)
        git(root, "add", "--all")
        git(root, "commit", "-q", "-m", "base")
        base = git(root, "rev-parse", "HEAD")
        place(case / "head", root)
        git(root, "add", "--all")
        git(root, "commit", "-q", "--allow-empty", "-m", "head")
        argv += ["--base", base]
    else:
        shutil.copytree(case, root, dirs_exist_ok=True, ignore=shutil.ignore_patterns("expected"))
    code = main(argv)
    return code, [line.split(":", 1)[0] for line in capsys.readouterr().out.splitlines()]


def expected(case):
    return sorted((case / "expected").read_text().splitlines())


@pytest.mark.parametrize("case", RULE_CASES, ids=lambda c: f"{c.parent.name}/{c.name}")
def test_failing_fixture_reports_its_rule(case, tmp_path, capsys):
    code, lines = run(case, tmp_path, capsys)
    assert (code, sorted(lines)) == (1, expected(case))


@pytest.mark.parametrize("case", VALID_CASES, ids=lambda c: c.name)
def test_valid_store_is_admitted(case, tmp_path, capsys):
    assert run(case, tmp_path, capsys) == (0, [])


def test_private_store_without_license_is_admitted(tmp_path, capsys):
    case = FIXTURES / "rules" / "KC-C03" / "public-without-license"
    assert run(case, tmp_path, capsys, public=False) == (0, [])


def test_violations_are_reported_settings_first_then_in_path_order(tmp_path, capsys):
    assert run(FIXTURES / "order", tmp_path, capsys) == (
        1,
        ["KC-C02 kelsen.yml", "KC-E02 entries/a.md", "KC-E04 entries/b.md"],
    )


def test_every_spec_rule_has_a_fixture_directory_and_no_other_exists():
    assert {path.name for path in (FIXTURES / "rules").iterdir()} == SPEC_RULES


def test_the_validator_emits_exactly_the_spec_rules(tmp_path_factory, capsys):
    emitted = {
        line.split(" ", 1)[0]
        for case in RULE_CASES
        for line in run(case, tmp_path_factory.mktemp(case.name), capsys)[1]
    }
    assert emitted == SPEC_RULES


# Mutation sweep over the frontmatter field table of SPEC.md, applied to its example entry.

EXAMPLE = FIXTURES / "valid" / "example"
EXAMPLE_ENTRY = next((EXAMPLE / "entries").glob("*.md"))
_, EXAMPLE_FRONTMATTER, EXAMPLE_BODY = EXAMPLE_ENTRY.read_text().split("---\n", 2)


class Quoted(str):
    pass


class Dumper(yaml.SafeDumper):
    pass


Dumper.add_representer(Quoted, lambda d, s: d.represent_scalar("tag:yaml.org,2002:str", s, style='"'))


def example_frontmatter():
    data = yaml.safe_load(EXAMPLE_FRONTMATTER)
    context = data["context"]
    context["language"]["version"] = Quoted(context["language"]["version"])
    context["runtime"]["version"] = Quoted(context["runtime"]["version"])
    context["dependencies"][0]["version"] = Quoted(context["dependencies"][0]["version"])
    return data


def mutate(data, op, path, value):
    data = copy.deepcopy(data)
    *parents, last = path
    node = data
    for key in parents:
        node = node[key]
    if op == "drop":
        del node[last]
    else:
        node[last] = value
    return data


def validate_frontmatter(data, root, capsys):
    shutil.copytree(SCHEMA, root / "schema")
    shutil.copy(EXAMPLE / "kelsen.yml", root / "kelsen.yml")
    (root / "entries").mkdir()
    text = yaml.dump(data, Dumper=Dumper, sort_keys=False, width=10**6, allow_unicode=True)
    (root / "entries" / EXAMPLE_ENTRY.name).write_text(f"---\n{text}---\n{EXAMPLE_BODY}")
    code = main([str(root), "--public", "--today", TODAY])
    return code, {line.split(" ", 1)[0] for line in capsys.readouterr().out.splitlines()}


E02, PERMALINK, TITLE, TYPE, STATUS, CLAIM, TAGS = (
    "KC-E02", "KC-F-PERMALINK", "KC-F-TITLE", "KC-F-TYPE", "KC-F-STATUS", "KC-F-CLAIM", "KC-F-TAGS")
PROV, CTX, EV, LC, ST = "KC-F-PROVENANCE", "KC-F-CONTEXT", "KC-F-EVIDENCE", "KC-F-LIFECYCLE", "KC-F-STATS"
VER, REF, DATE = "KC-F-VER", "KC-F-REF", "KC-F-DATE"

LANGUAGE = ("context", "language")
RUNTIME = ("context", "runtime")
DEPENDENCY = ("context", "dependencies", 0)
SOURCE = ("stats", 0, "source")

REQUIRED = [
    (("permalink",), E02), (("title",), E02), (("type",), E02), (("status",), E02), (("claim",), E02),
    (("provenance",), E02), (("context",), E02), (("evidence",), E02), (("lifecycle",), E02),
    (("provenance", "project"), PROV), (("provenance", "sources"), PROV),
    (("provenance", "author"), PROV), (("provenance", "recorded_on"), PROV),
    (LANGUAGE, CTX), (("context", "dependencies"), CTX),
    (LANGUAGE + ("name",), CTX), (LANGUAGE + ("version",), CTX),
    (RUNTIME + ("name",), CTX), (RUNTIME + ("version",), CTX),
    (DEPENDENCY + ("ecosystem",), CTX), (DEPENDENCY + ("name",), CTX), (DEPENDENCY + ("version",), CTX),
    (("evidence", 0, "kind"), EV), (("evidence", 0, "ref"), EV), (("evidence", 0, "shows"), EV),
    (("lifecycle", "verified_on"), LC), (("lifecycle", "review_by"), LC),
    (("stats", 0, "name"), ST), (("stats", 0, "value"), ST), (("stats", 0, "as_of"), ST),
    (SOURCE, ST), (SOURCE + ("kind",), ST), (SOURCE + ("reporter",), ST),
]

WRONG_TYPE = [
    (("permalink",), 42, PERMALINK), (("title",), 42, TITLE), (("type",), 42, TYPE),
    (("status",), 42, STATUS), (("claim",), 42, CLAIM),
    (("tags",), "git", TAGS), (("tags", 0), 42, TAGS),
    (("provenance",), "x", PROV), (("provenance", "project"), 42, PROV),
    (("provenance", "sources"), "x", PROV), (("provenance", "sources", 0), 42, REF),
    (("provenance", "author"), 42, PROV), (("provenance", "recorded_on"), 42, DATE),
    (("context",), "x", CTX), (LANGUAGE, "x", CTX), (LANGUAGE + ("name",), 42, CTX),
    (LANGUAGE + ("version",), 42, VER), (RUNTIME, "x", CTX), (RUNTIME + ("version",), 42, VER),
    (("context", "platform"), 42, CTX), (("context", "dependencies"), "x", CTX), (DEPENDENCY, "x", CTX),
    (DEPENDENCY + ("ecosystem",), 42, CTX), (DEPENDENCY + ("name",), 42, CTX),
    (DEPENDENCY + ("version",), 42, VER),
    (("evidence",), "x", EV), (("evidence", 0), "x", EV), (("evidence", 1, "kind"), 42, EV),
    (("evidence", 0, "ref"), 42, REF), (("evidence", 0, "shows"), 42, EV),
    (("lifecycle",), "x", LC), (("lifecycle", "verified_on"), 42, DATE),
    (("lifecycle", "review_by"), 42, DATE), (("lifecycle", "superseded_by"), 42, LC),
    (("lifecycle", "supersedes"), "x", LC), (("lifecycle", "retracted"), "x", LC),
    (("stats",), "x", ST), (("stats", 0), "x", ST), (("stats", 0, "name"), 42, ST),
    (("stats", 0, "value"), "3", ST), (("stats", 0, "unit"), 42, ST), (("stats", 0, "as_of"), 42, DATE),
    (SOURCE, "x", ST), (SOURCE + ("kind",), 42, ST), (SOURCE + ("reporter",), 42, ST),
]

OUT_OF_RANGE = [
    (("type",), "note", TYPE), (("status",), "draft", STATUS),
    (DEPENDENCY + ("ecosystem",), "apt", CTX), (("evidence", 1, "kind"), "screenshot", EV),
    (SOURCE + ("kind",), "survey", ST),
]

UNKNOWN_KEY = [
    ((), E02), (("provenance",), PROV), (("context",), CTX), (LANGUAGE, CTX), (RUNTIME, CTX),
    (DEPENDENCY, CTX), (("evidence", 0), EV), (("lifecycle",), LC), (("stats", 0), ST), (SOURCE, ST),
]

OPTIONAL = [("tags",), RUNTIME, ("context", "platform"), ("stats",)]


def name(path):
    return ".".join(map(str, path)) or "root"


MUTATIONS = (
    [pytest.param("drop", path, None, rule, id=f"drop-{name(path)}") for path, rule in REQUIRED]
    + [pytest.param("set", path, value, rule, id=f"type-{name(path)}") for path, value, rule in WRONG_TYPE]
    + [pytest.param("set", path, value, rule, id=f"enum-{name(path)}") for path, value, rule in OUT_OF_RANGE]
    + [pytest.param("set", path + ("extra",), "x", rule, id=f"unknown-{name(path)}") for path, rule in UNKNOWN_KEY]
)


def test_redumped_example_entry_is_admitted(tmp_path, capsys):
    assert validate_frontmatter(example_frontmatter(), tmp_path, capsys) == (0, set())


@pytest.mark.parametrize("op, path, value, rule", MUTATIONS)
def test_frontmatter_mutation_is_rejected_under_its_rule(op, path, value, rule, tmp_path, capsys):
    code, rules = validate_frontmatter(mutate(example_frontmatter(), op, path, value), tmp_path, capsys)
    assert code == 1
    assert rule in rules


@pytest.mark.parametrize("path", OPTIONAL, ids=name)
def test_optional_field_may_be_absent(path, tmp_path, capsys):
    assert validate_frontmatter(mutate(example_frontmatter(), "drop", path, None), tmp_path, capsys) == (0, set())


def spec_key(path):
    return ".".join(list(itertools.takewhile(lambda part: isinstance(part, str), path))[:2])


def test_wrong_type_sweep_covers_every_key_of_the_spec_field_table():
    table = SPEC[SPEC.index("### Frontmatter"):SPEC.index("An **immutable reference**")]
    keys = set(re.findall(r"^\| `([a-z_.]+)` \|", table, re.MULTILINE))
    assert keys <= {spec_key(path) for path, _, _ in WRONG_TYPE}
