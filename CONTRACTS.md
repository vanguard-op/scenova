# CONTRACTS — Scenova

Frozen interfaces between layers. The lead is the only writer. A change after `Frozen` is a
change request: mark it `Frozen (revision N)` and re-dispatch both sides.

### C-001: POST /v1/lookups
Status: Frozen
Auth: Firebase ID token in `Authorization` (anonymous before sign-in; upgraded to the reader's account at sign-in); rate-limited at the gateway. The caller asserts consent; generation is refused when consent is absent.
Request: selection: string (raw selected text, trimmed, at most six words), clientLookupId: string (idempotency key), platform: android|ios, locale: string, consentModelProcessing: boolean
Response 200: lookupId: string, kind: word|phrase, rawSelection: string, normalisedLemma: string|null, status: served|generating|fallback|denied|empty, senses: [{ senseLabel: string, partOfSpeech: string, glossPhrase: string, entryId: string|null, clip: { url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean }|null }], notice: string|null, correlationId: string
Errors: 400 (empty or whitespace selection; selection over the six-word phrase limit), 401 (missing or invalid token), 409 (clientLookupId reused with a different selection), 429 (rate limited)

### C-002: GET /v1/lookups/{lookupId}
Status: Frozen
Auth: Firebase ID token; the lookup must belong to the caller's token subject (or its anonymous identity)
Request: lookupId: string (path)
Response 200: lookupId: string, kind: word|phrase, rawSelection: string, normalisedLemma: string|null, status: served|generating|fallback|denied|empty, senses: [{ senseLabel: string, partOfSpeech: string, glossPhrase: string, entryId: string|null, clip: { url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean }|null }], notice: string|null, correlationId: string
Errors: 401 (missing or invalid token), 404 (unknown lookup, or not owned by the caller)

### C-003: POST /internal/generation-jobs
Status: Frozen
Auth: internal service identity (service account); never reachable from the client
Request: jobId: string, lookupId: string, kind: word|phrase, lemma: string|null, phrase: string, senseLabel: string, partOfSpeech: string, targetDurationSeconds: number (at most 4), modelPin: string ("gemini-omni-1.1-flash"), attempt: integer
Response 202: jobId: string, status: queued|running
Errors: 400 (missing phrase, or target duration over four seconds), 401 (not an internal caller), 409 (jobId already enqueued), 503 (queue unavailable)

### C-004: POST /internal/model/phrase
Status: Frozen
Auth: internal service identity (called by the generation pipeline only)
Request: lemma: string|null, partOfSpeech: string, senseHint: string, modelPin: string
Response 200: phrase: string (fewer than seven words, common words), source: generated|fallback, bestGuess: boolean
Errors: 401 (not an internal caller), 503 (provider unavailable after retries; the caller substitutes the fallback). Refusal, timeout, or unusable output is returned as 200 with source=fallback, never as an error to the reader.

### C-005: POST /internal/model/clip
Status: Frozen
Auth: internal service identity (called by the generation pipeline only)
Request: phrase: string, targetDurationSeconds: number (at most 4), modelPin: string
Response 201: clipId: string, storageKey: string, url: string, durationSeconds: number, resolution: "360p", hasAudio: boolean, synthIdWatermark: boolean
Errors: 401 (not an internal caller), 422 (provider declined the phrase; no clip produced), 504 (provider timeout), 503 (provider unavailable). The caller maps 422, 504, and 503 to the reader's fallback.
