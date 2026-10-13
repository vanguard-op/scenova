"""API gateway: the single authenticated entry point for client requests.

Owns authentication, rate limiting, and request validation for the client
contracts, then routes to the lookup service. Generation and entitlement checks
are added behind it as those components ship.
"""
