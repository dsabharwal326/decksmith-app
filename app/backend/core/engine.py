import genanki
import hashlib
import re
from dataclasses import dataclass
from typing import List, Set, Tuple
from pathlib import Path


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
# Optimization Report
# =========================================

@dataclass
class OptimizationReport:
    total_input: int = 0
    total_output: int = 0
    duplicates_removed: int = 0
    empty_removed: int = 0
    cloze_reindexed: int = 0
    invalid_lines: int = 0

    def merge(self, other: "OptimizationReport"):
        self.total_input += other.total_input
        self.total_output += other.total_output
        self.duplicates_removed += other.duplicates_removed
        self.empty_removed += other.empty_removed
        self.cloze_reindexed += other.cloze_reindexed
        self.invalid_lines += other.invalid_lines


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
    def parse(text: str, strict: bool = True) -> Tuple[List[Note], int]:
        lines = text.split("\n")
        notes = []
        invalid_count = 0

        for raw in lines:
            line = raw.strip()
            if not line:
                continue

            try:
                notes.append(Parser._detect(line))
            except Exception:
                if strict:
                    raise
                invalid_count += 1

        return notes, invalid_count

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
# Optimizer
# =========================================

class DeckOptimizer:

    @staticmethod
    def optimize(notes: List[Note]) -> Tuple[List[Note], OptimizationReport]:

        total_input = len(notes)
        optimized = []
        seen: Set[str] = set()

        duplicates_removed = 0
        empty_removed = 0
        cloze_reindexed = 0

        for note in notes:
            if DeckOptimizer._is_empty(note):
                empty_removed += 1
                continue

            key = f"{note.note_type}|{note.front}|{note.back}|{note.extra}"

            if key in seen:
                duplicates_removed += 1
                continue

            seen.add(key)

            if note.note_type == "cloze":
                note, changed = DeckOptimizer._normalize_cloze_indices(note)
                if changed:
                    cloze_reindexed += 1

            optimized.append(note)

        report = OptimizationReport(
            total_input=total_input,
            total_output=len(optimized),
            duplicates_removed=duplicates_removed,
            empty_removed=empty_removed,
            cloze_reindexed=cloze_reindexed,
        )

        return optimized, report

    @staticmethod
    def _is_empty(note: Note) -> bool:
        if note.note_type == "cloze":
            return not note.front
        if note.note_type in ("basic", "basic_reverse"):
            return not note.front or not note.back
        if note.note_type == "basic_extra":
            return not note.front or not note.back
        return True

    @staticmethod
    def _normalize_cloze_indices(note: Note) -> Tuple[Note, bool]:
        pattern = r"\{\{c\d+::"
        matches = re.findall(pattern, note.front)

        if not matches:
            return note, False

        counter = 1
        new_text = note.front

        for match in matches:
            new_text = new_text.replace(match, f"{{{{c{counter}::", 1)
            counter += 1

        return Note("cloze", front=new_text), True


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
# Public Engine API
# =========================================

def generate_deck(
    input_files: List[Path],
    output_file: Path,
    optimize: bool = True,
    deck_name: str | None = None,
    strict: bool = True
) -> OptimizationReport:

    if not input_files:
        raise ValueError("No input files provided.")

    all_notes: List[Note] = []
    aggregate_report = OptimizationReport()

    for file_path in input_files:

        if not file_path.exists():
            raise ValueError(f"File not found: {file_path}")

        text = file_path.read_text(encoding="utf-8")
        notes, invalid = Parser.parse(text, strict=strict)

        aggregate_report.invalid_lines += invalid
        aggregate_report.total_input += len(notes) + invalid

        if optimize:
            notes, report = DeckOptimizer.optimize(notes)
            aggregate_report.merge(report)
        else:
            aggregate_report.total_output += len(notes)

        all_notes.extend(notes)

    if not all_notes:
        raise ValueError("No valid notes found.")

    final_deck_name = deck_name if deck_name else output_file.stem
    deck_id = _stable_int_hash(final_deck_name)

    deck = genanki.Deck(deck_id, final_deck_name)

    for note in all_notes:
        deck.add_note(Transformer.to_genanki(note))

    genanki.Package(deck).write_to_file(str(output_file))

    return aggregate_report
