"""
Local SQLite cache for AI enhancement payloads.
Keyed by card identity SHA-256. Hit = free, no API call.
DB lives at ~/.decksmith/cache.db
"""
from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path
from typing import Optional


_DB_PATH = Path.home() / ".decksmith" / "cache.db"
_lock = threading.Lock()
_conn: Optional[sqlite3.Connection] = None


def _get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        _DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        _conn = sqlite3.connect(str(_DB_PATH), check_same_thread=False)
        _conn.execute("""
            CREATE TABLE IF NOT EXISTS enhancements (
                identity TEXT PRIMARY KEY,
                payload_json TEXT NOT NULL,
                created_at INTEGER DEFAULT (strftime('%s', 'now'))
            )
        """)
        _conn.commit()
    return _conn


def get(identity: str) -> Optional[dict]:
    with _lock:
        try:
            row = _get_conn().execute(
                "SELECT payload_json FROM enhancements WHERE identity = ?", (identity,)
            ).fetchone()
            return json.loads(row[0]) if row else None
        except Exception:
            return None


def put(identity: str, payload_dict: dict) -> None:
    with _lock:
        try:
            _get_conn().execute(
                "INSERT OR REPLACE INTO enhancements (identity, payload_json) VALUES (?, ?)",
                (identity, json.dumps(payload_dict)),
            )
            _get_conn().commit()
        except Exception:
            pass


def stats() -> dict:
    with _lock:
        try:
            row = _get_conn().execute("SELECT COUNT(*) FROM enhancements").fetchone()
            return {"cached_cards": row[0] if row else 0, "db_path": str(_DB_PATH)}
        except Exception:
            return {"cached_cards": 0, "db_path": str(_DB_PATH)}
