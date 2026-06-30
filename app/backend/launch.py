"""
Decksmith launcher — cross-platform setup and start.

Handles: macOS (Intel + Apple Silicon), Windows, Linux
- Checks Python version
- Installs missing Python packages
- Detects hardware (RAM, GPU, chip)
- Installs Ollama if not present (or guides the user)
- Pulls the best local AI model for the device
- Starts the Streamlit app

Usage:
  python launch.py              # full setup
  python launch.py --no-ollama  # skip Ollama, just install packages and start
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


# =========================================
# PYTHON VERSION
# =========================================

MIN_PYTHON = (3, 9)

def check_python():
    v = sys.version_info[:2]
    if v < MIN_PYTHON:
        _die(
            f"Python {MIN_PYTHON[0]}.{MIN_PYTHON[1]}+ is required "
            f"(you have {v[0]}.{v[1]}).\n"
            "  Download: https://www.python.org/downloads/"
        )
    _ok(f"Python {sys.version.split()[0]}")


# =========================================
# PYTHON PACKAGES
# =========================================

REQUIRED = {
    "streamlit":  "streamlit>=1.35.0",
    "genanki":    "genanki>=0.13.0",
    "anthropic":  "anthropic>=0.25.0",
    "openai":     "openai>=1.30.0",
}

def install_packages():
    missing = [(mod, spec) for mod, spec in REQUIRED.items() if not _pkg_installed(mod)]
    if not missing:
        _ok("All Python packages present")
        return
    print(f"  Installing {len(missing)} package(s)…")
    for mod, spec in missing:
        try:
            subprocess.check_call(
                [sys.executable, "-m", "pip", "install", spec, "--quiet"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            _ok(f"Installed {spec}")
        except subprocess.CalledProcessError:
            _die(f"Could not install {spec}. Try:  pip install {spec}")

def _pkg_installed(module: str) -> bool:
    return importlib.util.find_spec(module) is not None


# =========================================
# HARDWARE DETECTION
# =========================================

SYSTEM = platform.system()   # "Darwin" | "Windows" | "Linux"
MACHINE = platform.machine() # "arm64" | "x86_64" | "AMD64" | ...

def get_ram_gb() -> float:
    try:
        import psutil
        return psutil.virtual_memory().total / (1024 ** 3)
    except Exception:
        pass
    try:
        if SYSTEM == "Darwin":
            out = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)
            return int(out.strip()) / (1024 ** 3)
        elif SYSTEM == "Windows":
            out = subprocess.check_output(
                ["powershell", "-Command",
                 "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory"],
                text=True, stderr=subprocess.DEVNULL,
            )
            return int(out.strip()) / (1024 ** 3)
        elif SYSTEM == "Linux":
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal"):
                        return int(line.split()[1]) / (1024 ** 2)
    except Exception:
        pass
    return 8.0

def is_apple_silicon() -> bool:
    return SYSTEM == "Darwin" and MACHINE == "arm64"

def has_nvidia() -> bool:
    if shutil.which("nvidia-smi"):
        return True
    # Windows: nvidia-smi may be in a non-PATH location
    if SYSTEM == "Windows":
        nv = Path(os.environ.get("SystemRoot", "C:\\Windows")) / "System32" / "nvidia-smi.exe"
        return nv.exists()
    return False

def has_amd_gpu() -> bool:
    # Linux ROCm
    if SYSTEM == "Linux" and shutil.which("rocm-smi"):
        return True
    # Windows AMD
    if SYSTEM == "Windows":
        amd = Path("C:\\Windows\\System32\\amdkmdap.dll")
        return amd.exists()
    return False

def hardware_tier(ram_gb: float) -> str:
    if is_apple_silicon():
        if ram_gb >= 32:
            return "apple_high"
        elif ram_gb >= 16:
            return "apple_mid"
        else:
            return "apple_base"
    if has_nvidia():
        return "nvidia_high" if ram_gb >= 16 else "nvidia_base"
    if has_amd_gpu():
        return "amd" if ram_gb >= 16 else "cpu_base"
    # CPU-only
    return "cpu_high" if ram_gb >= 16 else "cpu_base"

def hardware_label(ram_gb: float) -> str:
    if is_apple_silicon():
        return f"Apple Silicon ({SYSTEM}), {ram_gb:.0f} GB unified memory"
    if has_nvidia():
        return f"NVIDIA GPU, {ram_gb:.0f} GB RAM"
    if has_amd_gpu():
        return f"AMD GPU, {ram_gb:.0f} GB RAM"
    return f"CPU-only ({SYSTEM}), {ram_gb:.0f} GB RAM"


# =========================================
# MODEL TABLE
# =========================================
# (model_id, size_gb, description)
TIER_MODELS: dict[str, list[tuple[str, float, str]]] = {
    "apple_high": [
        ("llama3.1:8b",  4.7, "Best medical reasoning — recommended for M2 Pro/Max, M3, M4"),
        ("mistral:7b",   4.1, "Strong alternative"),
        ("llama3.2:3b",  2.0, "Lightweight fallback"),
    ],
    "apple_mid": [
        ("llama3.2:3b",  2.0, "Good balance of speed and quality"),
        ("mistral:7b",   4.1, "Better quality, uses more memory"),
        ("phi3:mini",    2.3, "Very fast"),
    ],
    "apple_base": [
        ("phi3:mini",    2.3, "Best quality for 8 GB"),
        ("llama3.2:1b",  1.3, "Fastest — lowest memory use"),
    ],
    "nvidia_high": [
        ("llama3.1:8b",  4.7, "GPU-accelerated, best quality"),
        ("mistral:7b",   4.1, "Fast GPU inference"),
        ("phi3:mini",    2.3, "Lightweight"),
    ],
    "nvidia_base": [
        ("phi3:mini",    2.3, "Fits on smaller NVIDIA GPUs"),
        ("llama3.2:1b",  1.3, "Fastest option"),
    ],
    "amd": [
        ("phi3:mini",    2.3, "Best for AMD GPU (ROCm)"),
        ("llama3.2:3b",  2.0, "Slightly larger"),
    ],
    "cpu_high": [
        ("phi3:mini",    2.3, "Best CPU-only model"),
        ("llama3.2:1b",  1.3, "Faster, slightly less accurate"),
    ],
    "cpu_base": [
        ("llama3.2:1b",  1.3, "Recommended for low-RAM machines"),
    ],
}


# =========================================
# OLLAMA INSTALL
# =========================================

def ollama_installed() -> bool:
    return shutil.which("ollama") is not None

def start_ollama_server():
    """Ensure Ollama's background server is running before pulling."""
    try:
        import urllib.request
        urllib.request.urlopen("http://localhost:11434", timeout=2)
        return  # already running
    except Exception:
        pass
    # Not running — start it in the background
    if SYSTEM == "Darwin":
        subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif SYSTEM == "Windows":
        subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=subprocess.CREATE_NO_WINDOW)  # type: ignore
    elif SYSTEM == "Linux":
        subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)  # give it a moment to bind

