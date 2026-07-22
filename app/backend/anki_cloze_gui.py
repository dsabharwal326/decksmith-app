from __future__ import annotations

import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from pathlib import Path
from typing import Dict, List, Optional

from tkinterdnd2 import TkinterDnD, DND_FILES

import genanki
from core.engine import Note, parse_text_to_notes, build_deck
from core.classifier import classify_notes
from core.config import ConfigManager
from core.taxonomy import DEFAULT_TAXONOMY
from core.validator import NoteValidationResult, validate_notes, summary
from core.provider import build_provider, detect_available_provider, ProviderError, ProviderAuthError, AnthropicProvider, OpenAIProvider
from core.intake import run_intake, IntakeResult
from core.augment_ai import generate_augmentation_proposals, build_payload_map, AugmentationProposal
from core.augmentation import augment_notes, ExpansionPayload
from core.augmentation_policy import AugmentationPolicy, ExpansionMode


# =========================================
# GLOBALS
# =========================================

CONFIG_PATH = Path("config.json")
config_manager = ConfigManager(CONFIG_PATH)

COLOR_BG       = "#1e1e1e"
COLOR_FG       = "#d4d4d4"
COLOR_VALID    = "#4ec9b0"
COLOR_FIXABLE  = "#dcdcaa"
COLOR_INVALID  = "#f44747"
COLOR_DIM      = "#888888"
COLOR_BLUE     = "#2563eb"


# =========================================
# GUI APPLICATION
# =========================================

