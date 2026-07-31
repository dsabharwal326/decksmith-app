"""
Topic-based card generator.

Given a medical topic, asks the AI to produce a structured set of
flashcards covering it from multiple angles. Returns both:
  - List[Note]  — ready to feed into the validate → build pipeline
  - str         — the same cards as plain text in Decksmith format
                  (downloadable, editable, re-uploadable)
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Tuple

from core.engine import Note, parse_text_to_notes
from core.provider import Provider, ProviderError


# =========================================
# RESULT
# =========================================

@dataclass(frozen=True)
class FactoryResult:
    notes: List[Note]
    raw_text: str           # Decksmith-format text, ready to download as .txt
    topic: str
    card_count: int
    failed: bool
    error: str              # empty if succeeded


# =========================================
# SYSTEM PROMPT
# =========================================

_SYSTEM_BASE = """\
You are a medical education expert building high-yield Anki flashcards.
Given a medical topic, generate a comprehensive but focused set of flashcards.

Card formats (use a mix - choose the best format for each fact):
  Basic:         Front :: Back
  Reverse:       Front || Back         (generates card in both directions)
  Cloze:         Sentence with {{c1::hidden term}} here
  Cloze+extra:   Sentence with {{c1::hidden term}} ||| Extra context shown after flip
  Basic+extra:   Front ||| Back ||| Extra notes
  Table:         Question or title on one line, then pipe-delimited rows immediately after:
                 Compare limited vs diffuse systemic sclerosis
                 | Feature | Limited | Diffuse |
                 | Abs | Anti-centromere | Anti-Scl-70 |
                 | ILD | Mild/late | Early/severe |
                 Use for comparisons, classifications, or multi-column facts (≥2 columns, ≥2 rows)

