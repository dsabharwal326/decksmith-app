"""
Augmentation AI layer.

For each valid card, asks a high-quality model to generate structured
medical enrichment (mechanism, clinical context, high-yield points, exam trap).
Returns ExpansionPayload objects that the deterministic augmentation engine
in augmentation.py applies to the notes.

This layer is pure: it does not modify notes. It only produces payloads.
The caller decides whether to apply them (after user preview and approval).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Tuple

from core.augmentation import ExpansionPayload, _note_identity
from core.engine import Note
from core.provider import Provider, ProviderError
from core import enhancement_cache as _cache


# =========================================
# RESULT TYPE
# =========================================

@dataclass(frozen=True)
class AugmentationProposal:
    note: Note
    identity: str               # SHA key into payload_map
    payload: Optional[ExpansionPayload]
    succeeded: bool
    error: str                  # empty string if succeeded


# =========================================
# SYSTEM PROMPT
# =========================================

_SYSTEM_PROMPT = """\
You are a medical education expert helping doctors and students build \
high-yield Anki flashcards. Given a flashcard, you will return a structured \
JSON object enriching it with deep clinical context.

Rules:
1. Only expand on what the card already says - do not contradict or invent facts.
2. Be concise. Each field should be 1-3 sentences or bullet points max.
3. high_yield_points must be a JSON array of strings (2-4 points).
4. normal_vs_pathologic is optional - only include if directly relevant.
5. Write at the level of a senior medical student or resident.
6. Return ONLY the JSON object. No prose, no markdown fences.

Required JSON schema:
{
  "primary_concept": "one-line distillation of the core concept",
  "mechanism": "pathophysiology or mechanism of action",
  "high_yield_points": ["point 1", "point 2", "point 3"],
  "clinical_context": "how this presents or is used clinically",
  "exam_trap": "common mistake, confusing fact, or distinguishing feature",
  "normal_vs_pathologic": "compare normal to pathologic state (optional, omit if not relevant)"
}
"""


# =========================================
# CARD -> PROMPT
# =========================================

import re as _re

def _strip_cloze(text: str) -> str:
    """Convert {{c1::answer::hint}} -> answer for clean AI prompts."""
    return _re.sub(r"\{\{c\d+::(.*?)(?:::[^}]*)?\}\}", r"\1", text)

def _ascii_safe(text: str) -> str:
    """Transliterate or drop non-ASCII so the provider never sees them."""
    _map = {
        '≥': '>=', '≤': '<=', '±': '+/-', '×': 'x',
        'α': 'alpha', 'β': 'beta', 'γ': 'gamma',
        'μ': 'mu', 'δ': 'delta', 'ρ': 'rho',
        '→': '->', '←': '<-', '↔': '<->',
        '’': "'", '‘': "'", '“': '"', '”': '"',
        '—': '-', '–': '-', '…': '...',
    }
    out = []
    for ch in text:
        if ord(ch) < 128:
            out.append(ch)
        elif ch in _map:
            out.append(_map[ch])
        else:
            # Try latin transliteration for accented chars, else drop
            import unicodedata
            norm = unicodedata.normalize('NFD', ch)
            ascii_ch = norm.encode('ascii', errors='ignore').decode('ascii')
            out.append(ascii_ch if ascii_ch else '')
    return ''.join(out)

def _card_to_prompt(note: Note) -> str:
    parts = [f"Card type: {note.note_type}"]
    if note.front:
        parts.append(f"Front: {_ascii_safe(_strip_cloze(note.front))}")
    if note.back:
        parts.append(f"Back: {_ascii_safe(_strip_cloze(note.back))}")
    if note.extra:
        parts.append(f"Extra: {_ascii_safe(note.extra)}")
    if note.tags:
        parts.append(f"Tags: {', '.join(note.tags)}")
    return "\n".join(parts)


# =========================================
# BATCH CARD AUGMENTATION (5 cards per call)
# =========================================

_BATCH_SYSTEM_PROMPT = _SYSTEM_PROMPT + """

You will receive multiple flashcards. Return a JSON array with one object per card, in the same order.
Each object must follow the schema above. Example for 2 cards:
[
  { "primary_concept": "...", "mechanism": "...", ... },
  { "primary_concept": "...", "mechanism": "...", ... }
]
Return ONLY the JSON array. No prose, no markdown fences.
"""

_QUICK_SYSTEM_PROMPT = """\
You are a medical education expert. Given flashcards, return a JSON array with one object per card.
Each object needs only two fields:
  "high_yield_points": array of 2-3 short bullet strings (key facts for exams)
  "exam_trap": one sentence — a common mistake or distinguishing feature

