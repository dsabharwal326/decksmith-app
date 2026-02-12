import genanki
import hashlib
from dataclasses import dataclass
from typing import List, Set


# =========================================
# Canonical Note
# =========================================

@dataclass(frozen=True)
class Note:
    note_type: str
    front: str = ""
    back: str = ""
    extra: str = ""


# =========================================
# Deterministic Hash
# =========================================

def _stable_int_hash(text: str) -> int:
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return int(digest[:8], 16)


# =========================================
# Models
# =========================================

CLOZE_MODEL = genanki.Model(
    1607392319,
    "Cloze",
    fields=[{"name": "Text"}],
    templates=[{
        "name": "Cloze Card",
        "qfmt": "{{cloze:Text}}",
        "afmt": "{{cloze:Text}}",
    }],
    model_type=genanki.Model.CLOZE,
)

BASIC_MODEL = genanki.Model(
    1000000001,
    "Basic",
    fields=[{"name": "Front"}, {"name": "Back"}],
    templates=[{
        "name": "Card 1",
        "qfmt": "{{Front}}",
        "afmt": "{{FrontSide}}<hr id='answer'>{{Back}}",
    }],
)

BASIC_REVERSE_MODEL = genanki.Model(
    1000000002,
    "Basic (and reversed)",
    fields=[{"name": "Front"}, {"name": "Back"}],
    templates=[
        {
            "name": "Card 1",
            "qfmt": "{{Front}}",
            "afmt": "{{FrontSide}}<hr id='answer'>{{Back}}",
        },
        {
            "name": "Card 2",
            "qfmt": "{{Back}}",
            "afmt": "{{FrontSide}}<hr id='answer'>{{Front}}",
        },
    ],
)

BASIC_EXTRA_MODEL = genanki.Model(
    1000000003,
    "Basic (with Extra)",
    fields=[{"name": "Front"}, {"name": "Back"}, {"name": "Extra"}],
    templates=[{
        "name": "Card 1",
        "qfmt": "{{Front}}",
        "afmt": "{{FrontSide}}<hr id='answer'>{{Back}}<br><br>{{Extra}}",
    }],
)


# =========================================
# Parser
# =========================================

class Parser:

    @staticmethod
    def parse(text: str) -> List[Note]:
        lines = text.split("\n")
        notes = []
        errors = []

        for idx, raw in enumerate(lines, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                notes.append(Parser._detect(line))
            except Exception as e:
                errors.append(f"Line {idx}: {e}")

        if errors:
            raise ValueError("\n".join(errors))

        return notes

    @staticmethod
    def _detect(line: str) -> Note:

        if "{{c" in line:
            return Note("cloze", front=line)

        if "|||" in line:
            parts = line.split("|||")
            if len(parts) != 3:
                raise ValueError("Invalid basic+extra format")
            return Note("basic_extra", parts[0].strip(), parts[1].strip(), parts[2].strip())

        if "||" in line:
            parts = line.split("||")
            if len(parts) != 2:
                raise ValueError("Invalid basic_reverse format")
            return Note("basic_reverse", parts[0].strip(), parts[1].strip())

        if "::" in line:
            parts = line.split("::")
            if len(parts) != 2:
                raise ValueError("Invalid basic format")
            return Note("basic", parts[0].strip(), parts[1].strip())

        raise ValueError("Unrecognized format")


# =========================================
# Transformer
# =========================================

class Transformer:

    @staticmethod
    def to_genanki(note: Note):

        if note.note_type == "cloze":
            return genanki.Note(model=CLOZE_MODEL, fields=[note.front])

        if note.note_type == "basic":
            return genanki.Note(model=BASIC_MODEL, fields=[note.front, note.back])

        if note.note_type == "basic_reverse":
            return genanki.Note(model=BASIC_REVERSE_MODEL, fields=[note.front, note.back])

        if note.note_type == "basic_extra":
            return genanki.Note(model=BASIC_EXTRA_MODEL, fields=[note.front, note.back, note.extra])

        raise ValueError("Unsupported note type")


# =========================================
# DeckUnit (Atomic Deck Container)
# =========================================

class DeckUnit:

    def __init__(self, name: str):
        self.name = name
        self.deck_id = _stable_int_hash(name)
        self.deck = genanki.Deck(self.deck_id, name)
        self._seen: Set[Note] = set()

    def add_notes(self, notes: List[Note]):
        for note in notes:
            if note in self._seen:
                continue
            self._seen.add(note)
            self.deck.add_note(Transformer.to_genanki(note))


# =========================================
# DeckMerger (Phase 2)
# =========================================

class DeckMerger:

    def __init__(self, name: str):
        self.master = DeckUnit(name)

    def add_deck_unit(self, deck_unit: DeckUnit):
        for note in deck_unit._seen:
            self.master.add_notes([note])

    def export(self, output_path: str):
        genanki.Package(self.master.deck).write_to_file(output_path)


# =========================================
# Public API
# =========================================

def build_deck_from_text(text: str, deck_name: str, output_path: str):

    notes = Parser.parse(text)
    if not notes:
        raise ValueError("No valid notes found.")

    deck = DeckUnit(deck_name)
    deck.add_notes(notes)

    genanki.Package(deck.deck).write_to_file(output_path)


def combine_multiple_texts(text_blocks: List[str], deck_name: str, output_path: str):

    merger = DeckMerger(deck_name)

    for idx, text in enumerate(text_blocks):
        notes = Parser.parse(text)
        unit = DeckUnit(f"{deck_name}_{idx}")
        unit.add_notes(notes)
        merger.add_deck_unit(unit)

    merger.export(output_path)
