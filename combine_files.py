#!/usr/bin/env python3
"""
Combines all files in a folder into a single unified .txt file.

Usage:
    python combine_files.py /path/to/your/project/folder
    python combine_files.py /path/to/your/project/folder -o output.txt

By default it looks for common Apps Script extensions (.gs, .html, .js, .json).
Edit EXTENSIONS below if you have other file types to include.
"""

import argparse
import os

# Which file extensions to include. Add/remove as needed.
EXTENSIONS = {".gs", ".html", ".js", ".json", ".sql", ".css", ".md", ".txt"}

SEPARATOR = "=" * 150


def combine_files(folder, output_path):
    # Collect matching files, sorted alphabetically.
    # If you want Code.gs first (or a specific order), edit the sort logic below.
    files = [
        f for f in os.listdir(folder)
        if os.path.isfile(os.path.join(folder, f))
        and os.path.splitext(f)[1].lower() in EXTENSIONS
    ]

    if not files:
        print(f"No matching files found in {folder} (looking for {EXTENSIONS})")
        return

    # Put Code.gs first if present, then alphabetical for the rest.
    def sort_key(name):
        return (0, "") if name.lower() == "code.gs" else (1, name.lower())

    files.sort(key=sort_key)

    with open(output_path, "w", encoding="utf-8") as out:
        for i, filename in enumerate(files):
            filepath = os.path.join(folder, filename)
            with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()

            out.write(f"{filename}\n\n")
            out.write(content)
            out.write("\n\n")

            if i < len(files) - 1:
                out.write(f"{SEPARATOR}\n\n")

    print(f"Combined {len(files)} files into: {output_path}")
    for f in files:
        print(f"  - {f}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Combine project files into one txt file.")
    parser.add_argument("folder", help="Path to the folder containing your files")
    parser.add_argument("-o", "--output", default="combined_project.txt", help="Output file path")
    args = parser.parse_args()

    combine_files(args.folder, args.output)
