#!/bin/bash
# 測試繁中補標點的合併邏輯（ZhTWPunctuation.merge），不用 build 整個 App、也不用模型。
# 案例在 scripts/fixtures/punctuation-cases.json：原文、模型輸出、預期結果。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# 只有叫 main.swift 的檔案能直接寫頂層程式碼
cp "$ROOT/scripts/fixtures/PunctuationTest.swift" "$OUT/main.swift"
swiftc -O -o "$OUT/punctuation-test" \
    "$ROOT/VoiceInk/Features/ZhTW/ZhTWPunctuation.swift" \
    "$OUT/main.swift"
"$OUT/punctuation-test" "$ROOT/scripts/fixtures/punctuation-cases.json"