def model_pulled(model: str) -> bool:
    try:
        out = subprocess.check_output(["ollama", "list"], text=True, stderr=subprocess.DEVNULL)
        base = model.split(":")[0]
        return any(base in line for line in out.splitlines())
    except Exception:
        return False

def pull_model(model: str):
    start_ollama_server()
    print(f"  Downloading {model}…  (this may take several minutes on first run)")
    result = subprocess.run(["ollama", "pull", model])
    if result.returncode != 0:
        print(f"  Download failed. Try manually:  ollama pull {model}")

def install_ollama() -> bool:
    """Attempt to install Ollama. Returns True if successful."""
    if SYSTEM == "Darwin":
        return _install_ollama_mac()
    elif SYSTEM == "Windows":
        return _install_ollama_windows()
    elif SYSTEM == "Linux":
        return _install_ollama_linux()
    return False

def _install_ollama_mac() -> bool:
    if shutil.which("brew"):
        print("  Installing Ollama via Homebrew…")
        r = subprocess.run(["brew", "install", "ollama"], capture_output=False)
        if r.returncode == 0:
            _ok("Ollama installed via Homebrew")
            return True
    # Fallback: download the macOS app zip
    print("  Downloading Ollama for macOS…")
    url = "https://ollama.com/download/Ollama-darwin.zip"
    dest = Path.home() / "Downloads" / "Ollama-darwin.zip"
    try:
        _download_with_progress(url, dest)
        install_dir = Path("/Applications")
        subprocess.run(["unzip", "-o", str(dest), "-d", str(install_dir)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ollama_bin = install_dir / "Ollama.app" / "Contents" / "MacOS" / "ollama"
        if ollama_bin.exists():
            # Symlink to /usr/local/bin so it's on PATH
            link = Path("/usr/local/bin/ollama")
            link.unlink(missing_ok=True)
            link.symlink_to(ollama_bin)
            _ok("Ollama installed")
            return True
    except Exception as e:
        print(f"  Automatic install failed ({e}).")
    print("  Manual install: https://ollama.com/download")
    return False

def _install_ollama_windows() -> bool:
    print("  Downloading Ollama installer for Windows…")
    url = "https://ollama.com/download/OllamaSetup.exe"
    dest = Path(tempfile.gettempdir()) / "OllamaSetup.exe"
    try:
        _download_with_progress(url, dest)
        print("  Running installer (follow any prompts)…")
        subprocess.run([str(dest), "/S"], check=True)  # /S = silent install
        # Add to PATH for this session
        ollama_path = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Ollama"
        if ollama_path.exists():
            os.environ["PATH"] = str(ollama_path) + os.pathsep + os.environ.get("PATH", "")
        if ollama_installed():
            _ok("Ollama installed")
            return True
    except Exception as e:
        print(f"  Automatic install failed ({e}).")
    print("  Manual install: https://ollama.com/download/OllamaSetup.exe")
    return False

def _install_ollama_linux() -> bool:
    if not shutil.which("curl"):
        print("  curl not found. Install Ollama manually:")
        print("    curl -fsSL https://ollama.com/install.sh | sh")
        return False
    print("  Installing Ollama via official install script…")
    try:
        result = subprocess.run(
            "curl -fsSL https://ollama.com/install.sh | sh",
            shell=True, check=True,
        )
        if ollama_installed():
            _ok("Ollama installed")
            return True
    except subprocess.CalledProcessError as e:
        print(f"  Install script failed ({e}).")
    print("  Manual install: https://ollama.com/install.sh")
    return False

def _download_with_progress(url: str, dest: Path):
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url) as resp:
        total = int(resp.headers.get("Content-Length", 0))
        downloaded = 0
        chunk = 1024 * 64
        with open(dest, "wb") as f:
            while True:
                data = resp.read(chunk)
                if not data:
                    break
                f.write(data)
                downloaded += len(data)
                if total:
                    pct = downloaded * 100 // total
                    print(f"\r  {pct}% ({downloaded // (1024*1024)} MB / {total // (1024*1024)} MB)", end="", flush=True)
    print()


# =========================================
# OLLAMA SETUP ORCHESTRATOR
# =========================================

def setup_ollama(skip: bool):
    _section("Ollama — local AI (optional)")

    ram_gb = get_ram_gb()
    tier = hardware_tier(ram_gb)
    models = TIER_MODELS.get(tier, TIER_MODELS["cpu_base"])

    print(f"  Device: {hardware_label(ram_gb)}")
    print("  Recommended models for your hardware:")
    for model_id, size_gb, desc in models:
        print(f"    • {model_id:<22} {size_gb:.1f} GB  — {desc}")

    if skip:
        print("  (Skipping — pass --no-ollama to hide this)")
        return

    # Step 1: install Ollama if missing
    if not ollama_installed():
        print("\n  Ollama not installed.")
        ans = _prompt("  Install it now? [Y/n] ", default=True)
        if ans:
            if not install_ollama():
                print("  Re-run launch.py after installing Ollama to download a model.")
                return
        else:
            print("  Skipped. You can install Ollama later from https://ollama.com")
            return

    # Step 2: offer to pull the recommended model
    recommended = models[0][0]
    size = models[0][1]

    if model_pulled(recommended):
        _ok(f"{recommended} already downloaded")
        return

    print(f"\n  Recommended model: {recommended} ({size:.1f} GB)")
    ans = _prompt(f"  Download {recommended} now? [Y/n] ", default=True)
    if ans:
        pull_model(recommended)
        if model_pulled(recommended):
            _ok(f"{recommended} ready")
    else:
        print(f"  Skipped. Download later:  ollama pull {recommended}")


# =========================================
# UTILS
# =========================================

def _section(title: str):
    print(f"\n── {title} {'─' * max(0, 50 - len(title))}")

def _ok(msg: str):
    print(f"  ✓ {msg}")

def _die(msg: str):
    print(f"\n  ERROR: {msg}\n")
    sys.exit(1)

def _prompt(msg: str, default: bool = False) -> bool:
    try:
        ans = input(msg).strip().lower()
        return ans in ("y", "yes") if ans else default
    except (EOFError, KeyboardInterrupt):
        return default


# =========================================
# MAIN
# =========================================

def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--no-ollama", action="store_true", help="Skip Ollama setup")
    args, _ = parser.parse_known_args()

    print("=" * 52)
    print("  Decksmith — Setup & Launch")
    print("=" * 52)

    _section("Python")
    check_python()

    _section("Python packages")
    install_packages()

    setup_ollama(skip=args.no_ollama)

    app = Path(__file__).parent / "app.py"
    print("\n" + "=" * 52)
    print("  Starting Decksmith…  (Ctrl+C to stop)")
    print("=" * 52 + "\n")
    subprocess.run([sys.executable, "-m", "streamlit", "run", str(app)])


if __name__ == "__main__":
    main()
