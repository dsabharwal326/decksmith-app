import tkinter as tk
from tkinter import filedialog, messagebox
import os

from core.engine import build_deck_from_text


def select_file():
    file_path = filedialog.askopenfilename(
        filetypes=[("Text Files", "*.txt")]
    )

    if not file_path:
        return

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            text = f.read()

        deck_name = os.path.splitext(os.path.basename(file_path))[0]
        output_path = os.path.splitext(file_path)[0] + ".apkg"

        build_deck_from_text(text, deck_name, output_path)

        messagebox.showinfo("Success", f"Deck created:\n{output_path}")

    except Exception as e:
        messagebox.showerror("Error", str(e))


root = tk.Tk()
root.title("Anki Multi-Model Generator")
root.geometry("400x200")

label = tk.Label(
    root,
    text="Convert Text File to Anki Deck",
    font=("Helvetica", 12)
)
label.pack(pady=20)

button = tk.Button(
    root,
    text="Select Text File",
    command=select_file,
    width=20,
    height=2
)
button.pack()

root.mainloop()
