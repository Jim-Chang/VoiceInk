#!/bin/bash
# 編譯並執行 segment-bench(和 App 共用 TranscribeCppSpeechSegmenter.swift),調語音偵測切段的參數。
# 要先有 ~/VoiceInk-Dependencies 裡的 whisper.xcframework(make local 會編)。用法見 SegmentBench.swift。
set -euo pipefail
cd "$(dirname "$0")/../.."
FW="$HOME/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework/macos-arm64_x86_64"
OUT=${TMPDIR:-/tmp}/zhtw-segment-bench
mkdir -p "$OUT"
cp scripts/bench/SegmentBench.swift "$OUT/main.swift"
swiftc -O -o "$OUT/segment-bench" "$OUT/main.swift" \
    VoiceInk/Infrastructure/Providers/Transcription/TranscribeCpp/TranscribeCppSpeechSegmenter.swift \
    -F "$FW" -framework whisper -Xlinker -rpath -Xlinker "$FW"
"$OUT/segment-bench" "$@"
