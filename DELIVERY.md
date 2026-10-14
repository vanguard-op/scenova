# DELIVERY — Scenova

## Source of Truth
`docs/Scenova/` (BPRD), a git submodule of `vanguard-op/scenova-docs`. Content revision `b4859110fe5a`; submodule pinned at `45896c8410cb`. Read-only for the squad; `product-shaper` is the only writer. The roadmap owns the build order. The lead is the only agent who runs git against the submodule: commit and push `product-shaper`'s changes to the docs repo, then stage the pointer bump in the same commit as the code built against it, and never leave the parent pointing at an unpushed docs commit.

## Team & File Ownership
| Owner | Owns |
|---|---|
| infra-engineer | `infra/**`, `ci/**`, `.devcontainer/**`, `Makefile`, root workspace config |
| backend-engineer | `services/**` |
| ai-engineer | `ai/**`, `qa/golden/**` |
| frontend-engineer | `apps/mobile/**` |
| visual-artist | `assets/**` |
| qa-engineer | `tests/**`, `qa/**` |
| lead | `DELIVERY.md`, `CONTRACTS.md`, `ASSETS.md`, `.delivery/**`, `contracts/**` |
| product-shaper | `docs/**` |

Private scratch: `.scratch/<role>/**` (gitignored). No two engineers share a file or directory.

## Stack
| Layer | Choice |
|---|---|
| Client | Flutter (Dart), iOS + Android |
| Services | Python 3 + FastAPI |
| Primary database | Cloud SQL for PostgreSQL |
| Cache & queue | Memorystore (Redis) + Cloud Tasks |
| Object storage & CDN | Cloud Storage + Cloud CDN |
| Identity | Firebase Authentication |
| Payments | RevenueCat |
| Model | Gemini Omni Flash via the Gemini API, pinned to `gemini-omni-1.1-flash` |
| Cloud | Google Cloud |
| Repo | Monorepo |

## Structure
```
apps/mobile/    Flutter app (iOS + Android)
services/       FastAPI services: gateway, lookup, pipeline, library, entitlement, feedback
ai/             model serving, prompts, eval harness, golden sets
contracts/      frozen interface specs (lead)
infra/          IaC, CI/CD, environments, secrets
assets/         brand mark, icons, motion assets
tests/          integration + acceptance (qa)
qa/             quality-bar harness and golden-set evaluation (qa)
docs/           BPRD (product-shaper)
```

## Contracts
`CONTRACTS.md`

## Token Map
| Token group | Source | Code location |
|---|---|---|
| Colors (primary, grey, semantic) | `docs/Scenova/branding.md` Color Palette | `apps/mobile/lib/theme/colors.dart` |
| Type scale | `docs/Scenova/branding.md` Typography | `apps/mobile/lib/theme/typography.dart` |
| Spacing, sizing, radius, shadow | `docs/Scenova/branding.md` Spacing, Sizing, Shadows | `apps/mobile/lib/theme/tokens.dart` |

## Assets
`ASSETS.md`

## Conventions
- Commit messages cite durable IDs only (`FEAT-###`, `C-###`); never a task ID, a route filename, or a `.delivery/` path.
- Engineers commit to the shared dev branch; the lead merges to `main` only at a green phase gate.
- `docs/` is a submodule: docs changes are committed and pushed to `vanguard-op/scenova-docs`, and the pointer bump is staged in the same commit as the code built against it.
- Engineers own unit tests; QA owns integration and acceptance tests and the model quality-bar evaluation, and runs at the phase gate.
- Contracts are frozen in `CONTRACTS.md`; a change is a revision that re-dispatches both sides.
- Dart: `dart format` and `flutter analyze` clean. Python: `ruff` + `black`, typed.
- `.delivery/**` and `.scratch/**` are gitignored.

## Behavior Rules
- Send only the selected word or phrase to the model provider; page content is never read or transmitted.
- Generation requires consent; without it, library lookups and device history still serve.
- Analytics carry no personal data: never the word, phrase, email, or name; events reference a pseudonymous `user_id`.
- Clips are muted by default; sound is explicit.
- Reduce motion holds a clip on a still frame and plays on tap.
- Offline: serve device history and saved clips; queue feedback and reports for reconnection.
- Clips are capped at four seconds at 360p and carry the provider's watermark.
- Reader-facing copy never names the product's internals — no "sense list", "library entry", "generation job", or similar machinery — and never qualifies the meaning's confidence: no "best guess", no uncertainty notice. It speaks in the product's own voice, plain and brief.
- Provider circuit open: serve the library and device history, start no new generation.
- One generation runs per missing word; concurrent lookups share it.

