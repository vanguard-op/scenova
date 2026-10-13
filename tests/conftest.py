"""QA integration harness for the Scenova phase gate.

Engineer unit tests live beside their own workspace (`services/**/tests`,
`ai/tests`). This package holds the cross-component integration and acceptance
tests that verify the delivered whole against the frozen contracts and the
feature acceptance criteria.

The harness boots the services the same way the platform does — each as a
`uvicorn` process started from its own workspace, with the documented module and
ports — and hands the tests their base URLs over real HTTP. Three stacks are
provided:

- `stack` — the client path: gateway, lookup, pipeline, library, and the model
  service. `GEMINI_API_KEY` is left unset, so the model layer reports the
  provider as unavailable, which is the shipped fallback path (nfr.md
  "Degradation when a dependency fails").
- `loop_stack` — the generation loop: the same services with the external model
  provider boundary (C-004, C-005) served by a local test double, so a clip can
  actually be produced, written to the shared library, and served to a later
  reader (FEAT-006, FEAT-007).
- `library_down_stack` — the client path with no library service, so the lookup's
  library read is refused (FEAT-006 edge case).

No stack reaches the model provider: the client-path stacks run without a
credential, and the loop stack's provider is a double.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from collections.abc import Iterator, Mapping
from contextlib import closing, contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

import httpx2
import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

# Import the service workspaces exactly as the shipped layout exposes them:
# `services/` holds the service packages; `ai/` holds the model-serving `app`
# package.
for _workspace in ("services", "ai"):
    _path = str(REPO_ROOT / _workspace)
    if _path not in sys.path:
        sys.path.insert(0, _path)

# Dedicated ports for the gate run, so a developer's own `make boot` stack on the
# documented ports never collides with the test stack.
PORTS = {
    "gateway": 18080,
    "lookup": 18081,
    "pipeline": 18082,
    "library": 18083,
    "model": 18090,
}

# The generation-loop stack runs beside the client-path stack on its own ports,
# so both can be up at once during a single gate run.
LOOP_PORTS = {
    "gateway": 18180,
    "lookup": 18181,
    "pipeline": 18182,
    "library": 18183,
    "model": 18190,
}

# The library-degradation stack boots the client path with no library service;
# `library` names a port nothing binds, so the lookup's library read is refused.
LIBRARY_DOWN_PORTS = {
    "gateway": 18280,
    "lookup": 18281,
    "pipeline": 18282,
    "library": 18283,
    "model": 18290,
}

# name -> (working directory, uvicorn module). Mirrors ci/lib.sh's service
# registry for the shippable services.
SERVICES: dict[str, tuple[Path, str]] = {
    "gateway": (REPO_ROOT / "services" / "gateway", "app.main:app"),
    "lookup": (REPO_ROOT / "services" / "lookup", "app.main:app"),
    "pipeline": (REPO_ROOT / "services" / "pipeline", "app.main:app"),
    "library": (REPO_ROOT / "services" / "library", "app.main:app"),
}

# The model-serving service, and the test double that replaces it in the
# generation-loop stack. The double speaks the same internal endpoints (C-004,
# C-005) so the pipeline's clients are exercised unchanged.
MODEL_SERVICE: tuple[Path, str] = (REPO_ROOT / "ai", "app.main:app")
MODEL_STUB: tuple[Path, str] = (REPO_ROOT / "tests", "model_stub:app")

INTERNAL_AUDIENCE = "scenova-internal"
CORRELATION_HEADER = "x-correlation-id"


def _python() -> str:
    venv = REPO_ROOT / ".venv" / "bin" / "python"
    return str(venv) if venv.exists() else sys.executable


def _service_env(name: str, ports: Mapping[str, int]) -> dict[str, str]:
    """The environment for one service, wired to the given stack's ports.

    The gateway calls the lookup service, the lookup service calls the pipeline
    and the library, and the pipeline calls the model service and the library;
    each reads its downstream port from the documented variable.
    """

    env = dict(os.environ)
    env.pop("GEMINI_API_KEY", None)
    if name == "gateway":
        env["LOOKUP_PORT"] = str(ports["lookup"])
    elif name == "lookup":
        env["PIPELINE_PORT"] = str(ports["pipeline"])
        env["LIBRARY_PORT"] = str(ports["library"])
    elif name == "pipeline":
        env["MODEL_PORT"] = str(ports["model"])
        env["LIBRARY_PORT"] = str(ports["library"])
        # The harness exercises the generation path, so the pipeline's kill
        # switch is pinned on here rather than inherited from a local `.env`
        # (release.md "Rollout Phases & Feature Flags"). With the credential
        # removed above, a generation still ends in the provider-unavailable
        # fallback on the client-path stack.
        env["FLAG_ENABLE_GENERATION"] = "true"
    return env


def _wait_healthy(name: str, port: int, process: subprocess.Popen[bytes], log_path: Path) -> None:
    url = f"http://127.0.0.1:{port}/healthz"
    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(
                f"service '{name}' exited before it became healthy:\n"
                f"{log_path.read_text(encoding='utf-8', errors='replace')}"
            )
        try:
            response = httpx2.get(url, timeout=1.0)
        except httpx2.HTTPError:
            time.sleep(0.2)
            continue
        if response.status_code == 200:
            return
        time.sleep(0.2)
    raise RuntimeError(
        f"service '{name}' did not serve /healthz within 30s:\n"
        f"{log_path.read_text(encoding='utf-8', errors='replace')}"
    )


def _port_is_free(port: int) -> bool:
    with closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


@dataclass(frozen=True)
class Stack:
    """A booted stack, addressed by base URL."""

    base_urls: dict[str, str]

    def url(self, service: str) -> str:
        return self.base_urls[service]


@contextmanager
def _boot(
    entries: Mapping[str, tuple[Path, str]],
    ports: Mapping[str, int],
    tmp_path_factory: pytest.TempPathFactory,
) -> Iterator[Stack]:
    """Boot the named services on `ports` and yield the stack; tear it down after."""

    for name, port in ports.items():
        if not _port_is_free(port):
            pytest.fail(
                f"port {port} for '{name}' is already in use; "
                "stop the other stack and re-run the gate"
            )

    log_dir = tmp_path_factory.mktemp("scenova-stack")
    processes: dict[str, subprocess.Popen[bytes]] = {}
    logs: dict[str, Path] = {}
    handles: list[BinaryIO] = []

    try:
        for name, (workdir, module) in entries.items():
            log_path = log_dir / f"{name}.log"
            logs[name] = log_path
            handle = log_path.open("wb")
            handles.append(handle)
            process = subprocess.Popen(
                [
                    _python(),
                    "-m",
                    "uvicorn",
                    module,
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(ports[name]),
                    "--log-level",
                    "warning",
                ],
                cwd=str(workdir),
                env=_service_env(name, ports),
                stdout=handle,
                stderr=subprocess.STDOUT,
            )
            processes[name] = process

        for name, process in processes.items():
            _wait_healthy(name, ports[name], process, logs[name])
    except BaseException:
        for process in processes.values():
            process.terminate()
        for stream in handles:
            stream.close()
        raise

    try:
        yield Stack(base_urls={name: f"http://127.0.0.1:{port}" for name, port in ports.items()})
    finally:
        for process in processes.values():
            process.terminate()
        for process in processes.values():
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
        for stream in handles:
            stream.close()


@pytest.fixture(scope="session")
def stack(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Stack]:
    """Boot the client-path stack; the model provider is unavailable."""

    entries = {**SERVICES, "model": MODEL_SERVICE}
    with _boot(entries, PORTS, tmp_path_factory) as booted:
        yield booted


@pytest.fixture(scope="session")
def loop_stack(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Stack]:
    """Boot the generation-loop stack; the model provider is a local double."""

    entries = {**SERVICES, "model": MODEL_STUB}
    with _boot(entries, LOOP_PORTS, tmp_path_factory) as booted:
        yield booted


@pytest.fixture(scope="session")
def library_down_stack(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Stack]:
    """Boot the client path without the library, so the library read is refused."""

    entries = {name: service for name, service in SERVICES.items() if name != "library"}
    entries["model"] = MODEL_SERVICE
    with _boot(entries, LIBRARY_DOWN_PORTS, tmp_path_factory) as booted:
        yield booted


@pytest.fixture()
def gateway(stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the client-facing gateway (C-001, C-002)."""

    with httpx2.Client(base_url=stack.url("gateway"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def pipeline(stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the internal generation pipeline (C-003, C-006)."""

    with httpx2.Client(base_url=stack.url("pipeline"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def model(stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the internal model-serving layer (C-004, C-005)."""

    with httpx2.Client(base_url=stack.url("model"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def library(stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the internal shared word-clip library (C-009, C-010, C-011)."""

    with httpx2.Client(base_url=stack.url("library"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def loop_gateway(loop_stack: Stack) -> Iterator[httpx2.Client]:
    """A gateway client for the generation-loop stack."""

    with httpx2.Client(base_url=loop_stack.url("gateway"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def loop_library(loop_stack: Stack) -> Iterator[httpx2.Client]:
    """A library client for the generation-loop stack."""

    with httpx2.Client(base_url=loop_stack.url("library"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def loop_model_stub(loop_stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the generation-loop stack's model-provider double."""

    with httpx2.Client(base_url=loop_stack.url("model"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def library_down_gateway(library_down_stack: Stack) -> Iterator[httpx2.Client]:
    """A gateway client whose lookup service cannot reach the shared library."""

    with httpx2.Client(base_url=library_down_stack.url("gateway"), timeout=10.0) as client:
        yield client
