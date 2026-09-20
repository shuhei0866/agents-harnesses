#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
python3 -m unittest discover -s "$script_dir" -p 'test_resume*.py'
