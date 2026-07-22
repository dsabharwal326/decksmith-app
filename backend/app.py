"""
Decksmith — Streamlit front-end.

Runs locally:  streamlit run app.py
Hosted:        deploy to Streamlit Cloud / Render / Railway
"""
from __future__ import annotations

import io
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Set

import streamlit as st
import genanki

from core.engine import Note, parse_text_to_notes, build_deck
from core.classifier import classify_notes
from core.taxonomy import DEFAULT_TAXONOMY
from core.validator import NoteValidationResult, validate_notes, summary
from core.provider import (
    build_provider, detect_available_provider,
    AnthropicProvider, OpenAIProvider,
    ProviderError, ProviderAuthError,
)
from core.intake import run_intake, IntakeResult
from core.augment_ai import generate_augmentation_proposals, build_payload_map, AugmentationProposal
from core.augmentation import augment_notes
from core.augmentation_policy import AugmentationPolicy, ExpansionMode
from core.card_factory import generate_cards_for_topic, notes_to_text
from core.apkg_import import read_apkg, filter_new_notes


# =========================================
# PAGE CONFIG
# =========================================

st.set_page_config(
    page_title="Decksmith",
    page_icon="🃏",
    layout="centered",
    initial_sidebar_state="collapsed",
)


# =========================================
# SESSION STATE INIT
# =========================================

def _init_state():
    defaults = {
        "all_notes": [],
        "validation_results": [],
        "decisions": {},
        "validated": False,
        "intake_results": {},
        "aug_proposals": [],
        "aug_accepted": set(),
        "built_apkg": None,
        "report_lines": [],
        "factory_notes": [],        # cards generated from topic
        "factory_raw_text": "",     # downloadable .txt version
        "factory_topic": "",
        "existing_identity_set": frozenset(),  # identities from imported .apkg
        "existing_deck_note_count": 0,
    }
    for k, v in defaults.items():
        if k not in st.session_state:
            st.session_state[k] = v

_init_state()


# =========================================
# HELPERS
# =========================================

def _reset():
    keys = ["all_notes", "validation_results", "decisions", "validated",
            "intake_results", "aug_proposals", "aug_accepted", "built_apkg", "report_lines"]
    for k in keys:
        del st.session_state[k]
    _init_state()
    st.rerun()


def _log(line: str):
    st.session_state.report_lines.append(line)


def _secret_key(name: str) -> str:
    """Pull a key from st.secrets (Streamlit Cloud) if present, else empty string."""
    try:
        return st.secrets.get("api_keys", {}).get(name, "") or ""
    except Exception:
        return ""


def _get_provider(provider_name: str, api_key: str):
    key = api_key.strip() or None
    return build_provider(provider_name, api_key=key)


def _resolved_notes() -> List[Note]:
    notes: List[Note] = []
    for i, result in enumerate(st.session_state.validation_results):
        if result.status == "valid":
            notes.append(result.note)
        elif result.status == "fixable":
            if st.session_state.decisions.get(i) == "accept" and result.fixed_note:
                notes.append(result.fixed_note)
        elif result.status == "invalid":
            intake = st.session_state.intake_results.get(i)
            if st.session_state.decisions.get(i) == "accept" and intake and intake.proposed_note:
                notes.append(intake.proposed_note)
    return notes


# =========================================
# UI
# =========================================

st.title("Decksmith")
st.caption("Deterministic Anki deck builder — local or web, Mac, Windows, iOS, Android")

# ─── STEP 0: TOPIC GENERATOR ─────────────────────────────────────────────────

st.header("0  Generate Cards from a Topic", divider="gray")
st.caption("Optional — type a topic and the AI writes a full card set for you. Skip this if you're uploading your own cards.")

MEDICAL_SPECIALTIES = [
    "Any / General",
    "Internal Medicine", "Cardiology", "Pulmonology", "Gastroenterology",
    "Nephrology", "Endocrinology", "Neurology", "Hematology", "Oncology",
    "Rheumatology", "Infectious Disease", "Dermatology", "Ophthalmology",
    "ENT", "Urology", "Psychiatry", "Geriatrics",
    "Surgery", "Orthopedic Surgery", "Neurosurgery", "Cardiothoracic Surgery",
    "OB-GYN", "Obstetrics", "Gynecology", "Maternal-Fetal Medicine",
    "Pediatrics", "Neonatology", "Pediatric Cardiology",
    "Emergency Medicine", "Critical Care / ICU",
    "Radiology", "Anesthesiology",
    "Pharmacology", "Pathophysiology", "Biochemistry",
    "Anatomy", "Physiology", "Microbiology",
    "Preventive Medicine",
]

