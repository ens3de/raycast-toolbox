#!/bin/bash
# Rebuilds open-passwords-menu from open-passwords-menu.swift next to it.
# open-passwords-menu.sh (one level up) runs the result.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o open-passwords-menu open-passwords-menu.swift
echo "Built $(pwd)/open-passwords-menu"
