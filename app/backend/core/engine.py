import genanki
import hashlib
import re
from dataclasses import dataclass, field
from typing import List, Tuple, Dict
from pathlib import Path


# =========================================
# Canonical Note
# =========================================

@dataclass(frozen=True)
class Note:
    note_type: str
    front: str


# =========================================
# Optimization Report
# =========================================

@dataclass
class OptimizationReport:
    total_input: int = 0
    total_output: int = 0
    invalid_lines: int = 0
    lines_autofixed: int = 0
    repairs: Dict[str, str] = field(default_factory=dict)


# =========================================
# Deterministic Hash
# =========================================

def _stable_int_hash(text: str) -> int:
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return int(digest[:8], 16)


# =========================================
# Cloze Repair Engine
# =========================================

def _repair_cloze_text(text: str, strict_repair: bool) -> Tuple[str, Dict[str, str]]:

    lines = text.split("\n")
    repaired_lines = []
    repair_map = {}

    buffer = ""
    open_count = 0
    original_chunk = []

    for raw in lines:
        stripped = raw.strip()
        if not stripped:
            continue

        original_chunk.append(stripped)
        buffer += " " + stripped if buffer else stripped

        open_count += stripped.count("{{")
        open_count -= stripped.count("}}")

        if open_count == 0:
            fixed = buffer.strip()

            if "{{c" not in fixed:
                buffer = ""
                original_chunk = []
                continue

            if fixed.count("{{") > fixed.count("}}"):
                if strict_repair:
                    raise ValueError(f"Unmatched braces detected:\n{fixed}")
                missing = fixed.count("{{") - fixed.count("}}")
                fixed += "}}" * missing

            fixed = re.sub(r"\s+", " ", fixed)

            original_text = " ".join(original_chunk)

            if original_text != fixed:
                repair_map[original_text] = fixed

            repaired_lines.append(fixed)
            buffer = ""
            original_chunk = []

    return "\n".join(repaired_lines), repair_map


# =========================================
# Parser
# =========================================

def _parse_cloze_lines(text: str) -> Tuple[List[Note], int]:

    notes = []
    invalid = 0

    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue

        if "{{c" not in line:
            invalid += 1
            continue

        notes.append(Note("cloze", front=line))

    return notes, invalid


# =========================================
# Public Engine API
# =========================================

def generate_deck(
    input_files: List[Path],
    output_file: Path,
    deck_name: str | None = None,
    strict_repair: bool = False
) -> OptimizationReport:

    report = OptimizationReport()
    all_notes: List[Note] = []

    for file_path in input_files:

        raw_text = file_path.read_text(encoding="utf-8")
        report.total_input += len(raw_text.split("\n"))

        repaired_text, repair_map = _repair_cloze_text(
            raw_text,
            strict_repair=strict_repair
        )

        notes, invalid = _parse_cloze_lines(repaired_text)

        report.total_output += len(notes)
        report.invalid_lines += invalid
        report.lines_autofixed += len(repair_map)
        report.repairs.update(repair_map)

        all_notes.extend(notes)

    if not all_notes:
        raise ValueError("No valid cloze notes found.")

    final_name = deck_name if deck_name else output_file.stem
    deck_id = _stable_int_hash(final_name)

    model = genanki.Model(
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

    deck = genanki.Deck(deck_id, final_name)

    for note in all_notes:
        deck.add_note(genanki.Note(model=model, fields=[note.front]))

    genanki.Package(deck).write_to_file(str(output_file))

    return report
