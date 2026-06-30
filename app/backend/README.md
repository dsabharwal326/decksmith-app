# Decksmith

Deterministic Anki deck builder for medical students — runs locally on Mac/Windows/Linux, or deploy once and use from any browser, phone, or tablet.

---

## What it does

1. **Upload** your flashcard text files (or let the AI generate them for you)
2. **Validate** — catches broken cards and offers auto-fixes
3. **Classify** — routes cards into specialty subdecks automatically (`Medicine::Cardiology`, `Pharmacology::Cardiovascular_Drugs`, etc.)
4. **Augment** *(optional, needs AI key)* — enriches each card with mechanism, clinical context, high-yield points, and exam traps
5. **Build** — downloads a ready-to-import `.apkg` file for Anki

All card IDs are deterministic (SHA-256). Rebuild the same cards and Anki won't create duplicates.

---

## Card formats

Write one card per line in a plain `.txt` file:

```
# Basic — question on front, answer on back
What is troponin? :: Cardiac-specific protein released during MI

# Reverse — generates a card in both directions
Troponin || Cardiac biomarker for MI diagnosis

# Basic + Extra — extra info shown after the flip
Metoprolol ||| Beta-1 selective blocker ||| Avoid abrupt discontinuation

# Cloze — fill-in-the-blank
The {{c1::Frank-Starling}} law states stroke volume increases with preload

# Cloze + Extra — cloze with a note shown after the flip
The {{c1::troponin I}} is the most cardiac-specific isoform ||| Absent in healthy skeletal muscle
```

Mix formats freely in the same file. Blank lines are ignored.

---

## Running locally

### Requirements
- Python 3.9 or later ([python.org](https://www.python.org/downloads/))

### Mac — double-click to run
1. Download or clone this repo
2. Double-click **`Decksmith.command`**

That's it. The launcher installs dependencies and opens Decksmith in your browser automatically.

### Windows — double-click to run
1. Download or clone this repo
2. Double-click **`Decksmith.bat`**

### Linux
```bash
chmod +x Decksmith.desktop
./Decksmith.desktop
```

### Manual (any OS)
```bash
pip install streamlit genanki
streamlit run app.py
```

---

## Offline AI (no API key)

Decksmith can use [Ollama](https://ollama.com) to run AI features completely offline:

1. Install Ollama from [ollama.com](https://ollama.com)
2. The launcher will detect your hardware and recommend an appropriate model
3. In the app, select **Ollama (local, offline)** as the provider

Or pull a model manually:
```bash
ollama pull llama3        # ~4 GB, good for most machines
ollama pull phi3          # ~2 GB, lighter option
ollama pull mistral       # ~4 GB, strong reasoning
```

---

## Cloud / API providers

For the best results with AI features, use a cloud provider:

| Provider | Intake model | Augmentation model |
|---|---|---|
| Anthropic (recommended) | claude-haiku | claude-sonnet |
| OpenAI | gpt-4o-mini | gpt-4o |

Set your key in the **AI Settings** section of the app, or via environment variable:
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
```

---

## Deploy to the web (iOS / Android / any browser)

Deploy to [Streamlit Cloud](https://streamlit.io/cloud) — free tier available:

1. Push this repo to GitHub
2. Go to [share.streamlit.io](https://share.streamlit.io) → New app → select your repo → `app.py`
3. Under **App settings → Secrets**, paste:

```toml
[api_keys]
ANTHROPIC_API_KEY = "sk-ant-..."
```

The app will auto-detect the key and pre-select the right provider. Anyone with the URL can use it — no install required.

See [`.streamlit/secrets.toml.template`](.streamlit/secrets.toml.template) for the full secrets format.

---

## Subdecks and classification

When **Classify into subdecks** is enabled, Decksmith reads the taxonomy tags assigned to each card and routes it into the correct subdeck:

| Tags | Subdeck |
|---|---|
| None | `DeckName::General` |
| One specialty | `DeckName::Medicine::Cardiology` |
| Two or more specialties | `DeckName::Integrated` |

The taxonomy covers 300+ medical topics across 37 specialties. Classification is purely local — no AI needed.

---

## Adding cards to an existing deck

Upload your current `.apkg` in the **"Add to an existing deck"** section before building. Decksmith will compare front-field hashes and skip any card already present, so Anki won't see duplicates when you import.

---

## AI Augment — expansion modes

When augmenting cards with AI content, choose how the enrichment is applied:

| Mode | Behaviour |
|---|---|
| **Append** | Keeps your original answer and adds AI content below (safe default) |
| **Empty fields only** | Only fills cards whose back field is blank |
| **Overwrite** | Replaces the back entirely with AI-generated content |

---

## Project structure

```
app.py                  — Streamlit web UI
launch.py               — cross-platform installer / launcher
Decksmith.command       — macOS double-click launcher
Decksmith.bat           — Windows double-click launcher
Decksmith.desktop       — Linux launcher
core/
  engine.py             — parser, note models, deck builder
  validator.py          — fixable / invalid card detection
  classifier.py         — taxonomy-based subdeck routing
  taxonomy.py           — 300+ medical topic → specialty mappings
  provider.py           — Anthropic / OpenAI / Ollama / Stub abstraction
  intake.py             — AI repair of invalid cards
  augment_ai.py         — AI enrichment proposals
  card_factory.py       — AI topic-to-cards generator
  apkg_import.py        — read existing .apkg, extract identity set
  augmentation.py       — apply augmentation payloads to notes
  augmentation_policy.py— expansion mode policy
.streamlit/
  config.toml           — upload limits, XSRF, dark theme
  secrets.toml.template — API key setup guide for Streamlit Cloud
```

---

## Requirements

```
streamlit>=1.35.0
genanki>=0.13.0
anthropic>=0.25.0   # only if using Anthropic
openai>=1.30.0      # only if using OpenAI or Ollama
```

---

## License

MIT
