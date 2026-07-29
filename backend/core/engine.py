from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, Set
import csv
import hashlib
import io
import re
import genanki

try:
    import yaml as _yaml
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

try:
    import ftfy as _ftfy
    def _fix_encoding(text: str) -> str:
        return _ftfy.fix_text(text)
except ImportError:
    def _fix_encoding(text: str) -> str:  # type: ignore[misc]
        try:
            return text.encode('latin-1').decode('utf-8')
        except (UnicodeEncodeError, UnicodeDecodeError):
            return text


# =========================
# CONSTANTS
# =========================

ALLOWED_NOTE_TYPES = {
    "cloze",
    "basic",
    "basic_reverse",
    "basic_extra",
}

CLOZE_PATTERN = re.compile(r"\{\{c\d+::.+?\}\}")


# =========================
# CANONICAL NOTE MODEL
# =========================

@dataclass(frozen=True)
class Note:
    note_type: str
    front: str
    back: str
    extra: str = ""
    tags: Tuple[str, ...] = field(default_factory=tuple)
    guid: Optional[str] = None  # preserved from source .apkg for update-in-place imports

    def __post_init__(self):
        object.__setattr__(self, "tags", tuple(sorted(self.tags)))


# =========================
# BUILD RESULT
# =========================

@dataclass(frozen=True)
class BuildResult:
    decks: Tuple[genanki.Deck, ...]
    total_notes: int
    total_cards: int
    deck_id: int
    model_ids_used: Tuple[int, ...]
    warnings: Tuple[str, ...]
    subdeck_counts: Tuple[Tuple[str, int], ...]


# =========================
# DETERMINISTIC ID HELPERS
# =========================

def _stable_hash_int(value: str) -> int:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
    return int(digest[:12], 16)


def _deck_id(deck_name: str) -> int:
    return _stable_hash_int(f"deck::{deck_name}")


def _model_id(name: str) -> int:
    return _stable_hash_int(f"model::{name}")


# =========================
# VALIDATION
# =========================

class ValidationError(Exception):
    pass


def _contains_cloze(text: str) -> bool:
    return bool(CLOZE_PATTERN.search(text))


def _braces_balanced(text: str) -> bool:
    return text.count("{{") == text.count("}}")


def _validate_note(note: Note) -> None:
    if note.note_type not in ALLOWED_NOTE_TYPES:
        raise ValidationError(f"Invalid note_type: {note.note_type}")

    if note.note_type == "cloze":
        if not _contains_cloze(note.front):
            raise ValidationError("Cloze note missing cloze pattern")
        if not _braces_balanced(note.front):
            raise ValidationError("Cloze note has unbalanced braces")
    else:
        if _contains_cloze(note.front) or _contains_cloze(note.back):
            raise ValidationError("Non-cloze note contains cloze pattern")

    if note.note_type in {"basic", "basic_reverse", "basic_extra"}:
        if not note.front.strip():
            raise ValidationError("Front field empty")
        if not note.back.strip():
            raise ValidationError("Back field empty")


# =========================
# PARSER
# =========================

def parse_text_to_notes(text: str, strict_repair: bool) -> List[Note]:
    notes: List[Note] = []

    text = _fix_encoding(text)
    lines = text.splitlines()
    cloze_buffer: List[str] = []
    collecting_cloze = False

    _block_key_re = re.compile(r'^(TYPE|TEXT|FRONT|BACK|EXTRA|TAGS|NOTETYPE)\s*:', re.IGNORECASE)

    for raw_line in lines:
        line = raw_line.rstrip()

        if not line.strip():
            cloze_buffer.clear()
            collecting_cloze = False
            continue

        # Skip card-block metadata lines so they aren't mis-parsed as card content
        if _block_key_re.match(line.strip()):
            continue

        if strict_repair:
            line = line.strip()

        if collecting_cloze:
            cloze_buffer.append(line)
            combined = " ".join(cloze_buffer)

            if _braces_balanced(combined):
                notes.append(Note("cloze", combined, ""))
                cloze_buffer.clear()
                collecting_cloze = False
            continue

        if _contains_cloze(line):
            # Cloze with extra info:  {{c1::term}} sentence ||| extra shown after flip
            if "|||" in line:
                cloze_part, extra_part = line.split("|||", 1)
                cloze_part = cloze_part.strip()
                if _braces_balanced(cloze_part):
                    notes.append(Note("cloze", cloze_part, "", extra_part.strip()))
                else:
                    cloze_buffer = [cloze_part]
                    collecting_cloze = True
            elif _braces_balanced(line):
                notes.append(Note("cloze", line, ""))
            else:
                cloze_buffer = [line]
                collecting_cloze = True
            continue

        if "|||" in line:
            parts = line.split("|||", 2)
            if len(parts) == 3:
                notes.append(
                    Note("basic_extra", parts[0].strip(), parts[1].strip(), parts[2].strip())
                )
            continue

        if "||" in line:
            parts = line.split("||", 1)
            if len(parts) == 2:
                notes.append(
                    Note("basic_reverse", parts[0].strip(), parts[1].strip())
                )
            continue

        if "::" in line:
            parts = line.split("::", 1)
            if len(parts) == 2:
                notes.append(
                    Note("basic", parts[0].strip(), parts[1].strip())
                )
            continue

    return notes


