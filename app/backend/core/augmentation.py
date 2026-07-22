from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple
import hashlib

from core.engine import Note
from core.schema_registry import get_schema, SchemaValidationError
from core.augmentation_policy import AugmentationPolicy, ExpansionMode


# =========================================
# VALIDATION ERROR
# =========================================

class AugmentationValidationError(Exception):
    pass


# =========================================
# EXPANSION PAYLOAD
# =========================================

@dataclass(frozen=True)
class ExpansionPayload:
    primary_concept: str
    mechanism: str
    high_yield_points: Tuple[str, ...]
    clinical_context: str
    exam_trap: str
    normal_vs_pathologic: Optional[str] = None


# =========================================
# METADATA STRUCTURE
# =========================================

@dataclass(frozen=True)
class AugmentationMetadata:
    schema_version: str
    expansion_mode: str
    provider: Optional[str]
    model: Optional[str]
    prompt_hash: Optional[str]
    dictionary_sha: Optional[str]


# =========================================
# SHA-BASED NOTE IDENTITY
# =========================================

def _stable_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _canonical_identity_string(note: Note) -> str:
    return "||".join(
        [
            note.note_type.strip(),
            note.front.strip(),
            note.back.strip(),
            note.extra.strip(),
        ]
    )


def _note_identity(note: Note) -> str:
    return _stable_hash(_canonical_identity_string(note))


# =========================================
# PAYLOAD VALIDATION
# =========================================

def _validate_payload(
    payload: ExpansionPayload,
    schema_version: str
) -> None:

    try:
        schema = get_schema(schema_version)
    except SchemaValidationError as e:
        raise AugmentationValidationError(str(e))

    required_sections = schema["required_sections"]
    optional_sections = schema["optional_sections"]

    payload_dict = {
        "primary_concept": payload.primary_concept,
        "mechanism": payload.mechanism,
        "high_yield_points": payload.high_yield_points,
        "clinical_context": payload.clinical_context,
        "exam_trap": payload.exam_trap,
        "normal_vs_pathologic": payload.normal_vs_pathologic,
    }

    for section in required_sections:
        value = payload_dict.get(section)

        if section == "high_yield_points":
            # Allow empty tuple when high_yield was intentionally disabled
            if not isinstance(value, tuple):
                raise AugmentationValidationError(
                    "high_yield_points must be a tuple"
                )
        else:
            if not isinstance(value, str) or not value.strip():
                raise AugmentationValidationError(
                    f"{section} cannot be empty"
                )

    for section in optional_sections:
        value = payload_dict.get(section)
        if value is not None and not isinstance(value, str):
            raise AugmentationValidationError(
                f"{section} must be string if provided"
            )


# =========================================
# SECTION RENDERING
# =========================================

def _render_section(section_name: str, payload: ExpansionPayload) -> str:

    if section_name == "primary_concept":
        return f"Primary Concept:\n{payload.primary_concept.strip()}"

    if section_name == "mechanism":
        return f"Mechanism:\n{payload.mechanism.strip()}"

    if section_name == "high_yield_points":
        lines = [
            f"- {point.strip()}"
            for point in payload.high_yield_points
        ]
        return "High Yield Points:\n" + "\n".join(lines)

    if section_name == "clinical_context":
        return f"Clinical Context:\n{payload.clinical_context.strip()}"

    if section_name == "exam_trap":
        return f"Exam Trap:\n{payload.exam_trap.strip()}"

    if section_name == "normal_vs_pathologic":
        if payload.normal_vs_pathologic is None:
            return ""
        return f"Normal vs Pathologic:\n{payload.normal_vs_pathologic.strip()}"

    raise AugmentationValidationError(
        f"Unknown section: {section_name}"
    )


# =========================================
# FIELD-AWARE RENDERING
# =========================================

def _render_fields(
    payload: ExpansionPayload,
    schema_version: str
) -> Tuple[str, str]:

    schema = get_schema(schema_version)
    field_map = schema["field_map"]

    back_sections: List[str] = []
    extra_sections: List[str] = []

    for section_name in field_map["back"]:
        rendered = _render_section(section_name, payload)
        if rendered:
            back_sections.append(rendered)

    for section_name in field_map["extra"]:
        rendered = _render_section(section_name, payload)
        if rendered:
            extra_sections.append(rendered)

    back_content = "\n\n".join(back_sections).rstrip()
    extra_content = "\n\n".join(extra_sections).rstrip()

    return back_content, extra_content


# =========================================
# AUGMENTATION ORCHESTRATOR
# =========================================

def augment_notes(
    notes: List[Note],
    payload_map: Dict[str, ExpansionPayload],
    policy: AugmentationPolicy,
    *,
    prompt_hash: Optional[str] = None,
    dictionary_sha: Optional[str] = None,
) -> Tuple[List[Note], AugmentationMetadata]:

    policy.validate()

    schema_version = policy.schema_version
    mode = policy.expansion_mode

    augmented: List[Note] = []

    for note in notes:
        identity = _note_identity(note)
        payload = payload_map.get(identity)

        if payload is None:
            augmented.append(note)
            continue

        _validate_payload(payload, schema_version)
        new_back, new_extra = _render_fields(payload, schema_version)

        # Merge extra into back if note type does not support extra
        if note.note_type not in {"cloze", "basic_extra"}:
            if new_extra:
                new_back = (
                    f"{new_back}\n\n{new_extra}"
                    if new_back
                    else new_extra
                )
            new_extra = note.extra

        if mode.name == "OVERWRITE":
            updated = Note(
                note.note_type,
                note.front,
                new_back,
                new_extra,
                note.tags,
                guid=note.guid,
            )

        elif mode.name == "APPEND":
            combined_back = (
                f"{note.back.rstrip()}\n\n{new_back}"
                if note.back.strip()
                else new_back
            )

            combined_extra = (
                f"{note.extra.rstrip()}\n\n{new_extra}"
                if note.extra.strip()
                else new_extra
            )

            updated = Note(
                note.note_type,
                note.front,
                combined_back.rstrip(),
                combined_extra.rstrip(),
                note.tags,
                guid=note.guid,
            )

        elif mode.name == "EMPTY_ONLY":
            if note.back.strip():
                augmented.append(note)
                continue

            updated = Note(
                note.note_type,
                note.front,
                new_back,
                new_extra,
                note.tags,
                guid=note.guid,
            )

        else:
            raise AugmentationValidationError(
                f"Unsupported expansion mode: {mode}"
            )

        augmented.append(updated)

    metadata = AugmentationMetadata(
        schema_version=schema_version,
        expansion_mode=mode.value,
        provider=policy.provider,
        model=policy.model,
        prompt_hash=prompt_hash,
        dictionary_sha=dictionary_sha,
    )

    return augmented, metadata