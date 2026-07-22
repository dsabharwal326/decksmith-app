"""
Medical image search: NIH OpenI (primary) → Wikipedia REST (fallback).
NIH OpenI pulls figures from PubMed Central — actual medical diagrams.
Wikipedia REST fetches article thumbnails for broader coverage.
"""

from __future__ import annotations
import hashlib
import ssl
import time
import urllib.request
import urllib.parse
import json
from typing import Optional
import certifi

_NIH_API   = "https://openi.nlm.nih.gov/api/search"
_WP_SEARCH = "https://en.wikipedia.org/w/api.php"
_WP_REST   = "https://en.wikipedia.org/api/rest_v1/page/summary/"
_UA  = "Decksmith/1.0 (anki deck generator; educational use)"
_SSL = ssl.create_default_context(cafile=certifi.where())

_cache: dict[str, Optional[tuple[str, bytes]]] = {}
_last_request = 0.0
_MIN_INTERVAL = 0.8


def _fetch(url: str, params: dict | None = None) -> dict | None:
    global _last_request
    elapsed = time.time() - _last_request
    if elapsed < _MIN_INTERVAL:
        time.sleep(_MIN_INTERVAL - elapsed)
    _last_request = time.time()

    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": _UA})
    try:
        with urllib.request.urlopen(req, timeout=10, context=_SSL) as r:
            return json.loads(r.read())
    except Exception:
        return None


def _download(url: str) -> Optional[bytes]:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": _UA})
        with urllib.request.urlopen(req, timeout=15, context=_SSL) as r:
            data = r.read()
        return data if len(data) > 1000 else None
    except Exception:
        return None


def _ext_from_url(url: str) -> Optional[str]:
    low = url.lower().split("?")[0]
    for bad in (".svg", ".gif", ".pdf", ".tif", ".tiff"):
        if low.endswith(bad):
            return None
    return "jpg" if ("jpg" in low or "jpeg" in low) else "png"


def _make_filename(query: str, ext: str) -> str:
    slug = hashlib.md5(query.encode()).hexdigest()[:10]
    return f"ds_{slug}.{ext}"


# ── Source 1: NIH OpenI ──────────────────────────────────────────────────────

def _search_nih(query: str) -> Optional[tuple[str, bytes]]:
    data = _fetch(_NIH_API, {
        "query": query,
        "m": "1",       # start at result 1
        "n": "10",      # return 10 results
        "it": "x,p",   # image types: x-ray, photo/diagram
    })
    if not data:
        return None

    images = data.get("list", [])
    for img in images:
        img_url = img.get("imgThumb") or img.get("imgLarge")
        if not img_url:
            continue
        if not img_url.startswith("http"):
            img_url = "https://openi.nlm.nih.gov" + img_url
        ext = _ext_from_url(img_url)
        if not ext:
            continue
        img_bytes = _download(img_url)
        if img_bytes:
            return _make_filename(query, ext), img_bytes

    return None


# ── Source 2: Wikipedia REST ─────────────────────────────────────────────────

def _search_wikipedia(query: str) -> Optional[tuple[str, bytes]]:
    search_data = _fetch(_WP_SEARCH, {
        "action": "query",
        "list": "search",
        "srsearch": query,
        "srlimit": "3",
        "format": "json",
    })
    if not search_data:
        return None

    titles = [r["title"] for r in search_data.get("query", {}).get("search", [])]
    for title in titles:
        encoded = urllib.parse.quote(title.replace(" ", "_"))
        summary = _fetch(f"{_WP_REST}{encoded}")
        if not summary:
            continue
        thumb = summary.get("thumbnail") or summary.get("originalimage")
        if not thumb or thumb.get("width", 0) < 100:
            continue
        img_url = thumb.get("source", "")
        ext = _ext_from_url(img_url)
        if not ext:
            continue
        img_bytes = _download(img_url)
        if img_bytes:
            return _make_filename(query, ext), img_bytes

    return None


# ── Public entry point ────────────────────────────────────────────────────────

def search_image(query: str) -> Optional[tuple[str, bytes]]:
    """
    Search NIH OpenI first, fall back to Wikipedia.
    Returns (anki_filename, image_bytes) or None.
    """
    if query in _cache:
        return _cache[query]

    result = _search_nih(query) or _search_wikipedia(query)
    _cache[query] = result
    return result


def image_html(filename: str) -> str:
    return f'<img src="{filename}" style="max-width:100%;border-radius:6px;margin-top:8px">'