def parse_yaml_frontmatter_to_notes(text: str) -> List[Note]:
    """Parse the YAML-frontmatter card format.

    Each card block is:
        ---
        type: cloze | basic | basic_reverse | basic_extra
        tags:
          - Tag1
        difficulty: low | medium | high   (optional, ignored)
        ---

        <card content>

    Cloze content  — first paragraph is the cloze text; second paragraph (if
    present) is the extra field.

    Basic content  — lines starting with "Q:" and "A:" (multi-line supported);
    the text after Q: is the front, after A: is the back.
    """
    text = _fix_encoding(text)
    notes: List[Note] = []

    # Split on "---" boundaries; skip empty segments
    raw_blocks = re.split(r'\n?---\n', text)
    # Blocks alternate: [pre, frontmatter, body, frontmatter, body, ...]
    # Strip any leading non-frontmatter text
    i = 0
    # Skip content before first ---
    while i < len(raw_blocks) and not raw_blocks[i].strip().startswith('type:') \
            and 'type:' not in raw_blocks[i]:
        i += 1

    while i < len(raw_blocks) - 1:
        fm_raw = raw_blocks[i].strip()
        body_raw = raw_blocks[i + 1].strip() if i + 1 < len(raw_blocks) else ''
        i += 2

        if not fm_raw or 'type:' not in fm_raw:
            continue

        # Parse frontmatter
        if _YAML_AVAILABLE:
            try:
                meta = _yaml.safe_load(fm_raw) or {}
            except Exception:
                meta = {}
        else:
            meta = _parse_simple_yaml(fm_raw)

        note_type = str(meta.get('type', 'basic')).strip().lower()
        raw_tags = meta.get('tags', [])
        if isinstance(raw_tags, str):
            raw_tags = [t.strip() for t in raw_tags.split(',') if t.strip()]
        tags = tuple(str(t).strip() for t in raw_tags if t)

        if not body_raw:
            continue

        if note_type == 'cloze':
            # Split body into paragraphs; first = cloze text, rest = extra
            paragraphs = [p.strip() for p in re.split(r'\n\s*\n', body_raw) if p.strip()]
            if not paragraphs:
                continue
            cloze_text = paragraphs[0]
            extra = ' '.join(paragraphs[1:]) if len(paragraphs) > 1 else ''
            if _contains_cloze(cloze_text):
                notes.append(Note('cloze', cloze_text, '', extra, tags))

        elif note_type in ('basic', 'basic_reverse', 'basic_extra'):
            front, back, extra = _parse_qa_body(body_raw)
            if front and back:
                notes.append(Note(note_type, front, back, extra, tags))

    return notes


def _parse_simple_yaml(text: str) -> dict:
    """Minimal YAML parser for when PyYAML isn't available (handles type/tags/difficulty)."""
    result: dict = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if ':' in line and not line.startswith(' ') and not line.startswith('-'):
            key, _, val = line.partition(':')
            key = key.strip()
            val = val.strip()
            if not val:  # list follows
                items = []
                i += 1
                while i < len(lines) and lines[i].startswith(' ') or \
                        (i < len(lines) and lines[i].strip().startswith('-')):
                    item = lines[i].strip().lstrip('-').strip()
                    if item:
                        items.append(item)
                    i += 1
                result[key] = items
                continue
            else:
                result[key] = val
        i += 1
    return result


