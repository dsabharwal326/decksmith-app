"""
.apkg import — read an existing Anki package and extract card identities.

An .apkg is a ZIP containing collection.anki2 (SQLite).
We extract every note's front field and hash it to produce the same SHA
identity used by Decksmith's augmentation engine.  Any note whose identity
is already present in the imported deck is flagged as a duplicate so the
caller can skip it.
"""
from __future__ import annotations

import hashlib
import io
import sqlite3
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Set, Tuple


# =========================================
# RESULT TYPES
# =========================================

@dataclass(frozen=True)
class ImportedNote:
    front: str           # raw front field text (HTML stripped)
    back: str
    note_type: str       # "cloze" / "basic" / "unknown"
    identity: str        # SHA-256 hex of normalised front
    guid: str = ""       # original Anki note GUID for update-in-place imports


@dataclass(frozen=True)
class ApkgImportResult:
    notes: Tuple[ImportedNote, ...]
    identity_set: frozenset  # set of identity strings for O(1) lookup
    deck_names: Tuple[str, ...]
    failed: bool
    error: str


# =========================================
# HELPERS
# =========================================

def _strip_html(text: str) -> str:
    """Strip HTML tags without destroying medical content like Na <135 (>145 = hyper)."""
    import re, html as _html
    # Only strip tags that start with a letter (real HTML), not numeric comparisons
    text = re.sub(r'</?[a-zA-Z][a-zA-Z0-9]*[^>]*/?>',  ' ', text)
    text = re.sub(r'&nbsp;', ' ', text)
    text = _html.unescape(text)
    return re.sub(r'  +', ' ', text).strip()


def _front_identity(front: str) -> str:
    """Dedup key: normalised front text only.

    We can't reconstruct Decksmith's note_type from the SQLite flds column
    (genanki doesn't persist template names there), so we match by front field
    alone.  Same front text = same card for dedup purposes.
    """
    import re as _re
    text = _strip_html(front)
    # Strip cloze markers so {{c1::ACE inhibitors}} matches "ACE inhibitors"
    text = _re.sub(r"\{\{c\d+::(.*?)(?:::[^}]*)?\}\}", r"\1", text)
    normalised = " ".join(text.lower().split())
    return hashlib.sha256(normalised.encode("utf-8")).hexdigest()


def _detect_type(flds: str) -> str:
    """Heuristic: if the first field looks like a cloze, say so."""
    first = flds.split("\x1f", 1)[0] if "\x1f" in flds else flds
    import re
    if re.search(r"\{\{c\d+::", first):
        return "cloze"
    return "basic"


# =========================================
# PUBLIC API
# =========================================

