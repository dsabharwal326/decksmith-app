"""
Provider abstraction layer.

All AI calls in Decksmith go through here. The rest of the codebase
never imports an SDK directly - it calls complete() or complete_structured()
on a Provider instance.

Supported providers:
  - anthropic  (Claude models via anthropic SDK)
  - openai     (GPT models via openai SDK)
  - stub       (returns canned responses - for tests and offline use)
"""
from __future__ import annotations

import json
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, Dict, List, Optional


# =========================================
# ERRORS
# =========================================

class ProviderError(Exception):
    pass

class ProviderAuthError(ProviderError):
    pass

class ProviderRateLimitError(ProviderError):
    pass

class ProviderUnavailableError(ProviderError):
    pass


# =========================================
# RESPONSE TYPES
# =========================================

@dataclass(frozen=True)
class CompletionResponse:
    text: str
    model: str
    input_tokens: int
    output_tokens: int


@dataclass(frozen=True)
class StructuredResponse:
    data: Dict[str, Any]
    model: str
    input_tokens: int
    output_tokens: int


# =========================================
# ABSTRACT BASE
# =========================================

class Provider(ABC):

    @abstractmethod
    def complete(
        self,
        *,
        system: str,
        user: str,
        model: str,
        max_tokens: int = 1024,
        temperature: float = 0.3,
    ) -> CompletionResponse:
        """Send a plain text prompt, get text back."""

    @abstractmethod
    def complete_structured(
        self,
        *,
        system: str,
        user: str,
        model: str,
        schema: Dict[str, Any],
        max_tokens: int = 2048,
        temperature: float = 0.1,
    ) -> StructuredResponse:
        """Send a prompt and get a validated JSON dict back."""

    @abstractmethod
    def name(self) -> str:
        """Identifier string, e.g. 'anthropic' or 'openai'."""


# =========================================
# ANTHROPIC PROVIDER
# =========================================

class AnthropicProvider(Provider):

    # Default model tiers
    INTAKE_MODEL    = "claude-haiku-4-5-20251001"   # fast, cheap - structural fixes
    AUGMENT_MODEL   = "claude-haiku-4-5-20251001"   # fast - use haiku for speed on large decks

    def __init__(self, api_key: Optional[str] = None):
        try:
            import anthropic as _anthropic
        except ImportError:
            raise ProviderUnavailableError(
                "anthropic package not installed. Run: pip install anthropic"
            )
        import os
        key = api_key or os.environ.get("ANTHROPIC_API_KEY", "")
        if not key:
            raise ProviderAuthError(
                "ANTHROPIC_API_KEY not set. Add it to your environment or config."
            )
        self._client = _anthropic.Anthropic(api_key=key)

    def name(self) -> str:
        return "anthropic"

    def complete(
        self,
        *,
        system: str,
        user: str,
        model: str,
        max_tokens: int = 1024,
        temperature: float = 0.3,
    ) -> CompletionResponse:
        try:
            resp = self._client.messages.create(
                model=model,
                max_tokens=max_tokens,
                temperature=temperature,
                system=system,
                messages=[{"role": "user", "content": user}],
            )
        except Exception as e:
            import traceback as _tb
            print("PROVIDER EXCEPTION FULL TRACEBACK:")
            _tb.print_exc()
            _raise_mapped(e)

        text = resp.content[0].text if resp.content else ""
        return CompletionResponse(
            text=text,
            model=resp.model,
            input_tokens=resp.usage.input_tokens,
            output_tokens=resp.usage.output_tokens,
        )

    def complete_structured(
        self,
        *,
        system: str,
        user: str,
        model: str,
        schema: Dict[str, Any],
        max_tokens: int = 2048,
        temperature: float = 0.1,
    ) -> StructuredResponse:
        schema_hint = json.dumps(schema, indent=2)
        augmented_system = (
            f"{system}\n\n"
            f"Respond with a single JSON object matching this schema exactly. "
            f"No prose, no markdown fences - raw JSON only.\n\n"
            f"Schema:\n{schema_hint}"
        )
        resp = self.complete(
            system=augmented_system,
            user=user,
            model=model,
            max_tokens=max_tokens,
            temperature=temperature,
        )
        return StructuredResponse(
            data=_parse_json(resp.text),
            model=resp.model,
            input_tokens=resp.input_tokens,
            output_tokens=resp.output_tokens,
        )


# =========================================
# OPENAI PROVIDER
# =========================================

class OpenAIProvider(Provider):

    INTAKE_MODEL   = "gpt-4o-mini"
    AUGMENT_MODEL  = "gpt-4o"

    def __init__(self, api_key: Optional[str] = None):
        try:
            import openai as _openai
        except ImportError:
            raise ProviderUnavailableError(
                "openai package not installed. Run: pip install openai"
            )
        import os
        key = api_key or os.environ.get("OPENAI_API_KEY", "")
        if not key:
            raise ProviderAuthError(
                "OPENAI_API_KEY not set. Add it to your environment or config."
            )
        self._client = _openai.OpenAI(api_key=key)

    def name(self) -> str:
        return "openai"

    def complete(
        self,
        *,
        system: str,
        user: str,
        model: str,
        max_tokens: int = 1024,
        temperature: float = 0.3,
    ) -> CompletionResponse:
        try:
            resp = self._client.chat.completions.create(
                model=model,
                max_tokens=max_tokens,
                temperature=temperature,
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
            )
        except Exception as e:
            _raise_mapped(e)

        text = resp.choices[0].message.content or ""
        return CompletionResponse(
            text=text,
            model=resp.model,
            input_tokens=resp.usage.prompt_tokens,
            output_tokens=resp.usage.completion_tokens,
        )

    def complete_structured(
        self,
        *,
        system: str,
        user: str,
        model: str,
        schema: Dict[str, Any],
        max_tokens: int = 2048,
        temperature: float = 0.1,
    ) -> StructuredResponse:
        try:
            resp = self._client.chat.completions.create(
                model=model,
                max_tokens=max_tokens,
                temperature=temperature,
                response_format={"type": "json_object"},
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
            )
        except Exception as e:
            _raise_mapped(e)

        text = resp.choices[0].message.content or "{}"
        return StructuredResponse(
            data=_parse_json(text),
            model=resp.model,
            input_tokens=resp.usage.prompt_tokens,
            output_tokens=resp.usage.completion_tokens,
        )


