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
# Helper: Brace Balance Check
# =========================================

def _is_balanced(text: str) -> bool:
    return text.count("{{") == text.count("}}")


# =========================================
# Strict Line-Based Cloze Repair
# =========================================

def _repair_cloze_text(text: str, strict_repair: bool) -> Tuple[List[str], Dict[str, str]]:

    lines = text.split("\n")
    repaired_notes: List[str] = []
    repair_map: Dict[str, str] = {}

    buffer = ""
    original_buffer = ""

    for raw in lines:
        stripped = raw.strip()

        # Blank line resets buffer
        if not stripped:
            if buffer:
                repaired_notes.append(buffer.strip())
                buffer = ""
                original_buffer = ""
            continue

        # If no active buffer
        if not buffer:

            # If line is balanced, emit directly
            if _is_balanced(stripped):
                if "{{c" in stripped:
                    repaired_notes.append(stripped)
                continue

            # If unbalanced, start buffering
            buffer = stripped
            original_buffer = stripped
            continue

        # If we are buffering (previous line was unbalanced)
        buffer += " " + stripped
        original_buffer += " " + stripped

        if _is_balanced(buffer):

            fixed = re.sub(r"\s+", " ", buffer.strip())

            if "{{c" not in fixed:
                buffer = ""
                original_buffer = ""
                continue

            if buffer != fixed:
                repair_map[original_buffer] = fixed

            repaired_notes.append(fixed)
            buffer = ""
            original_buffer = ""

    # Flush remaining buffer
    if buffer:
        if strict_repair:
            raise ValueError(f"Unmatched cloze braces detected:\n{buffer}")

        # Auto-close braces if allowed
        missing = buffer.count("{{") - buffer.count("}}")
        if missing > 0:
            fixed = buffer + "}}" * missing
            fixed = re.sub(r"\s+", " ", fixed.strip())
            repair_map[buffer] = fixed
            repaired_notes.append(fixed)
        buffer = ""

    return repaired_notes, repair_map


# =========================================
# Parser
# =========================================

def _parse_cloze_lines(lines: List[str]) -> Tuple[List[Note], int]:

    notes = []
    invalid = 0

    for line in lines:
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

        repaired_lines, repair_map = _repair_cloze_text(
            raw_text,
            strict_repair=strict_repair
        )

        notes, invalid = _parse_cloze_lines(repaired_lines)

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