Example for 2 cards:
[
  { "high_yield_points": ["point 1", "point 2"], "exam_trap": "Don't confuse X with Y" },
  { "high_yield_points": ["point A", "point B"], "exam_trap": "Remember Z" }
]
Return ONLY the JSON array. No prose, no markdown fences.
"""

def _parse_one_item(
    data: dict,
    note: Note,
    include_clinical_context: bool,
    include_high_yield: bool,
    include_exam_traps: bool,
) -> AugmentationProposal:
    identity = _note_identity(note)
    for field in ("primary_concept", "mechanism"):
        if not data.get(field):
            return AugmentationProposal(
                note=note, identity=identity,
                payload=None, succeeded=False,
                error=f"AI response missing field: {field}",
            )
    hyp: tuple = ()
    if include_high_yield:
        raw_hyp = data.get("high_yield_points", [])
        hyp = tuple(str(p).strip() for p in raw_hyp) if isinstance(raw_hyp, list) else ()
    nvp = data.get("normal_vs_pathologic") or None
    if nvp and not isinstance(nvp, str):
        nvp = None
    exam_trap_raw = str(data.get("exam_trap", "")).strip() if include_exam_traps else ""
    clinical_context_raw = str(data.get("clinical_context", "")).strip() if include_clinical_context else ""
    payload = ExpansionPayload(
        primary_concept=str(data["primary_concept"]).strip(),
        mechanism=str(data["mechanism"]).strip(),
        high_yield_points=hyp,
        clinical_context=clinical_context_raw or "See primary concept.",
        exam_trap=exam_trap_raw or "No specific exam trap identified.",
        normal_vs_pathologic=nvp.strip() if nvp else None,
    )
    return AugmentationProposal(note=note, identity=identity, payload=payload, succeeded=True, error="")


def _augment_batch(
    notes: List[Note],
    provider: Provider,
    model: str,
    include_clinical_context: bool = True,
    include_high_yield: bool = True,
    include_exam_traps: bool = True,
    depth: str = "full",
) -> List[AugmentationProposal]:
    """Augment a batch of notes in a single API call. Checks cache first."""
    import json as _json

    # Check cache — only send uncached notes to the API
    results: List[Optional[AugmentationProposal]] = [None] * len(notes)
    uncached_indices: List[int] = []
    uncached_notes: List[Note] = []

    for i, note in enumerate(notes):
        identity = _note_identity(note)
        cached = _cache.get(identity)
        if cached:
            proposal = _parse_one_item(cached, note, include_clinical_context, include_high_yield, include_exam_traps)
            results[i] = proposal
        else:
            uncached_indices.append(i)
            uncached_notes.append(note)

    if not uncached_notes:
        return results  # type: ignore

    system_prompt = _QUICK_SYSTEM_PROMPT if depth == "quick" else _BATCH_SYSTEM_PROMPT
    max_tokens_per_card = 200 if depth == "quick" else 600

    cards_text = "\n\n".join(
        f"Card {i+1}:\n{_card_to_prompt(note)}"
        for i, note in enumerate(uncached_notes)
    )
    user_prompt = f"Enrich these {len(uncached_notes)} flashcards:\n\n{cards_text}"

    try:
        resp = provider.complete(
            system=system_prompt,
            user=user_prompt,
            model=model,
            max_tokens=max_tokens_per_card * len(uncached_notes),
            temperature=0.2,
        )
        text = resp.text.strip()
        if text.startswith("```"):
            lines = text.splitlines()
            text = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])
        items = _json.loads(text)
        if not isinstance(items, list):
            raise ValueError("Expected JSON array")
    except Exception as e:
        for i, note in zip(uncached_indices, uncached_notes):
            results[i] = AugmentationProposal(
                note=note, identity=_note_identity(note),
                payload=None, succeeded=False, error=str(e),
            )
        return results  # type: ignore

    for j, (orig_i, note) in enumerate(zip(uncached_indices, uncached_notes)):
        if j < len(items) and isinstance(items[j], dict):
            proposal = _parse_one_item(items[j], note, include_clinical_context, include_high_yield, include_exam_traps)
            results[orig_i] = proposal
            if proposal.succeeded and proposal.payload:
                _cache.put(proposal.identity, items[j])
        else:
            results[orig_i] = AugmentationProposal(
                note=note, identity=_note_identity(note),
                payload=None, succeeded=False, error="missing from batch response",
            )

    return results  # type: ignore


# =========================================
# BATCH ENTRY POINT
# =========================================

# =========================================
# CARD STYLE REWRITE
# =========================================

_STYLE_SYSTEM_PROMPTS: dict = {
    "cheesy_dorian": """\