## Task Board

### Completed Phases
| Phase | Closed | Notes |
|---|---|---|
| — | — | No verified phase closed yet; the conditional close of the first phase is a decisions-log entry. |

### Active Phase: Phase 2: The Reading Loop
| Task | Feature | Owner | Status | Contract |
|---|---|---|---|---|
| T-043 | FEAT-006 | backend-engineer | Done | C-001, C-002, C-003, C-006 |
| T-044 | FEAT-007 | ai-engineer | Done | C-005 |
| T-045 | FEAT-008 | backend-engineer | Done | C-008 |
| T-046 | FEAT-008 | frontend-engineer | Done | C-001, C-002, C-008 |
| T-047 | FEAT-007, FEAT-008 | frontend-engineer | Done | C-001, C-002, C-008 |
| T-048 | FEAT-006 | qa-engineer | Done | C-009, C-010, C-011 |
| T-049 | — | infra-engineer | Done | C-008 |
| T-050 | FEAT-008 | backend-engineer | Done | C-008 |
| T-051 | FEAT-006 | qa-engineer | Done | C-009, C-010, C-011 |
| T-052 | FEAT-008 | frontend-engineer | Done | C-008 |
| T-053 | FEAT-006, FEAT-007, FEAT-008 | qa-engineer | Done | C-001, C-002, C-003, C-005, C-006, C-008, C-009, C-010, C-011 |
| T-054 | FEAT-005, FEAT-007 | ai-engineer | Done | C-005 |
| T-055 | FEAT-008 | backend-engineer | Done | C-008 |
| T-056 | FEAT-008 | qa-engineer | Done | C-008 |
| T-057 | FEAT-005 | qa-engineer | Done | C-005 |
| T-058 | FEAT-005, FEAT-007 | backend-engineer | Done | C-005, C-009 |
| T-059 | FEAT-006 | qa-engineer | Done | C-003, C-006, C-009 |
| T-060 | FEAT-001, FEAT-002, FEAT-008 | frontend-engineer | Done | C-001, C-002, C-007, C-008 |
| T-061 | FEAT-005, FEAT-006 | ai-engineer | Done | C-005, C-009 |
| T-062 | FEAT-008 | frontend-engineer | Done | C-001, C-002 |
| T-063 | FEAT-001, FEAT-002, FEAT-008 | frontend-engineer | Done | C-001, C-002, C-008 |
| T-064 | FEAT-008 | frontend-engineer | Done | C-001, C-002 |
| T-065 | FEAT-007 | backend-engineer | Done | C-003, C-005 |
| T-066 | — | infra-engineer | Done | — |
| T-067 | FEAT-007 | qa-engineer | Done | C-003, C-005 |
| T-068 | — | infra-engineer | Done | — |
| T-069 | FEAT-001, FEAT-002 | backend-engineer | Done | C-001, C-002 |
| T-070 | FEAT-008 | frontend-engineer | Done | C-008 |
| T-071 | — | infra-engineer | Done | C-008 |
| T-072 | FEAT-003, FEAT-004, FEAT-008 | backend-engineer | Done | C-001, C-002, C-004, C-009, C-010 |
| T-073 | FEAT-003, FEAT-006 | qa-engineer | Done | C-001, C-002, C-009, C-010 |
| T-074 | FEAT-001, FEAT-002 | frontend-engineer | Done | — |

