#!/usr/bin/env bash
# Reproducible local QA. A failing acceptance test MUST produce a failing exit.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="${FLUTTER_ROOT:-/opt/flutter}/bin:$PATH"
export PUB_CACHE="${PUB_CACHE:-$HOME/.cache/pub}"
export TMPDIR="${TMPDIR:-$HOME/.cache/nexora-tmp}"
mkdir -p "$PUB_CACHE" "$TMPDIR" qa/evidence
flutter --version
flutter pub get
dart format --output=none --set-exit-if-changed lib/ test/
flutter analyze --no-pub
flutter test --no-pub --concurrency=1 --coverage --reporter expanded 2>&1 | tee qa/evidence/recheck.log
