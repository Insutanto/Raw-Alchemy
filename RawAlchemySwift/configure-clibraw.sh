#!/usr/bin/env bash
# configure-clibraw.sh
#
# Regenerates Sources/CLibRaw/module.modulemap so that the absolute header path
# matches the libraw installation on the current machine.
#
# Usage:
#   cd RawAlchemySwift && ./configure-clibraw.sh
#
# Requirements:
#   macOS : brew install libraw     (pkg-config must be in PATH)
#   Linux : apt install libraw-dev
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULEMAP="${SCRIPT_DIR}/Sources/CLibRaw/module.modulemap"

# Ask pkg-config for the libraw include root (e.g. /usr/local or /opt/homebrew)
if ! LIBRAW_PREFIX="$(pkg-config --variable=prefix libraw 2>/dev/null)"; then
    echo "ERROR: pkg-config cannot find libraw." >&2
    echo "  macOS:  brew install libraw" >&2
    echo "  Linux:  sudo apt install libraw-dev" >&2
    exit 1
fi

LIBRAW_HEADER="${LIBRAW_PREFIX}/include/libraw/libraw.h"
if [ ! -f "$LIBRAW_HEADER" ]; then
    echo "ERROR: Expected libraw header not found at: ${LIBRAW_HEADER}" >&2
    exit 1
fi

cat > "$MODULEMAP" <<EOF
// CLibRaw system-library module map.
// Tells the Swift compiler where to find the libraw C headers so they can be
// imported as \`import CLibRaw\` in Swift code.
//
// NOTE: This file uses an absolute path that is correct for Linux (apt install
// libraw-dev installs headers to /usr/include/libraw/).  On macOS the path
// differs by Homebrew prefix; run the helper script to regenerate it:
//
//   cd RawAlchemySwift && ./configure-clibraw.sh
//
// See configure-clibraw.sh for details.

module CLibRaw [system] {
    header "${LIBRAW_HEADER}"
    link "raw_r"
    export *
}
EOF

echo "Updated module.modulemap → header: ${LIBRAW_HEADER}"
