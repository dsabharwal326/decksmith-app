"""
Decksmith — FastAPI microservice.

Internal only — not exposed to the public internet.
Laravel calls this service using the SERVICE_API_KEY header.

Environment variables:
  SERVICE_API_KEY      shared secret Laravel uses to authenticate requests
  ANTHROPIC_API_KEY    (optional) server-side Anthropic key for AI features
  OPENAI_API_KEY       (optional) server-side OpenAI key for AI features
  DEFAULT_PROVIDER     anthropic | openai | none  (default: anthropic)
"""
from __future__ import annotations

import io
import os
import secrets
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional

import genanki
from fastapi import Depends, FastAPI, HTTPException, Header, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from core.engine import Note, build_deck, parse_text_to_notes
from core.validator import validate_notes, summary as validator_summary
from core.classifier import classify_notes
from core.taxonomy import DEFAULT_TAXONOMY
from core.augmentation import augment_notes
from core.augmentation_policy import AugmentationPolicy, ExpansionMode
from core.augment_ai import generate_augmentation_proposals, build_payload_map
from core.card_factory import generate_cards_for_topic, notes_to_text
from core.provider import build_provider, AnthropicProvider, OpenAIProvider
from core.apkg_import import read_apkg, filter_new_notes


# =========================================
# APP + AUTH
# =========================================

app = FastAPI(
    title="Decksmith API",
    version="1.0.0",
    docs_url=None,   # disable public docs in production
    redoc_url=None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],   # restrict to your Laravel domain in production
    allow_methods=["*"],
    allow_headers=["*"],
)

_SERVICE_KEY = os.environ.get("SERVICE_API_KEY", "")


def _auth(x_service_key: str = Header(...)):
    if not _SERVICE_KEY:
        raise HTTPException(500, "SERVICE_API_KEY not configured on server")
    if not secrets.compare_digest(x_service_key, _SERVICE_KEY):
        raise HTTPException(401, "Invalid service key")


def _get_provider():
    name = os.environ.get("DEFAULT_PROVIDER", "anthropic")
    key = (
        os.environ.get("ANTHROPIC_API_KEY", "")
        if name == "anthropic"
        else os.environ.get("OPENAI_API_KEY", "")
    )
    return build_provider(name, api_key=key or None)


def _intake_model() -> str:
    name = os.environ.get("DEFAULT_PROVIDER", "anthropic")
    return AnthropicProvider.INTAKE_MODEL if name == "anthropic" else OpenAIProvider.INTAKE_MODEL


def _augment_model() -> str:
    name = os.environ.get("DEFAULT_PROVIDER", "anthropic")
    return AnthropicProvider.AUGMENT_MODEL if name == "anthropic" else OpenAIProvider.AUGMENT_MODEL


# =========================================
# SCHEMAS
# =========================================

class NoteSchema(BaseModel):
    note_type: str
    front: str
    back: str
    extra: str = ""
    tags: List[str] = []


class ParseRequest(BaseModel):
    text: str
    strict_repair: bool = False


class ValidateRequest(BaseModel):
    notes: List[NoteSchema]


class BuildRequest(BaseModel):
    notes: List[NoteSchema]
    deck_name: str = "My Deck"
    classify: bool = True
    strict_repair: bool = False


class TopicRequest(BaseModel):
    topic: str
    specialty: Optional[str] = None
    card_count: int = 20


class AugmentGenerateRequest(BaseModel):
    notes: List[NoteSchema]


class AugmentApplyRequest(BaseModel):
    notes: List[NoteSchema]
    proposals: List[Dict[str, Any]]
    accepted_indices: List[int]
    expansion_mode: str = "append"   # append | empty_only | overwrite


class DedupeRequest(BaseModel):
    notes: List[NoteSchema]
    existing_apkg_b64: str           # base64-encoded .apkg bytes


# =========================================
# HELPERS
# =========================================

def _to_note(s: NoteSchema) -> Note:
    return Note(
        note_type=s.note_type,
        front=s.front,
        back=s.back,
        extra=s.extra,
        tags=tuple(s.tags),
    )


def _from_note(n: Note) -> dict:
    return {
        "note_type": n.note_type,
        "front": n.front,
        "back": n.back,
        "extra": n.extra,
        "tags": list(n.tags),
    }


def _expansion_mode(label: str) -> ExpansionMode:
    return {
        "append":     ExpansionMode.APPEND,
        "empty_only": ExpansionMode.EMPTY_ONLY,
        "overwrite":  ExpansionMode.OVERWRITE,
    }.get(label, ExpansionMode.APPEND)


# =========================================
# ROUTES
# =========================================

@app.get("/health")
def health():
    return {"status": "ok", "service": "decksmith"}


@app.post("/parse", dependencies=[Depends(_auth)])
def parse(req: ParseRequest):
    """Parse plain-text card format into a list of notes."""
    notes = parse_text_to_notes(req.text, strict_repair=req.strict_repair)
    return {"notes": [_from_note(n) for n in notes], "count": len(notes)}


@app.post("/validate", dependencies=[Depends(_auth)])
def validate(req: ValidateRequest):
    """Validate a list of notes, classify each as valid / fixable / invalid."""
    notes = [_to_note(s) for s in req.notes]
    results = validate_notes(notes)
    s = validator_summary(results)
    return {
        "summary": s,
        "results": [
            {
                "index": i,
                "status": r.status,
                "error": r.error,
                "fix_description": r.fix_description,
                "preview": r.preview,
                "fixed_note": _from_note(r.fixed_note) if r.fixed_note else None,
            }
            for i, r in enumerate(results)
        ],
    }


