from __future__ import annotations

import tkinter as tk
from tkinter import filedialog, messagebox
from pathlib import Path
from typing import Dict

from core.engine import build_deck
from core.classifier import classify_notes
from core.policy_resolver import resolve_policy
from core.augmentation import augment_notes, ExpansionPayload
from core.config import ConfigManager


# =========================================
# GLOBALS
# =========================================

CONFIG_PATH = Path("config.json")
config_manager = ConfigManager(CONFIG_PATH)


# =========================================
# GUI APPLICATION
# =========================================

class DecksmithApp:

    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Decksmith")

        self.input_path: Path | None = None
        self.output_path: Path | None = None

        self._build_ui()

    # -------------------------------------
    # UI
    # -------------------------------------

    def _build_ui(self):

        frame = tk.Frame(self.root, padx=20, pady=20)
        frame.pack(fill="both", expand=True)

        tk.Button(
            frame,
            text="Select Input File",
            command=self.select_input
        ).pack(fill="x", pady=5)

        tk.Button(
            frame,
            text="Select Output .apkg",
            command=self.select_output
        ).pack(fill="x", pady=5)

        tk.Button(
            frame,
            text="Build Deck",
            command=self.build
        ).pack(fill="x", pady=10)

    # -------------------------------------
    # FILE SELECTION
    # -------------------------------------

    def select_input(self):
        file_path = filedialog.askopenfilename(
            title="Select Input Text File",
            filetypes=[("Text Files", "*.txt")]
        )
        if file_path:
            self.input_path = Path(file_path)

    def select_output(self):
        file_path = filedialog.asksaveasfilename(
            title="Save Deck As",
            defaultextension=".apkg",
            filetypes=[("Anki Package", "*.apkg")]
        )
        if file_path:
            self.output_path = Path(file_path)

    # -------------------------------------
    # BUILD PIPELINE
    # -------------------------------------

    def build(self):

        if not self.input_path:
            messagebox.showerror("Error", "Input file not selected.")
            return

        if not self.output_path:
            messagebox.showerror("Error", "Output file not selected.")
            return

        try:
            # ----------------------------------------
            # PARSE INPUT
            # ----------------------------------------

            raw_text = self.input_path.read_text(encoding="utf-8")
            lines = raw_text.splitlines()

            from core.engine import parse_lines_to_notes
            notes = parse_lines_to_notes(lines)

            # ----------------------------------------
            # CLASSIFICATION (Deterministic)
            # ----------------------------------------

            notes = classify_notes(notes)

            # ----------------------------------------
            # POLICY RESOLUTION
            # ----------------------------------------

            user_default_policy = config_manager.get_user_default_policy()
            user_profiles = config_manager.get_profiles()

            resolved_policy = resolve_policy(
                system_profile_name="standard_v1",
                user_default_policy=user_default_policy,
                user_profiles=user_profiles,
                selected_profile_name=None,
                per_build_override=None,
            )

            # ----------------------------------------
            # AUGMENTATION (Optional)
            # ----------------------------------------

            payload_map: Dict[str, ExpansionPayload] = {}

            # NOTE:
            # This is currently empty.
            # Future AI provider layer will populate payload_map
            # keyed by SHA identity.

            if payload_map:
                notes, _ = augment_notes(
                    notes=notes,
                    payload_map=payload_map,
                    policy=resolved_policy,
                    prompt_hash=None,
                    dictionary_sha=None,
                )

            # ----------------------------------------
            # BUILD DECK
            # ----------------------------------------

            build_deck(
                notes=notes,
                output_path=self.output_path
            )

            messagebox.showinfo("Success", "Deck built successfully.")

        except Exception as e:
            messagebox.showerror("Build Failed", str(e))


# =========================================
# ENTRY POINT
# =========================================

def main():
    root = tk.Tk()
    app = DecksmithApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()