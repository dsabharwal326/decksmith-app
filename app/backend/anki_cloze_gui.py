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
        self.strict_repair_var = tk.BooleanVar(value=False)
        self.deck_name_var = tk.StringVar()

        self._build_ui()

    def _build_ui(self):

        file_frame = tk.Frame(self.root)
        file_frame.pack(padx=10, pady=10, fill="both", expand=True)

        self.file_listbox = tk.Listbox(file_frame, height=8)
        self.file_listbox.pack(fill="both", expand=True)

        tk.Button(self.root, text="Add Files", command=self.add_files).pack(fill="x")
        tk.Button(self.root, text="Clear Files", command=self.clear_files).pack(fill="x")

        tk.Label(self.root, text="Deck Name (Optional Override)").pack()
        tk.Entry(self.root, textvariable=self.deck_name_var).pack(fill="x")

        tk.Checkbutton(
            self.root,
            text="Strict Repair Enforcement (fail on unmatched braces)",
            variable=self.strict_repair_var
        ).pack(anchor="w")

        tk.Button(self.root, text="Generate Deck", command=self.generate_deck_threaded).pack(fill="x")

        self.report = tk.Text(self.root, height=8)
        self.report.pack(fill="both", expand=True)

    def add_files(self):
        files = filedialog.askopenfilenames()
        for f in files:
            self.selected_files.append(f)
            self.file_listbox.insert(tk.END, f)

    def clear_files(self):
        self.selected_files.clear()
        self.file_listbox.delete(0, tk.END)

    def generate_deck_threaded(self):
        threading.Thread(target=self.generate_deck).start()

    def generate_deck(self):

        try:
            output_path = filedialog.asksaveasfilename(defaultextension=".apkg")
            if not output_path:
                return

            deck_name = self.deck_name_var.get().strip() or None

            report = generate_deck(
                input_files=[Path(p) for p in self.selected_files],
                output_file=Path(output_path),
                deck_name=deck_name,
                strict_repair=self.strict_repair_var.get()
            )

            self.root.after(0, self._display_report, report)

            if report.repairs:
                self.root.after(0, self._show_repair_preview, report.repairs)

        except Exception as e:
            messagebox.showerror("Error", str(e))

    def _display_report(self, report):
        self.report.delete("1.0", tk.END)
        self.report.insert(
            tk.END,
            f"Total Input Lines: {report.total_input}\n"
            f"Total Output Notes: {report.total_output}\n"
            f"Invalid Lines: {report.invalid_lines}\n"
            f"Lines Auto-Fixed: {report.lines_autofixed}\n"
        )

    def _show_repair_preview(self, repairs):

        window = tk.Toplevel(self.root)
        window.title("Repair Preview (Before → After)")
        window.geometry("800x500")

        text = tk.Text(window)
        text.pack(fill="both", expand=True)

        for before, after in repairs.items():
            text.insert(tk.END, "BEFORE:\n")
            text.insert(tk.END, before + "\n")
            text.insert(tk.END, "AFTER:\n")
            text.insert(tk.END, after + "\n")
            text.insert(tk.END, "-" * 60 + "\n")

        text.config(state="disabled")


if __name__ == "__main__":
    root = tk.Tk()
    app = AnkiClozeGUI(root)
    root.mainloop()
