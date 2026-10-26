import shutil
from pathlib import Path

import pytest

from kelsen_corpus_validator.cli import main

FIXTURES = Path(__file__).parent / "fixtures"
SCHEMA = Path(__file__).parents[2] / "schema"


@pytest.fixture
def run(tmp_path, capsys):
    def run(*entries, config="valid.yml", public=False):
        shutil.copytree(SCHEMA, tmp_path / "schema")
        (tmp_path / "entries").mkdir()
        if config:
            shutil.copy(FIXTURES / "config" / config, tmp_path / "kelsen.yml")
        for name in entries:
            shutil.copy(FIXTURES / "entries" / name, tmp_path / "entries" / name)
        code = main([str(tmp_path), *(["--public"] if public else [])])
        lines = capsys.readouterr().out.splitlines()
        return code, [line.split(":", 1)[0] for line in lines]

    return run


def test_valid_store_is_admitted(run):
    assert run("valid-entry.md", public=True) == (0, [])


def test_empty_store_is_admitted(run):
    assert run(public=True) == (0, [])


def test_missing_settings_file_is_kc_c01(run):
    assert run(config=None) == (1, ["KC-C01 kelsen.yml"])


def test_settings_that_are_not_a_mapping_are_kc_c01(run):
    assert run(config="not-a-mapping.yml") == (1, ["KC-C01 kelsen.yml"])


def test_unknown_settings_key_is_kc_c02(run):
    assert run(config="unknown-key.yml") == (1, ["KC-C02 kelsen.yml"])


def test_unsupported_spec_version_is_kc_c02(run):
    assert run(config="wrong-spec.yml") == (1, ["KC-C02 kelsen.yml"])


def test_public_store_without_license_is_kc_c03(run):
    assert run(config="no-license.yml", public=True) == (1, ["KC-C03 kelsen.yml"])


def test_private_store_without_license_is_admitted(run):
    assert run("valid-entry.md", config="no-license.yml") == (0, [])


def test_entry_without_frontmatter_is_kc_e01(run):
    assert run("no-frontmatter.md") == (1, ["KC-E01 entries/no-frontmatter.md"])


def test_entry_with_unparseable_frontmatter_is_kc_e01(run):
    assert run("frontmatter-not-yaml.md") == (1, ["KC-E01 entries/frontmatter-not-yaml.md"])


def test_entry_missing_a_required_field_is_kc_e02(run):
    assert run("missing-claim.md") == (1, ["KC-E02 entries/missing-claim.md"])


def test_entry_with_an_unknown_key_is_kc_e02(run):
    assert run("unknown-key.md") == (1, ["KC-E02 entries/unknown-key.md"])


def test_entry_with_an_unknown_status_is_kc_e02(run):
    assert run("bad-status.md") == (1, ["KC-E02 entries/bad-status.md"])


def test_permalink_not_matching_the_file_is_kc_e03(run):
    assert run("permalink-mismatch.md") == (1, ["KC-E03 entries/permalink-mismatch.md"])


def test_entry_missing_a_required_section_is_kc_e04(run):
    assert run("missing-section.md") == (1, ["KC-E04 entries/missing-section.md"])


def test_every_violation_in_the_store_is_reported(run):
    assert run("valid-entry.md", "unknown-key.md", "missing-section.md") == (
        1,
        ["KC-E04 entries/missing-section.md", "KC-E02 entries/unknown-key.md"],
    )
