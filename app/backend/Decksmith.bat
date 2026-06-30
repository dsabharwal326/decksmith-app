@echo off
title Decksmith
color 0F
cls

echo ==================================================
echo   Decksmith
echo ==================================================
echo.

:: ── Check for Python ────────────────────────────────────────────────────────
where python >nul 2>&1
if %errorlevel% neq 0 (
    where python3 >nul 2>&1
    if %errorlevel% neq 0 (
        echo   Python not found.
        echo.
        echo   Please download and install Python 3.9+ from:
        echo   https://www.python.org/downloads/windows/
        echo.
        echo   IMPORTANT: Check "Add Python to PATH" during install.
        echo.
        start https://www.python.org/downloads/windows/
        pause
        exit /b 1
    )
    set PYTHON=python3
) else (
    set PYTHON=python
)

:: ── Check Python version ─────────────────────────────────────────────────────
for /f "tokens=*" %%i in ('%PYTHON% -c "import sys; ok=sys.version_info>=(3,9); print(ok)"') do set PY_OK=%%i
if "%PY_OK%" neq "True" (
    echo   Python 3.9 or later is required.
    echo   Download: https://www.python.org/downloads/windows/
    echo.
    start https://www.python.org/downloads/windows/
    pause
    exit /b 1
)

:: ── Change to the folder containing this file ─────────────────────────────────
cd /d "%~dp0"

:: ── Run the Python launcher ───────────────────────────────────────────────────
%PYTHON% launch.py

if %errorlevel% neq 0 (
    echo.
    echo   Something went wrong. See error above.
    pause
)
