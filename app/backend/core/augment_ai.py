"""
Augmentation AI layer.

For each valid card, asks a high-quality model to generate structured
medical enrichment (mechanism, clinical context, high-yield points, exam trap).
Returns ExpansionPayload objects that the deterministic augmentation engine
in augmentation.py applies to the notes.

This layer is pure: it does not modify notes. It only produces payloads.
The caller decides whether to apply them (after user preview and approval).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Tuple

from core.augmentation import ExpansionPayload, _note_identity
from core.engine import Note
from core.provider import Provider, ProviderError


# =========================================
# RESULT TYPE
# =========================================

@dataclass(frozen=True)
class AugmentationProposal:
    note: Note
    identity: str               # SHA key into payload_map
    payload: Optional[ExpansionPayload]
    succeeded: bool
    error: str                  # empty string if succeeded


# =========================================
# SYSTEM PROMPT
# =========================================

_SYSTEM_PROMPT = """\
You are a medical education expert helping doctors and students build \
high-yield Anki flashcards. Given a flashcard, you will return a structured \
JSON object enriching it with deep clinical context.

Rules:
1. Only expand on what the card already says — do not contradict or invent facts.
2. Be concise. Each field should be 1–3 sentences or bullet points max.
3. high_yield_points must be a JSON array of strings (2–4 points).
4. normal_vs_pathologic is optional — only include if directly relevant.
5. Write at the level of a senior medical student or resident.
6. Return ONLY the JSON object. No prose, no markdown fences.

Required JSON schema:
{
  "primary_concept": "one-line distillation of the core concept",
  "mechanism": "pathophysiology or mechanism of action",
  "high_yield_points": ["point 1", "point 2", "point 3"],
  "clinical_context": "how this presents or is used clinically",
  "exam_trap": "common mistake, confusing fact, or distinguishing feature",
  "normal_vs_pathologic": "compare normal to pathologic state (optional, omit if not relevant)"
}
"""


# =========================================
# CARD → PROMPT
# =========================================

def _card_to_prompt(note: Note) -> str:
    parts = [f"Card type: {note.note_type}"]
    if note.front:
        parts.append(f"Front: {note.front}")
    if note.back:
        parts.append(f"Back: {note.back}")
    if note.extra:
        parts.append(f"Extra: {note.extra}")
    if note.tags:
        parts.append(f"Tags: {', '.join(note.tags)}")
    return "\n".join(parts)


# =========================================
# SINGLE CARD AUGMENTATION
# =========================================

def _augment_one(note: Note, provider: Provider, model: str) -> AugmentationProposal:
    identity = _note_identity(note)
    user_prompt = "Enrich this flashcard:\n\n" + _card_to_prompt(note)

    schema = {
        "primary_concept": "string",
        "mechanism": "string",
        "high_yield_points": ["string"],
        "clinical_context": "string",
        "exam_trap": "string",
        "normal_vs_pathologic": "string (optional)",
    }

    try:
        resp = provider.complete_structured(
            system=_SYSTEM_PROMPT,
            user=user_prompt,
            model=model,
            schema=schema,
            max_tokens=700,
            temperature=0.2,
        )
        data = resp.data
    except ProviderError as e:
        return AugmentationProposal(
            note=note, identity=identity,
            payload=None, succeeded=False, error=str(e),
        )

    # Validate required fields
    required = ("primary_concept", "mechanism", "high_yield_points", "clinical_context", "exam_trap")
    for field in required:
        if not data.get(field):
            return AugmentationProposal(
                note=note, identity=identity,
                payload=None, succeeded=False,
                error=f"AI response missing field: {field}",
            )

    hyp = data["high_yield_points"]
    if not isinstance(hyp, list) or not hyp:
        return AugmentationProposal(
            note=note, identity=identity,
            payload=None, succeeded=False,
            error="high_yield_points must be a non-empty list",
        )

    nvp = data.get("normal_vs_pathologic") or None
    if nvp and not isinstance(nvp, str):
        nvp = None

    payload = ExpansionPayload(
        primary_concept=str(data["primary_concept"]).strip(),
        mechanism=str(data["mechanism"]).strip(),
        high_yield_points=tuple(str(p).strip() for p in hyp),
        clinical_context=str(data["clinical_context"]).strip(),
        exam_trap=str(data["exam_trap"]).strip(),
        normal_vs_pathologic=nvp.strip() if nvp else None,
    )

    return AugmentationProposal(
        note=note, identity=identity,
        payload=payload, succeeded=True, error="",
    )


# =========================================
# BATCH ENTRY POINT
# =========================================

def generate_augmentation_proposals(
    notes: List[Note],
    provider: Provider,
    model: str,
    progress_callback: Optional[Callable[[int, int], None]] = None,
) -> List[AugmentationProposal]:
    """
    For each note, ask the AI to generate an ExpansionPayload.
    Returns one proposal per note (even if AI failed for some).
    progress_callback(done, total) is called after each card if provided.
    """
    proposals: List[AugmentationProposal] = []
    total = len(notes)

    for i, note in enumerate(notes):
        proposal = _augment_one(note, provider, model)
        proposals.append(proposal)
        if progress_callback:
            progress_callback(i + 1, total)

    return proposals


# =========================================
# PAYLOAD MAP BUILDER
# =========================================

def build_payload_map(
    proposals: List[AugmentationProposal],
    accepted_indices: set,
) -> Dict[str, ExpansionPayload]:
    """
    Build the payload_map dict expected by augment_notes().
    Only includes proposals where the user accepted them.
    """
    payload_map: Dict[str, ExpansionPayload] = {}
    for i, proposal in enumerate(proposals):
        if i in accepted_indices and proposal.payload is not None:
            payload_map[proposal.identity] = proposal.payload
    return payload_map
