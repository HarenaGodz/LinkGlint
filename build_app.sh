#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
exec "$ROOT/scripts/build-app.sh" "$@"