## Decisions Log
| # | Decision | Rationale | By |
|---|---|---|---|
| D-001 | Client stack: Flutter | One codebase for iOS and Android; platform channels cover the Android selection action and the iOS share extension | user |
| D-002 | Backend runtime: Python (FastAPI) | Strongest model-orchestration and evaluation ecosystem for the generation path | user |
| D-003 | Primary database: Cloud SQL for PostgreSQL | The docs specify a relational primary store; keeps the foreign-key relationships and the review and reporting joins | user |
| D-004 | Cloud: Google Cloud | Same ecosystem as the pinned model provider; covers every component in the architecture | user |
| D-005 | Identity: Firebase Authentication | Managed sign-in; anonymous tokens available before accounts ship | user |
| D-006 | Repo structure: monorepo | One repo for the Flutter app, services, and AI; keeps frozen contracts in one place | user |
| D-007 | Model provider: Gemini Omni Flash via the Gemini API, pinned to `gemini-omni-1.1-flash` | As declared by the docs; the version is pinned so the quality bar has an anchor | user |
| D-008 | Payments: RevenueCat | Wraps StoreKit and Play Billing for subscriptions, the trial, and top-ups; keeps card scope out of the product | user |
| D-009 | Lemma and sense source: open-source lemmatiser with a WordNet-style sense inventory | Self-hostable, no per-call cost; matches the docs' note that open sources exist | user |
| D-010 | Phase 1 doc gaps settled: ten-second generation wait threshold; two-to-six-word phrase limit; model pinned to `gemini-omni-1.1-flash` | The docs were silent on each; settled via `product-shaper` at the user's direction | user |
| D-011 | Pre-account authentication: anonymous Firebase ID token, upgraded to the reader's account at sign-in | The gateway must enforce authentication before accounts ship, without the client holding a server secret | lead |
| D-012 | Contract revision 1 to C-001 and C-002: the reader-facing best-guess signal is `notice` (not a `senseLabel` sentinel); errors carry a `{code, message}` body; 503 is added as retryable | Both services already emit this shape; the sentinel was an undocumented coupling. Only the client needs re-aligning | lead |
| D-013 | Brand-doc gaps: motion timings stay build-layer-owned; the semantic families' 100/300/700/900 shades are completed; the gloss fallback is made grammatical | The branding reference deliberately excludes motion tokens, so the derived values stand; the shade and fallback gaps were real and are now settled | user |
| D-014 | The icon set's disabled state is carried by a solid colour, never opacity or alpha | Opacity renders inconsistently across platforms; the muted reading is carried by brightness instead (solid `grey-400` against the `grey-600` default) | user |
| D-015 | Phase 1's goal is restated to the capture-to-clip foundation; serving a stored clip to the reader defers to the reading loop | The phase's features produce a clip; the component that serves it is the shared library, which the roadmap places in the next phase | user |
| D-016 | The model quality bar's golden sets are built by the model engineer and the judged run is QA's gate | Keeps dataset construction with the model path and the release decision with QA | user |
| D-017 | Analytics is added to Phase 1, with a frozen client intake contract (C-007) | The taxonomy was specified but owned by no phase; the launch funnels depend on it | user |
| D-018 | The gloss phrase and the clip use separate pinned models: the text model `gemini-3.5-flash-lite` for the phrase, the video model `gemini-omni-1.1-flash` for the clip | One model for both is expensive and inaccurate at text; each output is pinned, costed, and measured on its own terms | user |
| D-019 | The gloss-phrase bound is seven words or fewer; the judged bar is a single trained rater with adjudication; the cost ceiling is verified from the cost signal; the quality gate asserts only the bars the phase's capabilities deliver | The earlier bound and two-rater panel were not achievable and cost a measured miss; NFR-051 is judged in this phase because the clip is generated here, while NFR-053 belongs to the next phase | user |
| D-020 | Phase 1 closed conditionally: regression and NFR-050 green, but NFR-051 (word-clip quality) unmeasured and NFR-052 (reader-helpful) unavailable | NFR-051 needs a judged video run; NFR-052 is live rolling-30-day feedback. The generation path's release stays flagged until NFR-051 is measured | user |
| D-021 | Library seeding is deferred: the shared library starts empty and fills only from real reader lookups; seeding is enabled later at the user's direction | The seed set is the project's largest one-time generation cost; the spend is held rather than committed. The roadmap's seeded-library outcome is deferred, not withdrawn | user |

## Definition of Done
- **Task:** the acceptance criteria in the cited feature doc are met; the frozen contract is conformed; unit tests pass; format, lint, analyze, and build are clean; work is committed to the dev branch and confined to `Own`.
- **Phase:** QA's integration, acceptance, and full regression pass is green at the phase gate; for the model-backed capabilities the phase delivers, the golden-set evaluation meets its threshold; the release flags for the phase are recorded.

## Key Commands
- `flutter analyze` / `flutter test` — the Flutter app (`apps/mobile`)
- `ruff check .` / `pytest` — services and AI
- `make ci` — the full local CI run
- Pinned and wired by `infra-engineer` in T-001.
