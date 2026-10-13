"""Generation pipeline: turn a gloss phrase into a short clip, asynchronously.

Consumes the model-serving clip endpoint (C-005) and serves the internal job
endpoint the lookup service calls on a library miss (C-003). A finished word
clip is written to the shared word-clip library; a finished phrase clip is
returned to the requesting device only.
"""
