#!/bin/sh
# Builds to ~/.local/bin, outside the source folder.
set -eu
out="$HOME/.local/bin/space-overview"
mkdir -p "$(dirname "$out")"
cd "$(dirname "$0")"
xcrun swiftc -O -o "$out" *.swift
echo "built $out"
