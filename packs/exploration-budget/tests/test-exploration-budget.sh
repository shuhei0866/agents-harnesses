#!/usr/bin/env bash
# exploration-budget pack のテスト。ロジックは Python にあり、この wrapper は bash 3.2 でも動く。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
python3 --version
python3 -m unittest discover -s packs/exploration-budget/tests -p 'test_*.py' -v
