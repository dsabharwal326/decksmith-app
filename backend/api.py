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
import threading
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import genanki
from fastapi import Depends, FastAPI, HTTPException, Header, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from core.engine import Note, build_deck, parse_text_to_notes, parse_auto, detect_format
from core.validator import validate_notes, summary as validator_summary
from core.classifier import classify_notes
from core.taxonomy import DEFAULT_TAXONOMY
from core.augmentation import augment_notes
from core.augmentation_policy import AugmentationPolicy, ExpansionMode
from core.augment_ai import generate_augmentation_proposals, generate_style_rewrite_proposals, build_payload_map
from core.card_factory import generate_cards_for_topic, notes_to_text
from core.provider import build_provider, AnthropicProvider, OpenAIProvider, Provider
from core.apkg_import import read_apkg, filter_new_notes, dedup_notes
from core.card_combiner import combine_cards
from core.wikimedia import search_image, image_html


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

# Default to "decksmith" so local desktop users need zero configuration
_SERVICE_KEY = os.environ.get("SERVICE_API_KEY", "decksmith")


def _auth(x_service_key: str = Header(...)):
    if not secrets.compare_digest(x_service_key, _SERVICE_KEY):
        raise HTTPException(401, "Invalid service key")


def _get_provider(x_anthropic_key: str = Header(None), x_openai_key: str = Header(None)):
    name = os.environ.get("DEFAULT_PROVIDER", "anthropic")
    if name == "anthropic":
        key = x_anthropic_key or os.environ.get("ANTHROPIC_API_KEY", "")
    else:
        key = x_openai_key or os.environ.get("OPENAI_API_KEY", "")
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
    guid: Optional[str] = None


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
    media_files_b64: Optional[Dict[str, str]] = None  # filename -> base64 bytes


class TopicRequest(BaseModel):
    topic: str
    specialty: Optional[str] = None
    card_count: int = 20
    card_style: str = "none"
    usmle_step: str = "step1"           # step1 | step2 | step3
    cloze_density: str = "recommended"  # recommended | single | double | triple
    tag_prefix: str = ""                # e.g. "Cardiology::HeartFailure"
    exclude_topics: str = ""            # comma-separated topics to skip
    mnemonics: bool = False             # embed mnemonics for list/multi-step facts


class RegenerateCardRequest(BaseModel):
    front: str
    topic: str
    specialty: Optional[str] = None
    card_style: str = "none"
    usmle_step: str = "step1"


class MergeRequest(BaseModel):
    apkg_a_b64: str
    apkg_b_b64: str
    deck_name: str = "Merged Deck"
    classify: bool = True


class DetectStepRequest(BaseModel):
    text: str


class EnhancementOptions(BaseModel):
    combine_cards: bool = False
    add_images: bool = False
    add_clinical_context: bool = True
    add_high_yield: bool = True
    add_exam_traps: bool = True
    target_format: str = "keep"      # keep | basic | cloze | basic_extra
    expansion_mode: str = "append"   # append | empty_only | overwrite
    depth: str = "full"              # full | quick
    provider: str = "anthropic"      # anthropic | openai | ollama
    ollama_model: str = "mistral"
    anthropic_model: str = ""        # empty = use server default
    openai_model: str = ""           # empty = use server default
    card_style: str = "none"         # none | cheesy_dorian | anking | zanki | lightyear | brosencephalon


class AugmentGenerateRequest(BaseModel):
    notes: List[NoteSchema]
    options: Optional[EnhancementOptions] = None


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
        guid=s.guid or None,
    )


def _from_note(n: Note) -> dict:
    return {
        "note_type": n.note_type,
        "front": n.front,
        "back": n.back,
        "extra": n.extra,
        "tags": list(n.tags),
        "guid": n.guid,
    }


def _expansion_mode(label: str) -> ExpansionMode:
    return {
        "append":     ExpansionMode.APPEND,
        "empty_only": ExpansionMode.EMPTY_ONLY,
        "overwrite":  ExpansionMode.OVERWRITE,
    }.get(label, ExpansionMode.APPEND)


# =========================================
# BACKGROUND JOB STORE
# =========================================