Guidelines:
- Use cloze for single high-yield facts embedded in a sentence
- Use cloze+extra when a fact benefits from a brief clarifying note after the flip
- Use reverse (||) for terminology that should be recalled in both directions
- Use basic+extra (|||) for facts that need a short note but aren't reverse-worthy
- Be concise - one fact per card, no padding
- Do NOT wrap output in any markdown, JSON, or code block
- Output ONLY the flashcard lines, one per line, blank line between groups"""

_CLOZE_HINTS = {
    "recommended": (
        "Cloze deletions: use your judgment. "
        "Single deletion (c1) for most cards; use c2 or c3 only when testing "
        "multiple related blanks in one sentence adds clear value."
    ),
    "single": (
        "Cloze deletions: use EXACTLY ONE deletion per cloze card (c1 only). "
        "Never number higher than c1. If a sentence has multiple testable facts, "
        "split them into separate cards."
    ),
    "double": (
        "Cloze deletions: use UP TO TWO deletions per cloze card (c1 and c2). "
        "Use two blanks when two closely related facts belong in the same sentence. "
        "Never number higher than c2."
    ),
    "triple": (
        "Cloze deletions: use UP TO THREE deletions per cloze card (c1, c2, c3). "
        "Use multiple blanks for dense fact-packed sentences. "
        "Never number higher than c3."
    ),
}

_STEP_HINTS = {
    "step1": (
        "USMLE Step 1 scope",
        "Focus on basic science foundations: mechanisms, pathophysiology, biochemistry, "
        "pharmacology (MOA, receptor, drug class), microbiology (virulence, treatment), "
        "anatomy (clinical correlates), histology, and embryology. "
        "Prioritize WHY things happen over clinical decision-making. "
        "Write at the level of a second-year medical student preparing for Step 1."
    ),
    "step2": (
        "USMLE Step 2 CK scope",
        "Focus on clinical knowledge: recognizing disease presentation, ordering the right "
        "diagnostic workup, first-line vs second-line treatment, when to refer, "
        "inpatient management, and clinical decision thresholds. "
        "Prioritize diagnosis and management over basic science mechanisms. "
        "Write at the level of a third-year clerkship student preparing for Step 2 CK."
    ),
    "step3": (
        "USMLE Step 3 scope",
        "Focus on patient management: ambulatory care, chronic disease management, "
        "preventive medicine (screening guidelines, immunizations), health maintenance, "
        "ICU/critical care decisions, biostatistics and epidemiology, and ethics/legal. "
        "Prioritize longitudinal patient management and population health. "
        "Write at the level of a resident preparing for Step 3."
    ),
}

def _build_system(usmle_step: str, cloze_density: str = "recommended", mnemonics: bool = False) -> str:
    hint_label, hint_text = _STEP_HINTS.get(usmle_step, _STEP_HINTS["step1"])
    cloze_hint = _CLOZE_HINTS.get(cloze_density, _CLOZE_HINTS["recommended"])
    mnemonic_hint = (
        "\n\nMnemonics: When a card covers a list, sequence, or group of ≥3 items, "
        "embed a mnemonic in the extra field (e.g. 'MUDPILES for anion-gap acidosis causes'). "
        "Keep it brief — acronym or phrase only, no explanation needed."
        if mnemonics else ""
    )
    return (
        _SYSTEM_BASE
        + f"\n\nScope: {hint_label}\n{hint_text}"
        + f"\n\n{cloze_hint}"
        + mnemonic_hint
    )



# =========================================
# ENTRY POINT
# =========================================

def generate_cards_for_topic(
    topic: str,
    provider: Provider,
    model: str,
    *,
    specialty: Optional[str] = None,
    card_count: int = 20,
    usmle_step: str = "step1",
    cloze_density: str = "recommended",
    tag_prefix: str = "",
    exclude_topics: str = "",
    mnemonics: bool = False,
) -> FactoryResult:
    """
    Generate flashcards for a medical topic.
    Returns a FactoryResult with notes + downloadable raw text.
    """
    specialty_hint = f" (focus on {specialty} context)" if specialty else ""
    exclude_hint = f"\n\nDo NOT generate cards covering: {exclude_topics}." if exclude_topics.strip() else ""
    user_prompt = (
        f"Generate approximately {card_count} high-yield flashcards on: "
        f"**{topic}**{specialty_hint}.\n\n"
        f"Cover the full clinical picture - definition, mechanism, presentation, "
        f"diagnosis, management, key drugs, complications, and at least 2 exam traps."
        f"{exclude_hint}"
    )

    try:
        resp = provider.complete(
            system=_build_system(usmle_step, cloze_density, mnemonics),
            user=user_prompt,
            model=model,
            max_tokens=3000,
            temperature=0.3,
        )
        raw_text = resp.text.strip()
    except ProviderError as e:
        return FactoryResult(
            notes=[], raw_text="", topic=topic,
            card_count=0, failed=True, error=str(e),
        )

    notes = parse_text_to_notes(raw_text, strict_repair=False)

    if tag_prefix.strip():
        tag = tag_prefix.strip()
        notes = [
            Note(note_type=n.note_type, front=n.front, back=n.back,
                 extra=n.extra, tags=[tag] + [t for t in n.tags if t != tag])
            for n in notes
        ]

    return FactoryResult(
        notes=notes,
        raw_text=raw_text,
        topic=topic,
        card_count=len(notes),
        failed=False,
        error="",
    )


# =========================================
# TEXT SERIALISER (notes → Decksmith format)
# =========================================

def notes_to_text(notes: List[Note]) -> str:
    """Convert a list of Notes back to Decksmith plain-text format."""
    lines: List[str] = []
    for note in notes:
        if note.note_type == "cloze":
            if note.extra:
                lines.append(f"{note.front} ||| {note.extra}")
            else:
                lines.append(note.front)
        elif note.note_type == "basic_reverse":
            lines.append(f"{note.front} || {note.back}")
        elif note.note_type == "basic_extra":
            lines.append(f"{note.front} ||| {note.back} ||| {note.extra}")
        else:
            lines.append(f"{note.front} :: {note.back}")
    return "\n".join(lines)
