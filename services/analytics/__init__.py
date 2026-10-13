"""Analytics event intake: the product event store behind the taxonomy.

Records the events in `analytics.md` "Event Taxonomy" — client events and the
generation pipeline's service events — and carries the governance rules of
"Analytics Data Governance": no personal data, a fourteen-month retention, and
deletion propagation for a data-subject request.
"""
