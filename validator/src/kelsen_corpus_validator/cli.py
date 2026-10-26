import argparse
import json
import re
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

REQUIRED_SECTIONS = ("Problem", "Cause", "Solution", "Applying it elsewhere")
FRONTMATTER = re.compile(r"\A---\n(.*?)^---\n?(.*)\Z", re.DOTALL | re.MULTILINE)


def schema_errors(schema_path, document):
    schema = json.loads(schema_path.read_text())
    errors = Draft202012Validator(schema).iter_errors(document)
    return sorted(error.message for error in errors)


def check_settings(root, public):
    try:
        settings = yaml.safe_load((root / "kelsen.yml").read_text())
    except (OSError, yaml.YAMLError) as error:
        return None, [("KC-C01", f"cannot read store settings: {error}")]
    if not isinstance(settings, dict):
        return None, [("KC-C01", "store settings must be a YAML mapping")]

    violations = [
        ("KC-C02", message)
        for message in schema_errors(root / "schema" / "kelsen.schema.json", settings)
    ]
    if public and "license" not in settings:
        violations.append(("KC-C03", "a public store must declare an SPDX license"))
    return (None if violations else settings["id"]), violations


def check_entry(root, path, store_id):
    match = FRONTMATTER.match(path.read_text())
    if not match:
        return [("KC-E01", "entry must start with a --- delimited YAML frontmatter block")]
    raw, body = match.groups()
    try:
        frontmatter = yaml.safe_load(raw)
    except yaml.YAMLError as error:
        return [("KC-E01", f"frontmatter is not valid YAML: {error}")]
    if not isinstance(frontmatter, dict):
        return [("KC-E01", "frontmatter must be a YAML mapping")]

    violations = [
        ("KC-E02", message)
        for message in schema_errors(root / "schema" / "entry.schema.json", frontmatter)
    ]
    expected = f"{store_id}/{path.stem}"
    if store_id and frontmatter.get("permalink") != expected:
        violations.append(("KC-E03", f"permalink must be {expected!r}"))
    headings = set(re.findall(r"^## (.+?)\s*$", body, re.MULTILINE))
    for section in REQUIRED_SECTIONS:
        if section not in headings:
            violations.append(("KC-E04", f"missing required section '## {section}'"))
    return violations


def validate(root, public):
    store_id, violations = check_settings(root, public)
    found = [(rule, "kelsen.yml", message) for rule, message in violations]
    for path in sorted((root / "entries").glob("*.md")):
        relative = path.relative_to(root).as_posix()
        found += [(rule, relative, message) for rule, message in check_entry(root, path, store_id)]
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(prog="kc-validate", description="Validate a kelsen-corpus store.")
    parser.add_argument("root", nargs="?", default=".", type=Path, help="store root (default: .)")
    parser.add_argument("--public", action="store_true", help="the store is public: require a license")
    args = parser.parse_args(argv)

    violations = validate(args.root, args.public)
    for rule, path, message in violations:
        print(f"{rule} {path}: {' '.join(message.split())}")
    return 1 if violations else 0
