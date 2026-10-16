"""Dependency scan for the service's own requirements (NFR-028).

The container boots from this service's requirements.txt alone, so every
third-party import under app/ must be declared there, and every runtime
dependency must carry its exact pin. This is what caught SQLAlchemy and its
psycopg driver only being satisfied because a sibling service had installed
them into the shared venv (`make setup`).
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[1]

# An import's top-level module is not always the distribution's name; only the
# divergences this service uses are mapped here.
IMPORT_TO_DISTRIBUTION = {
    "jwt": "pyjwt",
}


def _declared_distributions() -> set[str]:
    declared: set[str] = set()
    for line in (SERVICE_ROOT / "requirements.txt").read_text().splitlines():
        name = line.split("#", 1)[0].strip()
        if not name:
            continue
        declared.add(name.split("[")[0].split("==")[0].strip().lower())
    return declared


def _third_party_imports() -> set[str]:
    roots: set[str] = set()
    for module_file in sorted((SERVICE_ROOT / "app").rglob("*.py")):
        for node in ast.walk(ast.parse(module_file.read_text())):
            match node:
                case ast.Import(names=alias_names):
                    roots.update(alias.name.split(".")[0] for alias in alias_names)
                # An absolute import has level 0 (or None, per the ast
                # version); a non-empty level is a relative import inside app/,
                # and a module of None is one of those too.
                case ast.ImportFrom(module=module_name, level=level) if not level and module_name:
                    roots.add(module_name.split(".")[0])
    roots -= {"app"}
    return {name for name in roots if name not in sys.stdlib_module_names}


def test_every_third_party_import_is_declared() -> None:
    declared = _declared_distributions()
    missing = {IMPORT_TO_DISTRIBUTION.get(name, name) for name in _third_party_imports()} - declared
    assert not missing, f"imports missing from requirements.txt: {sorted(missing)}"


def test_every_runtime_dependency_is_pinned_exactly() -> None:
    unpinned = [
        stripped
        for line in (SERVICE_ROOT / "requirements.txt").read_text().splitlines()
        if (stripped := line.split("#", 1)[0].strip()) and "==" not in stripped
    ]
    assert not unpinned, f"unpinned runtime dependencies: {unpinned}"
