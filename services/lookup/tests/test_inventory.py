"""Lemma and sense inventory tests (FEAT-003)."""

from __future__ import annotations

from lookup.app.inventory import ResolvedWord, build_default_inventory


def _resolve(token: str) -> ResolvedWord:
    resolved = build_default_inventory().resolve(token)
    assert resolved is not None
    return resolved


def test_inflected_forms_resolve_to_the_base_form() -> None:
    assert _resolve("coming").lemma == "come"
    assert _resolve("came").lemma == "come"
    assert _resolve("Come").lemma == "come"


def test_related_forms_share_a_stem() -> None:
    assert _resolve("education").lemma == "educate"
    assert _resolve("educate").lemma == "educate"


def test_a_word_with_several_common_senses_returns_them_all() -> None:
    assert len(_resolve("bank").senses) >= 2
    assert len(_resolve("light").senses) >= 2


def test_an_unknown_word_returns_none() -> None:
    assert build_default_inventory().resolve("zephyr") is None