def _parse_qa_body(body: str) -> tuple[str, str, str]:
    """Extract front/back/extra from a Q:/A: body block."""
    front_lines: List[str] = []
    back_lines: List[str] = []
    extra_lines: List[str] = []
    mode = None  # 'q', 'a', 'extra'

    for line in body.splitlines():
        stripped = line.strip()
        if re.match(r'^Q\s*:', stripped, re.IGNORECASE):
            mode = 'q'
            rest = re.sub(r'^Q\s*:\s*', '', stripped, flags=re.IGNORECASE)
            if rest:
                front_lines.append(rest)
        elif re.match(r'^A\s*:', stripped, re.IGNORECASE):
            mode = 'a'
            rest = re.sub(r'^A\s*:\s*', '', stripped, flags=re.IGNORECASE)
            if rest:
                back_lines.append(rest)
        elif re.match(r'^Extra\s*:', stripped, re.IGNORECASE):
            mode = 'extra'
            rest = re.sub(r'^Extra\s*:\s*', '', stripped, flags=re.IGNORECASE)
            if rest:
                extra_lines.append(rest)
        else:
            if mode == 'q':
                front_lines.append(stripped)
            elif mode == 'a':
                back_lines.append(stripped)
            elif mode == 'extra':
                extra_lines.append(stripped)

    front = ' '.join(f for f in front_lines if f)
    back = ' '.join(b for b in back_lines if b)
    extra = ' '.join(e for e in extra_lines if e)
    return front, back, extra


def parse_tsv_to_notes(text: str) -> List[Note]:
    """Parse a TSV file into Notes.

    Supported column layouts (auto-detected by header or column count):

    3 columns:  front  back  tags
    4 columns:  front  back  extra  tags
    5 columns:  type   front  back  extra  tags
    With header row (first row contains non-card text like "front", "back", etc.)

    Tags column is comma- or space-separated.
    Type column values: basic, cloze, basic_reverse, basic_extra.
    If type is omitted: cloze if front contains {{c}}, else basic.
    """
    text = _fix_encoding(text)
    notes: List[Note] = []
    reader = csv.reader(io.StringIO(text), delimiter='\t')
    rows = list(reader)
    if not rows:
        return notes

    # Detect header row
    header_keywords = {'front', 'back', 'type', 'extra', 'tags', 'note_type',
                       'question', 'answer', 'text'}
    first = [c.strip().lower() for c in rows[0]]
    has_header = any(cell in header_keywords for cell in first)

    # Build column index map
    col: dict = {}
    if has_header:
        for idx, name in enumerate(first):
            col[name] = idx
        rows = rows[1:]
    else:
        # Positional mapping by column count
        ncols = len(rows[0]) if rows else 0
        if ncols == 3:
            col = {'front': 0, 'back': 1, 'tags': 2}
        elif ncols == 4:
            col = {'front': 0, 'back': 1, 'extra': 2, 'tags': 3}
        elif ncols >= 5:
            col = {'type': 0, 'front': 1, 'back': 2, 'extra': 3, 'tags': 4}
        else:
            col = {'front': 0, 'back': 1}

    # Aliases
    if 'question' in col and 'front' not in col:
        col['front'] = col['question']
    if 'answer' in col and 'back' not in col:
        col['back'] = col['answer']
    if 'note_type' in col and 'type' not in col:
        col['type'] = col['note_type']
    if 'notetype' in col and 'type' not in col:
        col['type'] = col['notetype']

    # Track whether a separate 'text' column exists alongside 'front'
    _text_col = col.get('text')
    if _text_col is not None and 'front' not in col:
        col['front'] = _text_col
        _text_col = None  # merged; no need for special handling

    def _get(row: list, key: str, default: str = '') -> str:
        idx = col.get(key)
        if idx is None or idx >= len(row):
            return default
        return row[idx].strip()

    def _parse_tags(raw: str) -> Tuple[str, ...]:
        parts = re.split(r'[,\s]+', raw.strip())
        return tuple(p for p in parts if p)

    for row in rows:
        if not any(cell.strip() for cell in row):
            continue
        # When both 'text' and 'front' columns exist (e.g. NoteType/Text/Front/Back/Extra/Tags),
        # cloze cards populate 'text' and leave 'front' empty; basic cards do the reverse.
        front = _get(row, 'front')
        if not front and _text_col is not None and _text_col < len(row):
            front = row[_text_col].strip()
        back = _get(row, 'back')
        extra = _get(row, 'extra')
        tags = _parse_tags(_get(row, 'tags'))
        raw_type = _get(row, 'type')

        if not front:
            continue

        # Infer type if not given
        if raw_type:
            note_type = raw_type.lower().replace(' ', '_').replace('-', '_')
        elif _contains_cloze(front):
            note_type = 'cloze'
        else:
            note_type = 'basic'

        if note_type not in ALLOWED_NOTE_TYPES:
            note_type = 'basic'

        notes.append(Note(note_type, front, back, extra, tags))

    return notes