@dataclass
class _AugmentJob:
    status: str = "pending"   # pending | running | done | failed | cancelled
    done_count: int = 0
    total: int = 0
    result: Optional[dict] = None
    error: str = ""
    created_at: float = field(default_factory=lambda: __import__("time").time(), compare=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, compare=False, repr=False)
    _cancel: threading.Event = field(default_factory=threading.Event, compare=False, repr=False)

_jobs: Dict[str, _AugmentJob] = {}
_jobs_lock = threading.Lock()


def _sweep_expired_jobs():
    import time
    while True:
        time.sleep(600)
        cutoff = time.time() - 1800  # 30 min TTL
        with _jobs_lock:
            expired = [jid for jid, j in _jobs.items() if j.created_at < cutoff]
            for jid in expired:
                del _jobs[jid]

threading.Thread(target=_sweep_expired_jobs, daemon=True).start()


def _run_augment_job(job_id: str, req_notes, opts, provider, model):
    """Runs augmentation in a background thread, updating the job store."""
    import base64 as _base64
    job = _jobs[job_id]

    try:
        with job._lock:
            job.status = "running"

        notes = [_to_note(s) for s in req_notes]

        # ── 1. Combine related cards ──────────────────────────────────────────
        if opts.combine_cards:
            notes = combine_cards(notes, provider, model)

        # ── 2. Format conversion ──────────────────────────────────────────────
        if opts.target_format != "keep":
            converted = []
            for n in notes:
                if opts.target_format == "basic_extra":
                    converted.append(Note(note_type="basic_extra", front=n.front, back=n.back, extra=n.extra, tags=n.tags))
                elif opts.target_format == "basic":
                    import re as _re
                    front = _re.sub(r"\{\{c\d+::(.*?)(?:::[^}]*)?\}\}", r"\1", n.front)
                    converted.append(Note(note_type="basic", front=front, back=n.back, extra=n.extra, tags=n.tags))
                elif opts.target_format == "cloze":
                    if "{{c" in n.front:
                        converted.append(n)
                    else:
                        converted.append(Note(note_type="cloze", front=f"{{{{c1::{n.front}}}}} - {n.back}", back="", extra=n.extra, tags=n.tags))
                else:
                    converted.append(n)
            notes = converted

        # ── 3. AI content enhancement ─────────────────────────────────────────
        from core.augment_ai import AugmentationProposal as _AP
        from core.augmentation import _note_identity as _ni

        MAX_ENHANCE = 1500
        cap_notes = notes[:MAX_ENHANCE]
        overflow_notes = notes[MAX_ENHANCE:]

        with job._lock:
            job.total = len(cap_notes)

        def _progress(done: int, total: int):
            with job._lock:
                job.done_count = done
                job.total = total

        if job._cancel.is_set():
            with job._lock:
                job.status = "cancelled"
                job.error = "Cancelled by user"
            return

        is_local = opts.provider == "ollama"

        # ── Style rewrite path ────────────────────────────────────────────────
        if opts.card_style and opts.card_style != "none":
            style_results = generate_style_rewrite_proposals(
                cap_notes, opts.card_style, provider, model,
                progress_callback=_progress,
                max_workers=2 if is_local else 4,
                batch_size=1 if is_local else 5,
                depth=opts.depth,
            )
            # Encode as style-rewrite proposal dicts (no AugmentationProposal wrapper)
            proposal_dicts = []
            for note, r in zip(cap_notes, style_results):
                proposal_dicts.append({
                    "style_rewrite": True,
                    "note": _from_note(note),
                    "identity": _ni(note),
                    "new_front": r.get("new_front", ""),
                    "new_extra": r.get("new_extra", ""),
                    "succeeded": r.get("succeeded", False),
                    "error": r.get("error", ""),
                })
            for note in overflow_notes:
                proposal_dicts.append({
                    "style_rewrite": True,
                    "note": _from_note(note),
                    "identity": _ni(note),
                    "new_front": "", "new_extra": "",
                    "succeeded": False, "error": "skipped: deck too large",
                })

            with job._lock:
                job.status = "done"
                job.result = {"proposals": proposal_dicts, "style_rewrite": True}
            return

        # ── Structured enrichment path ────────────────────────────────────────
        # Skip cards that already have extra content (unless overwrite mode)
        if opts.expansion_mode != "overwrite":
            enhance_notes = [n for n in cap_notes if not n.extra.strip()]
            preloaded = [n for n in cap_notes if n.extra.strip()]
        else:
            enhance_notes = cap_notes
            preloaded = []

        with job._lock:
            job.total = len(enhance_notes)

        proposals = generate_augmentation_proposals(
            enhance_notes, provider, model,
            progress_callback=_progress,
            include_clinical_context=opts.add_clinical_context,
            include_high_yield=opts.add_high_yield,
            include_exam_traps=opts.add_exam_traps,
            max_workers=2 if is_local else 4,
            batch_size=1 if is_local else 10,
            depth=opts.depth,
        )

        for n in preloaded:
            proposals.append(_AP(note=n, identity=_ni(n), payload=None, succeeded=False, error="skipped: already has content"))
        for n in overflow_notes:
            proposals.append(_AP(note=n, identity=_ni(n), payload=None, succeeded=False, error="skipped: deck too large"))

        # ── 4. Image search ───────────────────────────────────────────────────
        media_files: Dict[str, str] = {}
        proposal_image_html: Dict[int, str] = {}
        if opts.add_images:
            seen_concepts: set = set()
            img_count = 0
            for i, p in enumerate(proposals):
                if not p.succeeded or p.payload is None:
                    continue
                if img_count >= 20:
                    break
                concept = p.payload.primary_concept.lower().strip()
                if concept in seen_concepts:
                    continue
                seen_concepts.add(concept)
                query = f"{p.payload.primary_concept} anatomy diagram medical"
                result = search_image(query)
                if result:
                    fname, img_bytes = result
                    media_files[fname] = _base64.b64encode(img_bytes).decode()
                    proposal_image_html[i] = image_html(fname)
                    img_count += 1

        result_payload = {
            "proposals": [
                {
                    "index": i,
                    "succeeded": p.succeeded,
                    "error": p.error,
                    "identity": p.identity,
                    "note": _from_note(p.note),
                    "image_html": proposal_image_html.get(i),
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
            "notes": [_from_note(n) for n in notes],
            "media_files_b64": media_files,
        }

        with job._lock:
            job.status = "done"
            job.done_count = len(enhance_notes)
            job.total = len(enhance_notes)
            job.result = result_payload

    except Exception as e:
        with job._lock:
            job.status = "failed"
            job.error = str(e)


# =========================================
# ROUTES
# =========================================

@app.get("/health")
def health():
    return {"status": "ok", "service": "decksmith"}


@app.post("/parse", dependencies=[Depends(_auth)])
def parse(req: ParseRequest):
    """Parse plain-text card format into a list of notes."""
    notes = parse_auto(req.text, strict_repair=req.strict_repair)
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

    # Deduplicate within the submitted card set before building
    notes, dupe_count = dedup_notes(notes)

    if req.classify:
        notes, report = classify_notes(notes, DEFAULT_TAXONOMY)
        matched = report.matched_notes
        unmatched = report.unmatched_notes
    else:
        matched = unmatched = 0

    result = build_deck(notes=notes, deck_name=req.deck_name, strict_repair=req.strict_repair)

    # Write any embedded media to temp files
    import base64 as _base64
    media_paths: List[str] = []
    media_tmp_dir = None
    if req.media_files_b64:
        media_tmp_dir = tempfile.mkdtemp()
        for fname, b64 in req.media_files_b64.items():
            fpath = os.path.join(media_tmp_dir, fname)
            Path(fpath).write_bytes(_base64.b64decode(b64))
            media_paths.append(fpath)

    with tempfile.NamedTemporaryFile(suffix=".apkg", delete=False) as tmp:
        genanki.Package(list(result.decks), media_files=media_paths).write_to_file(tmp.name)
        apkg_bytes = Path(tmp.name).read_bytes()
    Path(tmp.name).unlink(missing_ok=True)

    # Clean up media temp files
    if media_tmp_dir:
        import shutil
        shutil.rmtree(media_tmp_dir, ignore_errors=True)

    return Response(
        content=apkg_bytes,
        media_type="application/octet-stream",
        headers={
            "X-Total-Notes": str(result.total_notes),
            "X-Total-Cards": str(result.total_cards),
            "X-Matched": str(matched),
            "X-Unmatched": str(unmatched),
            "X-Dupes-Removed": str(dupe_count),
            "Content-Disposition": f'attachment; filename="{req.deck_name}.apkg"',
        },
    )


@app.post("/topic/generate", dependencies=[Depends(_auth)])
def topic_generate(req: TopicRequest, provider: Provider = Depends(_get_provider)):
    """Generate flashcards for a medical topic using AI."""
    result = generate_cards_for_topic(
        topic=req.topic,
        provider=provider,
        model=_augment_model(),
        specialty=req.specialty,
        card_count=req.card_count,
        usmle_step=req.usmle_step,
        cloze_density=req.cloze_density,
        tag_prefix=req.tag_prefix,
        exclude_topics=req.exclude_topics,
        mnemonics=req.mnemonics,
    )
    if result.failed:
        raise HTTPException(502, f"AI generation failed: {result.error}")
    notes = result.notes
    if req.card_style and req.card_style != "none":
        from core.augment_ai import generate_style_rewrite_proposals
        rewrites = generate_style_rewrite_proposals(
            notes=notes,
            style=req.card_style,
            provider=provider,
            model=_augment_model(),
        )
        import re as _re
        rewritten = []
        for note, rw in zip(notes, rewrites):
            if rw.get("succeeded") and rw.get("new_front"):
                new_front = rw["new_front"]
                new_extra = rw.get("new_extra", note.extra)
                has_cloze = bool(_re.search(r"\{\{c\d+::", new_front))
                new_type = "cloze" if has_cloze else note.note_type
                from core.engine import Note
                rewritten.append(Note(
                    note_type=new_type, front=new_front,
                    back=note.back, extra=new_extra, tags=note.tags,
                ))
            else:
                rewritten.append(note)
        notes = rewritten
    return {
        "notes": [_from_note(n) for n in notes],
        "raw_text": result.raw_text,
        "card_count": len(notes),
        "topic": result.topic,
    }


@app.post("/topic/regenerate_card", dependencies=[Depends(_auth)])
def topic_regenerate_card(req: RegenerateCardRequest, provider: Provider = Depends(_get_provider)):
    """Regenerate a single card given its front text and topic context."""
    from core.card_factory import _build_system
    system = _build_system(req.usmle_step)
    user_prompt = (
        f"The deck topic is: {req.topic}.\n"
        f"Regenerate the following flashcard with improved wording, "
        f"keeping the same core fact but making it more memorable and precise.\n"
        f"Original front: {req.front}\n\n"
        f"Output exactly ONE card line in Decksmith format (e.g. Front :: Back, cloze, etc). "
        f"No explanations, no markdown."
    )
    try:
        resp = provider.complete(system=system, user=user_prompt,
                                 model=_augment_model(), max_tokens=300, temperature=0.5)
        notes = parse_auto(resp.text.strip(), strict_repair=False)
        note = notes[0] if notes else None
    except Exception as e:
        raise HTTPException(502, f"Regeneration failed: {e}")
    if not note:
        raise HTTPException(502, "Model returned no usable card")
    return {"note": _from_note(note)}


@app.post("/deck/merge", dependencies=[Depends(_auth)])
def deck_merge(req: MergeRequest):
    """Merge two .apkg files into one deck, deduplicating by card front."""
    import base64
    try:
        bytes_a = base64.b64decode(req.apkg_a_b64)
        bytes_b = base64.b64decode(req.apkg_b_b64)
    except Exception:
        raise HTTPException(400, "Invalid base64 in apkg_a_b64 or apkg_b_b64")

    res_a = read_apkg(bytes_a)
    res_b = read_apkg(bytes_b)
    if res_a.failed:
        raise HTTPException(422, f"Could not read first deck: {res_a.error}")
    if res_b.failed:
        raise HTTPException(422, f"Could not read second deck: {res_b.error}")

    combined = list(res_a.notes) + list(res_b.notes)
    # Deduplicate preserving order — keep first occurrence of each front
    seen: set[str] = set()
    unique: list = []
    for n in combined:
        key = n.front.strip().lower()
        if key not in seen:
            seen.add(key)
            unique.append(n)
    dupe_count = len(combined) - len(unique)

    if req.classify:
        unique, _ = classify_notes(unique, DEFAULT_TAXONOMY)

    result = build_deck(notes=unique, deck_name=req.deck_name)
    with tempfile.NamedTemporaryFile(suffix=".apkg", delete=False) as tmp:
        genanki.Package(list(result.decks)).write_to_file(tmp.name)
        apkg_bytes = Path(tmp.name).read_bytes()
    Path(tmp.name).unlink(missing_ok=True)

    import base64 as _b64
    return {
        "apkg_b64": _b64.b64encode(apkg_bytes).decode(),
        "total_notes": len(unique),
        "duplicate_count": dupe_count,
        "deck_name": req.deck_name,
    }


@app.post("/detect/step", dependencies=[Depends(_auth)])
def detect_step(req: DetectStepRequest):
    """Heuristic USMLE step detection from card text. No AI — instant."""
    import re
    text = req.text.lower()

    step1_kw = [
        "mechanism", "moa", "pathophysiology", "biochemistry", "enzyme",
        "receptor", "gene", "chromosome", "embryology", "histology",
        "synthesis", "degradation", "allele", "inheritance", "microtubule",
        "transcription", "translation", "mutation", "ion channel",
    ]
    step2_kw = [
        "diagnosis", "management", "treatment", "first-line", "workup",
        "presentation", "physical exam", "imaging", "labs", "hospitalize",
        "admission", "discharge", "prescription", "referral", "biopsy",
        "surgery", "antibiotic", "dose", "clinical", "symptom",
    ]
    step3_kw = [
        "screening", "preventive", "ambulatory", "outpatient", "chronic",
        "followup", "counseling", "epidemiology", "biostatistics", "incidence",
        "prevalence", "sensitivity", "specificity", "vaccine", "immunization",
        "health maintenance", "ppd", "mammogram", "colonoscopy", "public health",
    ]

    def score(kws: list[str]) -> int:
        return sum(1 for k in kws if re.search(r'\b' + re.escape(k) + r'\b', text))

    s1, s2, s3 = score(step1_kw), score(step2_kw), score(step3_kw)
    best = max(s1, s2, s3)
    if best == 0:
        step = "step1"
    elif s1 >= s2 and s1 >= s3:
        step = "step1"
    elif s2 >= s3:
        step = "step2"
    else:
        step = "step3"
    return {"step": step, "scores": {"step1": s1, "step2": s2, "step3": s3}}


@app.post("/augment/generate", dependencies=[Depends(_auth)])
def augment_generate(req: AugmentGenerateRequest):
    """Start AI augmentation as a background job. Returns job_id immediately.
    Poll GET /augment/job/{job_id} for progress and results."""
    opts = req.options or EnhancementOptions()

    try:
        if opts.provider == "ollama":
            from core.provider import OllamaProvider
            provider = OllamaProvider(model=opts.ollama_model)
            model = opts.ollama_model
        else:
            name = opts.provider if opts.provider in ("anthropic", "openai") else os.environ.get("DEFAULT_PROVIDER", "anthropic")
            key = (
                os.environ.get("ANTHROPIC_API_KEY", "") if name == "anthropic"
                else os.environ.get("OPENAI_API_KEY", "")
            )
            provider = build_provider(name, api_key=key or None)
            if name == "anthropic":
                model = opts.anthropic_model or AnthropicProvider.AUGMENT_MODEL
            else:
                model = opts.openai_model or OpenAIProvider.AUGMENT_MODEL
    except Exception as e:
        raise HTTPException(502, f"AI provider unavailable: {e}")
    job_id = str(uuid.uuid4())
    job = _AugmentJob(total=len(req.notes))

    with _jobs_lock:
        _jobs[job_id] = job

    t = threading.Thread(
        target=_run_augment_job,
        args=(job_id, req.notes, opts, provider, model),
        daemon=True,
    )
    t.start()

    return {"job_id": job_id, "total": len(req.notes)}


@app.get("/augment/job/{job_id}", dependencies=[Depends(_auth)])
def augment_job_status(job_id: str):
    """Poll augmentation job progress. When status='done', result is included."""
    with _jobs_lock:
        job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "Job not found")

    with job._lock:
        resp: dict = {
            "status": job.status,
            "done_count": job.done_count,
            "total": job.total,
            "error": job.error,
        }
        if job.status in ("done", "failed", "cancelled"):
            resp["result"] = job.result
            with _jobs_lock:
                _jobs.pop(job_id, None)

    return resp


@app.delete("/augment/job/{job_id}", dependencies=[Depends(_auth)])
def augment_job_cancel(job_id: str):
    """Cancel a running augmentation job."""
    with _jobs_lock:
        job = _jobs.get(job_id)
    if job is None:
        return {"cancelled": False, "reason": "not found"}
    job._cancel.set()
    return {"cancelled": True}


@app.get("/cache/stats", dependencies=[Depends(_auth)])
def cache_stats():
    from core import enhancement_cache as _ec
    return _ec.stats()


@app.delete("/cache", dependencies=[Depends(_auth)])
def cache_clear():
    from core import enhancement_cache as _ec
    try:
        with _ec._lock:
            _ec._get_conn().execute("DELETE FROM enhancements")
            _ec._get_conn().commit()
        return {"cleared": True}
    except Exception as e:
        raise HTTPException(500, str(e))


@app.post("/augment/apply", dependencies=[Depends(_auth)])
def augment_apply(req: AugmentApplyRequest):
    """Apply accepted augmentation proposals to notes."""
    from core.augment_ai import AugmentationProposal
    from core.augmentation import ExpansionPayload

    notes = [_to_note(s) for s in req.notes]
    accepted = set(req.accepted_indices)

    # ── Style-rewrite path ────────────────────────────────────────────────────
    # Detect style-rewrite proposals (they have "style_rewrite": true).
    if req.proposals and req.proposals[0].get("style_rewrite"):
        # Build identity → new_front/new_extra from accepted proposals
        rewrite_map: dict = {}
        for i, p_dict in enumerate(req.proposals):
            if i in accepted and p_dict.get("succeeded"):
                note = _to_note(NoteSchema(**p_dict["note"]))
                identity = p_dict.get("identity", "")
                rewrite_map[identity] = (
                    p_dict.get("new_front", ""),
                    p_dict.get("new_extra", ""),
                )

        from core.augmentation import _note_identity as _ni
        result_notes = []
        for n in notes:
            identity = _ni(n)
            if identity in rewrite_map:
                new_front, new_extra = rewrite_map[identity]
                if new_front:
                    # Preserve note_type; if new_front has cloze syntax, use cloze
                    import re as _re
                    has_cloze = bool(_re.search(r"\{\{c\d+::", new_front))
                    new_type = "cloze" if has_cloze else n.note_type
                    n = Note(note_type=new_type, front=new_front, back=n.back, extra=new_extra, tags=n.tags)
            result_notes.append(n)
        return {"notes": [_from_note(n) for n in result_notes]}

    # ── Structured enrichment path ────────────────────────────────────────────
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

    # Build image_html lookup: identity -> image_html
    image_map = {
        p_dict.get("identity", ""): p_dict.get("image_html")
        for p_dict in req.proposals
        if p_dict.get("image_html")
    }

    payload_map = {}
    front_to_identity = {}
    for i, p in enumerate(proposals):
        front_to_identity[p.note.front] = p.identity
        if i in accepted and p.payload is not None:
            payload_map[p.identity] = p.payload
    augmented, _ = augment_notes(notes=notes, payload_map=payload_map, policy=policy)

    if image_map:
        final = []
        for n in augmented:
            identity = front_to_identity.get(n.front)
            img = image_map.get(identity or "")
            if img:
                n = Note(
                    note_type=n.note_type, front=n.front, back=n.back,
                    extra=n.extra + img, tags=n.tags,
                )
            final.append(n)
        augmented = final

    return {"notes": [_from_note(n) for n in augmented]}


class ImportRequest(BaseModel):
    apkg_b64: str


@app.post("/import", dependencies=[Depends(_auth)])
def import_apkg(req: ImportRequest):
    """
    Read cards out of an existing .apkg file and return them as notes.
    Used by the Enhance flow to load an existing deck for AI augmentation.
    """
    import base64
    try:
        apkg_bytes = base64.b64decode(req.apkg_b64)
    except Exception:
        raise HTTPException(400, "apkg_b64 is not valid base64")

    result = read_apkg(apkg_bytes)
    if result.failed:
        raise HTTPException(422, f"Could not read .apkg: {result.error}")

    notes = [
        {
            "note_type": "basic_extra" if n.note_type == "basic" else n.note_type,
            "front": n.front,
            "back": n.back,
            "extra": "",
            "tags": [],
            "guid": n.guid or None,
        }
        for n in result.notes
    ]
    return {"notes": notes, "count": len(notes)}


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
    new_notes, dupes = filter_new_notes(
        notes, import_result.identity_set, existing_notes=import_result.notes
    )

    return {
        "new_notes": [_from_note(n) for n in new_notes],
        "duplicate_count": len(dupes),
        "new_count": len(new_notes),
    }


@app.get("/ollama/models", dependencies=[Depends(_auth)])
def ollama_models():
    """Return list of locally available Ollama models."""
    import urllib.request, json as _json
    try:
        with urllib.request.urlopen("http://localhost:11434/api/tags", timeout=5) as resp:
            data = _json.loads(resp.read())
        models = [m["name"] for m in data.get("models", [])]
        return {"models": models, "available": True}
    except Exception as e:
        return {"models": [], "available": False, "error": str(e)}


@app.get("/debug/ai", dependencies=[Depends(_auth)])
def debug_ai():
    """Test AI provider with a plain ASCII message and return full error info."""
    import traceback as _tb
    try:
        provider = _get_provider()
        resp = provider.complete(
            system="You are a helpful assistant.",
            user="Say hello in one word.",
            model=_augment_model(),
            max_tokens=10,
            temperature=0.0,
        )
        return {"ok": True, "response": resp.text}
    except Exception as e:
        return {"ok": False, "error": str(e), "traceback": _tb.format_exc()}


# =========================================
# PDF IMPORT
# =========================================

class PdfImportRequest(BaseModel):
    pdf_b64: str


@app.post("/import/pdf", dependencies=[Depends(_auth)])
def import_pdf(req: PdfImportRequest):
    """Extract text from a PDF and parse it into notes."""
    try:
        import pdfplumber
    except ImportError:
        raise HTTPException(500, "pdfplumber not installed — run: pip install pdfplumber")

    try:
        pdf_bytes = io.BytesIO(__import__("base64").b64decode(req.pdf_b64))
        pages: list[str] = []
        with pdfplumber.open(pdf_bytes) as pdf:
            for page in pdf.pages:
                text = page.extract_text()
                if text:
                    pages.append(text.strip())
        full_text = "\n\n".join(pages)
        if not full_text.strip():
            raise HTTPException(422, "No text could be extracted from this PDF. It may be a scanned image — try image import instead.")
        notes = parse_auto(full_text)
        return {"notes": [_from_note(n) for n in notes], "page_count": len(pages), "char_count": len(full_text)}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, f"PDF import failed: {e}")


