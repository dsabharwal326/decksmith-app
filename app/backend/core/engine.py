from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Tuple, Set
import hashlib
import re
import genanki


# =========================
# CONSTANTS
# =========================

ALLOWED_NOTE_TYPES = {
    "cloze",
    "basic",
    "basic_reverse",
    "basic_extra",
}

CLOZE_PATTERN = re.compile(r"\{\{c\d+::.+?\}\}")


# =========================
# CANONICAL NOTE MODEL
# =========================

@dataclass(frozen=True)
class Note:
    note_type: str
    front: str
    back: str
    extra: str = ""
    tags: Tuple[str, ...] = field(default_factory=tuple)

    def __post_init__(self):
        object.__setattr__(self, "tags", tuple(sorted(self.tags)))


# =========================
# BUILD RESULT
# =========================

@dataclass(frozen=True)
class BuildResult:
    deck: genanki.Deck
    total_notes: int
    total_cards: int
    deck_id: int
    model_ids_used: Tuple[int, ...]
    warnings: Tuple[str, ...]


# =========================
# DETERMINISTIC ID HELPERS
# =========================

def _stable_hash_int(value: str) -> int:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
    return int(digest[:12], 16)


def _deck_id(deck_name: str) -> int:
    return _stable_hash_int(f"deck::{deck_name}")


def _model_id(name: str) -> int:
    return _stable_hash_int(f"model::{name}")


# =========================
# VALIDATION
# =========================

class ValidationError(Exception):
    pass


def _contains_cloze(text: str) -> bool:
    return bool(CLOZE_PATTERN.search(text))


def _braces_balanced(text: str) -> bool:
    return text.count("{{") == text.count("}}")


def _validate_note(note: Note) -> None:
    if note.note_type not in ALLOWED_NOTE_TYPES:
        raise ValidationError(f"Invalid note_type: {note.note_type}")

    if note.note_type == "cloze":
        if not _contains_cloze(note.front):
            raise ValidationError("Cloze note missing cloze pattern")
        if not _braces_balanced(note.front):
            raise ValidationError("Cloze note has unbalanced braces")
    else:
        if _contains_cloze(note.front) or _contains_cloze(note.back):
            raise ValidationError("Non-cloze note contains cloze pattern")

    if note.note_type in {"basic", "basic_reverse", "basic_extra"}:
        if not note.front.strip():
            raise ValidationError("Front field empty")
        if not note.back.strip():
            raise ValidationError("Back field empty")


# =========================
# PARSER
# =========================

def parse_text_to_notes(text: str, strict_repair: bool) -> List[Note]:
    notes: List[Note] = []

    lines = text.splitlines()
    cloze_buffer: List[str] = []
    collecting_cloze = False

    for raw_line in lines:
        line = raw_line.rstrip()

        if not line.strip():
            cloze_buffer.clear()
            collecting_cloze = False
            continue

        if strict_repair:
            line = line.strip()

        if collecting_cloze:
            cloze_buffer.append(line)
            combined = " ".join(cloze_buffer)

            if _braces_balanced(combined):
                notes.append(Note("cloze", combined, ""))
                cloze_buffer.clear()
                collecting_cloze = False
            continue

        if _contains_cloze(line):
            if _braces_balanced(line):
                notes.append(Note("cloze", line, ""))
            else:
                cloze_buffer = [line]
                collecting_cloze = True
            continue

        if "|||" in line:
            parts = line.split("|||", 2)
            if len(parts) == 3:
                notes.append(
                    Note("basic_extra", parts[0].strip(), parts[1].strip(), parts[2].strip())
                )
            continue

        if "||" in line:
            parts = line.split("||", 1)
            if len(parts) == 2:
                notes.append(
                    Note("basic_reverse", parts[0].strip(), parts[1].strip())
                )
            continue

        if "::" in line:
            parts = line.split("::", 1)
            if len(parts) == 2:
                notes.append(
                    Note("basic", parts[0].strip(), parts[1].strip())
                )
            continue

    return notes


# =========================
# MODEL FACTORY
# =========================

def _create_models():
    return {
        "cloze": genanki.Model(
            _model_id("cloze"),
            "Cloze",
            fields=[{"name": "Text"}, {"name": "Extra"}],
            templates=[{
                "name": "Cloze Card",
                "qfmt": "{{cloze:Text}}",
                "afmt": "{{cloze:Text}}<br>{{Extra}}",
            }],
            model_type=genanki.Model.CLOZE,
        ),
        "basic": genanki.Model(
            _model_id("basic"),
            "Basic",
            fields=[{"name": "Front"}, {"name": "Back"}],
            templates=[{
                "name": "Card 1",
                "qfmt": "{{Front}}",
                "afmt": "{{Front}}<hr id=\"answer\">{{Back}}",
            }],
        ),
        "basic_reverse": genanki.Model(
            _model_id("basic_reverse"),
            "Basic (Reversed)",
            fields=[{"name": "Front"}, {"name": "Back"}],
            templates=[
                {"name": "Card 1", "qfmt": "{{Front}}", "afmt": "{{Front}}<hr id=\"answer\">{{Back}}"},
                {"name": "Card 2", "qfmt": "{{Back}}", "afmt": "{{Back}}<hr id=\"answer\">{{Front}}"},
            ],
        ),
        "basic_extra": genanki.Model(
            _model_id("basic_extra"),
            "Basic (Extra)",
            fields=[{"name": "Front"}, {"name": "Back"}, {"name": "Extra"}],
            templates=[{
                "name": "Card 1",
                "qfmt": "{{Front}}",
                "afmt": "{{Front}}<hr id=\"answer\">{{Back}}<br>{{Extra}}",
            }],
        ),
    }


# =========================
# ENGINE ENTRY
# =========================

def build_deck(notes: List[Note], deck_name: str, strict_repair: bool) -> BuildResult:
    deck_id = _deck_id(deck_name)
    deck = genanki.Deck(deck_id, deck_name)

    models = _create_models()
    used_model_ids: Set[int] = set()
    warnings = []
    total_cards = 0
    accepted_notes = 0

    for note in notes:
        try:
            _validate_note(note)
        except ValidationError as e:
            if strict_repair:
                raise
            warnings.append(str(e))
            continue

        model = models[note.note_type]
        used_model_ids.add(model.model_id)

        if note.note_type == "cloze":
            fields = [note.front, note.extra]
        elif note.note_type == "basic":
            fields = [note.front, note.back]
        elif note.note_type == "basic_reverse":
            fields = [note.front, note.back]
        else:
            fields = [note.front, note.back, note.extra]

        deck.add_note(genanki.Note(model=model, fields=fields, tags=list(note.tags)))

        total_cards += len(model.templates)
        accepted_notes += 1

    return BuildResult(
        deck=deck,
        total_notes=accepted_notes,
        total_cards=total_cards,
        deck_id=deck_id,
        model_ids_used=tuple(sorted(used_model_ids)),
        warnings=tuple(warnings),
    )