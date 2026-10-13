#!/usr/bin/env bash
# Model quality bar — the golden-set evaluation against the pinned model
# (nfr.md "Measurement & Verification", NFR-050 to NFR-053; architecture.md
# "Evaluation Harness"). Run per release of the generation path: a capability
# below its threshold blocks that release until the pinned model or the phrase
# prompt moves it back above the bar.
#
# The evaluation itself is the `ai/quality` run (`python -m quality`); this
# wrapper is the one place the platform invokes it, so `make model-bar` on a
# laptop and any release job are the same command over the same golden sets. It
# writes one report per bar and decides the gate from the report: a run that
# could not be completed, a rubric pre-screen standing in for a judged bar, or a
# bar below its threshold all fail.
#
# A judged run needs the pinned-model credential (`GEMINI_API_KEY`) or a recorded
# replay (`--replay`). The phrase bar (NFR-050) needs rater judgements
# (`--ratings`) to judge the full bar, and a clip bar (NFR-051, NFR-053) cannot
# be judged without them. A missing input is reported, never passed silently.
#
# Usage: ci/checks/model_bar.sh [bar] [extra args ...]
#   bar          NFR-050 | NFR-051 | NFR-053 | all   (default: all)
#   extra args   passed through to `python -m quality`
#                (--replay, --ratings, --record, --sheet)
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

if ! has_python || [ ! -d ai/quality ]; then
  skip "no model quality-bar harness (ai/quality)"
  exit 0
fi

BAR="${1:-all}"
shift || true
extra=("$@")

case "$BAR" in
  all) bars=(NFR-050 NFR-051 NFR-053) ;;
  NFR-050 | NFR-051 | NFR-053) bars=("$BAR") ;;
  *) die "unknown bar '$BAR' (expected NFR-050, NFR-051, NFR-053, or all)" ;;
esac

reports_dir="${MODEL_BAR_REPORTS_DIR:-$(mktemp -d)}"
mkdir -p "$reports_dir"
failed=0

for bar in "${bars[@]}"; do
  report="$reports_dir/$bar.json"
  log "Model bar · $bar"

  status=0
  PYTHONPATH=ai "$(py)" -m quality --bar "$bar" ${extra[@]+"${extra[@]}"} --out "$report" ||
    status=$?
  if [ "$status" -ne 0 ]; then
    warn "$bar could not be completed — see the message above (missing golden set, credential, or ratings)"
    failed=1
    continue
  fi

  if grep -q 'pre-screen' "$report"; then
    warn "$bar ran the rubric pre-screen only; pass --ratings to judge the bar (report: $report)"
    failed=1
    continue
  fi
  if grep -q '"meetsBar": true' "$report"; then
    info "$bar meets its bar (report: $report)"
  else
    warn "$bar is below its bar — blocks release of the generation path (report: $report)"
    failed=1
  fi
done

[ "$failed" -eq 0 ] || die "model quality bar not met"
log "Model quality bar met"
