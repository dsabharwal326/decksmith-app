from __future__ import annotations

from typing import List, Optional, Dict, Tuple

from core.engine import Note, build_deck
from core.augmentation import (
    augment_notes,
    ExpansionMode,
    ExpansionPayload,
    AugmentationMetadata,
)


def build_with_optional_augmentation(
    notes: List[Note],
    deck_name: str,
    strict_repair: bool,
    *,
    payload_map: Optional[Dict[str, ExpansionPayload]] = None,
    expansion_mode: Optional[ExpansionMode] = None,
    provider: Optional[str] = None,
    model: Optional[str] = None,
    prompt_hash: Optional[str] = None,
    dictionary_sha: Optional[str] = None,
) -> Tuple:
    """
    Deterministic orchestration wrapper.

    - Engine remains unaware of augmentation.
    - Augmentation fully optional.
    - No side effects.
    - No config logic.
    """

    metadata: Optional[AugmentationMetadata] = None

    working_notes = notes

    if payload_map is not None and expansion_mode is not None:
        working_notes, metadata = augment_notes(
            notes=notes,
            payload_map=payload_map,
            mode=expansion_mode,
            provider=provider,
            model=model,
            prompt_hash=prompt_hash,
            dictionary_sha=dictionary_sha,
        )

    build_result = build_deck(
        notes=working_notes,
        deck_name=deck_name,
        strict_repair=strict_repair,
    )

    return build_result, metadata