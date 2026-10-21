#!/bin/bash
# 編譯並執行 PunctTool(和 App 共用 ZhTWPunctuation.swift)。用法見 PunctTool.swift。
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=${TMPDIR:-/tmp}/zhtw-punct-tool
mkdir -p "$OUT"
cp scripts/bench/PunctTool.swift "$OUT/main.swift"
swiftc -O -o "$OUT/punct-tool" "$OUT/main.swift" VoiceInk/Features/ZhTW/ZhTWPunctuation.swift
"$OUT/punct-tool" "$@"
