"""QA integration harness for the Scenova phase gate.

Engineer unit tests live beside their own workspace (`services/**/tests`,
`ai/tests`). This package holds the cross-component integration and acceptance
tests that verify the delivered whole against the frozen contracts and the
feature acceptance criteria.

The harness boots the four services the same way the platform does — each as a
`uvicorn` process started from its own workspace, with the documented module and
ports — and hands the tests their base URLs over real HTTP. Nothing here reaches
the model provider: `GEMINI_API_KEY` is left unset, so the model layer reports
the provider as unavailable, which is the shipped fallback path (nfr.md
"Degradation when a dependency fails").
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from collections.abc import Iterator
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

import httpx2
import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

# Import the service workspaces exactly as the shipped layout exposes them:
# `services/` holds the `gateway`, `lookup`, and `pipeline` packages; `ai/`
# holds the model-serving `app` package.
for _workspace in ("services", "ai"):
    _path = str(REPO_ROOT / _workspace)
    if _path not in sys.path:
        sys.path.insert(0, _path)

# Dedicated ports for the gate run, so a developer's own `make boot` stack on the
# documented ports never collides with the test stack.
PORTS = {"gateway": 18080, "lookup": 18081, "pipeline": 18082, "model": 18090}

# name -> (working directory, uvicorn module). Mirrors ci/lib.sh's service
# registry and the model workspace.
SERVICES = {
    "gateway": (REPO_ROOT / "services" / "gateway", "app.main:app"),
    "lookup": (REPO_ROOT / "services" / "lookup", "app.main:app"),
    "pipeline": (REPO_ROOT / "services" / "pipeline", "app.main:app"),
    "model": (REPO_ROOT / "ai", "app.main:app"),
}

INTERNAL_AUDIENCE = "scenova-internal"
CORRELATION_HEADER = "x-correlation-id"


def _python() -> str:
    venv = REPO_ROOT / ".venv" / "bin" / "python"
    return str(venv) if venv.exists() else sys.executable


def _process_env(name: str) -> dict[str, str]:
    """The environment for one service, wired to the test ports.

    The gateway calls the lookup service, the lookup service calls the pipeline,
    and the pipeline calls the model service; each reads its downstream port from
    the documented variable (`LOOKUP_PORT`, `PIPELINE_PORT`, `MODEL_PORT`).
    """

    env = dict(os.environ)
    env.pop("GEMINI_API_KEY", None)
    if name == "gateway":
        env["LOOKUP_PORT"] = str(PORTS["lookup"])
    elif name == "lookup":
        env["PIPELINE_PORT"] = str(PORTS["pipeline"])
    elif name == "pipeline":
        env["MODEL_PORT"] = str(PORTS["model"])
    return env


def _wait_healthy(name: str, process: subprocess.Popen[bytes], log_path: Path) -> None:
    url = f"http://127.0.0.1:{PORTS[name]}/healthz"
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
    """The booted stack, addressed by base URL."""

    base_urls: dict[str, str]

    def url(self, service: str) -> str:
        return self.base_urls[service]


@pytest.fixture(scope="session")
def stack(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Stack]:
    """Boot gateway, lookup, pipeline, and model; yield their base URLs."""

    for name, port in PORTS.items():
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
        for name, (workdir, module) in SERVICES.items():
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
                    str(PORTS[name]),
                    "--log-level",
                    "warning",
                ],
                cwd=str(workdir),
                env=_process_env(name),
                stdout=handle,
                stderr=subprocess.STDOUT,
            )
            processes[name] = process

        for name, process in processes.items():
            _wait_healthy(name, process, logs[name])
    except BaseException:
        for process in processes.values():
            process.terminate()
        for stream in handles:
            stream.close()
        raise

    try:
        yield Stack(base_urls={name: f"http://127.0.0.1:{port}" for name, port in PORTS.items()})
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