def parse_card_block_to_notes(text: str) -> List[Note]:
    """Parse the --- CARD N --- / TYPE: / TEXT: / FRONT: / BACK: / EXTRA: / TAGS: format."""
    text = _fix_encoding(text)
    notes: List[Note] = []

    # Split on card-block separators
    blocks = re.split(r'-{2,}\s*CARD\s+\d+\s*-{2,}', text, flags=re.IGNORECASE)

    def _parse_tags(raw: str) -> Tuple[str, ...]:
        parts = re.split(r'[,\s]+', raw.strip())
        return tuple(p for p in parts if p)

    for block in blocks:
        block = block.strip()
        if not block:
            continue
        fields: dict = {}
        current_key: Optional[str] = None
        current_lines: List[str] = []

        for line in block.splitlines():
            m = re.match(r'^(TYPE|TEXT|FRONT|BACK|EXTRA|TAGS)\s*:\s*(.*)', line, re.IGNORECASE)
            if m:
                if current_key:
                    fields[current_key] = '\n'.join(current_lines).strip()
                current_key = m.group(1).upper()
                current_lines = [m.group(2)]
            elif current_key:
                current_lines.append(line)

        if current_key:
            fields[current_key] = '\n'.join(current_lines).strip()

        if not fields:
            continue

        raw_type = fields.get('TYPE', '').lower().replace(' ', '_').replace('-', '_')
        # Cloze cards use TEXT; basic cards use FRONT/BACK
        front = fields.get('TEXT') or fields.get('FRONT', '')
        back = fields.get('BACK', '')
        extra = fields.get('EXTRA', '')
        tags = _parse_tags(fields.get('TAGS', ''))

        if not front:
            continue

        if raw_type in ALLOWED_NOTE_TYPES:
            note_type = raw_type
        elif _contains_cloze(front):
            note_type = 'cloze'
        else:
            note_type = 'basic'

        notes.append(Note(note_type, front, back, extra, tags))

    return notes


