"""Loader for the versioned gloss-phrase prompt artifact.

The prompt is a behaviour artifact, not a string in a handler: it lives in
`ai/prompts/gloss_phrase.v2.txt`, carries its own version, and is loaded and
parsed here. A change to the prompt is a new versioned file, so the phrase
behaviour can be diffed and rolled back like code.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

PROMPT_DIR = Path(__file__).resolve().parent.parent / "prompts"
# The pinned gloss-phrase behaviour is the artifact the quality bar is measured
# on (NFR-050). A change to it is a new versioned file; the previous version is
# kept so the pin can be diffed and rolled back.
DEFAULT_PROMPT_PATH = PROMPT_DIR / "gloss_phrase.v2.txt"
DEFAULT_CLIP_PROMPT_PATH = PROMPT_DIR / "word_clip.v1.txt"

_SYSTEM_MARKER = "[system]"
_USER_MARKER = "[user]"


@dataclass(frozen=True, slots=True)
class PromptTemplate:
    """A parsed prompt: a system instruction and a user template."""

    version: str
    system: str
    user: str

    def render(self, **fields: str) -> tuple[str, str]:
        """Return the (system, user) pair with the request's fields filled in."""

        return self.system, self.user.format(**fields)


def load_prompt(path: Path | None = None) -> PromptTemplate:
    """Read and parse a prompt artifact; raise if it is malformed."""

    source = path or DEFAULT_PROMPT_PATH
    version = ""
    sections: dict[str, list[str]] = {"system": [], "user": []}
    current: str | None = None

    for line in source.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.lower().startswith("version:"):
            version = stripped.split(":", 1)[1].strip()
            continue
        if stripped == _SYSTEM_MARKER:
            current = "system"
            continue
        if stripped == _USER_MARKER:
            current = "user"
            continue
        if current is not None:
            sections[current].append(line)

    system = "\n".join(sections["system"]).strip()
    user = "\n".join(sections["user"]).strip()
    if not version or not system or not user:
        raise ValueError(f"malformed prompt artifact: {source}")
    return PromptTemplate(version=version, system=system, user=user)
