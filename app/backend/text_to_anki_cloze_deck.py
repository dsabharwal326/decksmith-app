import genanki
import random
import re
import os
import sys


# -----------------------------
# Cloze Conversion Functions
# -----------------------------

def convert_brace_cloze(text):
    """
    Converts {{answer}} into sequential {{c1::answer}}, {{c2::...}}, etc.
    """
    cloze_number = 1

    def replacer(match):
        nonlocal cloze_number
        content = match.group(1)
        result = f"{{{{c{cloze_number}::{content}}}}}"
        cloze_number += 1
        return result

    return re.sub(r"\{\{(.*?)\}\}", replacer, text)


def convert_cloze_lines(text):
    """
    Converts lines starting with CLOZE: into {{cX::text}}
    """
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
    """
    Splits cards by blank lines.
    Each block becomes one note.
    """
    raw_cards = text.strip().split("\n\n")
    processed = []

    for card in raw_cards:
        card = convert_brace_cloze(card)
        card = convert_cloze_lines(card)
        processed.append(card.strip())

    return processed


# -----------------------------
# Main Program
# -----------------------------

def main():

    if len(sys.argv) < 2:
        print("Drag and drop a .txt file onto this executable.")
        input("Press Enter to exit...")
        return

    input_path = sys.argv[1]

    if not os.path.exists(input_path):
        print("File not found.")
        input("Press Enter to exit...")
        return

    base_name = os.path.splitext(os.path.basename(input_path))[0]
    output_file = os.path.join(os.path.dirname(input_path), base_name + ".apkg")

    with open(input_path, "r", encoding="utf-8") as f:
        text = f.read()

    cards = process_cards(text)

    # Random IDs prevent conflicts
    model_id = random.randrange(1 << 30, 1 << 31)
    deck_id = random.randrange(1 << 30, 1 << 31)

    cloze_model = genanki.Model(
        model_id,
        'Custom Cloze Model',
        fields=[
            {'name': 'Text'},
        ],
        templates=[
            {
                'name': 'Cloze Card',
                'qfmt': '{{cloze:Text}}',
                'afmt': '{{cloze:Text}}',
            },
        ],
        model_type=genanki.Model.CLOZE,
    )

    deck = genanki.Deck(
        deck_id,
        base_name
    )

    for card in cards:
        note = genanki.Note(
            model=cloze_model,
            fields=[card],
        )
        deck.add_note(note)

    genanki.Package(deck).write_to_file(output_file)

    print(f"\nDeck created successfully:\n{output_file}")
    input("\nPress Enter to exit...")


if __name__ == "__main__":
    main()
