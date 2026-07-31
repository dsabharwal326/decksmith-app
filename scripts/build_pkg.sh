#!/usr/bin/env bash
# build_pkg.sh — builds a self-contained Decksmith.pkg for macOS distribution
# Usage: bash scripts/build_pkg.sh [--version 1.0.0]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$REPO/backend"
APP_SRC="$REPO/app"
VERSION="${2:-1.0.0}"
if [[ "${1:-}" == "--version" ]]; then VERSION="$2"; fi

APP_NAME="decksmith_app"
APP_BUNDLE="$APP_SRC/build/macos/Build/Products/Release/$APP_NAME.app"
PKG_OUT="$REPO/dist/Decksmith-$VERSION.pkg"

echo "==> Building Decksmith $VERSION"
mkdir -p "$REPO/dist"

# ── 1. Flutter release build ──────────────────────────────────────────────
echo "==> [1/4] Building Flutter app..."
cd "$APP_SRC"
flutter build macos --release
echo "    Built: $APP_BUNDLE"

# ── 2. PyInstaller backend bundle ─────────────────────────────────────────
echo "==> [2/4] Bundling Python backend..."
cd "$BACKEND"

# Clean previous build
rm -rf dist build decksmith_backend.spec 2>/dev/null || true

pyinstaller backend_main.py \
  --name decksmith_backend \
  --onedir \
  --noconfirm \
  --hidden-import=genanki \
  --hidden-import=yaml \
  --hidden-import=ftfy \
  --hidden-import=anyio \
  --hidden-import=anyio._backends._asyncio \
  --hidden-import=anyio._backends._trio \
  --hidden-import=starlette \
  --hidden-import=starlette.middleware \
  --collect-all genanki \
  --collect-all ftfy \
  --collect-all pyyaml \
  2>&1 | tail -10

BUNDLED_BIN="$BACKEND/dist/decksmith_backend"
echo "    Bundled: $BUNDLED_BIN"

# ── 3. Embed backend inside .app ──────────────────────────────────────────
echo "==> [3/4] Embedding backend in .app..."
RESOURCES="$APP_BUNDLE/Contents/Resources"
DEST="$RESOURCES/decksmith_backend"
rm -rf "$DEST"
cp -R "$BUNDLED_BIN" "$DEST"
echo "    Embedded at: $DEST"

# ── 4. Build .pkg ─────────────────────────────────────────────────────────
echo "==> [4/4] Creating installer package..."

# Stage payload: /Applications
STAGE="$REPO/dist/.pkg_stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Applications"
cp -R "$APP_BUNDLE" "$STAGE/Applications/"

# Postinstall script: copy app to the installing user's Desktop
SCRIPTS_DIR="$REPO/dist/.pkg_scripts"
rm -rf "$SCRIPTS_DIR"
mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" <<'SCRIPT'
#!/usr/bin/env bash
# Copy the app to the current user's Desktop (overwrite if present)
DEST_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "$USER")
DESKTOP="/Users/$DEST_USER/Desktop"
if [ -d "$DESKTOP" ]; then
    cp -R "/Applications/decksmith_app.app" "$DESKTOP/decksmith_app.app"
    chown -R "$DEST_USER" "$DESKTOP/decksmith_app.app"
fi
exit 0
SCRIPT
chmod +x "$SCRIPTS_DIR/postinstall"

pkgbuild \
  --root "$STAGE" \
  --identifier "com.decksmith.app" \
  --version "$VERSION" \
  --install-location "/" \
  --scripts "$SCRIPTS_DIR" \
  "$PKG_OUT"

rm -rf "$STAGE" "$SCRIPTS_DIR"

echo ""
echo "✓ Done! Installer: $PKG_OUT"
echo "  Transfer to new Mac and double-click to install."
echo "  The app will appear in /Applications/decksmith_app.app"