gen_col1, gen_col2, gen_col3 = st.columns([3, 2, 1])
with gen_col1:
    topic_input = st.text_input(
        "Topic",
        placeholder="e.g. Myocardial Infarction, Beta Blockers, Septic Shock…",
        key="topic_input",
    )
with gen_col2:
    specialty_input = st.selectbox(
        "Specialty (optional)",
        options=MEDICAL_SPECIALTIES,
        key="specialty_input",
    )
with gen_col3:
    card_count = st.number_input("Cards", min_value=5, max_value=60, value=20, step=5)

_topic_btn_placeholder = st.empty()

if st.session_state.factory_notes:
    topic = st.session_state.factory_topic
    notes_gen = st.session_state.factory_notes
    raw_text = st.session_state.factory_raw_text

    st.success(f"Generated {len(notes_gen)} cards on **{topic}**.")

    # Preview — collapsible
    with st.expander("Preview generated cards", expanded=False):
        type_counts: dict = {}
        for n in notes_gen:
            type_counts[n.note_type] = type_counts.get(n.note_type, 0) + 1
        st.caption("  ".join(f"{t}: {c}" for t, c in sorted(type_counts.items())))
        st.code(raw_text[:3000] + ("…" if len(raw_text) > 3000 else ""), language=None)

    dl_col, add_col, clear_col = st.columns(3)
    with dl_col:
        filename_safe = topic.replace(" ", "_").replace("/", "-")
        st.download_button(
            f"⬇  Download {filename_safe}.txt",
            data=raw_text,
            file_name=f"{filename_safe}.txt",
            mime="text/plain",
        )
    with add_col:
        if st.button("➕  Add to pipeline", type="primary"):
            st.session_state.all_notes = notes_gen + st.session_state.all_notes
            # Trigger a fresh validation pass
            from core.validator import validate_notes as _vn, summary as _vs
            results = _vn(st.session_state.all_notes)
            s = _vs(results)
            st.session_state.validation_results = results
            st.session_state.decisions = {
                i: "accept" for i, r in enumerate(results) if r.status == "valid"
            }
            st.session_state.validated = False
            st.session_state.intake_results = {}
            st.session_state.aug_proposals = []
            st.session_state.aug_accepted = set()
            st.session_state.built_apkg = None
            st.session_state.report_lines = [
                f"Added {len(notes_gen)} generated cards for '{topic}'.",
                f"Total: {s['total']}  Valid: {s['valid']}  Fixable: {s['fixable']}  Invalid: {s['invalid']}",
            ]
            st.session_state.factory_notes = []
            st.session_state.factory_raw_text = ""
            st.session_state.factory_topic = ""
            st.rerun()
    with clear_col:
        if st.button("✕  Discard"):
            st.session_state.factory_notes = []
            st.session_state.factory_raw_text = ""
            st.session_state.factory_topic = ""
            st.rerun()

# ─── STEP 1: FILES ───────────────────────────────────────────────────────────

st.header("1  Upload Cards", divider="gray")

uploaded = st.file_uploader(
    "Upload one or more .txt card files",
    type=["txt"],
    accept_multiple_files=True,
    help="Each line should be a card: Front :: Back  or  {{c1::cloze}}  or  Front || Back",
)

