#!/usr/bin/env bash
# Launch LangCheck from source (no packaging needed).
cd "$(dirname "$0")"
exec ./venv/bin/python app.py
