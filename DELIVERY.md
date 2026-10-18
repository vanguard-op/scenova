# DELIVERY — Scenova

## Source of Truth
`docs/Scenova/` (BPRD), a git submodule of `vanguard-op/scenova-docs`, pinned at `e07755a5f9dec2a555a4ea14025e606d8532f5d2` (`e07755a5f9de`). Read-only for the squad; `product-shaper` is the only writer. The roadmap owns the build order. The lead is the only agent who runs git against the submodule: commit and push `product-shaper`'s changes to the docs repo, then stage the pointer bump in the same commit as the code built against it, and never leave the parent pointing at an unpushed docs commit.

## Team & File Ownership
| Owner | Owns |
|---|---|
| infra-engineer | `infra/**`, `ci/**`, `.github/**`, `.devcontainer/**`, `Makefile`, root workspace config, `services/*/Dockerfile` |
| backend-engineer | `services/**` |
| ai-engineer | `ai/**`, `qa/golden/**` |
| frontend-engineer | `apps/mobile/**`, `apps/console/**`, `packages/scenova_design/**` |
| visual-artist | `assets/**` |
| qa-engineer | `tests/**`, `qa/**` |
| lead | `DELIVERY.md`, `CONTRACTS.md`, `ASSETS.md`, `.delivery/**`, `contracts/**` |
| product-shaper | `docs/**` |

Private scratch: `.scratch/<role>/**` (gitignored). No two engineers share a file or directory.

## Stack
| Layer | Choice |
|---|---|
| Client | Flutter (Dart), iOS + Android |
| Operator console | Flutter Web (Dart), web |
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
apps/console/   Flutter Web app (curator review console)
services/       FastAPI services: gateway, lookup, pipeline, library, entitlement, feedback
ai/             model serving, prompts, eval harness, golden sets
contracts/      frozen interface specs (lead)
infra/          IaC, CI/CD, environments, secrets
packages/scenova_design/  the shared design system both apps import
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
| Colors (primary, grey, semantic) | `docs/Scenova/branding.md` Color Palette | `packages/scenova_design/lib/src/theme/colors.dart` |
| Type scale | `docs/Scenova/branding.md` Typography | `packages/scenova_design/lib/src/theme/typography.dart` |
| Spacing, sizing, radius, shadow | `docs/Scenova/branding.md` Spacing, Sizing, Shadows | `packages/scenova_design/lib/src/theme/tokens.dart` |

## Assets
`ASSETS.md`

## Conventions
- Commit messages cite durable IDs only (`FEAT-###`, `C-###`); never a task ID, a route filename, or a `.delivery/` path.
- Engineers commit to the shared dev branch; the lead merges to `main` only at a green phase gate.
- `docs/` is a submodule: docs changes are committed and pushed to `vanguard-op/scenova-docs`, and the pointer bump is staged in the same commit as the code built against it.
- Engineers own unit tests; QA owns integration and acceptance tests and the model quality-bar evaluation, and runs at the phase gate.
- Contracts are frozen in `CONTRACTS.md`; a change is a revision that re-dispatches both sides.
- Dart: `dart format` and `flutter analyze` clean. Python: `ruff` + `black`, typed.
- Run `make ci` in full before reporting: a scoped lint, type or test check is not the gate, and two typing slips have reached `dev` through checks narrowed to a directory.
- A push cancels the branch's in-flight CI run (`cancel-in-progress`): read a run's result before pushing again, or the verification you were waiting on is the one you discarded.
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
| Phase 3: Trust and Continuity | 2026-10-15 | C-012 to C-016 frozen and conformed at the gate; the moderation change (`D-030`) reworked and re-verified. The generation path's release still flagged (`D-023`) |
| Phase 4: Polish and Account | 2026-10-16 | C-018 to C-022 frozen and conformed; the tier gates and the primary database landed; the generation path's release still flagged (`D-023`) |
| — | — | The conditional closes of the first two phases are decisions-log entries (`D-020`, `D-023`). |