# ── Topic generate button (rendered here so provider_choice is in scope) ──────
with _topic_btn_placeholder:
    _cached_provider = st.session_state.get("provider_choice_widget", "none")
    _no_ai = _cached_provider == "none"
    if st.button(
        "Generate Cards",
        disabled=(not topic_input.strip()),
        help="Configure an AI provider in Step 3 first" if _no_ai else "Generate flashcards for this topic",
        key="generate_topic_btn",
    ):
        specialty = None if specialty_input == "Any / General" else specialty_input
        with st.spinner(f"Generating cards on '{topic_input}'…"):
            try:
                if provider_choice == "ollama":
                    from core.provider import OllamaProvider
                    prov = OllamaProvider(model=ollama_model)
                    mdl = ollama_model
                else:
                    prov = _get_provider(provider_choice, api_key_input)
                    mdl = AnthropicProvider.AUGMENT_MODEL if provider_choice == "anthropic" else OpenAIProvider.AUGMENT_MODEL

                result = generate_cards_for_topic(
                    topic=topic_input.strip(),
                    provider=prov,
                    model=mdl,
                    specialty=specialty,
                    card_count=int(card_count),
                )
                if result.failed:
                    st.error(f"Generation failed: {result.error}")
                else:
                    st.session_state.factory_notes = result.notes
                    st.session_state.factory_raw_text = result.raw_text
                    st.session_state.factory_topic = result.topic
            except ProviderAuthError as e:
                st.error(str(e))
            except Exception as e:
                st.error(f"Error: {e}")
        st.rerun()

if uploaded:
    if st.button("Clear and start over", type="secondary"):
        _reset()

# ─── STEP 1b: EXISTING DECK (optional dedup) ─────────────────────────────────

with st.expander("➕  Add to an existing deck (optional — skip duplicates)", expanded=False):
    st.caption(
        "Upload your current .apkg so Decksmith can detect cards you already have. "
        "Any card whose front matches an existing note will be skipped at build time."
    )
    existing_apkg = st.file_uploader(
        "Existing .apkg (optional)",
        type=["apkg"],
        key="existing_apkg_upload",
        help="Upload the deck you're adding to. Decksmith never modifies this file.",
    )
    if existing_apkg is not None:
        apkg_data = existing_apkg.read()
        import_result = read_apkg(apkg_data)
        if import_result.failed:
            st.error(f"Could not read .apkg: {import_result.error}")
            st.session_state.existing_identity_set = frozenset()
            st.session_state.existing_deck_note_count = 0
        else:
            st.session_state.existing_identity_set = import_result.identity_set
            st.session_state.existing_deck_note_count = len(import_result.notes)
            deck_label = ", ".join(
                n for n in import_result.deck_names
                if n and n != "Default"
            )[:60] or "unnamed deck"
            st.success(
                f"Loaded **{len(import_result.notes)} existing notes** from \"{deck_label}\". "
                "Duplicates will be skipped at build time."
            )
    elif st.session_state.existing_deck_note_count > 0:
        st.info(
            f"Using {st.session_state.existing_deck_note_count} notes from previously uploaded deck for dedup."
        )

# ─── STEP 2: SETTINGS ────────────────────────────────────────────────────────

st.header("2  Deck Settings", divider="gray")

col1, col2 = st.columns([2, 1])
with col1:
    deck_name = st.text_input("Deck name", value="My Deck", placeholder="e.g. Step 1 Cardiology")
with col2:
    classify = st.checkbox("Classify into subdecks by specialty", value=True)

# ─── STEP 3: AI SETTINGS ─────────────────────────────────────────────────────

st.header("3  AI Settings", divider="gray")
st.caption("Optional — only needed for 'AI Fix Invalid' and 'AI Augment Cards'. Everything else works offline.")

_cloud_default = (
    "anthropic" if _secret_key("ANTHROPIC_API_KEY") else
    "openai"    if _secret_key("OPENAI_API_KEY")    else
    None
)

ai_col1, ai_col2 = st.columns([1, 2])
with ai_col1:
    _provider_options = ["anthropic", "openai", "ollama", "none"]
    _provider_default_idx = (
        _provider_options.index(_cloud_default)
        if _cloud_default and "provider_choice_widget" not in st.session_state
        else 0
    )
    provider_choice = st.selectbox(
        "Provider",
        options=_provider_options,
        index=_provider_default_idx,
        key="provider_choice_widget",
        format_func=lambda x: {
            "anthropic": "Anthropic (Claude)",
            "openai": "OpenAI (GPT-4)",
            "ollama": "Ollama (local, offline)",
            "none": "No AI",
        }[x],
    )
