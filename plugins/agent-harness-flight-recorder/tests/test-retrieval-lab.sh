#!/usr/bin/env bash
set -euo pipefail
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
python3 -m unittest discover -s "$test_dir" -p 'test_retrieval*.py'