# =========================================
# STUB PROVIDER (offline / tests)
# =========================================

class StubProvider(Provider):
    """
    Returns deterministic canned responses. No network calls.
    Used for testing the pipeline without API keys.
    """

    def __init__(self, canned_text: str = "stub response", canned_data: Optional[Dict] = None):
        self._text = canned_text
        self._data = canned_data or {}

    def name(self) -> str:
        return "stub"

    def complete(self, *, system: str, user: str, model: str, **kwargs) -> CompletionResponse:
        return CompletionResponse(
            text=self._text,
            model=model,
            input_tokens=len(user) // 4,
            output_tokens=len(self._text) // 4,
        )

    def complete_structured(self, *, system: str, user: str, model: str, schema: Dict, **kwargs) -> StructuredResponse:
        return StructuredResponse(
            data=self._data,
            model=model,
            input_tokens=len(user) // 4,
            output_tokens=10,
        )


# =========================================
# FACTORY
# =========================================

PROVIDER_NAMES = ("anthropic", "openai", "ollama", "stub")


class OllamaProvider(Provider):
    """
    Local Ollama provider - no API key, no internet.
    Ollama exposes an OpenAI-compatible API at localhost:11434.
    Install: https://ollama.com  then  ollama pull llama3
    """

    BASE_URL = "http://localhost:11434/v1"

    def __init__(self, model: str = "llama3"):
        try:
            import openai as _openai
        except ImportError:
            raise ProviderUnavailableError(
                "openai package not installed (needed for Ollama compat layer). Run: pip install openai"
            )
        self._model = model
        self._client = _openai.OpenAI(base_url=self.BASE_URL, api_key="ollama")

    def name(self) -> str:
        return "ollama"

    def complete(self, *, system: str, user: str, model: str, max_tokens: int = 1024, temperature: float = 0.3) -> CompletionResponse:
        try:
            resp = self._client.chat.completions.create(
                model=self._model,
                max_tokens=max_tokens,
                temperature=temperature,
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
            )
        except Exception as e:
            _raise_mapped(e)

        text = resp.choices[0].message.content or ""
        return CompletionResponse(
            text=text,
            model=self._model,
            input_tokens=getattr(resp.usage, "prompt_tokens", 0),
            output_tokens=getattr(resp.usage, "completion_tokens", 0),
        )

    def complete_structured(self, *, system: str, user: str, model: str, schema: Dict[str, Any], max_tokens: int = 2048, temperature: float = 0.1) -> StructuredResponse:
        schema_hint = json.dumps(schema, indent=2)
        augmented_system = (
            f"{system}\n\n"
            f"Respond with a single JSON object matching this schema exactly. "
            f"No prose, no markdown fences - raw JSON only.\n\nSchema:\n{schema_hint}"
        )
        resp = self.complete(system=augmented_system, user=user, model=model, max_tokens=max_tokens, temperature=temperature)
        return StructuredResponse(
            data=_parse_json(resp.text),
            model=self._model,
            input_tokens=resp.input_tokens,
            output_tokens=resp.output_tokens,
        )


def build_provider(name: str, api_key: Optional[str] = None) -> Provider:
    """
    Instantiate a provider by name.
    Raises ProviderError if the name is unknown or setup fails.
    """
    if name == "anthropic":
        return AnthropicProvider(api_key=api_key)
    if name == "openai":
        return OpenAIProvider(api_key=api_key)
    if name == "ollama":
        return OllamaProvider()
    if name == "stub":
        return StubProvider()
    raise ProviderError(f"Unknown provider: {name!r}. Choose from: {PROVIDER_NAMES}")


def detect_available_provider() -> Optional[str]:
    """
    Return the name of the first provider whose API key is set.
    Returns None if no keys found (user must configure one).
    """
    import os
    if os.environ.get("ANTHROPIC_API_KEY"):
        return "anthropic"
    if os.environ.get("OPENAI_API_KEY"):
        return "openai"
    return None


# =========================================
# INTERNAL HELPERS
# =========================================

def _parse_json(text: str) -> Dict[str, Any]:
    text = text.strip()
    # Strip markdown fences if the model added them anyway
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        raise ProviderError(f"Model returned invalid JSON: {e}\n\nRaw:\n{text[:300]}")


def _raise_mapped(exc: Exception) -> None:
    msg = str(exc)
    low = msg.lower()
    if "401" in low or "authentication" in low or "api key" in low:
        raise ProviderAuthError(f"Authentication failed: {msg}") from exc
    if "429" in low or "rate limit" in low:
        raise ProviderRateLimitError(f"Rate limited: {msg}") from exc
    raise ProviderError(f"Provider call failed: {msg}") from exc
