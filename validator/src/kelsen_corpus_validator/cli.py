import argparse
import datetime
import json
import re
import subprocess
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

DEFAULT_HOST = "github.com"
REQUIRED_SECTIONS = ("Problem", "Cause", "Solution", "Applying it elsewhere")
SINGLE_SECTIONS = (*REQUIRED_SECTIONS, "Limits")
FRONTMATTER = re.compile(r"\A---\n(.*?)^---\n?(.*)\Z", re.DOTALL | re.MULTILINE)
ENTRY_NAME = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*\.md")
STATUS_CHANGES = {
    ("verified", "stale"), ("verified", "superseded"), ("stale", "superseded"),
    ("verified", "retracted"), ("stale", "retracted"), ("stale", "verified"),
}


class Loader(yaml.SafeLoader):
    pass


Loader.yaml_implicit_resolvers = {
    first: [(tag, regexp) for tag, regexp in resolvers if tag != "tag:yaml.org,2002:timestamp"]
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def load_yaml(text):
    loader = Loader(text)
    try:
        node = loader.get_single_node()
        return (loader.construct_document(node) if node else None), node
    finally:
        loader.dispose()


def walk_nodes(node):
    yield node
    if isinstance(node, yaml.MappingNode):
        for _, value in node.value:
            yield from walk_nodes(value)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            yield from walk_nodes(item)


def mapping(value):
    return value if isinstance(value, dict) else {}


def as_date(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None


def load_schema(root, name, host):
    def substitute(node):
        if isinstance(node, dict):
            return {
                key: value.replace("<host>", re.escape(host)) if key == "pattern" else substitute(value)
                for key, value in node.items()
            }
        if isinstance(node, list):
            return [substitute(item) for item in node]
        return node

    return substitute(json.loads((root / "schema" / name).read_text()))


def schema_violations(schema, document):
    validator = Draft202012Validator(schema, format_checker=Draft202012Validator.FORMAT_CHECKER)
    found = []
    for error in validator.iter_errors(document):
        node, rule = schema, schema["x-rule"]
        for part in error.schema_path:
            # jsonschema leaves $ref out of the path, so follow it wherever the next step is missing.
            while isinstance(node, dict) and part not in node and "$ref" in node:
                ref, node = node["$ref"], schema
                for step in ref.removeprefix("#/").split("/"):
                    node = node[step]
                rule = node.get("x-rule", rule)
            node = node[part]
            if isinstance(node, dict) and "x-rule" in node:
                rule = node["x-rule"]
        location = ".".join(map(str, error.absolute_path)) or "frontmatter"
        found.append((rule, f"{location}: {error.message}"))
    return found


def read_settings(text):
    try:
        settings, _ = load_yaml(text)
    except yaml.YAMLError:
        return None
    return settings if isinstance(settings, dict) else None


def check_settings(root, settings, public):
    if not (root / "kelsen.yml").is_file():
        return [("KC-C01", "kelsen.yml is missing")]
    if settings is None:
        return [("KC-C01", "kelsen.yml must be a YAML mapping")]
    violations = schema_violations(load_schema(root, "kelsen.schema.json", DEFAULT_HOST), settings)
    if public and "license" not in settings:
        violations.append(("KC-C03", "a public store must declare an SPDX license"))
    return violations


def parse_entry(text):
    """Return (frontmatter, node, body) or a KC-E01 message."""
    match = FRONTMATTER.match(text)
    if not match:
        return "entry must start with a --- delimited YAML frontmatter block"
    raw, body = match.groups()
    try:
        frontmatter, node = load_yaml(raw)
    except yaml.YAMLError as error:
        return f"frontmatter is not valid YAML: {error}"
    if not isinstance(frontmatter, dict):
        return "frontmatter must be a YAML mapping"
    return frontmatter, node, body


def sections(body):
    found, current = [], None
    for line in body.splitlines():
        if line.startswith("## "):
            current = (line[3:].strip(), [])
            found.append(current)
        elif line.startswith("# "):
            current = None
        elif current:
            current[1].append(line)
    return [(name, "\n".join(lines)) for name, lines in found]


def check_entry(path, parsed, schema, store_id, host, today):
    frontmatter, node, body = parsed
    violations = []
    for candidate in walk_nodes(node):
        if isinstance(candidate, yaml.MappingNode):
            keys = [key.value for key, _ in candidate.value if isinstance(key, yaml.ScalarNode)]
            for key in sorted({key for key in keys if keys.count(key) > 1}):
                violations.append(("KC-S02", f"duplicate key {key!r}"))
            for key, value in candidate.value:
                if key.value == "version" and not (isinstance(value, yaml.ScalarNode) and value.style in ("'", '"')):
                    violations.append(("KC-F-VER", f"version must be a quoted string, line {value.start_mark.line + 2}"))

    violations += schema_violations(schema, frontmatter)

    permalink = frontmatter.get("permalink")
    expected = f"{store_id}/{path.stem}"
    if store_id is not None and isinstance(permalink, str) and permalink != expected:
        violations.append(("KC-E03", f"permalink must be {expected!r}"))

    provenance, lifecycle = mapping(frontmatter.get("provenance")), mapping(frontmatter.get("lifecycle"))
    stats = frontmatter.get("stats") if isinstance(frontmatter.get("stats"), list) else []
    dated = [("provenance.recorded_on", provenance.get("recorded_on")),
             ("lifecycle.verified_on", lifecycle.get("verified_on"))]
    dated += [(f"stats.{i}.as_of", mapping(stat).get("as_of")) for i, stat in enumerate(stats)]
    for location, value in dated:
        if (date := as_date(value)) and date > today:
            violations.append(("KC-F-DATE", f"{location}: {value} is after today, {today}"))

    verified_on, review_by = as_date(lifecycle.get("verified_on")), as_date(lifecycle.get("review_by"))
    if verified_on and review_by and not 0 < (review_by - verified_on).days <= 365:
        violations.append(("KC-F-LIFECYCLE", "review_by must be 1 to 365 days after verified_on"))

    found = sections(body)
    names = [name for name, _ in found]
    for section in REQUIRED_SECTIONS:
        if section not in names:
            violations.append(("KC-E04", f"missing required section '## {section}'"))
    for section in SINGLE_SECTIONS:
        if names.count(section) > 1:
            violations.append(("KC-S03", f"'## {section}' appears more than once"))
        if any(name == section and not content.strip() for name, content in found):
            violations.append(("KC-S03", f"'## {section}' is empty"))
    fix = re.compile(
        rf"https://{re.escape(host)}/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/(pull/[0-9]+|commit/[0-9a-f]{{40}})(?!\w)"
    )
    solutions = [content for name, content in found if name == "Solution"]
    if solutions and not any(fix.search(content) for content in solutions):
        violations.append(("KC-S04", "'## Solution' must link the merged fix: a PR or a SHA-pinned commit"))
    return violations


def check_cross_file(entries):
    violations = []
    by_permalink = {}
    for path, frontmatter in entries.items():
        permalink = frontmatter.get("permalink")
        if not isinstance(permalink, str):
            continue
        if permalink in by_permalink:
            violations.append((path, "KC-X01", f"permalink {permalink!r} is already claimed by {by_permalink[permalink][0]}"))
        else:
            by_permalink[permalink] = (path, frontmatter)

    for path, frontmatter in entries.items():
        permalink, lifecycle = frontmatter.get("permalink"), mapping(frontmatter.get("lifecycle"))
        target = lifecycle.get("superseded_by")
        if isinstance(target, str):
            _, other = by_permalink.get(target, (None, None))
            other_lifecycle = mapping(other and other.get("lifecycle"))
            supersedes = other_lifecycle.get("supersedes")
            if other is None:
                violations.append((path, "KC-X02", f"superseded_by names no entry: {target!r}"))
            elif other.get("status") == "retracted":
                violations.append((path, "KC-X02", f"superseded_by names a retracted entry: {target!r}"))
            elif not (isinstance(supersedes, list) and permalink in supersedes):
                violations.append((path, "KC-X02", f"{target!r} does not list this entry in supersedes"))
        supersedes = lifecycle.get("supersedes")
        for name in supersedes if isinstance(supersedes, list) else []:
            _, other = by_permalink.get(name, (None, None)) if isinstance(name, str) else (None, None)
            if (
                other is None
                or other.get("status") != "superseded"
                or mapping(other.get("lifecycle")).get("superseded_by") != permalink
            ):
                violations.append((path, "KC-X03", f"{name!r} is not an entry superseded by this one"))
    return violations


def git_show(root, base, path):
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{base}:./{path}"], capture_output=True, text=True,
    )
    return result.stdout if result.returncode == 0 else None


def check_transitions(root, base, settings, entries):
    violations = []
    listing = subprocess.run(
        ["git", "-C", str(root), "ls-tree", "--name-only", base, "--", "entries/"],
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    for path in listing:
        name = path.rsplit("/", 1)[-1]
        if name.endswith(".md") and not name.startswith(".") and not (root / path).is_file():
            violations.append((path, "KC-T01", "an entry at the base was deleted or renamed"))

    text = git_show(root, base, "kelsen.yml")
    base_settings = read_settings(text) if text is not None else None
    if base_settings is None or settings is None:
        return violations
    if base_settings.get("id") != settings.get("id"):
        violations.append(("kelsen.yml", "KC-X04", f"id must stay {base_settings.get('id')!r}"))
    if base_settings.get("spec") != settings.get("spec"):
        return violations

    for path, head in entries.items():
        text = git_show(root, base, path)
        if text is None:
            if head.get("status") != "verified":
                violations.append((path, "KC-T02", "a new entry must have status: verified"))
            continue
        parsed = parse_entry(text)
        if isinstance(parsed, str):
            continue
        old = parsed[0]
        for key in ("permalink", "provenance"):
            if head.get(key) != old.get(key):
                violations.append((path, "KC-T03", f"{key} must equal the base's"))
        before, after = old.get("status"), head.get("status")
        if before != after and (before, after) not in STATUS_CHANGES:
            violations.append((path, "KC-T04", f"status cannot change from {before} to {after}"))
        old_verified = as_date(mapping(old.get("lifecycle")).get("verified_on"))
        new_verified = as_date(mapping(head.get("lifecycle")).get("verified_on"))
        reverified = bool(old_verified and new_verified and new_verified > old_verified)
        if (before, after) == ("stale", "verified"):
            refs = lambda entry: {
                item.get("ref") for item in entry.get("evidence") or [] if isinstance(item, dict)
            }
            if not reverified or not refs(head) - refs(old):
                violations.append((path, "KC-T05", "stale to verified needs a later verified_on and new evidence"))
        changed = [key for key in ("claim", "context", "evidence") if head.get(key) != old.get(key)]
        if changed and not reverified:
            violations.append((path, "KC-T06", f"{', '.join(changed)} changed without a later verified_on"))
    return violations


def validate(root, public, base, today):
    found = {}

    def report(path, rule, message):
        found.setdefault(path, {}).setdefault(rule, []).append(message)

    settings_path = root / "kelsen.yml"
    settings = read_settings(settings_path.read_text()) if settings_path.is_file() else None
    for rule, message in check_settings(root, settings, public):
        report("kelsen.yml", rule, message)

    store_id = mapping(settings).get("id")
    store_id = store_id if isinstance(store_id, str) else None
    host = mapping(settings).get("host")
    host = host if isinstance(host, str) else DEFAULT_HOST
    schema = load_schema(root, "entry.schema.json", host)

    entries = {}
    directory = root / "entries"
    for path in sorted(directory.iterdir()) if directory.is_dir() else []:
        relative = path.relative_to(root).as_posix()
        if path.name.startswith("."):
            continue
        if path.is_dir() or not ENTRY_NAME.fullmatch(path.name):
            report(relative, "KC-S01", "entries/ holds only <slug>.md files")
        if not (path.is_file() and path.suffix == ".md"):
            continue
        parsed = parse_entry(path.read_text())
        if isinstance(parsed, str):
            report(relative, "KC-E01", parsed)
            continue
        entries[relative] = parsed[0]
        for rule, message in check_entry(path, parsed, schema, store_id, host, today):
            report(relative, rule, message)

    for path, rule, message in check_cross_file(entries):
        report(path, rule, message)
    if base:
        for path, rule, message in check_transitions(root, base, settings, entries):
            report(path, rule, message)

    order = sorted(found, key=lambda path: (path != "kelsen.yml", path))
    return [(rule, path, "; ".join(messages)) for path in order for rule, messages in found[path].items()]


def main(argv=None):
    parser = argparse.ArgumentParser(prog="kc-validate", description="Validate a kelsen-corpus store.")
    parser.add_argument("root", nargs="?", default=".", type=Path, help="store root (default: .)")
    parser.add_argument("--public", action="store_true", help="the store is public: require a license")
    parser.add_argument("--base", help="the commit the change is judged against")
    parser.add_argument(
        "--today", type=datetime.date.fromisoformat, help="the date to judge against (default: today in UTC)",
    )
    args = parser.parse_args(argv)
    today = args.today or datetime.datetime.now(datetime.UTC).date()

    violations = validate(args.root, args.public, args.base, today)
    for rule, path, message in violations:
        print(f"{rule} {path}: {' '.join(message.split())}")
    return 1 if violations else 0
