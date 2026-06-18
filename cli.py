"""
JSON bridge for the native macOS front-end.

The Swift app invokes this script and reads a single JSON object from stdout.

Usage:
    # analyze text piped on stdin
    echo "some text" | python cli.py [--phrase "..."] [--clean]

    # analyze a file
    python cli.py --file path/to/doc.txt [--phrase "..."] [--clean]

On success stdout is the report dict from analyzer.analyze_text/analyze_file.
On failure stdout is {"error": "...", "trace": "..."} and exit code is 1.
Nothing but JSON is ever written to stdout (warnings go to stderr).
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback


def main() -> int:
    parser = argparse.ArgumentParser(description="LangCheck JSON bridge")
    parser.add_argument("--file", help="path to a .txt file (otherwise read stdin)")
    parser.add_argument("--phrase", default=None, help="phrase to score for rarity")
    parser.add_argument("--clean", action="store_true", help="strip letter salutations/closings")
    args = parser.parse_args()

    try:
        import analyzer  # imported here so import errors are reported as JSON

        phrase = args.phrase or None
        if args.file:
            report = analyzer.analyze_file(args.file, clean=args.clean, rarity_phrase=phrase)
        else:
            text = sys.stdin.read()
            report = analyzer.analyze_text(text, clean=args.clean, rarity_phrase=phrase)

        json.dump(report, sys.stdout, ensure_ascii=False)
        sys.stdout.flush()
        return 0
    except Exception as exc:  # noqa: BLE001 - surface everything to the UI
        json.dump({"error": str(exc), "trace": traceback.format_exc()},
                  sys.stdout, ensure_ascii=False)
        sys.stdout.flush()
        return 1


if __name__ == "__main__":
    sys.exit(main())
