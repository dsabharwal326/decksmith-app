from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List

from core.hash_utils import compute_sha256


class DictionaryValidationError(Exception):
    pass


def load_validated_dictionaries(
    dictionaries_dir: Path,
    registry_data: Dict
) -> List[Dict]:
    """
    Returns a list of validated dictionary objects.

    Each dictionary object returned:
    {
        "name": str,
        "entries": Dict[str, List[str]]
    }

    Deterministic:
    - Registry entries sorted by name
    - No auto-discovery
    - SHA strictly enforced
    """

    if registry_data.get("schema_version") != 1:
        raise DictionaryValidationError("Unsupported registry schema version.")

    validated = []

    entries = registry_data.get("entries", [])
    sorted_entries = sorted(entries, key=lambda x: x["name"])

    for entry in sorted_entries:
        if not entry.get("enabled", False):
            continue

        name = entry["name"]
        file_name = entry["file"]
        expected_sha = entry["sha256"]

        dict_path = dictionaries_dir / file_name

        if not dict_path.exists():
            raise DictionaryValidationError(f"Dictionary file missing: {file_name}")

        actual_sha = compute_sha256(dict_path)

        if actual_sha != expected_sha:
            raise DictionaryValidationError(
                f"SHA mismatch for dictionary: {name}"
            )

        with dict_path.open("r", encoding="utf-8") as f:
            dictionary_content = json.load(f)

        validated.append({
            "name": name,
            "entries": dictionary_content
        })

    return validated