from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Tuple, Set
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
    decks: Tuple[genanki.Deck, ...]
    total_notes: int
    total_cards: int
    deck_id: int
    model_ids_used: Tuple[int, ...]
    warnings: Tuple[str, ...]
    subdeck_counts: Tuple[Tuple[str, int], ...]


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
            # Cloze with extra info:  {{c1::term}} sentence ||| extra shown after flip
            if "|||" in line:
                cloze_part, extra_part = line.split("|||", 1)
                cloze_part = cloze_part.strip()
                if _braces_balanced(cloze_part):
                    notes.append(Note("cloze", cloze_part, "", extra_part.strip()))
                else:
                    cloze_buffer = [cloze_part]
                    collecting_cloze = True
            elif _braces_balanced(line):
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
# SUBDECK ROUTING
# =========================

def _taxonomy_tags(note: Note) -> List[str]:
    return [t for t in note.tags if "::" in t]


def _subdeck_name(note: Note, root: str) -> str:
    taxonomy = _taxonomy_tags(note)
    if len(taxonomy) == 0:
        return f"{root}::General"
    elif len(taxonomy) == 1:
        return f"{root}::{taxonomy[0]}"
    else:
        return f"{root}::Integrated"


# =========================
# ENGINE ENTRY
# =========================

def build_deck(notes: List[Note], deck_name: str, strict_repair: bool) -> BuildResult:
    root_id = _deck_id(deck_name)
    root_deck = genanki.Deck(root_id, deck_name)

    models = _create_models()
    used_model_ids: Set[int] = set()
    warnings: List[str] = []
    total_cards = 0
    accepted_notes = 0

    subdecks: Dict[str, genanki.Deck] = {}

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
        elif note.note_type in {"basic", "basic_reverse"}:
            fields = [note.front, note.back]
        else:
            fields = [note.front, note.back, note.extra]

        genanki_note = genanki.Note(model=model, fields=fields, tags=list(note.tags))

        subdeck_name = _subdeck_name(note, deck_name)
        if subdeck_name not in subdecks:
            subdecks[subdeck_name] = genanki.Deck(_deck_id(subdeck_name), subdeck_name)

        subdecks[subdeck_name].add_note(genanki_note)

        total_cards += len(model.templates)
        accepted_notes += 1

    # Root deck first, then subdecks sorted by name for determinism
    all_decks = tuple(
        [root_deck] + [subdecks[k] for k in sorted(subdecks.keys())]
    )

    subdeck_counts = tuple(
        (k, len(subdecks[k].notes)) for k in sorted(subdecks.keys())
    )

    return BuildResult(
        decks=all_decks,
        total_notes=accepted_notes,
        total_cards=total_cards,
        deck_id=root_id,
        model_ids_used=tuple(sorted(used_model_ids)),
        warnings=tuple(warnings),
        subdeck_counts=subdeck_counts,
    )