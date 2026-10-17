"""Dependency scan across the services (NFR-028).

Every service container installs its own requirements.txt alone, so each service
must declare exactly what its app/ imports and needs at runtime — a sibling
service's pins in the shared development venv (`make setup`) prove nothing about
the image the container actually boots from. The scan is strict:

- every third-party import under a service's app/ is declared in that service's
  own requirements.txt, through the import-to-distribution divergence table
  below;
- the divergence table carries no stale entry — an entry whose import the
  service no longer makes is a silent allowance and is refused;
- every declared runtime dependency is pinned exactly (`==`);

A tag in the table or a missing pin fails for the service named in the test id.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

import pytest

SERVICES_ROOT = Path(__file__).resolve().parent

# A top-level import is not always the distribution's name. The table carries
# only the divergences a service's app/ actually imports; anything else is noise.
IMPORT_DIVERGENCES: dict[str, dict[str, str]] = {
    "analytics": {"jwt": "pyjwt"},
    "entitlement": {"jwt": "pyjwt"},
    "feedback": {"jwt": "pyjwt"},
    "gateway": {"jwt": "pyjwt", "google": "google-auth"},
    "library": {},
    "lookup": {},
    "notification": {"jwt": "pyjwt", "google": "google-auth"},
    "pipeline": {},
}

SERVICE_NAMES: list[str] = sorted(
    path.name
    for path in SERVICES_ROOT.iterdir()
    if (path / "requirements.txt").is_file() and (path / "app").is_dir()
)


def test_the_scan_covers_the_services() -> None:
    assert SERVICE_NAMES, "no service scanned — the pins scan is checking nothing"


def _declared_distributions(service: Path) -> set[str]:
    declared: set[str] = set()
    for line in (service / "requirements.txt").read_text().splitlines():
        name = line.split("#", 1)[0].strip()
        if not name:
            continue
        declared.add(name.split("[")[0].split("==")[0].strip().lower())
    return declared


def _third_party_imports(service: Path) -> set[str]:
    roots: set[str] = set()
    for module_file in sorted((service / "app").rglob("*.py")):
        for node in ast.walk(ast.parse(module_file.read_text())):
            match node:
                case ast.Import(names=alias_names):
                    roots.update(alias.name.split(".")[0] for alias in alias_names)
                # An absolute import has level 0 (or None, per the ast
                # version); a non-empty level is a relative import inside app/.
                case ast.ImportFrom(module=module_name, level=level) if not level and module_name:
                    roots.add(module_name.split(".")[0])
    roots -= {service.name}
    return {name for name in roots if name not in sys.stdlib_module_names}


def _distribution_for(service: str, import_name: str) -> str:
    return IMPORT_DIVERGENCES.get(service, {}).get(import_name, import_name)


@pytest.mark.parametrize("service", SERVICE_NAMES)
def test_every_third_party_import_is_declared(service: str) -> None:
    declared = _declared_distributions(SERVICES_ROOT / service)
    imports = _third_party_imports(SERVICES_ROOT / service)
    missing = {_distribution_for(service, name) for name in imports} - declared
    assert not missing, f"{service}: imports missing from its requirements.txt: {sorted(missing)}"


def test_the_divergence_table_carries_no_stale_entry() -> None:
    stale = []
    for service, divergences in sorted(IMPORT_DIVERGENCES.items()):
        imports = _third_party_imports(SERVICES_ROOT / service)
        unused = sorted(divergences.keys() - imports)
        if unused:
            stale.append(f"{service}: {unused}")
    assert not stale, f"stale divergence entries (no longer imported): {stale}"


@pytest.mark.parametrize("service", SERVICE_NAMES)
def test_every_runtime_dependency_is_pinned_exactly(service: str) -> None:
    unpinned = [
        stripped
        for line in (SERVICES_ROOT / service / "requirements.txt").read_text().splitlines()
        if (stripped := line.split("#", 1)[0].strip()) and "==" not in stripped
    ]
    assert not unpinned, f"{service}: unpinned runtime dependencies: {unpinned}"
