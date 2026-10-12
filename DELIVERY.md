# DELIVERY — Scenova

## Source of Truth
`docs/Scenova/` (BPRD), a nested git repo. Content revision `df34986b0735`; docs commit `89596c71341f`. Read-only for the squad; `product-shaper` is the only writer. The roadmap owns the build order.

## Team & File Ownership
| Owner | Owns |
|---|---|
| infra-engineer | `infra/**`, `ci/**`, `.devcontainer/**`, `Makefile`, root workspace config |
| backend-engineer | `services/**` |
| ai-engineer | `ai/**` |
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
| T-002 | FEAT-001, FEAT-002 | frontend-engineer | Ready | C-001, C-002 |
| T-003 | FEAT-003 | backend-engineer | Ready | C-001, C-002 |
| T-004 | FEAT-004 | ai-engineer | Ready | C-004 |
| T-005 | FEAT-005 | ai-engineer | Ready | C-005 |
| T-006 | FEAT-005 | backend-engineer | Ready | C-003, C-005 |

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

## Definition of Done
- **Task:** the acceptance criteria in the cited feature doc are met; the frozen contract is conformed; unit tests pass; format, lint, analyze, and build are clean; work is committed to the dev branch and confined to `Own`.
- **Phase:** QA's integration, acceptance, and full regression pass is green at the phase gate; for model-backed capabilities the NFR-050 to NFR-053 golden-set evaluation meets its threshold; the release flags for the phase are recorded.

## Key Commands
- `flutter analyze` / `flutter test` — the Flutter app (`apps/mobile`)
- `ruff check .` / `pytest` — services and AI
- `make ci` — the full local CI run
- Pinned and wired by `infra-engineer` in T-001.
