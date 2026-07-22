from __future__ import annotations

import re
from dataclasses import dataclass
from typing import List, Optional

from core.engine import Note, ValidationError, _validate_note, CLOZE_PATTERN


# =========================================
# VALIDATION RESULT
# =========================================

@dataclass(frozen=True)
class NoteValidationResult:
    note: Note
    status: str                      # "valid" | "fixable" | "invalid"
    error: Optional[str]             # what is wrong
    fixed_note: Optional[Note]       # proposed repair (if fixable)
    fix_description: Optional[str]   # plain-English description of the fix
    preview: str                     # short display label for the card


# =========================================
# REPAIR LOGIC
# =========================================

def _preview(note: Note) -> str:
    text = note.front or note.back
    return text[:80] + "…" if len(text) > 80 else text


_PARTIAL_CLOZE = re.compile(r"\{\{c\d+::")


def _try_fix(note: Note) -> Optional[tuple[Note, str]]:
    """
    Attempt to produce a valid repaired note.
    Returns (fixed_note, description) or None if unfixable.
    """

    if note.note_type == "cloze":
        # --- Cloze unbalanced braces — try closing open {{ first ---
        open_count = note.front.count("{{")
        close_count = note.front.count("}}")
        if open_count > close_count and _PARTIAL_CLOZE.search(note.front):
            diff = open_count - close_count
            fixed_front = note.front + "}}" * diff
            candidate = Note(
                note_type="cloze",
                front=fixed_front,
                back=note.back,
                extra=note.extra,
                tags=note.tags,
            )
            try:
                _validate_note(candidate)
                return candidate, f"Closed {diff} unclosed {{{{…}}}} brace(s)"
            except ValidationError:
                pass

        # --- Cloze missing wrapper entirely ---
        if not CLOZE_PATTERN.search(note.front) and note.front.strip():
            fixed = Note(
                note_type="cloze",
                front=f"{{{{c1::{note.front.strip()}}}}}",
                back=note.back,
                extra=note.extra,
                tags=note.tags,
            )
            return fixed, 'Wrapped entire front in {{c1::…}}'

    # --- Non-cloze has cloze syntax — convert to cloze ---
    if note.note_type != "cloze":
        text = note.front + " " + note.back
        if CLOZE_PATTERN.search(text):
            cloze_text = note.front if CLOZE_PATTERN.search(note.front) else note.back
            candidate = Note(
                note_type="cloze",
                front=cloze_text.strip(),
                back="",
                extra=note.extra,
                tags=note.tags,
            )
            try:
                _validate_note(candidate)
                return candidate, "Detected cloze syntax — converted note type to cloze"
            except ValidationError:
                pass

    # --- Basic: empty front but non-empty back — swap (only if back is also non-empty after swap) ---
    if note.note_type in {"basic", "basic_reverse", "basic_extra"}:
        if not note.front.strip() and note.back.strip():
            candidate = Note(
                note_type=note.note_type,
                front=note.back.strip(),
                back="(no answer provided)",
                extra=note.extra,
                tags=note.tags,
            )
            try:
                _validate_note(candidate)
                return candidate, "Front was empty — moved content to front, back needs filling"
            except ValidationError:
                pass

    return None


# =========================================
# SPECIFIC ERROR MESSAGES
# =========================================

def _explain_error(note: Note) -> str:
    if note.note_type == "cloze":
        if not CLOZE_PATTERN.search(note.front):
            return (
                "Cloze card has no {{c1::…}} pattern. "
                "Wrap the key term like: The {{c1::heart}} pumps blood."
            )
        if note.front.count("{{") != note.front.count("}}"):
            return (
                "Cloze card has unbalanced braces. "
                f"Found {note.front.count('{{')} opening and "
                f"{note.front.count('}}')} closing braces."
            )

    if note.note_type in {"basic", "basic_reverse", "basic_extra"}:
        if not note.front.strip() and not note.back.strip():
            return "Card has no content — both front and back are empty."
        if not note.front.strip():
            return "Front field is empty. Add a question or term to the front."
        if not note.back.strip():
            return "Back field is empty. Add an answer or definition to the back."

    if note.note_type not in {"cloze", "basic", "basic_reverse", "basic_extra"}:
        return (
            f'Unrecognized note type "{note.note_type}". '
            "Use :: for basic, || for reverse, ||| for extra, or {{c1::…}} for cloze."
        )

    return "Validation failed for an unknown reason. Check the card format."


# =========================================
# PUBLIC ENTRY POINT
# =========================================

def validate_notes(notes: List[Note]) -> List[NoteValidationResult]:
    results: List[NoteValidationResult] = []

    for note in notes:
        try:
            _validate_note(note)
            results.append(NoteValidationResult(
                note=note,
                status="valid",
                error=None,
                fixed_note=None,
                fix_description=None,
                preview=_preview(note),
            ))
        except ValidationError:
            fix = _try_fix(note)
            if fix:
                fixed_note, fix_description = fix
                results.append(NoteValidationResult(
                    note=note,
                    status="fixable",
                    error=_explain_error(note),
                    fixed_note=fixed_note,
                    fix_description=fix_description,
                    preview=_preview(note),
                ))
            else:
                results.append(NoteValidationResult(
                    note=note,
                    status="invalid",
                    error=_explain_error(note),
                    fixed_note=None,
                    fix_description=None,
                    preview=_preview(note),
                ))

    return results


def summary(results: List[NoteValidationResult]) -> dict:
    valid = sum(1 for r in results if r.status == "valid")
    fixable = sum(1 for r in results if r.status == "fixable")
    invalid = sum(1 for r in results if r.status == "invalid")
    return {"valid": valid, "fixable": fixable, "invalid": invalid, "total": len(results)}