### Active Phase: Phase 4: Polish and Account
| Task | Feature | Owner | Status | Contract |
|---|---|---|---|---|
| T-143 | — | infra-engineer | Done | — |
| T-144 | — | infra-engineer | Done | — |
| T-145 | — | infra-engineer | Done | — |
| T-146 | — | infra-engineer | Done | — |
| T-147 | — | backend-engineer | Done | — |
| T-148 | — | infra-engineer | Done | — |
| T-149 | — | infra-engineer | Done | — |
| T-151 | — | infra-engineer | Done | — |
| T-152 | — | backend-engineer | Done | — |
| T-153 | — | infra-engineer | Done | — |
| T-154 | — | infra-engineer | Done | — |
| T-155 | — | infra-engineer | Done | — |
| T-156 | — | infra-engineer | Done | — |
| T-159 | — | infra-engineer | Done | — |
| T-160 | FEAT-006, FEAT-013 | backend-engineer | Done | — |
| T-161 | — | infra-engineer | Done | — |
| T-162 | FEAT-013 | infra-engineer | In Progress | C-019 |
| T-157 | FEAT-013 | backend-engineer | Done | C-019 |
| T-158 | FEAT-013 | backend-engineer | Done | — |
| T-159 | — | infra-engineer | Backlog | — |
| T-150 | — | backend-engineer | Done | — |

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
| D-022 | The setup panel keeps a slice of its setup content at the position it takes when dragged down, instead of reducing to its handle | A handle-only panel does not tell the reader there is setup they must attend to; the panel's resting and expanded positions are unchanged | user |
| D-023 | Phase 2 closes conditionally: its integration, acceptance, and regression pass is gated, but the judged model bars are held | The phase's phrase-clip bar (NFR-053) and the carried-over word-clip bar (NFR-051) are judged generation runs; the spend is held rather than committed. The generation path's release stays flagged | user |
| D-024 | Store release signing is deferred to the release workstream; no feature phase cuts a store-signed build | The feature phases build and test the app, and nothing they deliver is submitted to a store; the signing material and its handling belong with release, which the specification does not yet cover | user |
| D-025 | The curator review console is a second Flutter app in the monorepo (`apps/console`), built with Flutter Web and owned by `frontend-engineer` | It reuses the design system's tokens and shared states and the toolchain the repo already pins; the console is operator-only, so its bundle weight matters less than a second stack would cost | user |
| D-026 | The Free tier's 50-entry history limit applies to every reader until the paid tier ships | Matches the Free row in `monetization.md` and the History screen's edge case; the tiers are introduced with the account feature | user |
| D-027 | The review component is carried by the feedback service, with the gateway exposing the console's routes | No standalone review service exists in the stack, and the feedback store already holds the queue, the reports, and the negative feedback; the console's hosting rewrites `/internal/review/**` to the gateway | lead |
| D-028 | The design system is extracted into a shared package both apps import, rather than mirrored copies | The console carried a byte copy of the palette and its own copies of the shared widgets; every token change and the mark audit would otherwise be made twice, and the token map pointed at one location while two existed | user |
| D-029 | The device keeps the clip for every reader until the paid tier ships; the account phase applies the Free/Pro split | FEAT-009 requires stored clips to replay with no connection and the roadmap makes offline replay this phase's headline outcome; the tiers are introduced with the account feature | user |
| D-030 | A report regenerates one clip for the entry, kept as a candidate on the entry's queue item; the entry keeps serving the clip it already serves to other readers, and the curator resolves with one `choose` action or a `retire` | The reporter is the one who found the clip wrong, so the fresh clip is theirs to see, while a report should not withdraw a clip other readers are using before a curator has judged it. One candidate per entry keeps the spend to one generation however many readers report it | user |
| D-031 | The report-triggered generation spend is absorbed; the cost and monetization documents are left as they are | The per-clip cost ceiling still applies; only the volume is unaccounted for, and the user chose not to carry the change into the margin model | user |
| D-032 | Readers sign in with email and password; no third-party sign-in | Keeps store review simple, since offering third-party sign-in would oblige Sign in with Apple alongside it; the identity provider is already Firebase and its providers are declared | user |
| D-033 | The selection-action label ships in English only; the choice is stored and every other language reads that it is shown in English | No translated label set exists to ship, so the platform per-app-locale wiring waits for real translations rather than shipping a choice that does nothing | user |
| D-034 | Pre-revenue the product runs on the free tiers with no always-on infrastructure: scale-to-zero services, the cheapest reachable Postgres, no Redis, no CDN, and Firebase's free tier — with the paid resources started, paused and destroyed on demand rather than left running | There are no readers yet, so the availability the production shape exists to meet buys nothing; every choice reverses by configuration because the stores sit behind ports, and the lifecycle action means the paid parts exist only during testing windows | user |
| D-035 | The product is billed through Vanguard Billing, freeing its project slot by unlinking `waypoint-510216` | Vanguard is at its project quota and cannot take another project without a support request; Waypoint keeps its project and its data but loses its billing link, so any billable service there stops until it is re-linked | user |
| D-036 | The product repository is public and the documentation submodule stays private | The public repository is what lets the Actions run and the environment protection rules attach; the specification is not published with the code, so a public cloner gets a build it cannot reproduce without the docs | user |

## Definition of Done
- **Task:** the acceptance criteria in the cited feature doc are met; the frozen contract is conformed; unit tests pass; format, lint, analyze, and build are clean; work is committed to the dev branch and confined to `Own`.
- **Phase:** QA's integration, acceptance, and full regression pass is green at the phase gate; for the model-backed capabilities the phase delivers, the golden-set evaluation meets its threshold; the release flags for the phase are recorded.

## Key Commands
- `flutter analyze` / `flutter test` — the Flutter app (`apps/mobile`)
- `ruff check .` / `pytest` — services and AI
- `make ci` — the full local CI run
- Pinned and wired by `infra-engineer` in T-001.
