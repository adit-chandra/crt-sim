#!/bin/bash
# Keep the build entry point independent of the caller's working directory.
set -euo pipefail
cd "$(dirname "$0")/.."
exec /usr/bin/python3 scripts/build-app.py "$@"
