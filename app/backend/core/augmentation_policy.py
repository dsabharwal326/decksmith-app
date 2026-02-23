from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional

from core.augmentation import ExpansionMode
from core.schema_registry import SUPPORTED_SCHEMA_VERSIONS


# =========================================
# POLICY VALIDATION ERROR
# =========================================

class PolicyValidationError(Exception):
    pass


# =========================================
# AUGMENTATION POLICY
# =========================================

@dataclass(frozen=True)
class AugmentationPolicy:
    """
    Deterministic build-level augmentation policy.

    This does NOT execute augmentation.
    It only defines behavior.
    """

    schema_version: str
    expansion_mode: ExpansionMode
    provider: Optional[str] = None
    model: Optional[str] = None

    def validate(self) -> None:
        if self.schema_version not in SUPPORTED_SCHEMA_VERSIONS:
            raise PolicyValidationError(
                f"Unsupported schema version: {self.schema_version}"
            )

        if not isinstance(self.expansion_mode, ExpansionMode):
            raise PolicyValidationError(
                "Invalid expansion_mode"
            )


# =========================================
# SYSTEM DEFAULT PROFILES (HARDCODED)
# =========================================

SYSTEM_PROFILES: Dict[str, AugmentationPolicy] = {
    "standard_v1": AugmentationPolicy(
        schema_version="1.0.0",
        expansion_mode=ExpansionMode.APPEND,
        provider=None,
        model=None,
    ),
    "minimal_safe": AugmentationPolicy(
        schema_version="1.0.0",
        expansion_mode=ExpansionMode.EMPTY_ONLY,
        provider=None,
        model=None,
    ),
    "overwrite_full": AugmentationPolicy(
        schema_version="1.0.0",
        expansion_mode=ExpansionMode.OVERWRITE,
        provider=None,
        model=None,
    ),
}


# =========================================
# PUBLIC API
# =========================================

def get_system_profile(name: str) -> AugmentationPolicy:
    if name not in SYSTEM_PROFILES:
        raise PolicyValidationError(
            f"Unknown system profile: {name}"
        )

    policy = SYSTEM_PROFILES[name]
    policy.validate()
    return policy