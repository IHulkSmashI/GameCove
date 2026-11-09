#!/bin/sh
# Entry point the packaging tests look for; the real tests live in tests/.
exec sh "$(dirname "$0")/tests/test.sh" "$@"
