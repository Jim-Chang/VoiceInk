import Foundation
import whisper

/// voiceink-zhtw：transcribe.cpp 的錄音先用語音偵測（App 內建 whisper.cpp 的 Silero）切段再辨識。
/// 只把有人講話的部分送進模型、在停頓處切開，靜音和多半的音樂不送，模型比較不會「鬼打牆」。
/// 設計見 docs/plan/2026-10-22-long-audio-segmentation.md；scripts/bench/segment-bench.sh 用同一份檔案調參數。
enum TranscribeCppSpeechSegmenter {
    struct Parameters {
        /// 講話機率高於這個值算講話（原作者 Whisper 路線也是 0.5）
        var threshold: Float = 0.5
        /// 短於這個長度的講話當成雜音丟掉。250 毫秒會把句首單獨的「好」丟掉，所以設短一點
        var minimumSpeechMilliseconds: Int32 = 100
        /// 停頓超過這個長度才算一段講完；要在停頓處切段，所以比原作者的 100 毫秒長
        var minimumSilenceMilliseconds: Int32 = 400
        /// 每段講話前後多留的長度，避免切掉句首句尾的輕聲
        var paddingMilliseconds: Int32 = 300
    }

    struct Chunk {
        let samples: [Float]
        /// `samples` 依序由原始錄音的哪些區間接成（中間的靜音不送）；紀錄卡住的位置時對回原始錄音
        let sourceRanges: [Range<Int>]

        var startSample: Int { sourceRanges.first?.lowerBound ?? 0 }

        /// 這段第 `offset` 個樣本在原始錄音裡的位置
        func sourcePosition(ofOffset offset: Int) -> Int {
            var remaining = offset
            for range in sourceRanges {
                if remaining < range.count { return range.lowerBound + remaining }
                remaining -= range.count
            }
            return sourceRanges.last?.upperBound ?? offset
        }
    }

    static let sampleRate = 16_000

    /// 找出講話的區間（已含前後留邊），單位是樣本。語音偵測載入或執行失敗時回傳 nil。
    static func speechRanges(
        in samples: [Float],
        modelPath: String,
        maximumSeconds: Int,
        parameters: Parameters = Parameters()
    ) -> [Range<Int>]? {
        var contextParameters = whisper_vad_default_context_params()
        contextParameters.use_gpu = false
        guard let context = whisper_vad_init_from_file_with_params(modelPath, contextParameters) else { return nil }
        defer { whisper_vad_free(context) }

        var vadParameters = whisper_vad_default_params()
        vadParameters.threshold = parameters.threshold
        vadParameters.min_speech_duration_ms = parameters.minimumSpeechMilliseconds
        vadParameters.min_silence_duration_ms = parameters.minimumSilenceMilliseconds
        // 一直講沒停時，讓語音偵測在它找到的短停頓切開
        vadParameters.max_speech_duration_s = Float(maximumSeconds)
        vadParameters.speech_pad_ms = parameters.paddingMilliseconds
        vadParameters.samples_overlap = 0

        let segments = samples.withUnsafeBufferPointer { buffer in
            whisper_vad_segments_from_samples(context, vadParameters, buffer.baseAddress, Int32(buffer.count))
        }
        guard let segments else { return nil }
        defer { whisper_vad_free_segments(segments) }

        var ranges: [Range<Int>] = []
        for index in 0..<whisper_vad_segments_n_segments(segments) {
            // whisper.cpp 給的時間單位是百分之一秒
            let start = samplePosition(centiseconds: whisper_vad_segments_get_segment_t0(segments, index))
            let end = samplePosition(centiseconds: whisper_vad_segments_get_segment_t1(segments, index))
            let lower = min(max(0, start), samples.count)
            let upper = min(max(lower, end), samples.count)
            guard upper > lower else { continue }
            if let last = ranges.last, lower <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                ranges.append(lower..<upper)
            }
        }
        return ranges
    }

    /// 把相鄰的講話區間接成一段（只接講話的部分，中間的靜音不送），每段不超過 `maximumCount` 個樣本。
    /// 放不下時，在這一段後半最長的停頓處切開。單一區間就超過上限時，交給 `splitLongSpeech` 切。
    static func pack(
        _ ranges: [Range<Int>],
        of samples: [Float],
        maximumCount: Int,
        splitLongSpeech: ([Float]) -> [[Float]]
    ) -> [Chunk] {
        var chunks: [Chunk] = []
        var pending: [Range<Int>] = []

        func emit(_ group: [Range<Int>]) {
            guard !group.isEmpty else { return }
            var chunkSamples: [Float] = []
            chunkSamples.reserveCapacity(group.reduce(0) { $0 + $1.count })
            for range in group {
                chunkSamples.append(contentsOf: samples[range])
            }
            chunks.append(Chunk(samples: chunkSamples, sourceRanges: group))
        }

        for range in ranges {
            if range.count > maximumCount {
                emit(pending)
                pending = []
                var pieceStart = range.lowerBound
                for piece in splitLongSpeech(Array(samples[range])) {
                    chunks.append(Chunk(samples: piece, sourceRanges: [pieceStart..<(pieceStart + piece.count)]))
                    pieceStart += piece.count
                }
                continue
            }

            pending.append(range)
            while pending.reduce(0, { $0 + $1.count }) > maximumCount {
                let cut = cutAtLongestPause(pending)
                emit(Array(pending[..<cut]))
                pending.removeFirst(cut)
            }
        }
        emit(pending)
        return chunks
    }

    /// 放不下時的切點 k（前 k 個區間成一段）。最後一個區間是剛加進來、放不下的，切點在它前面；
    /// 只在前面那些區間的後半找停頓最長的地方，避免切出很短的段。
    private static func cutAtLongestPause(_ ranges: [Range<Int>]) -> Int {
        let fittingCount = ranges.dropLast().reduce(0) { $0 + $1.count }
        var best = ranges.count - 1
        var longestPause = -1
        var counted = 0
        for cut in 1..<ranges.count {
            counted += ranges[cut - 1].count
            guard counted * 2 >= fittingCount else { continue }
            let pause = ranges[cut].lowerBound - ranges[cut - 1].upperBound
            if pause > longestPause {
                longestPause = pause
                best = cut
            }
        }
        return best
    }

    private static func samplePosition(centiseconds: Float) -> Int {
        Int((Double(centiseconds) / 100 * Double(sampleRate)).rounded())
    }
}
