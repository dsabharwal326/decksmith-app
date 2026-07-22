from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, Optional

from core.augmentation_policy import (
    AugmentationPolicy,
    PolicyValidationError,
)
from core.augmentation import ExpansionMode


# =========================================
# CONFIG ERRORS
# =========================================

class ConfigValidationError(Exception):
    pass


# =========================================
# CONFIG MANAGER
# =========================================

class ConfigManager:

    def __init__(self, config_path: Path):
        self.config_path = config_path
        self._data = self._load()

    # -------------------------------------
    # LOAD / SAVE
    # -------------------------------------

    def _load(self) -> Dict:
        if not self.config_path.exists():
            return self._default_config()

        try:
            with self.config_path.open("r", encoding="utf-8") as f:
                raw = json.load(f)
        except Exception:
            return self._default_config()

        return self._validate_and_normalize(raw)

    def save(self) -> None:
        with self.config_path.open("w", encoding="utf-8") as f:
            json.dump(self._data, f, indent=2, sort_keys=True)

    # -------------------------------------
    # DEFAULT CONFIG
    # -------------------------------------

    def _default_config(self) -> Dict:
        return {
            "augmentation": {
                "user_default_policy": None,
                "profiles": {}
            }
        }

    # -------------------------------------
    # VALIDATION
    # -------------------------------------

    def _validate_and_normalize(self, raw: Dict) -> Dict:

        if "augmentation" not in raw:
            raw["augmentation"] = {
                "user_default_policy": None,
                "profiles": {}
            }

        aug = raw["augmentation"]

        # Validate user_default_policy
        if aug.get("user_default_policy") is not None:
            policy = self._deserialize_policy(
                aug["user_default_policy"]
            )
            policy.validate()
            aug["user_default_policy"] = self._serialize_policy(policy)

        # Validate profiles
        profiles = aug.get("profiles", {})
        normalized_profiles = {}

        for name, policy_data in profiles.items():
            policy = self._deserialize_policy(policy_data)
            policy.validate()
            normalized_profiles[name] = self._serialize_policy(policy)

        aug["profiles"] = normalized_profiles

        return raw

    # -------------------------------------
    # SERIALIZATION
    # -------------------------------------

    def _serialize_policy(self, policy: AugmentationPolicy) -> Dict:
        return {
            "schema_version": policy.schema_version,
            "expansion_mode": policy.expansion_mode.value,
            "provider": policy.provider,
            "model": policy.model,
        }

    def _deserialize_policy(self, data: Dict) -> AugmentationPolicy:
        try:
            return AugmentationPolicy(
                schema_version=data["schema_version"],
                expansion_mode=ExpansionMode(data["expansion_mode"]),
                provider=data.get("provider"),
                model=data.get("model"),
            )
        except Exception as e:
            raise ConfigValidationError(
                f"Invalid policy format: {e}"
            )

    # -------------------------------------
    # PUBLIC API
    # -------------------------------------

    def get_user_default_policy(self) -> Optional[AugmentationPolicy]:
        data = self._data["augmentation"]["user_default_policy"]
        if data is None:
            return None
        return self._deserialize_policy(data)

    def set_user_default_policy(self, policy: Optional[AugmentationPolicy]) -> None:
        if policy is None:
            self._data["augmentation"]["user_default_policy"] = None
        else:
            policy.validate()
            self._data["augmentation"]["user_default_policy"] = \
                self._serialize_policy(policy)

    def get_profiles(self) -> Dict[str, AugmentationPolicy]:
        raw_profiles = self._data["augmentation"]["profiles"]
        return {
            name: self._deserialize_policy(policy_data)
            for name, policy_data in raw_profiles.items()
        }

    def set_profile(self, name: str, policy: AugmentationPolicy) -> None:
        policy.validate()
        self._data["augmentation"]["profiles"][name] = \
            self._serialize_policy(policy)

    def delete_profile(self, name: str) -> None:
        if name in self._data["augmentation"]["profiles"]:
            del self._data["augmentation"]["profiles"][name]