with ai_col2:
    if provider_choice == "ollama":
        ollama_model = st.text_input("Ollama model", value="llama3", help="Run: ollama pull llama3")
        api_key_input = ""
        st.caption("✓ Ollama runs locally — no API key or internet needed")
    elif provider_choice == "none":
        api_key_input = ""
        st.caption("AI features disabled")
        ollama_model = ""
    else:
        detected = detect_available_provider()
        # Pull from Streamlit Cloud secrets if present
        secret_key_name = "ANTHROPIC_API_KEY" if provider_choice == "anthropic" else "OPENAI_API_KEY"
        cloud_key = _secret_key(secret_key_name)
        placeholder = "Paste key here, or set in environment"
        hint = ""
        if cloud_key:
            hint = "✓ Key loaded from Streamlit Cloud secrets"
        elif detected == provider_choice:
            hint = f"✓ {detected} key detected in environment"
        api_key_input = st.text_input(
            "API Key",
            value=cloud_key,
            type="password",
            placeholder=placeholder,
            help="Key is never stored — used only for this session",
        )
        if hint:
            st.caption(hint)
        ollama_model = ""

# ─── STEP 4: VALIDATE ────────────────────────────────────────────────────────

st.header("4  Validate", divider="gray")

if st.button("Validate Cards", type="primary", disabled=not uploaded):
    all_notes: List[Note] = []
    for f in uploaded:
        text = f.read().decode("utf-8", errors="replace")
        notes = parse_text_to_notes(text, strict_repair=False)
        all_notes.extend(notes)

    results = validate_notes(all_notes)
    s = summary(results)

    st.session_state.all_notes = all_notes
    st.session_state.validation_results = results
    st.session_state.decisions = {i: "accept" for i, r in enumerate(results) if r.status == "valid"}
    st.session_state.validated = False
    st.session_state.intake_results = {}
    st.session_state.aug_proposals = []
    st.session_state.aug_accepted = set()
    st.session_state.built_apkg = None
    st.session_state.report_lines = [
        f"Parsed {len(all_notes)} cards from {len(uploaded)} file(s).",
        f"Valid: {s['valid']}   Fixable: {s['fixable']}   Invalid: {s['invalid']}",
    ]
    st.rerun()

# ─── VALIDATION RESULTS ──────────────────────────────────────────────────────

if st.session_state.validation_results:
    results = st.session_state.validation_results
    s = summary(results)

    # Summary chips
    chip_col1, chip_col2, chip_col3, chip_col4 = st.columns(4)
    chip_col1.metric("Total", s["total"])
    chip_col2.metric("✓ Valid", s["valid"])
    chip_col3.metric("⚠ Fixable", s["fixable"])
    chip_col4.metric("✗ Invalid", s["invalid"])

    issues = [(i, r) for i, r in enumerate(results) if r.status != "valid"]

    if issues:
        st.subheader("Issues to review")

        for i, result in issues:
            color = "orange" if result.status == "fixable" else "red"
            symbol = "⚠️" if result.status == "fixable" else "✗"
            label = f"{symbol} {result.preview[:70]}"

            with st.expander(label, expanded=False):
                if result.error:
                    st.caption(f"**Problem:** {result.error}")

                if result.status == "fixable" and result.fix_description:
                    st.caption(f"**Proposed fix:** {result.fix_description}")
                    current = st.session_state.decisions.get(i, "pending")
                    choice = st.radio(
                        "Decision",
                        ["accept", "reject"],
                        index=0 if current == "accept" else 1,
                        key=f"fix_{i}",
                        horizontal=True,
                        format_func=lambda x: "Accept fix ✓" if x == "accept" else "Skip card ✗",
                    )
                    st.session_state.decisions[i] = choice

                elif result.status == "invalid":
                    intake = st.session_state.intake_results.get(i)
                    if intake and intake.ai_succeeded and intake.proposed_note:
                        st.caption(f"**AI fix:** {intake.ai_explanation}")
                        p = intake.proposed_note
                        st.code(
                            f"Type:  {p.note_type}\n"
                            f"Front: {p.front}\n"
                            f"Back:  {p.back}",
                            language=None,
                        )
                        current = st.session_state.decisions.get(i, "pending")
                        choice = st.radio(
                            "Decision",
                            ["accept", "reject"],
                            index=0 if current == "accept" else 1,
                            key=f"ai_fix_{i}",
                            horizontal=True,
                            format_func=lambda x: "Accept AI fix ✓" if x == "accept" else "Skip card ✗",
                        )
                        st.session_state.decisions[i] = choice
                    elif intake and not intake.ai_succeeded:
                        st.warning(f"AI could not fix: {intake.ai_explanation} — card will be skipped.")
                        st.session_state.decisions[i] = "reject"
                    else:
                        st.info("Click 'AI Fix Invalid Cards' below to let the AI propose a correction, or this card will be skipped.")
                        st.session_state.decisions[i] = "reject"

        # All-decided check
        all_decided = all(
            st.session_state.decisions.get(i, "pending") != "pending"
            for i, _ in issues
        )

        # Quick-select buttons
        qcol1, qcol2 = st.columns(2)
        with qcol1:
            if st.button("Accept all fixable", disabled=s["fixable"] == 0):
                for idx, r in enumerate(results):
                    if r.status == "fixable":
                        st.session_state.decisions[idx] = "accept"
                st.rerun()
        with qcol2:
            if st.button("Skip all fixable", disabled=s["fixable"] == 0):
                for idx, r in enumerate(results):
                    if r.status == "fixable":
                        st.session_state.decisions[idx] = "reject"
                st.rerun()

        if all_decided:
            st.session_state.validated = True
    else:
        st.success("All cards are valid.")
        st.session_state.validated = True