# =========================================
# IMAGE IMPORT (Claude vision)
# =========================================

class ImageImportRequest(BaseModel):
    image_b64: str
    media_type: str = "image/jpeg"   # image/jpeg | image/png | image/webp | image/gif


_IMAGE_SYSTEM = """You are a medical flashcard extraction assistant.
The user will show you an image containing study notes, slides, or textbook content.
Extract all flashcard-worthy facts and return them as a plain-text flashcard list.

Format each card as:
Q: <question or term>
A: <answer or definition>

Rules:
- One card per distinct fact, concept, drug, or mechanism
- Keep Q concise (≤15 words), A complete but focused
- Ignore page numbers, headers, decorative text
- If the image has a table, extract each row as a card
- Output ONLY the Q:/A: pairs, no preamble"""


@app.post("/import/image", dependencies=[Depends(_auth)])
def import_image(req: ImageImportRequest, x_anthropic_key: str = Header(None)):
    """Use Claude vision to extract flashcards from an image."""
    import base64 as _b64
    import anthropic as _anthropic

    api_key = x_anthropic_key or os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        raise HTTPException(400, "Anthropic API key required for image import. Add it in Settings.")

    try:
        client = _anthropic.Anthropic(api_key=api_key)
        msg = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=2048,
            system=_IMAGE_SYSTEM,
            messages=[{
                "role": "user",
                "content": [{
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": req.media_type,
                        "data": req.image_b64,
                    },
                }, {
                    "type": "text",
                    "text": "Extract all flashcards from this image.",
                }],
            }],
        )
        raw_text = msg.content[0].text
        notes = parse_auto(raw_text)
        return {"notes": [_from_note(n) for n in notes], "raw_text": raw_text}
    except _anthropic.AuthenticationError:
        raise HTTPException(401, "Invalid Anthropic API key.")
    except Exception as e:
        raise HTTPException(500, f"Image import failed: {e}")