def detect_format(text: str) -> str:
    """Return 'yaml_frontmatter', 'card_block', 'tsv', or 'decksmith'."""
    stripped = text.lstrip()
    if stripped.startswith('---') and 'type:' in stripped[:200]:
        return 'yaml_frontmatter'
    # Card-block: lines like "--- CARD 1 ---" or "TYPE: Cloze"
    if re.search(r'-{2,}\s*CARD\s+\d+\s*-{2,}', stripped[:500], re.IGNORECASE):
        return 'card_block'
    if re.match(r'(TYPE|TEXT|FRONT|BACK)\s*:', stripped[:200], re.IGNORECASE):
        return 'card_block'
    # TSV: at least one line with a tab
    lines = stripped.splitlines()
    tab_lines = sum(1 for l in lines[:20] if '\t' in l)
    if tab_lines >= max(1, min(3, len(lines) // 2)):
        return 'tsv'
    return 'decksmith'


def parse_auto(text: str, strict_repair: bool = False) -> List[Note]:
    """Detect format and parse accordingly."""
    fmt = detect_format(text)
    if fmt == 'yaml_frontmatter':
        return parse_yaml_frontmatter_to_notes(text)
    if fmt == 'card_block':
        return parse_card_block_to_notes(text)
    if fmt == 'tsv':
        return parse_tsv_to_notes(text)
    return parse_text_to_notes(text, strict_repair=strict_repair)


# =========================
# MODEL FACTORY
# =========================

def _create_models():
    return {
        "cloze": genanki.Model(
            _model_id("cloze"),
            "Cloze",
            fields=[{"name": "Text"}, {"name": "Extra"}],
            templates=[{
                "name": "Cloze Card",
                "qfmt": "{{cloze:Text}}",
                "afmt": "{{cloze:Text}}<br>{{Extra}}",
            }],
            model_type=genanki.Model.CLOZE,
        ),
        "basic": genanki.Model(
            _model_id("basic"),
            "Basic",
            fields=[{"name": "Front"}, {"name": "Back"}],
            templates=[{
                "name": "Card 1",
                "qfmt": "{{Front}}",
                "afmt": "{{Front}}<hr id=\"answer\">{{Back}}",
            }],
        ),
        "basic_reverse": genanki.Model(
            _model_id("basic_reverse"),
            "Basic (Reversed)",
            fields=[{"name": "Front"}, {"name": "Back"}],
            templates=[
                {"name": "Card 1", "qfmt": "{{Front}}", "afmt": "{{Front}}<hr id=\"answer\">{{Back}}"},
                {"name": "Card 2", "qfmt": "{{Back}}", "afmt": "{{Back}}<hr id=\"answer\">{{Front}}"},
            ],
        ),
        "basic_extra": genanki.Model(
            _model_id("basic_extra"),
            "Basic (Extra)",
            fields=[{"name": "Front"}, {"name": "Back"}, {"name": "Extra"}],
            templates=[{
                "name": "Card 1",
                "qfmt": "{{Front}}",
                "afmt": "{{Front}}<hr id=\"answer\">{{Back}}<br>{{Extra}}",
            }],
        ),
    }


# =========================
# SUBDECK ROUTING
# =========================

def _taxonomy_tags(note: Note) -> List[str]:
    return [t for t in note.tags if "::" in t]


def _subdeck_name(note: Note, root: str) -> str:
    taxonomy = _taxonomy_tags(note)
    if len(taxonomy) == 0:
        return f"{root}::General"
    elif len(taxonomy) == 1:
        return f"{root}::{taxonomy[0]}"
    else:
        return f"{root}::Integrated"


# =========================
# ENGINE ENTRY
# =========================

def _html_extra(text: str) -> str:
    """Convert plain-text extra content to safe HTML for Anki fields."""
    import re as _re
    # If text already has HTML tags, leave it alone (e.g. image HTML from wikimedia)
    if _re.search(r"<\s*\w+[^>]*>", text):
        return text
    # Plain text: escape bare < > and convert newlines to <br>
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br>")


def build_deck(notes: List[Note], deck_name: str, strict_repair: bool) -> BuildResult:
    root_id = _deck_id(deck_name)
    root_deck = genanki.Deck(root_id, deck_name)

    models = _create_models()
    used_model_ids: Set[int] = set()
    warnings: List[str] = []
    total_cards = 0
    accepted_notes = 0

    subdecks: Dict[str, genanki.Deck] = {}

    for note in notes:
        try:
            _validate_note(note)
        except ValidationError as e:
            if strict_repair:
                raise
            warnings.append(str(e))
            continue

        model = models[note.note_type]
        used_model_ids.add(model.model_id)

        if note.note_type == "cloze":
            fields = [note.front, _html_extra(note.extra)]
        elif note.note_type in {"basic", "basic_reverse"}:
            fields = [note.front, note.back]
        else:
            fields = [note.front, note.back, _html_extra(note.extra)]

        genanki_kwargs: dict = {"model": model, "fields": fields, "tags": list(note.tags)}
        if note.guid:
            genanki_kwargs["guid"] = note.guid
        genanki_note = genanki.Note(**genanki_kwargs)

        subdeck_name = _subdeck_name(note, deck_name)
        if subdeck_name not in subdecks:
            subdecks[subdeck_name] = genanki.Deck(_deck_id(subdeck_name), subdeck_name)

        subdecks[subdeck_name].add_note(genanki_note)

        total_cards += len(model.templates)
        accepted_notes += 1

    # Root deck first, then subdecks sorted by name for determinism
    all_decks = tuple(
        [root_deck] + [subdecks[k] for k in sorted(subdecks.keys())]
    )

    subdeck_counts = tuple(
        (k, len(subdecks[k].notes)) for k in sorted(subdecks.keys())
    )

    return BuildResult(
        decks=all_decks,
        total_notes=accepted_notes,
        total_cards=total_cards,
        deck_id=root_id,
        model_ids_used=tuple(sorted(used_model_ids)),
        warnings=tuple(warnings),
        subdeck_counts=subdeck_counts,
    )