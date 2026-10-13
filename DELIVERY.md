# DELIVERY — Scenova

## Source of Truth
`docs/Scenova/` (BPRD), a nested git repo. Content revision `f801f30e6e9b`; docs commit `4a1a00225ff1`. Read-only for the squad; `product-shaper` is the only writer. The roadmap owns the build order.

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
- Provider circuit open: serve the library and device history, start no new generation.
- One generation runs per missing word; concurrent lookups share it.

## Task Board

### Completed Phases
| Phase | Closed | Notes |
|---|---|---|
| — | — | No phase closed yet. |

### Active Phase: Phase 1: Foundations
| Task | Feature | Owner | Status | Contract |
|---|---|---|---|---|
| T-001 | — | infra-engineer | Done | — |
| T-002 | FEAT-001 | frontend-engineer | Done | C-001, C-002 |
| T-003 | FEAT-003 | backend-engineer | Done | C-001, C-002 |
| T-004 | FEAT-004 | ai-engineer | Done | C-004 |
| T-005 | FEAT-005 | ai-engineer | Done | C-005 |
| T-006 | FEAT-005 | backend-engineer | Done | C-003, C-005 |
| T-007 | — | infra-engineer | Done | — |
| T-008 | FEAT-003, FEAT-005 | backend-engineer | Done | C-002, C-003, C-005 |
| T-009 | FEAT-005 | backend-engineer | Done | C-002, C-006 |
| T-010 | FEAT-004 | ai-engineer | Done | C-004 |
| T-011 | FEAT-002 | frontend-engineer | Done | C-001, C-002 |
| T-012 | FEAT-002 | frontend-engineer | Done | C-001, C-002 |
| T-013 | FEAT-001, FEAT-002, FEAT-012 | frontend-engineer | Done | C-001 |
| T-014 | — | visual-artist | Done | — |
| T-015 | — | visual-artist | Done | — |
| T-016 | — | frontend-engineer | Done | — |
| T-018 | — | infra-engineer | Done | — |
| T-019 | FEAT-005 | backend-engineer | Done | C-001, C-003, C-006 |
| T-020 | FEAT-001, FEAT-002 | frontend-engineer | Done | C-001, C-002 |
| T-021 | FEAT-005 | ai-engineer | Done | C-005 |
| T-022 | FEAT-005 | qa-engineer | Done | C-005 |
| T-023 | FEAT-004, FEAT-005, FEAT-007 | ai-engineer | Done | C-004, C-005 |
| T-024 | — | backend-engineer | Done | C-007 |
| T-025 | — | frontend-engineer | Done | C-007 |
| T-026 | — | backend-engineer | Done | C-007 |
| T-027 | — | infra-engineer | Done | — |
| T-028 | — | qa-engineer | Done | C-004, C-005 |
| T-029 | FEAT-004 | ai-engineer | Done | C-004 |
| T-030 | FEAT-005 | backend-engineer | Done | C-003, C-006 |
| T-031 | — | qa-engineer | Done | C-004, C-005 |
| T-032 | FEAT-004 | backend-engineer | Done | C-003, C-004 |
| T-033 | FEAT-004 | backend-engineer | Done | C-001, C-002, C-003 |
| T-034 | — | infra-engineer | Done | — |
| T-035 | FEAT-003 | backend-engineer | Done | C-003 |

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

## Definition of Done
- **Task:** the acceptance criteria in the cited feature doc are met; the frozen contract is conformed; unit tests pass; format, lint, analyze, and build are clean; work is committed to the dev branch and confined to `Own`.
- **Phase:** QA's integration, acceptance, and full regression pass is green at the phase gate; for model-backed capabilities the NFR-050 to NFR-053 golden-set evaluation meets its threshold; the release flags for the phase are recorded.

## Key Commands
- `flutter analyze` / `flutter test` — the Flutter app (`apps/mobile`)
- `ruff check .` / `pytest` — services and AI
- `make ci` — the full local CI run
- Pinned and wired by `infra-engineer` in T-001.
