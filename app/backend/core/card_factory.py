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

_SYSTEM = """\
You are a medical education expert building high-yield Anki flashcards.
Given a medical topic, generate a comprehensive but focused set of flashcards.

Card formats (use a mix — choose the best format for each fact):
  Basic:         Front :: Back
  Reverse:       Front || Back         (generates card in both directions)
  Cloze:         Sentence with {{c1::hidden term}} here
  Cloze+extra:   Sentence with {{c1::hidden term}} ||| Extra context shown after flip
  Basic+extra:   Front ||| Back ||| Extra notes

Guidelines:
- Cover: definition, mechanism/pathophysiology, clinical presentation, diagnosis,
  management, key drugs (dose/class/MOA if relevant), complications, exam traps
- Use cloze for single high-yield facts embedded in a sentence
- Use cloze+extra when a fact benefits from a brief clarifying note after the flip
- Use reverse (||) for terminology that should be recalled in both directions
- Use basic+extra (|||) for facts that need a short note but aren't reverse-worthy
- Write at the level of a third-year medical student
- Be concise — one fact per card, no padding
- Do NOT wrap output in any markdown, JSON, or code block
- Output ONLY the flashcard lines, one per line, blank line between groups

Example output format:
Beta blockers :: Class of drugs that block β-adrenergic receptors
Beta blockers || β-adrenergic receptor antagonists
{{c1::Metoprolol}} is a cardioselective beta blocker (β1-selective) ||| Cardioselectivity lost at high doses
Metoprolol ||| Beta blocker — selective β1 antagonist ||| Avoid in decompensated HF; safe in stable HF with EF reduction
What is the first-line treatment for hypertensive urgency? :: Oral antihypertensives — no need for IV
"""


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
) -> FactoryResult:
    """
    Generate flashcards for a medical topic.
    Returns a FactoryResult with notes + downloadable raw text.
    """
    specialty_hint = f" (focus on {specialty} context)" if specialty else ""
    user_prompt = (
        f"Generate approximately {card_count} high-yield flashcards on: "
        f"**{topic}**{specialty_hint}.\n\n"
        f"Cover the full clinical picture — definition, mechanism, presentation, "
        f"diagnosis, management, key drugs, complications, and at least 2 exam traps."
    )

    try:
        resp = provider.complete(
            system=_SYSTEM,
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