You are a medical educator rewriting cards in the Cheesy Dorian Anki style.

Pattern: Every card is a cloze. The question leads, and the answer is hidden inline.
Two allowed sentence structures:
  A) "What is/are X? {{c1::answer}}"
  B) "[Clinical fact or eponym] = {{c1::diagnosis/answer}}"

Rules:
- FRONT: A clear question or factual statement with {{c1::answer}} inline. 10-20 words max.
- EXTRA: 1-2 sentence mnemonic, mechanism, or clinical pearl. Empty string "" if nothing useful to add.
- Never put the cloze deletion at the very start of the sentence.
- If multiple facts exist, pick the single most testable one.
- Keep cloze syntax exactly: {{c1::answer}}

Real examples from this deck:
  "What is the most common cause of postpartum hemorrhage? {{c1::Uterine atony (90%)}}"
  "What is the contraindication for Prostaglandin F2 alpha in postpartum hemorrhage? {{c1::Asthma}}"
  "Dementia + visual hallucinations followed by early Parkinsonism = {{c1::Lewy body dementia}}"
  "corkscrew esophagus = {{c1::diffuse esophageal spasm}}"
  "Bell's palsy involves a {{c1::peripheral}} lesion of the facial nerve (VII)."
  "What gross motor milestone is expected at 18 months? {{c1::Kicks a ball}}, runs"
  "What birth weight is considered macrosomia? {{c1::> 4500 g}}"

Return a JSON array, one object per card, in the same order:
[{"new_front": "...", "new_extra": "...", "succeeded": true}, ...]
Return ONLY the JSON array. No prose, no markdown fences.
""",

    "anking": """\
You are a medical educator rewriting cards in the AnKing Anki style.

Pattern: Cloze cards that test one or more related facts in a single sentence. Use multiple cloze
numbers ({{c1::}}, {{c2::}}, {{c3::}}) when testing related parts of the same concept.

Rules:
- FRONT: A complete sentence with cloze deletions. 10-25 words. Can be a question or a statement.
- For related paired facts (drug + MOA, organism + disease), test both in one card with {{c1::}} and {{c2::}}.
- Optional hint syntax: {{c2::answer::(hint to show in blank)}} — use sparingly for disambiguation.
- EXTRA: "" (empty string)
- Cloze syntax: {{cN::answer}} or {{cN::answer::(hint)}}

Real examples from this deck:
  "One possible treatment for a growth hormone adenoma is a(n) {{c1::somatostatin}} analog, such as {{c1::octreotide}}"
  "In general, sex chromosome disorders (e.g. Turner's, Klinefelter) present with {{c1::decreased}} testosterone and/or estrogen"
  "What demographic is most commonly affected by PCOS? {{c1::Obese, young women of reproductive age}}"
  "{{c1::2nd degree Mobitz type I (Wenckebach)::(aka)}} AV block is characterized by progressive lengthening of the {{c2::PR interval}}"
  "What is the diagnosis in an infant with an omega-shaped epiglottis and collapse of the supraglottic structures? {{c1::Laryngomalacia}}"
  "Which subtypes of HPV are covered by the quadrivalent vaccine? {{c1::HPV6, 11, 16, 18}}"
  "In {{c1::red blood}} cells, {{c2::CO2}} is combined with {{c2::H2O}} via {{c3::carbonic anhydrase}}"

Return a JSON array, one object per card, in the same order:
[{"new_front": "...", "new_extra": "", "succeeded": true}, ...]
Return ONLY the JSON array. No prose, no markdown fences.
""",

    "zanki": """\
You are a medical educator using the Zanki Anki style.
Transform each flashcard into ultra-atomic cloze deletions:
  FRONT: The core fact as a SHORT sentence (<=12 words) with {{c1::answer}}. Strip all context.
  EXTRA: "" (empty string)

