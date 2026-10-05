#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="${FLUTTER_ROOT:-/opt/flutter}/bin:$PATH"
export PUB_CACHE="${PUB_CACHE:-$HOME/.cache/pub}"
export TMPDIR="${TMPDIR:-$HOME/.cache/nexora-tmp}"
export CMAKE_BUILD_PARALLEL_LEVEL=1
RUNNER="$HOME/.cache/nexora_qa_runtime"
mkdir -p "$TMPDIR" "$PUB_CACHE"
if [ ! -f "$RUNNER/linux/CMakeLists.txt" ]; then
  flutter create --platforms=linux --project-name=nexora_app --org=com.nexora --no-pub "$RUNNER"
fi
cp pubspec.yaml pubspec.lock "$RUNNER/"
cp -a lib assets "$RUNNER/"
(cd "$RUNNER" && flutter pub get && flutter build linux --debug)
ln -sfn /usr/share/novnc/core "$ROOT/qa/preview/core"
ln -sfn /usr/share/novnc/vendor "$ROOT/qa/preview/vendor"
printf '\nRunner: %s\nWeb viewer: %s/qa/preview\n' "$RUNNER" "$ROOT"
