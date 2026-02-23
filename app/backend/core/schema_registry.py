from __future__ import annotations

from typing import Dict, List, Set


# =========================================
# SCHEMA REGISTRY (HARDCODED 1.x LINE)
# =========================================

SCHEMA_REGISTRY: Dict[str, Dict] = {
    "1.0.0": {
        "required_sections": {
            "primary_concept",
            "mechanism",
            "high_yield_points",
            "clinical_context",
            "exam_trap",
        },
        "optional_sections": {
            "normal_vs_pathologic",
        },
        "field_map": {
            "back": [
                "primary_concept",
                "mechanism",
                "high_yield_points",
                "clinical_context",
                "exam_trap",
                "normal_vs_pathologic",
            ],
            "extra": [],
        },
    }
}


SUPPORTED_SCHEMA_VERSIONS: Set[str] = set(SCHEMA_REGISTRY.keys())


# =========================================
# VALIDATION ERRORS
# =========================================

class SchemaValidationError(Exception):
    pass


# =========================================
# INTERNAL VALIDATION (FAIL FAST)
# =========================================

def _validate_registry() -> None:
    """
    Strict fail-fast validation at import time.
    Ensures schema contract integrity.
    """

    for version, schema in SCHEMA_REGISTRY.items():

        if "required_sections" not in schema:
            raise SchemaValidationError(
                f"Schema {version} missing required_sections"
            )

        if "optional_sections" not in schema:
            raise SchemaValidationError(
                f"Schema {version} missing optional_sections"
            )

        if "field_map" not in schema:
            raise SchemaValidationError(
                f"Schema {version} missing field_map"
            )

        required = schema["required_sections"]
        optional = schema["optional_sections"]
        field_map = schema["field_map"]

        if not isinstance(required, set):
            raise SchemaValidationError(
                f"Schema {version} required_sections must be set"
            )

        if not isinstance(optional, set):
            raise SchemaValidationError(
                f"Schema {version} optional_sections must be set"
            )

        if not isinstance(field_map, dict):
            raise SchemaValidationError(
                f"Schema {version} field_map must be dict"
            )

        # Validate field_map structure
        for field_name, section_list in field_map.items():
            if field_name not in {"back", "extra"}:
                raise SchemaValidationError(
                    f"Schema {version} invalid field target: {field_name}"
                )

            if not isinstance(section_list, list):
                raise SchemaValidationError(
                    f"Schema {version} field_map[{field_name}] must be list"
                )

        # Ensure every required section appears somewhere in field_map
        mapped_sections = set()
        for section_list in field_map.values():
            mapped_sections.update(section_list)

        missing_required = required - mapped_sections
        if missing_required:
            raise SchemaValidationError(
                f"Schema {version} missing required mappings: {missing_required}"
            )

        # Ensure no unknown section names appear in field_map
        all_allowed = required | optional
        for section_list in field_map.values():
            for section in section_list:
                if section not in all_allowed:
                    raise SchemaValidationError(
                        f"Schema {version} unknown section in field_map: {section}"
                    )


# Run validation at import time (fail-fast)
_validate_registry()


# =========================================
# PUBLIC API
# =========================================

def get_schema(version: str) -> Dict:
    if version not in SUPPORTED_SCHEMA_VERSIONS:
        raise SchemaValidationError(
            f"Unsupported schema version: {version}"
        )

    return SCHEMA_REGISTRY[version]