# CONTRACTS — Scenova

Frozen interfaces between layers. The lead is the only writer. A change after `Frozen` is a
change request: mark it `Frozen (revision N)` and re-dispatch both sides.

### C-001: POST /v1/lookups
Status: Frozen (revision 2)
Auth: Firebase ID token in `Authorization` (anonymous before sign-in; upgraded to the reader's account at sign-in); rate-limited at the gateway. The caller asserts consent; generation is refused when consent is absent.
Request: selection: string (raw selected text, trimmed, at most six words), clientLookupId: string (idempotency key), platform: android|ios, locale: string, consentModelProcessing: boolean
Response 200: lookupId: string, kind: word|phrase, rawSelection: string, normalisedLemma: string|null, status: served|generating|fallback|denied|empty (a phrase lookup is never `served`; a phrase clip reaches the client by C-008's notice, never on this response), senses: [{ senseLabel: string, partOfSpeech: string, glossPhrase: string, entryId: string|null, clip: { url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean }|null }], notice: string|null, correlationId: string
Errors: 400 (empty or whitespace selection; selection over the six-word phrase limit), 401 (missing or invalid token), 409 (clientLookupId reused with a different selection), 429 (rate limited), 503 (upstream lookup unavailable; retryable)
Body: error responses are `{"code": string, "message": string}`. `notice` carries a clip-availability advisory; `senseLabel` is a plain human label and is not a signal.

### C-002: GET /v1/lookups/{lookupId}
Status: Frozen (revision 2)
Auth: Firebase ID token; the lookup must belong to the caller's token subject (or its anonymous identity)
Request: lookupId: string (path)
Response 200: lookupId: string, kind: word|phrase, rawSelection: string, normalisedLemma: string|null, status: served|generating|fallback|denied|empty (a phrase lookup is never `served`; a phrase clip reaches the client by C-008's notice, never on this response), senses: [{ senseLabel: string, partOfSpeech: string, glossPhrase: string, entryId: string|null, clip: { url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean }|null }], notice: string|null, correlationId: string
Errors: 401 (missing or invalid token), 404 (unknown lookup, or not owned by the caller), 503 (upstream lookup unavailable; retryable)
Body: error responses are `{"code": string, "message": string}`. `notice` carries a clip-availability advisory; `senseLabel` is a plain human label and is not a signal.

### C-003: POST /internal/generation-jobs
Status: Frozen
Auth: internal service identity (service account); never reachable from the client
Request: jobId: string, lookupId: string, kind: word|phrase, lemma: string|null, phrase: string|null (the selection for a phrase job; null for a word job, where the pipeline generates the phrase via C-004), senseLabel: string, partOfSpeech: string, targetDurationSeconds: number (at most 4), modelPin: string ("gemini-omni-1.1-flash"), attempt: integer
Response 202: jobId: string, status: queued|running
Errors: 400 (a phrase job without a phrase, or target duration over four seconds), 401 (not an internal caller), 409 (jobId already enqueued), 503 (queue unavailable)

### C-004: POST /internal/model/phrase
Status: Frozen
Auth: internal service identity (called by the generation pipeline only)
Request: lemma: string|null, partOfSpeech: string, senseHint: string, modelPin: string ("gemini-3.5-flash-lite")
Response 200: phrase: string (seven words or fewer, common words), source: generated|fallback, bestGuess: boolean
Errors: 401 (not an internal caller), 503 (provider unavailable after retries; the caller substitutes the fallback). Refusal, timeout, or unusable output is returned as 200 with source=fallback, never as an error to the reader.

### C-005: POST /internal/model/clip
Status: Frozen
Auth: internal service identity (called by the generation pipeline only)
Request: phrase: string, targetDurationSeconds: number (at most 4), modelPin: string
Response 201: clipId: string, storageKey: string, url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean, synthIdWatermark: boolean
Errors: 400 (target duration over four seconds), 401 (not an internal caller), 422 (provider declined the phrase; no clip produced), 504 (provider timeout), 503 (provider unavailable). The caller maps 422, 504, and 503 to the reader's fallback.

### C-006: GET /internal/generation-jobs/{jobId}
Status: Frozen
Auth: internal service identity (called by the lookup service only)
Request: jobId: string (path)
Response 200: jobId: string, lookupId: string, status: queued|running|succeeded|failed|declined
Errors: 401 (not an internal caller), 404 (unknown job). The lookup service consults this on a C-002 poll so a generation that fails or is declined after enqueue resolves to the reader's fallback.

### C-007: POST /v1/events
Status: Frozen
Auth: Firebase ID token in `Authorization` (anonymous before sign-in); rate-limited at the gateway. Events that describe reading behaviour are suppressed by the client until model-processing consent is granted.
Request: events: [{ eventId: string, name: string (an EVT-### name), occurredAt: string (UTC ISO-8601), anonymousId: string, sessionId: string, platform: android|ios, appVersion: string, locale: string, properties: object }] (batch, at most 50)
Response 202: accepted: integer
Errors: 400 (unknown event name; a property carrying personal data), 401 (missing or invalid token), 429 (rate limited)

### C-008: POST /v1/push-registrations
Status: Frozen (revision 2)
Auth: Firebase ID token in `Authorization` (anonymous before sign-in); rate-limited at the gateway
Request: token: string (the platform push token), platform: android|ios, lookupId: string (the lookup the reader asked to be notified about)
Response 202: registered: boolean
Errors: 400 (missing or unreadable token, unknown platform, unknown lookup), 401 (missing or invalid token), 429 (rate limited). The notification service pushes a clip-ready notice to this token when that lookup's generation completes; the notice's data payload is lookupId: string, clipUrl: string, durationSeconds: number, resolution: "360p", hasAudio: boolean, and the client obtains the clip from it, plays it, and saves it to device history.

### C-009: POST /internal/library/entries
Status: Frozen (revision 1)
Auth: internal service identity; never reachable from the client
Request: entry: { id: string, lemma: string, partOfSpeech: string, senseLabel: string, glossPhrase: string (at most 60), clipAssetId: string, status: active|held|retired, source: seeded|generated, createdAt: string, updatedAt: string }, asset: { id: string, durationSeconds: number (three to four), resolution: "360p", storageKey: string, url: string, hasAudio: boolean, synthIdWatermark: boolean, createdAt: string }
Response 202: entryId: string, status: active|held|retired
Errors: 400 (missing key fields or clip), 401 (not an internal caller), 503 (library unavailable). Upserts by the lemma and sense key.

### C-010: GET /internal/library/entries
Status: Frozen (revision 1)
Auth: internal service identity; never reachable from the client
Request: lemma: string, senseLabel: string, partOfSpeech: string (query)
Response 200: entry: { entryId: string, status: active|held|retired, glossPhrase: string, clip: { url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean } }|null
Errors: 401 (not an internal caller), 503 (library unavailable). Only an `active` entry is served; `held` and `retired` read as null to the lookup, which then regenerates.

### C-011: PATCH /internal/library/entries/{entryId}
Status: Frozen
Auth: internal service identity; never reachable from the client
Request: entryId: string (path), status: active|held|retired
Response 200: entryId: string, status: active|held|retired
Errors: 400 (unknown status), 401 (not an internal caller), 404 (unknown entry), 503 (library unavailable).

### C-012: POST /v1/feedback
Status: Frozen
Auth: Firebase ID token in `Authorization` (anonymous before sign-in); rate-limited at the gateway. The lookup must belong to the caller's token subject.
Request: lookupId: string, rating: helpful|not_helpful|wrong, clientFeedbackId: string (idempotency key)
Response 202: recorded: boolean
Errors: 400 (unknown rating; a lookup with no clip served to the reader), 401 (missing or invalid token), 404 (unknown lookup, or not owned by the caller), 409 (clientFeedbackId reused with a different rating), 429 (rate limited), 503 (feedback store unavailable). One reader's rating of a lookup replaces their earlier rating for the same entry rather than adding to it; a rating on a phrase lookup is recorded against the lookup and never touches the shared library; a rating that crosses the negative-feedback threshold queues the entry for review.

### C-013: POST /v1/reports
Status: Frozen
Auth: Firebase ID token in `Authorization` (anonymous before sign-in); rate-limited at the gateway. The lookup must belong to the caller's token subject.
Request: lookupId: string, reason: wrong_meaning|offensive|low_quality|other, note: string|null (at most 300), clientReportId: string (idempotency key)
Response 202: reportId: string, status: queued
Errors: 400 (unknown reason; a note over 300 characters; a lookup with no clip served to the reader), 401 (missing or invalid token), 404 (unknown lookup, or not owned by the caller), 409 (clientReportId reused with a different report; the same reader has already reported this entry), 429 (rate limited), 503 (feedback store unavailable). A report queues the entry for review and holds it from new readers until it is reviewed; a report on an entry already under review joins the existing queue item; a report on a phrase lookup is recorded against the lookup and has no shared effect.

### C-014: GET /internal/review/queue
Status: Frozen
Auth: operator identity carrying the curator role, multi-factor authenticated; never reachable from the reader client. A caller without the role is refused and the attempt is logged.
Request: reason: wrong_meaning|offensive|low_quality|other|null, state: queued|reviewed|actioned|null, word: string|null, page: integer (query)
Response 200: items: [{ entryId: string, lemma: string, senseLabel: string, reason: string, queuedAt: string, state: queued|reviewed|actioned }], openCount: integer, page: integer, pageCount: integer
Errors: 401 (no operator session), 403 (an operator without the curator role), 503 (review service unavailable). Newest report first, one item per entry however many reports it holds.

### C-015: GET /internal/review/entries/{entryId}
Status: Frozen
Auth: operator identity carrying the curator role, multi-factor authenticated; never reachable from the reader client.
Request: entryId: string (path)
Response 200: entry: { entryId: string, lemma: string, senseLabel: string, glossPhrase: string, status: active|held|retired, clip: { url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean } }, reports: [{ reportId: string, reason: string, note: string|null, createdAt: string }], feedback: [{ rating: helpful|not_helpful|wrong, createdAt: string }], state: queued|reviewed|actioned
Errors: 401 (no operator session), 403 (an operator without the curator role), 404 (unknown entry, or an entry with nothing queued), 503 (review service unavailable).

### C-016: POST /internal/review/entries/{entryId}/actions
Status: Frozen
Auth: operator identity carrying the curator role, multi-factor authenticated; never reachable from the reader client.
Request: action: clear|hold|retire|replace|edit_phrase, phrase: string|null (the new generation phrase, for edit_phrase), notes: string|null (at most 500), expectedState: queued|reviewed|actioned (the state the curator acted on)
Response 200: actionId: string, entryId: string, status: active|held|retired, state: reviewed|actioned
Errors: 400 (unknown action; edit_phrase without a phrase; notes over 500 characters), 401 (no operator session), 403 (an operator without the curator role), 404 (unknown entry), 409 (the entry has already moved since the curator saw it), 503 (review service unavailable). Every action records a ModerationAction; `clear` returns the entry to serving, `hold` withholds it, `retire` stops serving it and the next lookup generates a replacement, `replace` retires it and regenerates, and `edit_phrase` records the new phrase and regenerates from it.