def read_apkg(data: bytes) -> ApkgImportResult:
    """
    Parse an .apkg byte blob and return its notes + identity set.

    Parameters
    ----------
    data : bytes
        Raw bytes of the .apkg file (as returned by st.file_uploader or
        Path.read_bytes()).

    Returns
    -------
    ApkgImportResult
        .failed is True if the file could not be parsed; check .error.
    """
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            names = z.namelist()
            # Prefer anki21b (zstd-compressed, Anki 24+), then anki21, then anki2
            if "collection.anki21b" in names:
                import zstandard
                compressed = z.read("collection.anki21b")
                dctx = zstandard.ZstdDecompressor()
                db_bytes = dctx.stream_reader(io.BytesIO(compressed)).read()
            elif "collection.anki21" in names:
                db_bytes = z.read("collection.anki21")
            elif "collection.anki2" in names:
                db_bytes = z.read("collection.anki2")
            else:
                return ApkgImportResult(
                    notes=(), identity_set=frozenset(), deck_names=(),
                    failed=True, error="No collection database found in .apkg",
                )

        # Write to a temp file so sqlite3 can open it
        with tempfile.NamedTemporaryFile(suffix=".anki2", delete=False) as tmp:
            tmp.write(db_bytes)
            tmp_path = tmp.name

        con = sqlite3.connect(tmp_path)
        try:
            notes_rows = con.execute("SELECT flds, mid, guid FROM notes").fetchall()
            # Deck names from the col table (JSON blob)
            col_row = con.execute("SELECT decks FROM col").fetchone()
        finally:
            con.close()
        Path(tmp_path).unlink(missing_ok=True)

        # Parse deck names
        import json
        deck_names: List[str] = []
        if col_row:
            try:
                decks_json = json.loads(col_row[0])
                deck_names = [d.get("name", "") for d in decks_json.values()]
            except Exception:
                pass

        imported: List[ImportedNote] = []
        for flds, mid, guid in notes_rows:
            parts = flds.split("\x1f")
            front_raw = parts[0] if parts else ""
            back_raw  = parts[1] if len(parts) > 1 else ""
            front     = _strip_html(front_raw)
            back      = _strip_html(back_raw)
            ntype     = _detect_type(flds)
            identity  = _front_identity(front_raw)
            imported.append(ImportedNote(
                front=front, back=back,
                note_type=ntype, identity=identity,
                guid=str(guid) if guid else "",
            ))

        identity_set = frozenset(n.identity for n in imported)

        return ApkgImportResult(
            notes=tuple(imported),
            identity_set=identity_set,
            deck_names=tuple(deck_names),
            failed=False,
            error="",
        )

    except zipfile.BadZipFile:
        return ApkgImportResult(
            notes=(), identity_set=frozenset(), deck_names=(),
            failed=True, error="File is not a valid .apkg (bad ZIP)",
        )
    except Exception as e:
        return ApkgImportResult(
            notes=(), identity_set=frozenset(), deck_names=(),
            failed=True, error=str(e),
        )


def _tokenise(text: str) -> frozenset[str]:
    """Return a set of meaningful word tokens from a normalised string."""
    import re
    # Strip HTML, cloze, lowercase, split on non-alphanum
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"\{\{c\d+::(.*?)(?:::[^}]*)?\}\}", r"\1", text)
    tokens = re.findall(r"[a-z0-9]{3,}", text.lower())
    return frozenset(tokens)


def _jaccard(a: frozenset, b: frozenset) -> float:
    if not a and not b:
        return 1.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def dedup_notes(notes, fuzzy_threshold: float = 0.85):
    """
    Deduplicate a list of Note objects against themselves.

    Pass 1 — exact: SHA-256 of normalised front (same card twice).
    Pass 2 — fuzzy: Jaccard token similarity >= fuzzy_threshold.
    Keeps the first occurrence; discards later duplicates.

    Returns (unique_notes, duplicate_count).
    """
    seen_identities: set = set()
    seen_tokens: list = []
    unique = []
    dupe_count = 0

    for note in notes:
        identity = _front_identity(note.front)
        if identity in seen_identities:
            dupe_count += 1
            continue

        ntok = _tokenise(note.front)
        if ntok and any(_jaccard(ntok, et) >= fuzzy_threshold for et in seen_tokens):
            dupe_count += 1
            continue

        seen_identities.add(identity)
        seen_tokens.append(ntok)
        unique.append(note)

    return unique, dupe_count


def filter_new_notes(notes, existing_identity_set: frozenset,
                     existing_notes: tuple = (), fuzzy_threshold: float = 0.85):
    """
    Return only notes not already present in the existing deck.

    Pass 1 — exact match: SHA-256 of normalised front text.
    Pass 2 — fuzzy match: Jaccard token similarity >= fuzzy_threshold on front text.
             Only runs when existing_notes is provided (non-empty).
    """
    # Build token sets for existing notes (for fuzzy pass)
    existing_tokens: list[frozenset] = [_tokenise(n.front) for n in existing_notes] if existing_notes else []

    new, dupes = [], []
    for note in notes:
        identity = _front_identity(note.front)
        if identity in existing_identity_set:
            dupes.append(note)
            continue

        # Fuzzy pass: check if any existing card is nearly identical
        if existing_tokens:
            ntok = _tokenise(note.front)
            if ntok and any(_jaccard(ntok, et) >= fuzzy_threshold for et in existing_tokens):
                dupes.append(note)
                continue

        new.append(note)
    return new, dupes
