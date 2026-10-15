"""QA integration harness for the Scenova phase gate.

Engineer unit tests live beside their own workspace (`services/**/tests`,
`ai/tests`). This package holds the cross-component integration and acceptance
tests that verify the delivered whole against the frozen contracts and the
feature acceptance criteria.

The harness boots the services the same way the platform does — each as a
`uvicorn` process started from its own workspace, with the documented module and
ports — and hands the tests their base URLs over real HTTP. Five stacks are
provided:

- `stack` — the client path: gateway, lookup, pipeline, library, analytics, and
  the model service. `GEMINI_API_KEY` is left unset, so the model layer reports the
  provider as unavailable, which is the shipped fallback path (nfr.md
  "Degradation when a dependency fails").
- `loop_stack` — the generation loop: the same services with the external model
  provider boundary (C-004, C-005) served by a local test double, so a clip can
  actually be produced, written to the shared library, and served to a later
  reader (FEAT-006, FEAT-007).
- `library_down_stack` — the client path with no library service, so the lookup's
  library read is refused (FEAT-006 edge case).
- `notify_stack` — the client path plus the notification service and a push-provider
  double, so a clip-ready notice is followed end to end (FEAT-008).
- `review_stack` — the client path plus the feedback service, the notification
  service, a push-provider double, and the model double, so a reader can rate and
  report a served clip, the regenerated clip reaches the reporting reader by the
  clip-ready notice, and a curator can work the review queue (FEAT-010, FEAT-011,
  FEAT-015; C-008, C-012 to C-016).
- `account_stack` — the client path plus the account and entitlement service
  (C-001 metering, C-018 to C-022) and the analytics intake, so a signed-in
  reader's lookup is metered end to end and the account reads and writes are
  followed through the gateway (FEAT-012, FEAT-013).

No stack reaches an external provider. The client-path stacks run without a
model credential and the model-backed stacks point at a local double, and the
notification stack clears the ambient push-provider configuration and aims the
generic HTTP seam at a local double, so the shipped Firebase Cloud Messaging
provider is never contacted.

No stack reaches the primary database inside a run either: a relational store
holds whatever earlier runs left behind, so a suite's outcome would depend on
machine history rather than on what one run placed itself. The harness strips
`DATABASE_URL` from the ambient environment — `.env` exports one and `make qa`
runs under it — so every stack runs on the in-memory stores. The store-backed
behaviour is exercised where a phase needs it by the store's own check: a
restart-survival run in `tests/` boots a service with the primary database
directly.
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
    "analytics": 18086,
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

# The notification-path stack boots the client path plus the notification service
# and a push-provider double, so a clip-ready notice can be followed from the
# reader's registration (C-008) through a finished generation to the push send
# (FEAT-008).
NOTIFY_PORTS = {
    "gateway": 18380,
    "lookup": 18381,
    "pipeline": 18382,
    "library": 18383,
    "notification": 18384,
    "model": 18390,
    "push": 18391,
}

# The review-path stack boots the client path plus the feedback service, which
# carries the reader's rating and report intake (C-012, C-013) and the curator's
# review surface (C-014 to C-016). The generation path is served by the model
# double, so a word lookup actually produces a clip a reader can rate and report.
# The notification service and the push-provider double are included too, so a
# report's regenerated clip can be followed to the reporting reader by the
# clip-ready notice it reaches them on (C-008, FEAT-011).
REVIEW_PORTS = {
    "gateway": 18480,
    "lookup": 18481,
    "pipeline": 18482,
    "library": 18483,
    "feedback": 18485,
    "notification": 18487,
    "model": 18490,
    "push": 18491,
}

# The account stack boots the client path plus the account and entitlement
# service (C-018 to C-022) and the analytics intake, so a signed-in reader's
# lookup is metered through the gateway (C-001) and the account's consent and
# locale reads and writes are followed end to end (FEAT-012, FEAT-013). The
# generation path is the model double, so a consented miss's clip arrives and
# the allowance can be followed across served and generated lookups alike.
ACCOUNT_PORTS = {
    "gateway": 18680,
    "lookup": 18681,
    "pipeline": 18682,
    "library": 18683,
    "entitlement": 18684,
    "analytics": 18686,
    "model": 18690,
}

# name -> (working directory, uvicorn module). Mirrors ci/lib.sh's service
# registry for the shippable services.
SERVICES: dict[str, tuple[Path, str]] = {
    "gateway": (REPO_ROOT / "services" / "gateway", "app.main:app"),
    "lookup": (REPO_ROOT / "services" / "lookup", "app.main:app"),
    "pipeline": (REPO_ROOT / "services" / "pipeline", "app.main:app"),
    "library": (REPO_ROOT / "services" / "library", "app.main:app"),
}

# The feedback service: the reader's rating and report intake (C-012, C-013) and
# the curator review surface (C-014 to C-016, FEAT-015). It reads the lookup
# service to confirm a lookup and holds a reported entry through the library.
FEEDBACK_SERVICE: tuple[Path, str] = (
    REPO_ROOT / "services" / "feedback",
    "app.main:app",
)

# The model-serving service, and the test double that replaces it in the
# generation-loop stack. The double speaks the same internal endpoints (C-004,
# C-005) so the pipeline's clients are exercised unchanged.
MODEL_SERVICE: tuple[Path, str] = (REPO_ROOT / "ai", "app.main:app")
MODEL_STUB: tuple[Path, str] = (REPO_ROOT / "tests", "model_stub:app")

# The notification service (C-008) and the push-provider double the notify stack
# points its outbound send at, so a clip-ready notice is observable end to end.
NOTIFICATION_SERVICE: tuple[Path, str] = (
    REPO_ROOT / "services" / "notification",
    "app.main:app",
)
PUSH_STUB: tuple[Path, str] = (REPO_ROOT / "tests", "push_stub:app")

# The analytics event intake (C-007), booted on the client path so the shipped
# gateway routes a reader's events to a real intake rather than an absent port.
ANALYTICS_SERVICE: tuple[Path, str] = (
    REPO_ROOT / "services" / "analytics",
    "app.main:app",
)

# The account and entitlement service (C-018 to C-022): the reader-facing plan
# and allowance read, the account's consent and locale, the account's deletion,
# and the spend seam the lookup path meters through (FEAT-013).
ENTITLEMENT_SERVICE: tuple[Path, str] = (
    REPO_ROOT / "services" / "entitlement",
    "app.main:app",
)

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
    # The relational store is stripped the same way: `.env` exports a
    # `DATABASE_URL`, and a store that keeps data across runs makes the outcome
    # of a run depend on whatever earlier runs left behind. Every stack here runs
    # on the in-memory stores; the store-backed path is exercised by the check
    # that owns it (the restart-survival run boots the primary database itself).
    env.pop("DATABASE_URL", None)
    # The gate exercises the pre-account dev verifier (D-011): every request
    # presents a pseudonymous `dev:<subject>` token and the review surface a
    # `dev:curator:mfa:<subject>` operator token. Pin the mode here so a
    # developer's ambient environment, which may verify real Firebase ID tokens,
    # cannot leak into the run and 401 the suite. `ci/checks/qa.sh` pins the same
    # value for the same reason.
    env["AUTH_MODE"] = "dev"
    if name == "gateway":
        env["LOOKUP_PORT"] = str(ports["lookup"])
        if "analytics" in ports:
            env["ANALYTICS_PORT"] = str(ports["analytics"])
        if "notification" in ports:
            env["NOTIFICATION_PORT"] = str(ports["notification"])
        if "feedback" in ports:
            # The gateway routes the reader's rating and report (C-012, C-013) and
            # the curator's review calls (C-014 to C-016) to the feedback service.
            env["FEEDBACK_PORT"] = str(ports["feedback"])
        if "entitlement" in ports:
            # The gateway routes the entitlement read (C-018) and the account's
            # reads and writes (C-020 to C-022) to the entitlement service, and
            # its deletion erases the reader's data behind it (C-021).
            env["ENTITLEMENT_PORT"] = str(ports["entitlement"])
    elif name == "feedback":
        # The intake confirms a lookup (C-012, C-013) and holds a reported entry
        # through the library (C-011); a curator's replace or edit_phrase hands a
        # regeneration job to the pipeline (C-016).
        env["LOOKUP_PORT"] = str(ports["lookup"])
        env["LIBRARY_PORT"] = str(ports["library"])
        env["PIPELINE_PORT"] = str(ports["pipeline"])
    elif name == "lookup":
        env["PIPELINE_PORT"] = str(ports["pipeline"])
        env["LIBRARY_PORT"] = str(ports["library"])
        if "entitlement" in ports:
            # The meter lives on the entitlement service (FEAT-013): a signed-in
            # reader's lookup spends before it serves or generates. Without it,
            # the meter is unreachable and every lookup proceeds on the grace
            # path, which is the degradation the other stacks exercise.
            env["ENTITLEMENT_PORT"] = str(ports["entitlement"])
        # The harness exercises the phrase path (FEAT-007), so the phrase-clip
        # release flag is pinned on here rather than inherited from a local
        # `.env`, which ships it off until the phase rolls out (release.md
        # "Rollout Phases & Feature Flags"). Left off, a short phrase falls back
        # to the word path, so the phrase routing and acceptance criteria cannot
        # be exercised at all.
        env["FLAG_ENABLE_PHRASE_CLIP"] = "true"
    elif name == "pipeline":
        env["MODEL_PORT"] = str(ports["model"])
        env["LIBRARY_PORT"] = str(ports["library"])
        if "notification" in ports:
            env["NOTIFICATION_PORT"] = str(ports["notification"])
        # The harness exercises the generation path, so the pipeline's kill
        # switch is pinned on here rather than inherited from a local `.env`
        # (release.md "Rollout Phases & Feature Flags"). With the credential
        # removed above, a generation still ends in the provider-unavailable
        # fallback on the client-path stack.
        env["FLAG_ENABLE_GENERATION"] = "true"
        # The phrase path is delivered by this phase (FEAT-007); pin its release
        # flag on for the same reason, so the inherited `.env` default (off until
        # the phase rolls out) cannot stop a phrase job before it runs.
        env["FLAG_ENABLE_PHRASE_CLIP"] = "true"
    elif name == "entitlement":
        # The harness exercises the tiers this phase delivers (FEAT-013): the
        # paid-tier kill switch is pinned on here rather than inherited from a
        # local `.env`, which ships it off until the rollout (release.md
        # "Rollout Phases & Feature Flags"). With it off, every reader is served
        # as Free — the trial, the Pro plan, and a top-up on top of the Pro
        # allowance cannot be exercised at all.
        env["FLAG_ENABLE_PAID_TIER"] = "true"
    elif name == "notification":
        # The notification intake confirms the lookup against the lookup service
        # (C-008) and sends the clip-ready notice through the push-provider
        # double, so nothing is asked of a real provider.
        env["LOOKUP_PORT"] = str(ports["lookup"])
        # Isolate the push provider. The ambient environment — `.env`, which the
        # CI scripts source and export — configures the shipped provider
        # (Firebase Cloud Messaging). Left in place it would win over the
        # double: the service would build the FCM sender and reach for the real
        # provider, so no notice would reach the double under `make qa`. The
        # provider selection is cleared and the generic HTTP seam — the seam
        # `build_push_sender` falls back to — is aimed at the double.
        env.pop("PUSH_PROVIDER", None)
        env.pop("PUSH_FCM_BASE_URL", None)
        env["PUSH_BASE_URL"] = f"http://127.0.0.1:{ports['push']}"
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
    extra_env: Mapping[str, str] | None = None,
) -> Iterator[Stack]:
    """Boot the named services on `ports` and yield the stack; tear it down after.

    `extra_env` carries the environment a check owns outright — the
    restart-survival run points its own service at the primary database it
    prepared — and wins over the shared wiring for every service in the call.
    """

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
                env=_service_env(name, ports) | dict(extra_env or {}),
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

    entries = {**SERVICES, "analytics": ANALYTICS_SERVICE, "model": MODEL_SERVICE}
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


@pytest.fixture(scope="session")
def notify_stack(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Stack]:
    """Boot the notification path: the client path plus the notifier and a push double."""

    entries = {
        **SERVICES,
        "notification": NOTIFICATION_SERVICE,
        "model": MODEL_STUB,
        "push": PUSH_STUB,
    }
    with _boot(entries, NOTIFY_PORTS, tmp_path_factory) as booted:
        yield booted


@pytest.fixture(scope="session")
def review_stack(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Stack]:
    """Boot the review path: the client path, the feedback service, and a model double.

    The feedback service carries the reader's rating and report intake (C-012,
    C-013) and the curator review surface (C-014 to C-016). The model provider is
    the local double, so a word lookup produces a real clip a reader can rate and
    report, and a curator's choose or edit_phrase has a generation to hand off.
    The notification service and the push double are booted beside it, so a
    report's regenerated clip can be followed to the reporting reader by the
    clip-ready notice (C-008, FEAT-011).
    """

    entries = {
        **SERVICES,
        "feedback": FEEDBACK_SERVICE,
        "notification": NOTIFICATION_SERVICE,
        "model": MODEL_STUB,
        "push": PUSH_STUB,
    }
    with _boot(entries, REVIEW_PORTS, tmp_path_factory) as booted:
        yield booted


@pytest.fixture(scope="session")
def account_stack(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Stack]:
    """Boot the account stack: the client path, the meter, and the event intake.

    The account and entitlement service carries the reader's plan and allowance
    (C-018), their account's consent and locale (C-020, C-022), their deletion
    (C-021), and the spend seam the lookup path meters through (C-001, FEAT-013).
    The generation path is the model double, so a consented miss actually
    produces, and the analytics intake answers a client's events (C-007).
    """

    entries = {
        **SERVICES,
        "entitlement": ENTITLEMENT_SERVICE,
        "analytics": ANALYTICS_SERVICE,
        "model": MODEL_STUB,
    }
    with _boot(entries, ACCOUNT_PORTS, tmp_path_factory) as booted:
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


@pytest.fixture()
def notify_gateway(notify_stack: Stack) -> Iterator[httpx2.Client]:
    """A gateway client for the notification-path stack (C-001, C-008)."""

    with httpx2.Client(base_url=notify_stack.url("gateway"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def notify_push(notify_stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the push-provider double (observes the clip-ready notice)."""

    with httpx2.Client(base_url=notify_stack.url("push"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def notify_model_stub(notify_stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the notification-path stack's model-provider double."""

    with httpx2.Client(base_url=notify_stack.url("model"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def notify_library(notify_stack: Stack) -> Iterator[httpx2.Client]:
    """A library client for the notification-path stack."""

    with httpx2.Client(base_url=notify_stack.url("library"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def review_gateway(review_stack: Stack) -> Iterator[httpx2.Client]:
    """A gateway client for the review-path stack (C-001, C-012, C-013, C-014 to C-016)."""

    with httpx2.Client(base_url=review_stack.url("gateway"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def review_library(review_stack: Stack) -> Iterator[httpx2.Client]:
    """A library client for the review-path stack (C-009, C-010, C-011)."""

    with httpx2.Client(base_url=review_stack.url("library"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def review_model_stub(review_stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the review-path stack's model-provider double."""

    with httpx2.Client(base_url=review_stack.url("model"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def review_push(review_stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the review-path stack's push-provider double (C-008, FEAT-011)."""

    with httpx2.Client(base_url=review_stack.url("push"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def review_feedback(review_stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the feedback service, addressed directly (C-012 to C-016)."""

    with httpx2.Client(base_url=review_stack.url("feedback"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def account_gateway(account_stack: Stack) -> Iterator[httpx2.Client]:
    """A gateway client for the account stack (C-001, C-018 to C-022, C-007)."""

    with httpx2.Client(base_url=account_stack.url("gateway"), timeout=10.0) as client:
        yield client


@pytest.fixture()
def account_entitlement(account_stack: Stack) -> Iterator[httpx2.Client]:
    """A client for the entitlement service, addressed directly.

    The spend seam (C-001 metering) and the billing sync (C-019) are internal
    seams the gateway never exposes, so the meter's arithmetic — what a reader's
    allowance counted at, what a stored billing event changed — is observed at
    the service the way the lookup service and the payment processor call it.
    """

    with httpx2.Client(base_url=account_stack.url("entitlement"), timeout=10.0) as client:
        yield client
