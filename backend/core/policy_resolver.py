from __future__ import annotations

from dataclasses import replace
from typing import Optional, Dict

from core.augmentation_policy import (
    AugmentationPolicy,
    SYSTEM_PROFILES,
    get_system_profile,
    PolicyValidationError,
)


# =========================================
# POLICY RESOLUTION ERROR
# =========================================

class PolicyResolutionError(Exception):
    pass


# =========================================
# POLICY RESOLVER
# =========================================

def resolve_policy(
    *,
    system_profile_name: str = "standard_v1",
    user_default_policy: Optional[AugmentationPolicy] = None,
    user_profiles: Optional[Dict[str, AugmentationPolicy]] = None,
    selected_profile_name: Optional[str] = None,
    per_build_override: Optional[AugmentationPolicy] = None,
) -> AugmentationPolicy:
    """
    Deterministic layered resolution:

    1. System profile (required fallback)
    2. User default policy (optional)
    3. Selected named user profile (optional)
    4. Per-build override (optional)

    Later layers override earlier layers.
    """

    # -------------------------------------
    # 1️⃣ System baseline (always required)
    # -------------------------------------

    try:
        resolved = get_system_profile(system_profile_name)
    except PolicyValidationError as e:
        raise PolicyResolutionError(str(e))

    # -------------------------------------
    # 2️⃣ User default policy (if provided)
    # -------------------------------------

    if user_default_policy is not None:
        user_default_policy.validate()
        resolved = user_default_policy

    # -------------------------------------
    # 3️⃣ Selected named profile (if provided)
    # -------------------------------------

    if selected_profile_name is not None:
        if user_profiles is None:
            raise PolicyResolutionError(
                "selected_profile_name provided but user_profiles is None"
            )

        if selected_profile_name not in user_profiles:
            raise PolicyResolutionError(
                f"Unknown user profile: {selected_profile_name}"
            )

        selected = user_profiles[selected_profile_name]
        selected.validate()
        resolved = selected

    # -------------------------------------
    # 4️⃣ Per-build override (if provided)
    # -------------------------------------

    if per_build_override is not None:
        per_build_override.validate()

        # Override fields individually to preserve structure
        resolved = replace(
            resolved,
            schema_version=per_build_override.schema_version,
            expansion_mode=per_build_override.expansion_mode,
            provider=per_build_override.provider,
            model=per_build_override.model,
        )

    return resolved