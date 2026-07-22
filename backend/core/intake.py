"""
Intake AI layer.

Receives invalid cards (ones the deterministic repair engine couldn't fix)
and asks a fast/cheap model to propose a correction.

Each fix is a proposal — the GUI shows it to the user for approval,
exactly like the deterministic fixable cards.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional

from core.engine import Note, _validate_note, ValidationError
from core.provider import Provider, ProviderError
from core.validator import NoteValidationResult


# =========================================
# INTAKE RESULT
# =========================================

@dataclass(frozen=True)
class IntakeResult:
    original: NoteValidationResult      # the invalid card
    proposed_note: Optional[Note]       # AI-proposed fix, or None if AI also failed
    ai_explanation: str                 # what the AI says is wrong / how it fixed it
    ai_succeeded: bool


# =========================================
# SYSTEM PROMPT
# =========================================

_SYSTEM_PROMPT = """\
You are a medical flashcard repair assistant. You receive a broken Anki flashcard \
and must return a corrected version as JSON.

Card formats:
- basic: front question :: back answer
- cloze: sentence with {{c1::hidden term}} pattern
- basic_reverse: front || back (generates cards in both directions)
- basic_extra: front ||| back ||| extra notes

Rules:
1. Only fix the structural problem — do not change medical content.
2. Return ONLY a JSON object with these keys:
   {
     "note_type": "basic" | "cloze" | "basic_reverse" | "basic_extra",
     "front": "...",
     "back": "...",
     "extra": "...",
     "explanation": "one sentence describing what was wrong and what you fixed"
   }
3. If you cannot fix it, set front/back/extra to empty strings and explain why.
4. For cloze: front must contain {{c1::term}}, back can be empty.
5. Never invent medical facts. If you don't understand the content, leave it.
"""


# =========================================
# CARD SERIALISER FOR PROMPT
# =========================================

def _card_to_prompt(result: NoteValidationResult) -> str:
    note = result.note
    lines = [
        f"note_type: {note.note_type}",
        f"front: {note.front or '(empty)'}",
        f"back: {note.back or '(empty)'}",
    ]
    if note.extra:
        lines.append(f"extra: {note.extra}")
    if result.error:
        lines.append(f"error detected: {result.error}")
    return "\n".join(lines)


# =========================================
# SINGLE-CARD FIX
# =========================================

def _fix_one(
    result: NoteValidationResult,
    provider: Provider,
    model: str,
) -> IntakeResult:
    user_prompt = (
        "Fix this broken flashcard:\n\n"
        + _card_to_prompt(result)
    )

    try:
        schema = {
            "note_type": "string",
            "front": "string",
            "back": "string",
            "extra": "string",
            "explanation": "string",
        }
        resp = provider.complete_structured(
            system=_SYSTEM_PROMPT,
            user=user_prompt,
            model=model,
            schema=schema,
            max_tokens=512,
            temperature=0.1,
        )
        data = resp.data
    except ProviderError as e:
        return IntakeResult(
            original=result,
            proposed_note=None,
            ai_explanation=f"AI call failed: {e}",
            ai_succeeded=False,
        )

    note_type = data.get("note_type", "").strip()
    front = data.get("front", "").strip()
    back = data.get("back", "").strip()
    extra = data.get("extra", "").strip()
    explanation = data.get("explanation", "").strip() or "No explanation provided."

    if not front or note_type not in {"basic", "cloze", "basic_reverse", "basic_extra"}:
        return IntakeResult(
            original=result,
            proposed_note=None,
            ai_explanation=explanation or "AI returned an unusable response.",
            ai_succeeded=False,
        )

    proposed = Note(
        note_type=note_type,
        front=front,
        back=back,
        extra=extra,
        tags=result.note.tags,
    )

    # Validate the AI's output — don't trust it blindly
    try:
        _validate_note(proposed)
        succeeded = True
    except ValidationError as ve:
        explanation = f"{explanation}  [Engine rejected AI fix: {ve}]"
        succeeded = False
        proposed = None  # type: ignore

    return IntakeResult(
        original=result,
        proposed_note=proposed if succeeded else None,
        ai_explanation=explanation,
        ai_succeeded=succeeded,
    )


# =========================================
# BATCH ENTRY POINT
# =========================================

def run_intake(
    invalid_results: List[NoteValidationResult],
    provider: Provider,
    model: str,
) -> List[IntakeResult]:
    """
    For each invalid card, ask the AI to propose a fix.
    Only processes cards with status == 'invalid'.
    """
    return [
        _fix_one(r, provider, model)
        for r in invalid_results
        if r.status == "invalid"
    ]