class DecksmithApp:

    def __init__(self, root: TkinterDnD.Tk):
        self.root = root
        self.root.title("Decksmith")
        self.root.resizable(True, True)

        self.input_paths: List[Path] = []
        self.output_path: Optional[Path] = None

        # Validation state
        self._validation_results: List[NoteValidationResult] = []
        # Maps result index → user decision: "accept" | "reject" | "pending"
        self._decisions: Dict[int, str] = {}
        self._validated = False

        # Intake AI state: index → IntakeResult (for invalid cards)
        self._intake_results: Dict[int, IntakeResult] = {}

        # Augmentation AI state
        self._aug_proposals: List[AugmentationProposal] = []
        self._aug_accepted: set = set()   # indices of accepted proposals

        self._build_ui()

    # -------------------------------------
    # UI CONSTRUCTION
    # -------------------------------------

    def _build_ui(self):
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)

        main = tk.Frame(self.root, padx=16, pady=12)
        main.grid(row=0, column=0, sticky="nsew")
        main.columnconfigure(0, weight=1)
        main.rowconfigure(8, weight=1)

        # Title
        tk.Label(main, text="Decksmith", font=("Helvetica", 20, "bold")).grid(
            row=0, column=0, pady=(0, 2), sticky="w"
        )
        tk.Label(main, text="Deterministic Anki deck builder", font=("Helvetica", 11), fg="#666").grid(
            row=1, column=0, pady=(0, 12), sticky="w"
        )

        # Input files
        self._build_input_panel(main, row=2)

        # Deck settings
        self._build_settings_panel(main, row=3)

        # AI settings
        self._build_ai_panel(main, row=4)

        # Action buttons
        self._build_action_buttons(main, row=5)

        # Validation panel (hidden until validate runs)
        self._build_validation_panel(main, row=6)

        # Augmentation preview panel (hidden until augment runs)
        self._build_augment_panel(main, row=7)

        # Report panel
        self._build_report_panel(main, row=8)

    def _build_input_panel(self, parent, row):
        frame = tk.LabelFrame(parent, text="Input Files", font=("Helvetica", 11, "bold"), padx=8, pady=8)
        frame.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        frame.columnconfigure(0, weight=1)

        self.drop_label = tk.Label(
            frame,
            text="Drag & drop .txt files here  —  or click Add Files",
            font=("Helvetica", 10),
            fg="#888",
            height=2,
            relief="groove",
            bg="#f5f5f5",
        )
        self.drop_label.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        self.drop_label.drop_target_register(DND_FILES)
        self.drop_label.dnd_bind("<<Drop>>", self._on_drop)

        self.file_listbox = tk.Listbox(frame, height=3, font=("Helvetica", 10), selectmode=tk.EXTENDED)
        self.file_listbox.grid(row=1, column=0, sticky="ew", pady=(0, 6))

        btn_row = tk.Frame(frame)
        btn_row.grid(row=2, column=0, sticky="w")
        tk.Button(btn_row, text="Add Files", command=self._add_files).pack(side="left", padx=(0, 6))
        tk.Button(btn_row, text="Remove Selected", command=self._remove_selected).pack(side="left")

    def _build_settings_panel(self, parent, row):
        frame = tk.LabelFrame(parent, text="Deck Settings", font=("Helvetica", 11, "bold"), padx=8, pady=8)
        frame.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        frame.columnconfigure(1, weight=1)

        tk.Label(frame, text="Deck Name:", font=("Helvetica", 11)).grid(
            row=0, column=0, sticky="w", padx=(0, 8), pady=3
        )
        self.deck_name_var = tk.StringVar(value="My Deck")
        tk.Entry(frame, textvariable=self.deck_name_var, font=("Helvetica", 11)).grid(
            row=0, column=1, sticky="ew", pady=3
        )

        tk.Label(frame, text="Output File:", font=("Helvetica", 11)).grid(
            row=1, column=0, sticky="w", padx=(0, 8), pady=3
        )
        output_row = tk.Frame(frame)
        output_row.grid(row=1, column=1, sticky="ew", pady=3)
        output_row.columnconfigure(0, weight=1)
        self.output_label = tk.Label(output_row, text="Not selected", font=("Helvetica", 10), fg="#888", anchor="w")
        self.output_label.grid(row=0, column=0, sticky="ew")
        tk.Button(output_row, text="Choose…", command=self._select_output).grid(row=0, column=1, padx=(8, 0))

        self.classify_var = tk.BooleanVar(value=True)
        tk.Checkbutton(
            frame,
            text="Classify by specialty and route into subdecks",
            variable=self.classify_var,
            font=("Helvetica", 10),
        ).grid(row=2, column=0, columnspan=2, sticky="w", pady=(4, 0))

    def _build_ai_panel(self, parent, row):
        frame = tk.LabelFrame(parent, text="AI Settings (optional)", font=("Helvetica", 11, "bold"), padx=8, pady=8)
        frame.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        frame.columnconfigure(1, weight=1)

        tk.Label(frame, text="Provider:", font=("Helvetica", 11)).grid(
            row=0, column=0, sticky="w", padx=(0, 8), pady=2
        )
        self.provider_var = tk.StringVar(value="anthropic")
        provider_menu = tk.OptionMenu(frame, self.provider_var, "anthropic", "openai")
        provider_menu.config(font=("Helvetica", 10))
        provider_menu.grid(row=0, column=1, sticky="w", pady=2)

        tk.Label(frame, text="API Key:", font=("Helvetica", 11)).grid(
            row=1, column=0, sticky="w", padx=(0, 8), pady=2
        )
        self.api_key_var = tk.StringVar()
        api_key_entry = tk.Entry(frame, textvariable=self.api_key_var, font=("Helvetica", 11), show="•", width=40)
        api_key_entry.grid(row=1, column=1, sticky="ew", pady=2)

        # Detect if a key is already in the environment
        detected = detect_available_provider()
        if detected:
            self.provider_var.set(detected)
            hint = tk.Label(frame, text=f"✓ {detected} key detected in environment", font=("Helvetica", 9), fg="#16a34a")
        else:
            hint = tk.Label(frame, text="No API key detected. Paste one above or set ANTHROPIC_API_KEY / OPENAI_API_KEY.", font=("Helvetica", 9), fg="#888")
        hint.grid(row=2, column=0, columnspan=2, sticky="w", pady=(2, 0))

    def _build_action_buttons(self, parent, row):
        btn_frame = tk.Frame(parent)
        btn_frame.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        for col in range(4):
            btn_frame.columnconfigure(col, weight=1)

        self.validate_btn = tk.Button(
            btn_frame,
            text="Validate Cards",
            font=("Helvetica", 11, "bold"),
            bg="#16a34a", fg="white",
            activebackground="#15803d", activeforeground="white",
            padx=8, pady=7,
            command=self._run_validate,
        )
        self.validate_btn.grid(row=0, column=0, sticky="ew", padx=(0, 3))

        self.ai_fix_btn = tk.Button(
            btn_frame,
            text="AI Fix Invalid",
            font=("Helvetica", 11, "bold"),
            bg="#7c3aed", fg="white",
            activebackground="#6d28d9", activeforeground="white",
            padx=8, pady=7,
            state="disabled",
            command=self._run_intake_ai,
        )
        self.ai_fix_btn.grid(row=0, column=1, sticky="ew", padx=(3, 3))

        self.augment_btn = tk.Button(
            btn_frame,
            text="AI Augment Cards",
            font=("Helvetica", 11, "bold"),
            bg="#b45309", fg="white",
            activebackground="#92400e", activeforeground="white",
            padx=8, pady=7,
            state="disabled",
            command=self._run_augment_ai,
        )
        self.augment_btn.grid(row=0, column=2, sticky="ew", padx=(3, 3))

        self.build_btn = tk.Button(
            btn_frame,
            text="Build Deck",
            font=("Helvetica", 11, "bold"),
            bg=COLOR_BLUE, fg="white",
            activebackground="#1d4ed8", activeforeground="white",
            padx=8, pady=7,
            state="disabled",
            command=self._build,
        )
        self.build_btn.grid(row=0, column=3, sticky="ew", padx=(3, 0))

    def _build_validation_panel(self, parent, row):
        self.val_frame = tk.LabelFrame(
            parent, text="Validation", font=("Helvetica", 11, "bold"), padx=8, pady=8
        )
        self.val_frame.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        self.val_frame.columnconfigure(0, weight=1)
        self.val_frame.grid_remove()  # hidden until validation runs

        # Summary bar
        self.val_summary_label = tk.Label(self.val_frame, text="", font=("Helvetica", 10), anchor="w")
        self.val_summary_label.grid(row=0, column=0, sticky="ew", pady=(0, 6))

        # Scrollable issue list
        list_container = tk.Frame(self.val_frame)
        list_container.grid(row=1, column=0, sticky="ew")
        list_container.columnconfigure(0, weight=1)

        self.val_canvas = tk.Canvas(list_container, height=160, highlightthickness=0)
        self.val_canvas.grid(row=0, column=0, sticky="ew")
        val_scroll = tk.Scrollbar(list_container, orient="vertical", command=self.val_canvas.yview)
        val_scroll.grid(row=0, column=1, sticky="ns")
        self.val_canvas.configure(yscrollcommand=val_scroll.set)

        self.val_inner = tk.Frame(self.val_canvas)
        self.val_canvas_window = self.val_canvas.create_window((0, 0), window=self.val_inner, anchor="nw")
        self.val_inner.bind("<Configure>", self._on_val_inner_configure)
        self.val_canvas.bind("<Configure>", self._on_val_canvas_configure)

        # Accept all / reject all
        action_row = tk.Frame(self.val_frame)
        action_row.grid(row=2, column=0, sticky="w", pady=(6, 0))
        tk.Button(action_row, text="Accept All Fixes", command=self._accept_all_fixes, font=("Helvetica", 10)).pack(side="left", padx=(0, 6))
        tk.Button(action_row, text="Reject All Fixes", command=self._reject_all_fixes, font=("Helvetica", 10)).pack(side="left")

    def _build_augment_panel(self, parent, row):
        self.aug_frame = tk.LabelFrame(
            parent, text="AI Augmentation Preview", font=("Helvetica", 11, "bold"), padx=8, pady=8
        )
        self.aug_frame.grid(row=row, column=0, sticky="ew", pady=(0, 8))
        self.aug_frame.columnconfigure(0, weight=1)
        self.aug_frame.grid_remove()

        self.aug_summary_label = tk.Label(self.aug_frame, text="", font=("Helvetica", 10), anchor="w")
        self.aug_summary_label.grid(row=0, column=0, sticky="ew", pady=(0, 6))

        list_container = tk.Frame(self.aug_frame)
        list_container.grid(row=1, column=0, sticky="ew")
        list_container.columnconfigure(0, weight=1)

        self.aug_canvas = tk.Canvas(list_container, height=180, highlightthickness=0)
        self.aug_canvas.grid(row=0, column=0, sticky="ew")
        aug_scroll = tk.Scrollbar(list_container, orient="vertical", command=self.aug_canvas.yview)
        aug_scroll.grid(row=0, column=1, sticky="ns")
        self.aug_canvas.configure(yscrollcommand=aug_scroll.set)

        self.aug_inner = tk.Frame(self.aug_canvas)
        self.aug_canvas_window = self.aug_canvas.create_window((0, 0), window=self.aug_inner, anchor="nw")
        self.aug_inner.bind("<Configure>", lambda e: self.aug_canvas.configure(scrollregion=self.aug_canvas.bbox("all")))
        self.aug_canvas.bind("<Configure>", lambda e: self.aug_canvas.itemconfig(self.aug_canvas_window, width=e.width))

        action_row = tk.Frame(self.aug_frame)
        action_row.grid(row=2, column=0, sticky="w", pady=(6, 0))
        tk.Button(action_row, text="Accept All", command=self._aug_accept_all, font=("Helvetica", 10)).pack(side="left", padx=(0, 6))
        tk.Button(action_row, text="Reject All", command=self._aug_reject_all, font=("Helvetica", 10)).pack(side="left")

    def _build_report_panel(self, parent, row):
        report_frame = tk.LabelFrame(parent, text="Build Report", font=("Helvetica", 11, "bold"), padx=8, pady=8)
        report_frame.grid(row=row, column=0, sticky="nsew")
        report_frame.columnconfigure(0, weight=1)
        report_frame.rowconfigure(0, weight=1)
        parent.rowconfigure(row, weight=1)

        self.report_text = tk.Text(
            report_frame,
            height=8,
            font=("Menlo", 10),
            state="disabled",
            wrap="word",
            bg=COLOR_BG,
            fg=COLOR_FG,
            relief="flat",
        )
        self.report_text.grid(row=0, column=0, sticky="nsew")
        scrollbar = tk.Scrollbar(report_frame, command=self.report_text.yview)
        scrollbar.grid(row=0, column=1, sticky="ns")
        self.report_text.config(yscrollcommand=scrollbar.set)
        self.report_text.tag_config("valid",   foreground=COLOR_VALID)
        self.report_text.tag_config("fixable", foreground=COLOR_FIXABLE)
        self.report_text.tag_config("invalid", foreground=COLOR_INVALID)
        self.report_text.tag_config("dim",     foreground=COLOR_DIM)

        self._log("Ready. Add files and click Validate Cards.", "dim")

    # -------------------------------------
    # CANVAS RESIZE HELPERS
    # -------------------------------------

    def _on_val_inner_configure(self, event):
        self.val_canvas.configure(scrollregion=self.val_canvas.bbox("all"))

    def _on_val_canvas_configure(self, event):
        self.val_canvas.itemconfig(self.val_canvas_window, width=event.width)

    # -------------------------------------
    # FILE MANAGEMENT
    # -------------------------------------

    def _on_drop(self, event):
        for p in self.root.tk.splitlist(event.data):
            path = Path(p)
            if path.suffix.lower() in (".txt", ".apkg") and path not in self.input_paths:
                self.input_paths.append(path)
                self.file_listbox.insert(tk.END, path.name)
            elif path.suffix.lower() not in (".txt", ".apkg"):
                self._log(f"Skipped {path.name} — only .txt supported for now.", "dim")
        self._reset_validation()

    def _add_files(self):
        files = filedialog.askopenfilenames(
            title="Select Input Files",
            filetypes=[("Text Files", "*.txt"), ("Anki Packages", "*.apkg")],
        )
        for f in files:
            path = Path(f)
            if path not in self.input_paths:
                self.input_paths.append(path)
                self.file_listbox.insert(tk.END, path.name)
        self._reset_validation()

    def _remove_selected(self):
        for i in reversed(list(self.file_listbox.curselection())):
            self.file_listbox.delete(i)
            self.input_paths.pop(i)
        self._reset_validation()

    def _select_output(self):
        deck_name = self.deck_name_var.get().strip() or "deck"
        path = filedialog.asksaveasfilename(
            title="Save Deck As",
            initialfile=f"{deck_name.replace(' ', '_')}.apkg",
            defaultextension=".apkg",
            filetypes=[("Anki Package", "*.apkg")],
        )
        if path:
            self.output_path = Path(path)
            self.output_label.config(text=self.output_path.name, fg="#333")

    # -------------------------------------
    # VALIDATION
    # -------------------------------------

    def _reset_validation(self):
        self._validation_results = []
        self._decisions = {}
        self._validated = False
        self._intake_results = {}
        self._aug_proposals = []
        self._aug_accepted = set()
        self.build_btn.config(state="disabled")
        self.ai_fix_btn.config(state="disabled")
        self.augment_btn.config(state="disabled")
        self.val_frame.grid_remove()
        self.aug_frame.grid_remove()

    def _run_validate(self):
        if not self.input_paths:
            messagebox.showerror("Error", "No input files selected.")
            return

        self._clear_report()
        self._log("Parsing files…", "dim")

        all_notes: List[Note] = []
        try:
            for path in self.input_paths:
                raw = path.read_text(encoding="utf-8")
                notes = parse_text_to_notes(raw, strict_repair=False)
                self._log(f"  {path.name}: {len(notes)} cards parsed", "dim")
                all_notes.extend(notes)
        except Exception as e:
            self._log(f"✗ Read error: {e}", "invalid")
            return

        self._log(f"\nValidating {len(all_notes)} cards…", "dim")
        results = validate_notes(all_notes)
        s = summary(results)

        self._validation_results = results
        self._decisions = {}

        # Pre-accept valid cards silently
        for i, r in enumerate(results):
            if r.status == "valid":
                self._decisions[i] = "accept"

        self._render_validation_panel(s)
        self._log(
            f"\nValidation complete — "
            f"{s['valid']} valid  |  {s['fixable']} fixable  |  {s['invalid']} invalid",
            "dim"
        )

        if s["fixable"] == 0 and s["invalid"] == 0:
            self._log("All cards are valid. Ready to build.", "valid")
            self._validated = True
            self.build_btn.config(state="normal")
            self.augment_btn.config(state="normal")
        elif s["invalid"] > 0:
            self.ai_fix_btn.config(state="normal")
            self._log(f"\n{s['invalid']} invalid card(s) — click 'AI Fix Invalid' to let the AI propose corrections.", "invalid")

    def _render_validation_panel(self, s: dict):
        # Clear previous
        for widget in self.val_inner.winfo_children():
            widget.destroy()

        issues = [(i, r) for i, r in enumerate(self._validation_results) if r.status != "valid"]

        if not issues:
            self.val_frame.grid_remove()
            return

        self.val_frame.grid()
        self.val_summary_label.config(
            text=f"  ✓ {s['valid']} valid   ⚠ {s['fixable']} fixable   ✗ {s['invalid']} invalid"
        )

        for i, result in issues:
            self._render_issue_row(i, result)

        self.val_inner.update_idletasks()
        self.val_canvas.configure(scrollregion=self.val_canvas.bbox("all"))

    def _render_issue_row(self, index: int, result: NoteValidationResult):
        color = COLOR_FIXABLE if result.status == "fixable" else COLOR_INVALID
        symbol = "⚠" if result.status == "fixable" else "✗"

        row = tk.Frame(self.val_inner, bd=1, relief="groove", padx=6, pady=4)
        row.pack(fill="x", pady=2)
        row.columnconfigure(0, weight=1)

        # Header: symbol + preview
        header = tk.Frame(row)
        header.grid(row=0, column=0, columnspan=2, sticky="ew")
        header.columnconfigure(1, weight=1)
        tk.Label(header, text=symbol, fg=color, font=("Helvetica", 12, "bold"), width=2).pack(side="left")
        tk.Label(
            header,
            text=result.preview,
            font=("Menlo", 9),
            fg="#333",
            anchor="w",
            wraplength=400,
            justify="left",
        ).pack(side="left", fill="x", expand=True)

        # Error message
        tk.Label(
            row,
            text=result.error or "",
            font=("Helvetica", 9),
            fg="#555",
            anchor="w",
            wraplength=420,
            justify="left",
        ).grid(row=1, column=0, columnspan=2, sticky="ew", pady=(2, 0))

        if result.status == "fixable" and result.fix_description:
            # Fix description
            tk.Label(
                row,
                text=f"Fix: {result.fix_description}",
                font=("Helvetica", 9, "italic"),
                fg=COLOR_FIXABLE,
                anchor="w",
            ).grid(row=2, column=0, sticky="ew", pady=(2, 0))

            # Accept / Reject buttons
            decision_var = tk.StringVar(value=self._decisions.get(index, "pending"))

            def _set_decision(idx=index, var=decision_var, r=row):
                self._decisions[idx] = var.get()
                self._update_build_readiness()

            btn_row = tk.Frame(row)
            btn_row.grid(row=3, column=0, sticky="w", pady=(4, 0))

            accept_btn = tk.Radiobutton(
                btn_row, text="Accept fix", variable=decision_var,
                value="accept", command=_set_decision,
                font=("Helvetica", 9), fg="#16a34a",
            )
            accept_btn.pack(side="left", padx=(0, 8))

            reject_btn = tk.Radiobutton(
                btn_row, text="Reject (skip card)", variable=decision_var,
                value="reject", command=_set_decision,
                font=("Helvetica", 9), fg="#dc2626",
            )
            reject_btn.pack(side="left")

            # Store var reference so it persists
            row._decision_var = decision_var

        elif result.status == "invalid":
            # Check if AI has a proposed fix for this card
            intake = self._intake_results.get(index)
            if intake and intake.ai_succeeded and intake.proposed_note:
                tk.Label(
                    row,
                    text=f"AI fix: {intake.ai_explanation}",
                    font=("Helvetica", 9, "italic"),
                    fg="#a78bfa",
                    anchor="w",
                    wraplength=420,
                ).grid(row=2, column=0, sticky="ew", pady=(2, 0))

                decision_var = tk.StringVar(value=self._decisions.get(index, "pending"))

                def _set_ai_decision(idx=index, var=decision_var):
                    self._decisions[idx] = var.get()
                    self._update_build_readiness()

                btn_row = tk.Frame(row)
                btn_row.grid(row=3, column=0, sticky="w", pady=(4, 0))
                tk.Radiobutton(
                    btn_row, text="Accept AI fix", variable=decision_var,
                    value="accept", command=_set_ai_decision,
                    font=("Helvetica", 9), fg="#7c3aed",
                ).pack(side="left", padx=(0, 8))
                tk.Radiobutton(
                    btn_row, text="Skip card", variable=decision_var,
                    value="reject", command=_set_ai_decision,
                    font=("Helvetica", 9), fg="#dc2626",
                ).pack(side="left")
                row._decision_var = decision_var
            elif intake and not intake.ai_succeeded:
                tk.Label(
                    row,
                    text=f"AI could not fix: {intake.ai_explanation}  — card will be skipped.",
                    font=("Helvetica", 9, "italic"),
                    fg=COLOR_DIM,
                    anchor="w",
                    wraplength=420,
                ).grid(row=2, column=0, sticky="ew", pady=(2, 0))
            else:
                tk.Label(
                    row,
                    text="Cannot be auto-fixed. Click 'AI Fix Invalid' to try AI repair, or edit the source file.",
                    font=("Helvetica", 9, "italic"),
                    fg=COLOR_INVALID,
                    anchor="w",
                    wraplength=420,
                ).grid(row=2, column=0, sticky="ew", pady=(2, 0))

    def _run_intake_ai(self):
        invalid_indexed = [(i, r) for i, r in enumerate(self._validation_results) if r.status == "invalid"]
        if not invalid_indexed:
            return

        provider_name = self.provider_var.get()
        api_key = self.api_key_var.get().strip() or None

        self._log(f"\nRunning AI intake on {len(invalid_indexed)} invalid card(s) via {provider_name}…", "dim")
        self.root.update_idletasks()

        try:
            provider = build_provider(provider_name, api_key=api_key)
        except ProviderAuthError as e:
            self._log(f"✗ {e}", "invalid")
            messagebox.showerror("API Key Missing", str(e))
            return
        except Exception as e:
            self._log(f"✗ {e}", "invalid")
            return

        from core.provider import AnthropicProvider, OpenAIProvider
        if isinstance(provider, AnthropicProvider):
            model = AnthropicProvider.INTAKE_MODEL
        elif isinstance(provider, OpenAIProvider):
            model = OpenAIProvider.INTAKE_MODEL
        else:
            model = "stub"

        invalid_results = [r for _, r in invalid_indexed]
        intake_list = run_intake(invalid_results, provider, model)

        # Map back by original index
        for (orig_idx, _), intake in zip(invalid_indexed, intake_list):
            self._intake_results[orig_idx] = intake
            if intake.ai_succeeded:
                self._decisions[orig_idx] = "pending"  # user must decide
                self._log(f"  ✓ AI proposed fix: {intake.ai_explanation[:60]}", "fixable")
            else:
                self._decisions[orig_idx] = "reject"   # auto-skip if AI failed
                self._log(f"  ✗ AI failed: {intake.ai_explanation[:60]}", "dim")

        self._re_render_validation()
        self._update_build_readiness()
        self.ai_fix_btn.config(state="disabled")

    def _run_augment_ai(self):
        notes = self._resolved_notes()
        if not notes:
            messagebox.showerror("Error", "No valid cards to augment.")
            return

        provider_name = self.provider_var.get()
        api_key = self.api_key_var.get().strip() or None

        self._log(f"\nRunning AI augmentation on {len(notes)} card(s) via {provider_name}…", "dim")
        self.root.update_idletasks()

        try:
            provider = build_provider(provider_name, api_key=api_key)
        except ProviderAuthError as e:
            self._log(f"✗ {e}", "invalid")
            messagebox.showerror("API Key Missing", str(e))
            return
        except Exception as e:
            self._log(f"✗ {e}", "invalid")
            return

        if isinstance(provider, AnthropicProvider):
            model = AnthropicProvider.AUGMENT_MODEL
        elif isinstance(provider, OpenAIProvider):
            model = OpenAIProvider.AUGMENT_MODEL
        else:
            model = "stub"

        def _progress(done, total):
            self._log(f"  Augmenting {done}/{total}…", "dim")
            self.root.update_idletasks()

        proposals = generate_augmentation_proposals(notes, provider, model, progress_callback=_progress)
        self._aug_proposals = proposals
        self._aug_accepted = set()  # user must decide

        succeeded = sum(1 for p in proposals if p.succeeded)
        failed = len(proposals) - succeeded
        self._log(f"\nAugmentation complete — {succeeded} proposals ready, {failed} failed.", "dim")

        self._render_augment_panel(proposals)
        self.augment_btn.config(state="disabled")

    def _render_augment_panel(self, proposals: List[AugmentationProposal]):
        for widget in self.aug_inner.winfo_children():
            widget.destroy()

        succeeded = [p for p in proposals if p.succeeded]
        if not succeeded:
            self.aug_frame.grid_remove()
            return

        self.aug_frame.grid()
        self.aug_summary_label.config(
            text=f"  {len(succeeded)} AI proposals ready — review and accept the ones you want added to each card"
        )

        for i, proposal in enumerate(proposals):
            self._render_aug_row(i, proposal)

        self.aug_inner.update_idletasks()
        self.aug_canvas.configure(scrollregion=self.aug_canvas.bbox("all"))

    def _render_aug_row(self, index: int, proposal: AugmentationProposal):
        row = tk.Frame(self.aug_inner, bd=1, relief="groove", padx=6, pady=4)
        row.pack(fill="x", pady=2)
        row.columnconfigure(0, weight=1)

        # Card label
        front_preview = proposal.note.front[:60] + "…" if len(proposal.note.front) > 60 else proposal.note.front
        tk.Label(row, text=front_preview, font=("Menlo", 9), fg="#333", anchor="w").grid(
            row=0, column=0, sticky="ew"
        )

        if not proposal.succeeded:
            tk.Label(row, text=f"✗ AI failed: {proposal.error}", font=("Helvetica", 9, "italic"), fg=COLOR_DIM, anchor="w").grid(
                row=1, column=0, sticky="ew"
            )
            return

        p = proposal.payload
        # Show a compact preview of what will be added
        hyp_preview = " · ".join(p.high_yield_points[:2])
        if len(p.high_yield_points) > 2:
            hyp_preview += f" (+{len(p.high_yield_points)-2} more)"

        preview_text = (
            f"Concept: {p.primary_concept[:70]}\n"
            f"Mechanism: {p.mechanism[:70]}\n"
            f"High-yield: {hyp_preview}\n"
            f"Exam trap: {p.exam_trap[:70]}"
        )
        tk.Label(
            row, text=preview_text, font=("Helvetica", 9), fg="#444",
            anchor="w", justify="left", wraplength=430,
        ).grid(row=1, column=0, sticky="ew", pady=(2, 4))

        # Accept / reject toggle
        decision_var = tk.StringVar(value="pending")

        def _toggle(idx=index, var=decision_var):
            self._aug_accepted.discard(idx)
            if var.get() == "accept":
                self._aug_accepted.add(idx)

        btn_row = tk.Frame(row)
        btn_row.grid(row=2, column=0, sticky="w")
        tk.Radiobutton(btn_row, text="Add to card", variable=decision_var, value="accept",
                       command=_toggle, font=("Helvetica", 9), fg="#b45309").pack(side="left", padx=(0, 8))
        tk.Radiobutton(btn_row, text="Skip", variable=decision_var, value="reject",
                       command=_toggle, font=("Helvetica", 9), fg="#666").pack(side="left")
        row._aug_var = decision_var

    def _aug_accept_all(self):
        self._aug_accepted = {i for i, p in enumerate(self._aug_proposals) if p.succeeded}
        for widget in self.aug_inner.winfo_children():
            var = getattr(widget, "_aug_var", None)
            if var:
                var.set("accept")

    def _aug_reject_all(self):
        self._aug_accepted = set()
        for widget in self.aug_inner.winfo_children():
            var = getattr(widget, "_aug_var", None)
            if var:
                var.set("reject")

    def _accept_all_fixes(self):
        for i, r in enumerate(self._validation_results):
            if r.status == "fixable":
                self._decisions[i] = "accept"
        self._re_render_validation()
        self._update_build_readiness()

    def _reject_all_fixes(self):
        for i, r in enumerate(self._validation_results):
            if r.status == "fixable":
                self._decisions[i] = "reject"
        self._re_render_validation()
        self._update_build_readiness()

    def _re_render_validation(self):
        s = summary(self._validation_results)
        self._render_validation_panel(s)

    def _update_build_readiness(self):
        issues = [(i, r) for i, r in enumerate(self._validation_results) if r.status != "valid"]
        all_decided = all(
            self._decisions.get(i, "pending") != "pending"
            for i, _ in issues
        )
        if all_decided:
            self.build_btn.config(state="normal")
            self.augment_btn.config(state="normal")
            self._validated = True
        else:
            self.build_btn.config(state="disabled")
            self.augment_btn.config(state="disabled")
            self._validated = False

    def _resolved_notes(self) -> List[Note]:
        notes: List[Note] = []
        for i, result in enumerate(self._validation_results):
            if result.status == "valid":
                notes.append(result.note)
            elif result.status == "fixable":
                decision = self._decisions.get(i, "reject")
                if decision == "accept" and result.fixed_note:
                    notes.append(result.fixed_note)
            elif result.status == "invalid":
                decision = self._decisions.get(i, "reject")
                intake = self._intake_results.get(i)
                if decision == "accept" and intake and intake.proposed_note:
                    notes.append(intake.proposed_note)
        return notes

    # -------------------------------------
    # BUILD
    # -------------------------------------

    def _build(self):
        if not self._validated:
            messagebox.showerror("Error", "Run validation first.")
            return
        if not self.output_path:
            messagebox.showerror("Error", "No output file selected.")
            return

        deck_name = self.deck_name_var.get().strip()
        if not deck_name:
            messagebox.showerror("Error", "Deck name cannot be empty.")
            return

        self._clear_report()
        self._log(f"Building: {deck_name}")

        try:
            notes = self._resolved_notes()
            skipped = len(self._validation_results) - len(notes)
            self._log(f"Cards queued: {len(notes)}  |  Skipped: {skipped}")

            if not notes:
                self._log("✗ No valid cards to build.", "invalid")
                return

            # Apply augmentation if user accepted any proposals
            if self._aug_proposals and self._aug_accepted:
                payload_map = build_payload_map(self._aug_proposals, self._aug_accepted)
                self._log(f"\nApplying augmentation to {len(self._aug_accepted)} card(s)…", "dim")
                policy = AugmentationPolicy(
                    schema_version="1.0.0",
                    expansion_mode=ExpansionMode.APPEND,
                )
                notes, _ = augment_notes(notes=notes, payload_map=payload_map, policy=policy)

            if self.classify_var.get():
                self._log("\nClassifying by specialty…", "dim")
                notes, report = classify_notes(notes, DEFAULT_TAXONOMY)
                self._log(f"  Matched:   {report.matched_notes}", "dim")
                self._log(f"  Unmatched: {report.unmatched_notes} → General", "dim")

            self._log("\nBuilding deck…", "dim")
            result = build_deck(notes=notes, deck_name=deck_name, strict_repair=False)
            genanki.Package(list(result.decks)).write_to_file(str(self.output_path))

            self._log(f"\n✓ {result.total_notes} notes  |  {result.total_cards} cards", "valid")

            if result.subdeck_counts:
                self._log("\nSubdeck breakdown:", "dim")
                for subdeck, count in result.subdeck_counts:
                    label = subdeck.replace(f"{deck_name}::", "", 1).replace("_", " ")
                    self._log(f"  {label}: {count}", "dim")

            self._log(f"\nSaved → {self.output_path.name}", "valid")

        except Exception as e:
            self._log(f"\n✗ {e}", "invalid")
            messagebox.showerror("Build Failed", str(e))

    # -------------------------------------
    # REPORT HELPERS
    # -------------------------------------

    def _log(self, message: str, tag: str = ""):
        self.report_text.config(state="normal")
        if tag:
            self.report_text.insert(tk.END, message + "\n", tag)
        else:
            self.report_text.insert(tk.END, message + "\n")
        self.report_text.see(tk.END)
        self.report_text.config(state="disabled")
        self.root.update_idletasks()

    def _clear_report(self):
        self.report_text.config(state="normal")
        self.report_text.delete("1.0", tk.END)
        self.report_text.config(state="disabled")


# =========================================
# ENTRY POINT
# =========================================

def main():
    root = TkinterDnD.Tk()
    root.geometry("600x780")
    app = DecksmithApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
