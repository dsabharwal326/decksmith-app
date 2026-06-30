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
    """Very light HTML tag stripper — no dependency on lxml/BeautifulSoup."""
    import re
    return re.sub(r"<[^>]+>", "", text).strip()


def _front_identity(front: str) -> str:
    """Dedup key: normalised front text only.

    We can't reconstruct Decksmith's note_type from the SQLite flds column
    (genanki doesn't persist template names there), so we match by front field
    alone.  Same front text = same card for dedup purposes.
    """
    normalised = " ".join(_strip_html(front).lower().split())
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
            db_name = next(
                (n for n in names if n in ("collection.anki2", "collection.anki21")),
                None,
            )
            if db_name is None:
                return ApkgImportResult(
                    notes=(), identity_set=frozenset(), deck_names=(),
                    failed=True, error="No collection.anki2 found in .apkg",
                )
            db_bytes = z.read(db_name)

        # Write to a temp file so sqlite3 can open it
        with tempfile.NamedTemporaryFile(suffix=".anki2", delete=False) as tmp:
            tmp.write(db_bytes)
            tmp_path = tmp.name

        con = sqlite3.connect(tmp_path)
        try:
            notes_rows = con.execute("SELECT flds, mid FROM notes").fetchall()
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
        for flds, mid in notes_rows:
            parts = flds.split("\x1f")
            front_raw = parts[0] if parts else ""
            back_raw  = parts[1] if len(parts) > 1 else ""
            front     = _strip_html(front_raw)
            back      = _strip_html(back_raw)
            ntype     = _detect_type(flds)
            extra     = _strip_html(parts[2]) if len(parts) > 2 else ""
            identity  = _front_identity(front_raw)
            imported.append(ImportedNote(
                front=front, back=back,
                note_type=ntype, identity=identity,
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


def filter_new_notes(notes, existing_identity_set: frozenset):
    """
    Given a list of Note objects (from core.engine) and an existing identity
    set (from ApkgImportResult.identity_set), return only notes not already
    present in the existing deck.

    Dedup key is the normalised front field — same logic as _front_identity().
    """
    new, dupes = [], []
    for note in notes:
        identity = _front_identity(note.front)
        if identity in existing_identity_set:
            dupes.append(note)
        else:
            new.append(note)
    return new, dupes
