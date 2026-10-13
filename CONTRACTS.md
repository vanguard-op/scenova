# CONTRACTS — Scenova

Frozen interfaces between layers. The lead is the only writer. A change after `Frozen` is a
change request: mark it `Frozen (revision N)` and re-dispatch both sides.

### C-001: POST /v1/lookups
Status: Frozen (revision 1)
Auth: Firebase ID token in `Authorization` (anonymous before sign-in; upgraded to the reader's account at sign-in); rate-limited at the gateway. The caller asserts consent; generation is refused when consent is absent.
Request: selection: string (raw selected text, trimmed, at most six words), clientLookupId: string (idempotency key), platform: android|ios, locale: string, consentModelProcessing: boolean
Response 200: lookupId: string, kind: word|phrase, rawSelection: string, normalisedLemma: string|null, status: served|generating|fallback|denied|empty, senses: [{ senseLabel: string, partOfSpeech: string, glossPhrase: string, entryId: string|null, clip: { url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean }|null }], notice: string|null, correlationId: string
Errors: 400 (empty or whitespace selection; selection over the six-word phrase limit), 401 (missing or invalid token), 409 (clientLookupId reused with a different selection), 429 (rate limited), 503 (upstream lookup unavailable; retryable)
Body: error responses are `{"code": string, "message": string}`. `notice` carries any reader-facing advisory, including the best-guess note; `senseLabel` is a human label and is not a signal.

### C-002: GET /v1/lookups/{lookupId}
Status: Frozen (revision 1)
Auth: Firebase ID token; the lookup must belong to the caller's token subject (or its anonymous identity)
Request: lookupId: string (path)
Response 200: lookupId: string, kind: word|phrase, rawSelection: string, normalisedLemma: string|null, status: served|generating|fallback|denied|empty, senses: [{ senseLabel: string, partOfSpeech: string, glossPhrase: string, entryId: string|null, clip: { url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean }|null }], notice: string|null, correlationId: string
Errors: 401 (missing or invalid token), 404 (unknown lookup, or not owned by the caller), 503 (upstream lookup unavailable; retryable)
Body: error responses are `{"code": string, "message": string}`. `notice` carries any reader-facing advisory, including the best-guess note; `senseLabel` is a human label and is not a signal.

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