# ─── STEP 5: AI FIX INVALID ──────────────────────────────────────────────────

if st.session_state.validation_results:
    s = summary(st.session_state.validation_results)
    invalid_count = s["invalid"]
    ai_available = provider_choice != "none"
    already_ran = bool(st.session_state.intake_results)

    st.header("5  AI Fix Invalid Cards", divider="gray")
    if invalid_count == 0:
        st.caption("No invalid cards — nothing to fix here.")
    elif not already_ran:
        st.caption(f"{invalid_count} card(s) couldn't be auto-repaired. The AI can propose a fix for each.")

        if st.button(
            "Run AI Fix",
            disabled=not ai_available,
            help="Requires an AI provider to be configured above",
        ):
            with st.spinner("Asking AI to repair invalid cards…"):
                try:
                    if provider_choice == "ollama":
                        from core.provider import OllamaProvider
                        provider = OllamaProvider(model=ollama_model)
                        model = ollama_model
                    else:
                        provider = _get_provider(provider_choice, api_key_input)
                        model = AnthropicProvider.INTAKE_MODEL if provider_choice == "anthropic" else OpenAIProvider.INTAKE_MODEL

                    invalid_results = [r for r in st.session_state.validation_results if r.status == "invalid"]
                    invalid_indexed = [(i, r) for i, r in enumerate(st.session_state.validation_results) if r.status == "invalid"]
                    intake_list = run_intake(invalid_results, provider, model)

                    for (orig_idx, _), intake in zip(invalid_indexed, intake_list):
                        st.session_state.intake_results[orig_idx] = intake
                        if intake.ai_succeeded:
                            st.session_state.decisions[orig_idx] = "pending"
                        else:
                            st.session_state.decisions[orig_idx] = "reject"

                except ProviderAuthError as e:
                    st.error(str(e))
                except Exception as e:
                    st.error(f"AI error: {e}")
            st.rerun()

        if not ai_available:
            st.info("Set up an AI provider above to use this feature. Without it, invalid cards are skipped.")

# ─── STEP 6: AI AUGMENT ──────────────────────────────────────────────────────

EXPANSION_MODES = {
    "Append": {
        "value": ExpansionMode.APPEND,
        "caption": "Keeps your original answer and adds the AI enrichment below it. Safe for cards that already have content.",
    },
    "Empty fields only": {
        "value": ExpansionMode.EMPTY_ONLY,
        "caption": "Only fills in cards whose back field is blank. Leaves cards with existing answers untouched.",
    },
    "Overwrite": {
        "value": ExpansionMode.OVERWRITE,
        "caption": "Replaces the back of the card entirely with the AI-generated content. Use when you want a clean AI-written answer.",
    },
}