Rules:
- Ultra-atomic. No context sentences. Pure fact extraction.
- Multiple cloze numbers (c1, c2) are fine only if they test different parts of the same single sentence.
- Cloze must use {{cN::answer}} syntax exactly.

Return a JSON array, one object per card, in the same order:
[{"new_front": "...", "new_extra": "", "succeeded": true}, ...]
Return ONLY the JSON array. No prose, no markdown fences.
""",

    "lightyear": """\
You are a medical educator rewriting cards in the Lightyear Anki style.

Pattern: Mostly basic (non-cloze) Q/A cards. Short direct question on the front, concise answer on the back.
Use basic format unless the concept genuinely benefits from cloze fill-in.

Rules:
- FRONT: "What is X?", "Which X?", "What are the Y for Z?" — clean question, under 12 words, no vignette.
- BACK: Short factual answer. Can be a list (one item per line). 1-8 words per item typically.
- EXTRA: "" (empty string)
- Prefer basic (Q/A) over cloze. Only use cloze if the card tests a word embedded in a fact.
- No clinical vignettes, no "A patient with...", no lengthy sentences.

Real examples from this deck (BASIC format):
  Q: What are the treatments for ITP? | A: Steroids / IVIG / Rituximab / Splenectomy
  Q: Which mitral papillary muscle has a dual blood supply? | A: Anterolateral papillary muscle
  Q: What bacteria are branching and filamentous? | A: Nocardia / Actinomyces
  Q: Which inherited hypercoagulability disease presents as heparin resistance? | A: Antithrombin III deficiency
  Q: What is a common pharmacological cause of avascular necrosis of the hip? | A: Steroid therapy
  Q: What is the C3 convertase in the lectin complement pathway? | A: C2b4b
  Q: Which amino acids are purely ketogenic? | A: Leucine / Lysine

Return a JSON array, one object per card, in the same order.
For basic cards: {"new_front": "Question?", "new_back": "Answer", "new_extra": "", "succeeded": true}
For cloze cards: {"new_front": "Sentence with {{c1::answer}}", "new_extra": "", "succeeded": true}
Return ONLY the JSON array. No prose, no markdown fences.
""",

    "brosencephalon": """\
You are a medical educator rewriting cards in the Brosencephalon Anki style.

Pattern: Mix of entity-first cloze cards and short basic Q/A cards.
- Cloze style: Start with the drug/disease/concept name as the blank, then describe it.
  Example: "{{c1::Trimethoprim}} is an antibiotic that inhibits bacterial dihydrofolate reductase."
- Basic style: Very short front (a term, a receptor, a drug), dense back with all facts.
  Example: Front: "alpha1" | Back: "G-protein: q — increases vascular smooth muscle contraction, pupillary dilation"

Rules:
- FRONT: Either (A) entity-first cloze: "{{c1::Entity}} is/does X" — 15-30 words; or (B) ultra-short term/name (1-5 words).
- For entity-first cloze: the entity (drug, disease, gene) is {{c1::}}; include its MOA or defining feature.
- For basic: front is just the term; back is all key facts in dense form (G-protein type, effects, drug class, etc.).
- EXTRA: "" (empty string). All facts go in BACK for basic, or in the sentence for cloze.
- Use cloze for drugs and diseases. Use basic for receptors, lab values, and pure associations.

Real examples from this deck:
  Cloze: "{{c1::Trimethoprim}} is an antibiotic that inhibits cytoplasmic bacterial Dihydrofolate Reductase."
  Cloze: "{{c1::Phenoxybenzamine}} is an alpha-adrenergic blocker primarily used to treat Pheochromocytoma as a pre-operative prep."
  Cloze: "{{c1::Janeway lesions}} are non-painful lesions on the palms and soles that manifest in infectious endocarditis."
  Basic: F: "alpha1" | B: "G-protein: q — increases vascular smooth muscle contraction, increases pupillary dilator contraction"
  Basic: F: "Beta1" | B: "G-protein: s — increases heart rate, contractility, renin release, lipolysis"
  Basic: F: "Radiation exposure" | B: "Leukemia, sarcoma, papillary thyroid cancer, breast cancer"

Return a JSON array, one object per card, in the same order.
For cloze: {"new_front": "{{c1::Entity}} is...", "new_extra": "", "succeeded": true}
For basic: {"new_front": "Short term", "new_back": "Dense facts", "new_extra": "", "succeeded": true}
Return ONLY the JSON array. No prose, no markdown fences.
""",

    "step3_hq": """\