@app.post("/build", dependencies=[Depends(_auth)])
def build(req: BuildRequest):
    """
    Classify and build an .apkg from a list of notes.
    Returns the binary .apkg file directly.
    """
    notes = [_to_note(s) for s in req.notes]

    if req.classify:
        notes, report = classify_notes(notes, DEFAULT_TAXONOMY)
        matched = report.matched_notes
        unmatched = report.unmatched_notes
    else:
        matched = unmatched = 0

    result = build_deck(notes=notes, deck_name=req.deck_name, strict_repair=req.strict_repair)

    with tempfile.NamedTemporaryFile(suffix=".apkg", delete=False) as tmp:
        genanki.Package(list(result.decks)).write_to_file(tmp.name)
        apkg_bytes = Path(tmp.name).read_bytes()
    Path(tmp.name).unlink(missing_ok=True)

    return Response(
        content=apkg_bytes,
        media_type="application/octet-stream",
        headers={
            "X-Total-Notes": str(result.total_notes),
            "X-Total-Cards": str(result.total_cards),
            "X-Matched": str(matched),
            "X-Unmatched": str(unmatched),
            "Content-Disposition": f'attachment; filename="{req.deck_name}.apkg"',
        },
    )


@app.post("/topic/generate", dependencies=[Depends(_auth)])
def topic_generate(req: TopicRequest):
    """Generate flashcards for a medical topic using AI."""
    provider = _get_provider()
    result = generate_cards_for_topic(
        topic=req.topic,
        provider=provider,
        model=_augment_model(),
        specialty=req.specialty,
        card_count=req.card_count,
    )
    if result.failed:
        raise HTTPException(502, f"AI generation failed: {result.error}")
    return {
        "notes": [_from_note(n) for n in result.notes],
        "raw_text": result.raw_text,
        "card_count": result.card_count,
        "topic": result.topic,
    }


@app.post("/augment/generate", dependencies=[Depends(_auth)])
def augment_generate(req: AugmentGenerateRequest):
    """Generate AI augmentation proposals for a list of notes."""
    notes = [_to_note(s) for s in req.notes]
    provider = _get_provider()
    proposals = generate_augmentation_proposals(notes, provider, _augment_model())
    return {
        "proposals": [
            {
                "index": i,
                "succeeded": p.succeeded,
                "error": p.error,
                "identity": p.identity,
                "note": _from_note(p.note),
                "payload": {
                    "primary_concept":      p.payload.primary_concept      if p.payload else None,
                    "mechanism":            p.payload.mechanism             if p.payload else None,
                    "high_yield_points":    list(p.payload.high_yield_points) if p.payload else [],
                    "clinical_context":     p.payload.clinical_context      if p.payload else None,
                    "exam_trap":            p.payload.exam_trap             if p.payload else None,
                    "normal_vs_pathologic": p.payload.normal_vs_pathologic  if p.payload else None,
                } if p.payload else None,
            }
            for i, p in enumerate(proposals)
        ],
        "total": len(proposals),
        "succeeded": sum(1 for p in proposals if p.succeeded),
    }


@app.post("/augment/apply", dependencies=[Depends(_auth)])
def augment_apply(req: AugmentApplyRequest):
    """Apply accepted augmentation proposals to notes."""
    from core.augment_ai import AugmentationProposal
    from core.augmentation import ExpansionPayload

    notes = [_to_note(s) for s in req.notes]
    mode = _expansion_mode(req.expansion_mode)
    policy = AugmentationPolicy(schema_version="1.0.0", expansion_mode=mode)

    # Rebuild proposal objects from the JSON the caller stored
    proposals = []
    for p_dict in req.proposals:
        raw_payload = p_dict.get("payload")
        payload = None
        if raw_payload:
            payload = ExpansionPayload(
                primary_concept=raw_payload.get("primary_concept", ""),
                mechanism=raw_payload.get("mechanism", ""),
                high_yield_points=tuple(raw_payload.get("high_yield_points", [])),
                clinical_context=raw_payload.get("clinical_context", ""),
                exam_trap=raw_payload.get("exam_trap", ""),
                normal_vs_pathologic=raw_payload.get("normal_vs_pathologic"),
            )
        note = _to_note(NoteSchema(**p_dict["note"]))
        proposals.append(AugmentationProposal(
            note=note,
            identity=p_dict.get("identity", ""),
            payload=payload,
            succeeded=p_dict.get("succeeded", False),
            error=p_dict.get("error", ""),
        ))

    accepted = set(req.accepted_indices)
    payload_map = build_payload_map(proposals, accepted)
    augmented, _ = augment_notes(notes=notes, payload_map=payload_map, policy=policy)

    return {"notes": [_from_note(n) for n in augmented]}


@app.post("/dedupe", dependencies=[Depends(_auth)])
def dedupe(req: DedupeRequest):
    """
    Given a list of notes and an existing .apkg (base64-encoded),
    return only the notes not already in the existing deck.
    """
    import base64
    try:
        apkg_bytes = base64.b64decode(req.existing_apkg_b64)
    except Exception:
        raise HTTPException(400, "existing_apkg_b64 is not valid base64")

    import_result = read_apkg(apkg_bytes)
    if import_result.failed:
        raise HTTPException(422, f"Could not read .apkg: {import_result.error}")

    notes = [_to_note(s) for s in req.notes]
    new_notes, dupes = filter_new_notes(notes, import_result.identity_set)

    return {
        "new_notes": [_from_note(n) for n in new_notes],
        "duplicate_count": len(dupes),
        "new_count": len(new_notes),
    }
