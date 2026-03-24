#!/usr/bin/env bash
# Delegates to stack.sh (see ./stack.sh help).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/stack.sh" backup "$@"
