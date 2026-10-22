#!/bin/bash
# 編譯並執行 punct-ct(和 App 共用 ZhTWPunctuator.swift、ZhTWPunctuation.swift)。用法見 PunctCT.swift。
# 要先跑 scripts/deps-sherpa-onnx.sh。
set -euo pipefail
cd "$(dirname "$0")/../.."
DEPS="$HOME/VoiceInk-Dependencies/sherpa-onnx"
OUT=${TMPDIR:-/tmp}/zhtw-punct-ct
mkdir -p "$OUT"
cp scripts/bench/PunctCT.swift "$OUT/main.swift"
swiftc -O -o "$OUT/punct-ct" "$OUT/main.swift" scripts/bench/PunctCTStubs.swift \
    VoiceInk/Features/ZhTW/ZhTWPunctuator.swift VoiceInk/Features/ZhTW/ZhTWPunctuation.swift \
    VoiceInk/Features/ZhTW/ZhTWTiming.swift VoiceInk/Features/ZhTW/ZhTWTranscript.swift \
    VoiceInk/Features/ZhTW/ZhTWSimplifiedOnly.swift \
    -I "$DEPS/include" -L "$DEPS/lib" -lsherpa-onnx-c-api -Xlinker -rpath -Xlinker "$DEPS/lib"
"$OUT/punct-ct" "$@"
