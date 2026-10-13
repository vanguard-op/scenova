"""QA gate bootstrap: expose the `ai/` evaluation workspace to the gate tests.

The judged model quality-bar gate drives the evaluation run in `ai/quality` — the
same run `make model-bar` invokes — so that workspace must be importable from
`qa/`. `tests/conftest.py` does the same for the integration harness.
"""

from __future__ import annotations

import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[1]
_AI_ROOT = _REPO_ROOT / "ai"
if str(_AI_ROOT) not in sys.path:
    sys.path.insert(0, str(_AI_ROOT))
