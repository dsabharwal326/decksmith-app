from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Tuple
import re

from core.engine import Note


@dataclass(frozen=True)
class ClassificationReport:
    total_notes: int
    matched_notes: int
    unmatched_notes: int
    specialty_counts: Dict[str, int]


def _compile_dictionary(dictionary: Dict) -> Dict:
    compiled = {}

    for parent in sorted(dictionary.keys()):
        compiled[parent] = {}

        for child in sorted(dictionary[parent].keys()):
            entry = dictionary[parent][child]
            keywords = entry.get("keywords", [])

            patterns = []
            for keyword in sorted(keywords):
                pattern = re.compile(rf"\b{re.escape(keyword.lower())}\b")
                patterns.append(pattern)

            compiled[parent][child] = patterns

    return compiled


def _note_text(note: Note) -> str:
    return f"{note.front} {note.back} {note.extra}".lower()


def classify_notes(
    notes: List[Note],
    dictionary: Dict
) -> Tuple[List[Note], ClassificationReport]:

    compiled_dict = _compile_dictionary(dictionary)

    enriched_notes: List[Note] = []
    specialty_counts: Dict[str, int] = {}

    matched = 0

    for note in notes:
        text = _note_text(note)
        matched_specialties = []

        for parent in compiled_dict:
            for child in compiled_dict[parent]:
                patterns = compiled_dict[parent][child]

                for pattern in patterns:
                    if pattern.search(text):
                        tag = f"{parent}::{child}".replace(" ", "_")
                        matched_specialties.append(tag)
                        specialty_counts[tag] = specialty_counts.get(tag, 0) + 1
                        break

        if matched_specialties:
            matched += 1
            new_tags = tuple(sorted(set(note.tags + tuple(matched_specialties))))
            enriched_notes.append(
                Note(
                    note.note_type,
                    note.front,
                    note.back,
                    note.extra,
                    tags=new_tags,
                    guid=note.guid,
                )
            )
        else:
            enriched_notes.append(note)

    report = ClassificationReport(
        total_notes=len(notes),
        matched_notes=matched,
        unmatched_notes=len(notes) - matched,
        specialty_counts=dict(sorted(specialty_counts.items()))
    )

    return enriched_notes, report