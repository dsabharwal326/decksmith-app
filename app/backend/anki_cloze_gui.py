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

        self._build_ui()

    def _build_ui(self):
        # File Selection Frame
        file_frame = tk.Frame(self.root)
        file_frame.pack(padx=10, pady=10, fill="x")

        self.file_listbox = tk.Listbox(file_frame, height=8, width=60)
        self.file_listbox.pack(side="left", fill="both", expand=True)

        scrollbar = tk.Scrollbar(file_frame)
        scrollbar.pack(side="right", fill="y")
        self.file_listbox.config(yscrollcommand=scrollbar.set)
        scrollbar.config(command=self.file_listbox.yview)

        # Buttons Frame
        button_frame = tk.Frame(self.root)
        button_frame.pack(padx=10, pady=(0, 10), fill="x")

        tk.Button(button_frame, text="Add Files", command=self.add_files).pack(side="left")
        tk.Button(button_frame, text="Clear Files", command=self.clear_files).pack(side="left", padx=5)

        # Optimization Checkbox
        optimize_frame = tk.Frame(self.root)
        optimize_frame.pack(padx=10, pady=(0, 10), fill="x")

        tk.Checkbutton(
            optimize_frame,
            text="Enable Optimization",
            variable=self.optimize_var
        ).pack(anchor="w")

        # Generate Button
        generate_frame = tk.Frame(self.root)
        generate_frame.pack(padx=10, pady=(0, 10), fill="x")

        self.generate_button = tk.Button(
            generate_frame,
            text="Generate Deck",
            command=self.generate_deck_threaded
        )
        self.generate_button.pack(fill="x")

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
                self._reset_button()
                return

            generate_deck(
                input_files=[Path(p) for p in self.selected_files],
                output_file=Path(output_path),
                optimize=self.optimize_var.get()
            )

            messagebox.showinfo("Success", "Deck generated successfully.")

        except Exception as e:
            messagebox.showerror("Error", str(e))

        finally:
            self._reset_button()

    def _reset_button(self):
        self.generate_button.config(state="normal")


if __name__ == "__main__":
    root = tk.Tk()
    app = AnkiClozeGUI(root)
    root.mainloop()
