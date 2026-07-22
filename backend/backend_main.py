"""Bundled entry point — used by PyInstaller only."""
import multiprocessing
import os
import sys

# When frozen by PyInstaller, _MEIPASS is the directory where bundled files
# are extracted. Add it to sys.path so `import api` and `import core.*` work.
if getattr(sys, 'frozen', False):
    bundle_dir = sys._MEIPASS  # type: ignore[attr-defined]
    if bundle_dir not in sys.path:
        sys.path.insert(0, bundle_dir)
    # Also set cwd so any file-relative ops in api.py work
    os.chdir(bundle_dir)

if __name__ == "__main__":
    multiprocessing.freeze_support()
    import uvicorn
    from api import app  # noqa: F401
    uvicorn.run(app, host="0.0.0.0", port=8503, log_level="warning")
