import genanki
import random
import re
import os
import tkinter as tk
from tkinter import filedialog, messagebox


# -----------------------------
# Cloze Conversion Logic
# -----------------------------

def convert_brace_cloze(text):
    cloze_number = 1

    def replacer(match):
        nonlocal cloze_number
        content = match.group(1)
        result = f"{{{{c{cloze_number}::{content}}}}}"
        cloze_number += 1
        return result

    return re.sub(r"\{\{(.*?)\}\}", replacer, text)


def convert_cloze_lines(text):
    lines = text.split("\n")
    cloze_number = 1
    new_lines = []

    for line in lines:
        if line.strip().startswith("CLOZE:"):
            content = line.replace("CLOZE:", "").strip()
            new_lines.append(f"{{{{c{cloze_number}::{content}}}}}")
            cloze_number += 1
        else:
            new_lines.append(line)

    return "\n".join(new_lines)


def process_cards(text):
    raw_cards = text.strip().split("\n\n")
    processed = []

    for card in raw_cards:
        card = convert_brace_cloze(card)
        card = convert_cloze_lines(card)
        processed.append(card.strip())

    return processed


# -----------------------------
# Deck Generator
# -----------------------------

def generate_deck(file_path):

    base_name = os.path.splitext(os.path.basename(file_path))[0]
    output_file = os.path.join(os.path.dirname(file_path), base_name + ".apkg")

    with open(file_path, "r", encoding="utf-8") as f:
        text = f.read()

    cards = process_cards(text)

    model_id = random.randrange(1 << 30, 1 << 31)
    deck_id = random.randrange(1 << 30, 1 << 31)

    cloze_model = genanki.Model(
        model_id,
        "Custom Cloze Model",
        fields=[{"name": "Text"}],
        templates=[{
            "name": "Cloze Card",
            "qfmt": "{{cloze:Text}}",
            "afmt": "{{cloze:Text}}",
        }],
        model_type=genanki.Model.CLOZE,
    )

    deck = genanki.Deck(deck_id, base_name)

    for card in cards:
        note = genanki.Note(model=cloze_model, fields=[card])
        deck.add_note(note)

    genanki.Package(deck).write_to_file(output_file)

    return output_file


# -----------------------------
# GUI
# -----------------------------

def select_file():
    file_path = filedialog.askopenfilename(
        filetypes=[("Text Files", "*.txt")]
    )
    if file_path:
        try:
            output = generate_deck(file_path)
            messagebox.showinfo("Success", f"Deck created:\n{output}")
        except Exception as e:
            messagebox.showerror("Error", str(e))


root = tk.Tk()
root.title("Anki Cloze Deck Generator")
root.geometry("400x200")

label = tk.Label(root, text="Convert Text File to Anki Cloze Deck", font=("Helvetica", 12))
label.pack(pady=20)

button = tk.Button(root, text="Select Text File", command=select_file, width=20, height=2)
button.pack()

root.mainloop()
