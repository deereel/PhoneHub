#!/usr/bin/env python3
"""
Combines all files in a folder and its subfolders into a single unified .txt file.

Usage:
    python combine_files.py /path/to/your/project/folder
    python combine_files.py /path/to/your/project/folder -o output.txt

Edit EXTENSIONS below if you have other file types to include.
"""

import argparse
import os

# Which file extensions to include. Add/remove as needed.
EXTENSIONS = {".gs", ".html", ".js", ".json", ".sql", ".css", ".md", ".txt", ".ts", ".py"}


# Never walk into these - huge, binary-heavy, or not yours to index.
# This is what caused venv/site-packages to end up in a combined dump before.
EXCLUDE_DIRS = {"node_modules", ".git", "venv", ".venv", "env", "__pycache__",
                 "dist", "build", ".next", "chroma_db", "site-packages",
                 "target", "bin", "obj", "vendor", ".idea", ".vscode"}

SEPARATOR = "=" * 150


def combine_files(folder, output_path, subfolders=True):
    # Collect matching files.
    files = []
    if subfolders:
        for root, dirs, filenames in os.walk(folder):
            dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith(".")]
            for filename in filenames:
                if os.path.splitext(filename)[1].lower() in EXTENSIONS:
                    relative_path = os.path.relpath(os.path.join(root, filename), folder)
                    files.append(relative_path)
    else:
        for filename in os.listdir(folder):
            filepath = os.path.join(folder, filename)
            if os.path.isfile(filepath) and os.path.splitext(filename)[1].lower() in EXTENSIONS:
                files.append(filename)

    if not files:
        print(f"No matching files found in {folder} (looking for {EXTENSIONS})")
        return

    # Put Code.gs first if present, then alphabetical for the rest.
    def sort_key(filepath):
        name = os.path.basename(filepath)
        return (0, "") if name.lower() == "code.gs" else (1, name.lower())

    files.sort(key=sort_key)

    with open(output_path, "w", encoding="utf-8") as out:
        for i, filename in enumerate(files):
            filepath = os.path.join(folder, filename)
            with open(filepath, "r", encoding="utf-8", errors="replace") as f: # filename is now a relative path
                content = f.read()

            out.write(f"{filename}\n\n")
            out.write(content.strip())
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
    parser.add_argument("--subfolders", action="store_true", default=True, help="Include files in subfolders (default)")
    parser.add_argument("--no-subfolders", action="store_false", dest="subfolders", help="Exclude files in subfolders")
    args = parser.parse_args()

    combine_files(args.folder, args.output, subfolders=args.subfolders)