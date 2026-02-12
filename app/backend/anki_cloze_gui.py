import tkinter as tk
from tkinter import filedialog, messagebox
from pathlib import Path
import threading

from core.engine import generate_deck


class AnkiClozeGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("Anki Cloze Generator")

        self.selected_files = []
        self.optimize_var = tk.BooleanVar(value=True)
        self.strict_var = tk.BooleanVar(value=True)
        self.deck_name_var = tk.StringVar()
        self.status_var = tk.StringVar()

        self._build_ui()

    # =========================================
    # UI Construction
    # =========================================

    def _build_ui(self):

        # File List
        file_frame = tk.Frame(self.root)
        file_frame.pack(padx=10, pady=10, fill="both", expand=True)

        self.file_listbox = tk.Listbox(file_frame, height=8)
        self.file_listbox.pack(side="left", fill="both", expand=True)

        scrollbar = tk.Scrollbar(file_frame)
        scrollbar.pack(side="right", fill="y")

        self.file_listbox.config(yscrollcommand=scrollbar.set)
        scrollbar.config(command=self.file_listbox.yview)

        # File Buttons
        button_frame = tk.Frame(self.root)
        button_frame.pack(padx=10, pady=(0, 10), fill="x")

        tk.Button(button_frame, text="Add Files", command=self.add_files).pack(side="left")
        tk.Button(button_frame, text="Clear Files", command=self.clear_files).pack(side="left", padx=5)

        # Deck Name
        name_frame = tk.Frame(self.root)
        name_frame.pack(padx=10, pady=(0, 10), fill="x")

        tk.Label(name_frame, text="Deck Name (Optional Override):").pack(anchor="w")
        tk.Entry(name_frame, textvariable=self.deck_name_var).pack(fill="x")

        # Toggles
        toggle_frame = tk.Frame(self.root)
        toggle_frame.pack(padx=10, pady=(0, 10), fill="x")

        optimize_cb = tk.Checkbutton(
            toggle_frame,
            text="Enable Optimization",
            variable=self.optimize_var
        )
        optimize_cb.pack(anchor="w")

        strict_cb = tk.Checkbutton(
            toggle_frame,
            text="Strict Mode",
            variable=self.strict_var
        )
        strict_cb.pack(anchor="w")

        # Bind hover events for status help
        optimize_cb.bind("<Enter>", lambda e: self._set_status(
            "Optimization ON: removes duplicates, empty notes, reindexes cloze.\n"
            "Optimization OFF: preserves raw input."
        ))
        optimize_cb.bind("<Leave>", lambda e: self._clear_status())

        strict_cb.bind("<Enter>", lambda e: self._set_status(
            "Strict Mode ON: stops on first parsing error.\n"
            "Strict Mode OFF: skips invalid lines and reports count."
        ))
        strict_cb.bind("<Leave>", lambda e: self._clear_status())

        # Generate Button
        generate_frame = tk.Frame(self.root)
        generate_frame.pack(padx=10, pady=(0, 10), fill="x")

        self.generate_button = tk.Button(
            generate_frame,
            text="Generate Deck",
            command=self.generate_deck_threaded
        )
        self.generate_button.pack(fill="x")

        # Report Panel
        report_frame = tk.LabelFrame(self.root, text="Generation Report")
        report_frame.pack(padx=10, pady=(0, 10), fill="both", expand=True)

        self.report_text = tk.Text(report_frame, height=8, state="disabled")
        self.report_text.pack(fill="both", expand=True)

        # Status Bar
        status_bar = tk.Label(
            self.root,
            textvariable=self.status_var,
            anchor="w",
            relief="sunken",
            bd=1
        )
        status_bar.pack(fill="x", side="bottom")

    # =========================================
    # Status Helpers
    # =========================================

    def _set_status(self, text):
        self.status_var.set(text)

    def _clear_status(self):
        self.status_var.set("")

    # =========================================
    # File Handling
    # =========================================

    def add_files(self):
        files = filedialog.askopenfilenames(
            filetypes=[("Text Files", "*.txt"), ("All Files", "*.*")]
        )

        for file in files:
            if file not in self.selected_files:
                self.selected_files.append(file)
                self.file_listbox.insert(tk.END, file)

    def clear_files(self):
        self.selected_files.clear()
        self.file_listbox.delete(0, tk.END)

    # =========================================
    # Generation
    # =========================================

    def generate_deck_threaded(self):

        if not self.selected_files:
            messagebox.showerror("Error", "No input files selected.")
            return

        self.generate_button.config(state="disabled")
        thread = threading.Thread(target=self.generate_deck)
        thread.start()

    def generate_deck(self):

        try:
            output_path = filedialog.asksaveasfilename(
                defaultextension=".apkg",
                filetypes=[("Anki Package", "*.apkg")]
            )

            if not output_path:
                self.root.after(0, self._reset_button)
                return

            manual_name = self.deck_name_var.get().strip()
            deck_name = manual_name if manual_name else None

            report = generate_deck(
                input_files=[Path(p) for p in self.selected_files],
                output_file=Path(output_path),
                optimize=self.optimize_var.get(),
                deck_name=deck_name,
                strict=self.strict_var.get()
            )

            self.root.after(0, self._display_report, report)
            self.root.after(0, lambda: messagebox.showinfo("Success", "Deck generated successfully."))

        except Exception as e:
            self.root.after(0, self._show_error_window, str(e))

        finally:
            self.root.after(0, self._reset_button)

    # =========================================
    # Report Display
    # =========================================

    def _display_report(self, report):

        self.report_text.config(state="normal")
        self.report_text.delete("1.0", tk.END)

        lines = [
            f"Total Input Lines: {report.total_input}",
            f"Total Output Notes: {report.total_output}",
            f"Duplicates Removed: {report.duplicates_removed}",
            f"Empty Notes Removed: {report.empty_removed}",
            f"Cloze Reindexed: {report.cloze_reindexed}",
            f"Invalid Lines Skipped: {report.invalid_lines}",
        ]

        self.report_text.insert(tk.END, "\n".join(lines))
        self.report_text.config(state="disabled")

    # =========================================
    # Error Window
    # =========================================

    def _show_error_window(self, error_message):

        error_window = tk.Toplevel(self.root)
        error_window.title("Generation Error")
        error_window.geometry("600x300")

        frame = tk.Frame(error_window)
        frame.pack(fill="both", expand=True, padx=10, pady=10)

        scrollbar = tk.Scrollbar(frame)
        scrollbar.pack(side="right", fill="y")

        text_widget = tk.Text(frame, wrap="word")
        text_widget.pack(side="left", fill="both", expand=True)

        text_widget.insert("1.0", error_message)
        text_widget.config(state="disabled")

        text_widget.config(yscrollcommand=scrollbar.set)
        scrollbar.config(command=text_widget.yview)

    # =========================================
    # Utility
    # =========================================

    def _reset_button(self):
        self.generate_button.config(state="normal")


if __name__ == "__main__":
    root = tk.Tk()
    app = AnkiClozeGUI(root)
    root.mainloop()