You are a USMLE Step 3 flashcard writer. Rewrite each card in the high-yield Q/A style used by top Step 3 decks.

Style rules:
- FRONT: A direct question, typically "What is the most common/important/leading X for Y?" or "What is the first-line X for Y?" Keep under 18 words.
- BACK: Concise factual answer, 1–6 words when possible. Never a full sentence unless truly necessary.
- EXTRA: Always empty string "".
- No clinical vignettes, no "A patient with...", no cloze syntax.
- If a cloze card arrives, convert it to a Q/A pair.

Real examples of this style:
Q: What is the most important modifiable risk factor for coronary artery disease? | A: Smoking
Q: What is the most common cause of death in acromegaly? | A: Heart failure
Q: What is the leading risk factor for bladder cancer? | A: Smoking
Q: What is the most common cause of death in kidney transplant recipients? | A: Cardiovascular disease
Q: What is the most serious complication of acute rheumatic fever? | A: Carditis / pancarditis
Q: When is elective AAA repair indicated by size? | A: Diameter >5.5 cm
Q: What rapid AAA growth rate is an indication for repair? | A: >0.5 cm in 6 months or >1 cm in 1 year

Return a JSON array, one object per card, in the same order:
[{"new_front": "What is...", "new_back": "Short answer", "new_extra": "", "succeeded": true}, ...]
Return ONLY the JSON array. No prose, no markdown fences.
""",

    "protocol_cloze": """\
You are a USMLE Step 3 flashcard writer. Rewrite each card as a clean protocol/timing cloze card, matching the style of top pregnancy and testing-protocol decks.

Style rules:
- FRONT: A complete sentence with key facts replaced by {{c1::answer}}, {{c2::answer}}, etc.
- Use cloze for: timing (weeks, doses), specific tests ordered, specific thresholds, named tests/agents.
- Sentence structure: "[Clinical scenario] → {{c1::action/test}}" or "At {{c1::timepoint}}, [what happens]."
- Keep sentences concise (≤20 words). No multi-sentence fronts.
- EXTRA: Always empty string "".

Real examples of this style:
- Decreased fetal movement → {{c1::nonstress test}}.
- At {{c1::24–28 weeks}}, perform the {{c2::1-hour 50-g glucose challenge test}}.
- Suspected PROM → {{c1::speculum exam}}, {{c2::nitrazine}}, and {{c3::ferning}}.
- STEC/EHEC causes {{c1::bloody diarrhea}} and can lead to HUS.
- Campylobacter infection can precede {{c1::Guillain-Barré syndrome}}.
- Nonreactive NST → {{c1::biophysical profile}}.

Return a JSON array, one object per card, in the same order:
[{"new_front": "{{c1::...}} sentence", "new_extra": "", "succeeded": true}, ...]
Return ONLY the JSON array. No prose, no markdown fences.
""",
}

_STYLE_BATCH_SUFFIX = """

