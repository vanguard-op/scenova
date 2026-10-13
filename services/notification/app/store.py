"""Push-registration persistence for the clip-ready notice (C-008).

A registration binds a push token to the lookup the reader is waiting on, so a
finished generation can reach exactly the devices that asked for it. The store is
keyed by lookup and deduplicates a repeated token, since a reader may register
the same device more than once.

Each clip-ready ingest is claimed once by its job id, so a retried notification
never sends a second notice for the same finished clip.

The store is in memory for the reading phase; Cloud SQL or the queue replaces it
behind the same port, holding the same associations, so no caller changes.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from .models import Platform


@dataclass(frozen=True)
class PushRegistration:
    """One device registered for a lookup's clip-ready notice."""

    token: str
    platform: Platform
    subject: str
    lookup_id: str


class RegistrationStore(Protocol):
    """Port for push-registration persistence."""

    async def add(self, registration: PushRegistration) -> None:
        """Record a device for a lookup, replacing the same device if repeated."""
        ...

    async def take(self, lookup_id: str) -> list[PushRegistration]:
        """Return and clear the devices registered for a lookup."""
        ...

    async def claim(self, job_id: str) -> bool:
        """Claim a clip-ready ingest; False when its job id was already claimed."""
        ...

    async def aclose(self) -> None: ...


class InMemoryRegistrationStore:
    """An in-memory registration store, keyed by lookup."""

    def __init__(self) -> None:
        self._by_lookup: dict[str, dict[tuple[str, str], PushRegistration]] = {}
        self._claimed_jobs: set[str] = set()

    async def add(self, registration: PushRegistration) -> None:
        devices = self._by_lookup.setdefault(registration.lookup_id, {})
        devices[(registration.token, registration.platform.value)] = registration

    async def take(self, lookup_id: str) -> list[PushRegistration]:
        return list(self._by_lookup.pop(lookup_id, {}).values())

    async def claim(self, job_id: str) -> bool:
        if job_id in self._claimed_jobs:
            return False
        self._claimed_jobs.add(job_id)
        return True

    async def aclose(self) -> None:
        return None