if st.session_state.validated:
    already_augmented = bool(st.session_state.aug_proposals)
    ai_available = provider_choice != "none"

    st.header("6  AI Augment Cards", divider="gray")
    st.caption("Optional — enrich each card with mechanism, clinical context, high-yield points, and exam traps.")

    # Expansion mode selector — always visible so users can change before generating
    exp_col, _ = st.columns([2, 1])
    with exp_col:
        expansion_mode_label = st.selectbox(
            "How should AI content be added to each card?",
            options=list(EXPANSION_MODES.keys()),
            index=0,
            key="expansion_mode_label",
        )
    st.caption(EXPANSION_MODES[expansion_mode_label]["caption"])

    if not already_augmented:
        if st.button(
            "Generate Augmentation Previews",
            disabled=not ai_available,
            help="Requires an AI provider to be configured above",
        ):
            notes_to_augment = _resolved_notes()
            with st.spinner(f"Generating enrichment for {len(notes_to_augment)} cards…"):
                try:
                    if provider_choice == "ollama":
                        from core.provider import OllamaProvider
                        provider = OllamaProvider(model=ollama_model)
                        model = ollama_model
                    else:
                        provider = _get_provider(provider_choice, api_key_input)
                        model = AnthropicProvider.AUGMENT_MODEL if provider_choice == "anthropic" else OpenAIProvider.AUGMENT_MODEL

                    proposals = generate_augmentation_proposals(notes_to_augment, provider, model)
                    st.session_state.aug_proposals = proposals
                    st.session_state.aug_accepted = set()

                except ProviderAuthError as e:
                    st.error(str(e))
                except Exception as e:
                    st.error(f"AI error: {e}")
            st.rerun()

        if not ai_available:
            st.info("Set up an AI provider above to use this feature. You can skip this and build without augmentation.")

    if already_augmented:
        proposals = st.session_state.aug_proposals
        succeeded = [p for p in proposals if p.succeeded]
        st.caption(f"{len(succeeded)} proposals ready. Select which cards to enrich:")

        acol1, acol2 = st.columns(2)
        with acol1:
            if st.button("Accept all proposals"):
                st.session_state.aug_accepted = {i for i, p in enumerate(proposals) if p.succeeded}
                st.rerun()
        with acol2:
            if st.button("Reject all proposals"):
                st.session_state.aug_accepted = set()
                st.rerun()

        for i, proposal in enumerate(proposals):
            if not proposal.succeeded:
                continue
            p = proposal.payload
            front_label = proposal.note.front[:60] + "…" if len(proposal.note.front) > 60 else proposal.note.front
            is_accepted = i in st.session_state.aug_accepted

            with st.expander(f"{'✓' if is_accepted else '○'} {front_label}", expanded=False):
                mode = EXPANSION_MODES[expansion_mode_label]["value"]
                original_back = proposal.note.back.strip()

                # Build the AI content string for preview
                ai_content_parts = [
                    f"**Concept:** {p.primary_concept}",
                    f"**Mechanism:** {p.mechanism}",
                    "**High-yield:**\n" + "\n".join(f"- {pt}" for pt in p.high_yield_points),
                    f"**Exam trap:** {p.exam_trap}",
                ]
                if p.normal_vs_pathologic:
                    ai_content_parts.append(f"**Normal vs pathologic:** {p.normal_vs_pathologic}")
                ai_content = "\n\n".join(ai_content_parts)

                # Compute what the back field will look like after applying the mode
                if mode == ExpansionMode.APPEND:
                    if original_back:
                        after_back = f"{original_back}\n\n---\n\n{ai_content}"
                        after_label = "After (original + AI appended below)"
                    else:
                        after_back = ai_content
                        after_label = "After (AI fills empty back)"
                elif mode == ExpansionMode.OVERWRITE:
                    after_back = ai_content
                    after_label = "After (AI replaces original)"
                else:  # EMPTY_ONLY
                    if original_back:
                        after_back = original_back
                        after_label = "No change (back already has content)"
                    else:
                        after_back = ai_content
                        after_label = "After (AI fills empty back)"

                col_l, col_r = st.columns(2)
                with col_l:
                    st.markdown("**Before**")
                    st.markdown(f"*Front:* {proposal.note.front}")
                    st.markdown(f"*Back:* {original_back or '*(empty)*'}")
                with col_r:
                    st.markdown(f"**{after_label}**")
                    st.markdown(after_back)

                accepted = st.checkbox(
                    "Add this enrichment to the card",
                    value=is_accepted,
                    key=f"aug_{i}",
                )
                if accepted:
                    st.session_state.aug_accepted.add(i)
                else:
                    st.session_state.aug_accepted.discard(i)

