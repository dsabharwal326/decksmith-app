"""
AI-powered card combining: identifies clusters of related cards and merges them
into richer single cards to improve flow and reduce redundancy.
"""

from __future__ import annotations
import json
from typing import List, Tuple
from core.engine import Note
from core.provider import Provider, ProviderError


_SYSTEM = """You are a medical flashcard editor. You receive a list of Anki flashcards (index: cleaned front | cleaned back). Your job is to identify small groups (2-3 cards max) that are genuinely redundant or so tightly related that a single card would be clearer and more efficient to study.

Combine ONLY when:
- Two cards test the exact same fact from slightly different angles (true redundancy)
- Two sequential cards form a logical cause-to-effect or definition-to-example pair that reads better together
- Merging produces a meaningfully richer card, not just a longer one

Do NOT combine:
- Cards that merely share a topic or organ system
- More than 3 cards at once
- Cards where the combined front would be confusingly long

For the combined card:
- Write a clean front (no cloze syntax needed - back can hold all answers)
- Write a structured back that integrates the key facts
- Use note_type "basic_extra"
- Return JSON only."""

_USER_TMPL = """Flashcards (index: front | back):

{cards}

Return JSON:
{{
  "merges": [
    {{
      "indices": [0, 3],
      "front": "combined front",
      "back": "combined back with all key facts",
      "note_type": "basic_extra"
    }}
  ]
}}

Empty merges array if nothing should be combined. Be conservative - only merge when it clearly helps."""


import re as _re


def _clean(text: str) -> str:
    text = _re.sub(r"\{\{c\d+::(.*?)(?:::[^}]*)?\}\}", r"\1", text)
    return text.encode('ascii', errors='replace').decode('ascii')


def _tokens(text: str) -> set[str]:
    return set(_re.findall(r"[a-z]{4,}", _clean(text).lower()))


def _cluster_by_overlap(notes: List[Note], batch_size: int = 40) -> List[List[Tuple[int, Note]]]:
    """
    Group notes into clusters where cards share keyword overlap with at least one
    neighbour in the group.  Produces clusters of up to batch_size for AI review.
    Cards within a cluster are more likely to be combinable than random batches.
    """
    indexed = list(enumerate(notes))
    clusters: List[List[Tuple[int, Note]]] = []
    used = [False] * len(notes)

    for i, (gi, ni) in enumerate(indexed):
        if used[i]:
            continue
        cluster: List[Tuple[int, Note]] = [(gi, ni)]
        used[i] = True
        tok_i = _tokens(ni.front)

        for j in range(i + 1, len(indexed)):
            if used[j] or len(cluster) >= batch_size:
                break
            gj, nj = indexed[j]
            tok_j = _tokens(nj.front)
            inter = len(tok_i & tok_j)
            union = len(tok_i | tok_j)
            if union and inter / union >= 0.25:
                cluster.append((gj, nj))
                used[j] = True
                tok_i = tok_i | tok_j  # grow the cluster's token fingerprint

        clusters.append(cluster)

    return clusters


def _run_combine_batch(
    batch: List[Tuple[int, Note]],
    provider: Provider,
    model: str,
) -> List[Tuple[int, Note]]:
    """Run one AI combine pass on a cluster; return (global_idx, note) pairs."""
    if len(batch) < 2:
        return batch

    local_notes = [n for _, n in batch]
    card_lines = "\n".join(
        f"{i}: {_clean(n.front)[:120]} | {_clean(n.back)[:120]}"
        for i, n in enumerate(local_notes)
    )
    user_prompt = _USER_TMPL.format(cards=card_lines)

    try:
        resp = provider.complete_structured(
            system=_SYSTEM,
            user=user_prompt,
            model=model,
            schema={
                "merges": [
                    {
                        "indices": ["integer"],
                        "front": "string",
                        "back": "string",
                        "note_type": "string",
                    }
                ]
            },
            max_tokens=2000,
            temperature=0.1,
        )
        merges = resp.data.get("merges", [])
    except (ProviderError, Exception):
        return batch

    consumed: set[int] = set()
    merged: List[Tuple[int, Note]] = []

    for merge in merges:
        indices = merge.get("indices", [])
        if len(indices) < 2:
            continue
        if any(i >= len(batch) or i in consumed for i in indices):
            continue
        for i in indices:
            consumed.add(i)
        first_global, first_note = batch[indices[0]]
        combined = Note(
            note_type=merge.get("note_type", "basic_extra"),
            front=merge.get("front", first_note.front),
            back=merge.get("back", first_note.back),
            extra=first_note.extra,
            tags=first_note.tags,
        )
        merged.append((min(batch[i][0] for i in indices), combined))

    result = [(gi, n) for idx, (gi, n) in enumerate(batch) if idx not in consumed]
    result.extend(merged)
    result.sort(key=lambda x: x[0])
    return result


def combine_cards(notes: List[Note], provider: Provider, model: str) -> List[Note]:
    """
    Returns a new list of Notes with redundant cards merged.

    Strategy: cluster cards by keyword overlap so the AI sees related cards
    together (not random batches), then run one AI pass per cluster.
    """
    if len(notes) < 2:
        return notes

    clusters = _cluster_by_overlap(notes)

    # Collect all (global_idx, note) pairs after per-cluster merging
    all_results: List[Tuple[int, Note]] = []
    for cluster in clusters:
        if len(cluster) >= 2:
            merged_cluster = _run_combine_batch(cluster, provider, model)
            all_results.extend(merged_cluster)
        else:
            all_results.extend(cluster)

    all_results.sort(key=lambda x: x[0])
    return [n for _, n in all_results]
