# Decksmith

AI-powered Anki deck generator — monorepo.

```
decksmith/
  app/        Flutter macOS desktop app
  backend/    Python FastAPI server (AI card generation, .apkg build)
```

## Quick start

**Backend**
```bash
cd backend
pip install -r requirements.txt
uvicorn api:app --port 8503
```

**App**
```bash
cd app
flutter pub get
flutter run -d macos
```

## Distribution

Build a self-contained `.app` with both binaries bundled:

```bash
# 1. Bundle Python backend
cd backend
python3 -m PyInstaller decksmith_backend.spec --noconfirm

# 2. Build Flutter app
cd ../app
flutter build macos --release

# 3. Embed backend + ollama into .app
APP=build/macos/Build/Products/Release/decksmith_app.app
cp -R ../backend/dist/decksmith_backend "$APP/Contents/Resources/"
cp /usr/local/bin/ollama "$APP/Contents/Resources/ollama/ollama"

# 4. Zip
cd build/macos/Build/Products/Release
zip -r ~/Desktop/Decksmith.zip decksmith_app.app
```
