#!/usr/bin/env sh
# IFM frontend local web server launcher (Linux / macOS).
# Usage: ./serve.sh [--port 8000] [--room myroom] [--host 0.0.0.0] ...
set -e
cd "$(dirname "$0")"
exec python3 serve.py "$@"