You will receive multiple flashcards. Return a JSON array with one object per card, in the same order.
Each object: {"new_front": "...", "new_back": "", "new_extra": "...", "succeeded": true}
Include "new_back" only when producing a basic (non-cloze) card — set it to the answer text.
For cloze cards, set "new_back" to "" (empty string).
If you cannot meaningfully rewrite a card, set "succeeded": false and keep all text fields as empty strings.
Return ONLY the JSON array. No prose, no markdown fences.
"""


def style_rewrite_batch(
    notes: List[Note],
    style: str,
    provider: Provider,
    model: str,
    depth: str = "full",
) -> List[dict]:
    """Rewrite notes into the target card style. Returns one dict per note."""
    import json as _json

    system_prompt = _STYLE_SYSTEM_PROMPTS.get(style)
    if not system_prompt:
        return [{"new_front": "", "new_extra": "", "succeeded": False, "error": f"Unknown style: {style}"}] * len(notes)
    system_prompt = system_prompt + _STYLE_BATCH_SUFFIX

    cards_text = "\n\n".join(
        f"Card {i+1}:\n{_card_to_prompt(note)}"
        for i, note in enumerate(notes)
    )
    user_prompt = f"Rewrite these {len(notes)} flashcards in the specified style:\n\n{cards_text}"

    max_tokens_per_card = 300 if depth == "quick" else 600

    try:
        resp = provider.complete(
            system=system_prompt,
            user=user_prompt,
            model=model,
            max_tokens=max_tokens_per_card * len(notes),
            temperature=0.3,
        )
        text = resp.text.strip()
        if text.startswith("```"):
            lines = text.splitlines()
            text = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])
        items = _json.loads(text)
        if not isinstance(items, list):
            raise ValueError("Expected JSON array")
    except Exception as e:
        return [{"new_front": "", "new_extra": "", "succeeded": False, "error": str(e)}] * len(notes)

    results = []
    for j, note in enumerate(notes):
        if j < len(items) and isinstance(items[j], dict):
            item = items[j]
            results.append({
                "new_front": str(item.get("new_front", "") or "").strip(),
                "new_back":  str(item.get("new_back",  "") or "").strip(),
                "new_extra": str(item.get("new_extra", "") or "").strip(),
                "succeeded": bool(item.get("succeeded", True)),
                "error": str(item.get("error", "") or ""),
            })
        else:
            results.append({"new_front": "", "new_back": "", "new_extra": "", "succeeded": False, "error": "missing from batch response"})
    return results


def generate_style_rewrite_proposals(
    notes: List[Note],
    style: str,
    provider: Provider,
    model: str,
    progress_callback: Optional[Callable[[int, int], None]] = None,
    max_workers: int = 4,
    batch_size: int = 5,
    depth: str = "full",
) -> List[dict]:
    """Run style_rewrite_batch in parallel batches. Returns one dict per note."""
    from concurrent.futures import ThreadPoolExecutor, as_completed

    total = len(notes)
    batches = [notes[i:i + batch_size] for i in range(0, total, batch_size)]
    results: List[Optional[dict]] = [None] * total
    done_count = 0

    def _work(batch_start: int, batch: List[Note]) -> tuple:
        return batch_start, style_rewrite_batch(batch, style, provider, model, depth=depth)

    with ThreadPoolExecutor(max_workers=max_workers) as exe:
        futures = {exe.submit(_work, i * batch_size, b): i * batch_size for i, b in enumerate(batches)}
        for fut in as_completed(futures):
            start, batch_results = fut.result()
            for j, r in enumerate(batch_results):
                results[start + j] = r
            done_count += len(batch_results)
            if progress_callback:
                progress_callback(done_count, total)

    return [r for r in results if r is not None]  # type: ignore


def generate_augmentation_proposals(
    notes: List[Note],
    provider: Provider,
    model: str,
    progress_callback: Optional[Callable[[int, int], None]] = None,
    include_clinical_context: bool = True,
    include_high_yield: bool = True,
    include_exam_traps: bool = True,
    max_workers: int = 16,
    batch_size: int = 5,
    depth: str = "full",
) -> List[AugmentationProposal]:
    """
    Augment notes in batches of batch_size, running max_workers batches concurrently.
    Batching reduces API calls from N to N/batch_size, staying well within rate limits.
    Returns one proposal per note in original order.
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    total = len(notes)
    # Split into batches
    batches = [notes[i:i + batch_size] for i in range(0, total, batch_size)]
    # Track results by original note index
    results: List[Optional[AugmentationProposal]] = [None] * total
    done_count = 0

    def _work(batch_start: int, batch: List[Note]) -> tuple:
        proposals = _augment_batch(
            batch, provider, model,
            include_clinical_context=include_clinical_context,
            include_high_yield=include_high_yield,
            include_exam_traps=include_exam_traps,
            depth=depth,
        )
        return batch_start, proposals

    with ThreadPoolExecutor(max_workers=max_workers) as exe:
        futures = {
            exe.submit(_work, i * batch_size, batch): i
            for i, batch in enumerate(batches)
        }
        for future in as_completed(futures):
            batch_start, proposals = future.result()
            for j, proposal in enumerate(proposals):
                results[batch_start + j] = proposal
            done_count += len(proposals)
            if progress_callback:
                progress_callback(done_count, total)

    return results  # type: ignore


# =========================================
# PAYLOAD MAP BUILDER
# =========================================

def build_payload_map(
    proposals: List[AugmentationProposal],
    accepted_indices: set,
) -> Dict[str, ExpansionPayload]:
    """
    Build the payload_map dict expected by augment_notes().
    Only includes proposals where the user accepted them.
    """
    payload_map: Dict[str, ExpansionPayload] = {}
    for i, proposal in enumerate(proposals):
        if i in accepted_indices and proposal.payload is not None:
            payload_map[proposal.identity] = proposal.payload
    return payload_map