# ─── STEP 7: BUILD ───────────────────────────────────────────────────────────

st.header("7  Build Deck", divider="gray")

build_disabled = not st.session_state.validated or not deck_name.strip()

if st.button("Build .apkg", type="primary", disabled=build_disabled):
    with st.spinner("Building deck…"):
        try:
            notes = _resolved_notes()

            # Apply augmentation
            if st.session_state.aug_proposals and st.session_state.aug_accepted:
                payload_map = build_payload_map(st.session_state.aug_proposals, st.session_state.aug_accepted)
                chosen_mode = EXPANSION_MODES.get(
                    st.session_state.get("expansion_mode_label", "Append"), EXPANSION_MODES["Append"]
                )["value"]
                policy = AugmentationPolicy(schema_version="1.0.0", expansion_mode=chosen_mode)
                notes, _ = augment_notes(notes=notes, payload_map=payload_map, policy=policy)
                _log(f"Augmented {len(st.session_state.aug_accepted)} card(s) — mode: {chosen_mode.value}.")

            # Dedup against existing deck
            existing_ids = st.session_state.existing_identity_set
            if existing_ids:
                notes, dupes = filter_new_notes(notes, existing_ids)
                if dupes:
                    _log(f"Skipped {len(dupes)} duplicate(s) already in existing deck.")

            # Classify
            if classify:
                notes, report = classify_notes(notes, DEFAULT_TAXONOMY)
                _log(f"Classification: {report.matched_notes} matched, {report.unmatched_notes} → General.")

            # Build
            result = build_deck(notes=notes, deck_name=deck_name.strip(), strict_repair=False)

            # Write to bytes
            buf = io.BytesIO()
            with tempfile.NamedTemporaryFile(suffix=".apkg", delete=False) as tmp:
                genanki.Package(list(result.decks)).write_to_file(tmp.name)
                buf = Path(tmp.name).read_bytes()

            st.session_state.built_apkg = buf
            _log(f"Built: {result.total_notes} notes, {result.total_cards} cards.")
            if result.subdeck_counts:
                for subdeck, count in result.subdeck_counts:
                    label = subdeck.replace(f"{deck_name.strip()}::", "", 1).replace("_", " ")
                    _log(f"  {label}: {count} cards")
            if result.warnings:
                for w in result.warnings:
                    _log(f"  Warning: {w}")

        except Exception as e:
            st.error(f"Build failed: {e}")

if st.session_state.built_apkg:
    filename = deck_name.strip().replace(" ", "_") + ".apkg"
    st.download_button(
        label=f"⬇  Download {filename}",
        data=st.session_state.built_apkg,
        file_name=filename,
        mime="application/octet-stream",
        type="primary",
    )

# ─── BUILD REPORT ────────────────────────────────────────────────────────────

if st.session_state.report_lines:
    with st.expander("Build log", expanded=bool(st.session_state.built_apkg)):
        st.code("\n".join(st.session_state.report_lines), language=None)

# ─── SIDEBAR: HOW TO RUN ─────────────────────────────────────────────────────

with st.sidebar:
    st.header("Running Decksmith")
    st.markdown("""
**Locally (Mac/Windows)**
```
pip install streamlit genanki
streamlit run app.py
```
Opens in your browser. Works offline — no internet needed for core features.

**Offline AI (no API key)**
1. Install [Ollama](https://ollama.com)
2. Run `ollama pull llama3`
3. Select *Ollama (local)* above

**Hosted / iOS / Android**
Deploy to [Streamlit Cloud](https://streamlit.io/cloud) — free tier available. Works in any browser.

**Card format**
```
Basic:    Front :: Back
Reverse:  Front || Back
Extra:    Front ||| Back ||| Note
Cloze:    The {{c1::heart}} pumps blood
```
""")
