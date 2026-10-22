// segment-bench:用 App 同一份 TranscribeCppSpeechSegmenter 對錄音做語音偵測切段,調參數用。
// 只輸出時間和數量,不輸出內容。用法見 segment-bench.sh。
import AVFoundation
import Foundation
import whisper

func usage() -> Never {
    print("""
    用法:segment-bench [--model ggml-silero.bin] [--threshold 0.5] [--min-speech 250] [--min-silence 400]
                       [--pad 200] [--max-sec 30] [--wav-dir 資料夾] [--no-split] (--list id<TAB>音檔.tsv | 音檔…)
    --wav-dir:把切好的每段存成 16kHz wav,並寫 list.tsv(id<TAB>wav)給 tc_bench 辨識。
    --no-split:超過上限的講話不切,留給 tc_bench --max-chunk-sec 用 App 同一套算法切。
    """)
    exit(1)
}

var modelPath = "/Applications/VoiceInk.app/Contents/Resources/ggml-silero-v5.1.2.bin"
var parameters = TranscribeCppSpeechSegmenter.Parameters()
var maximumSeconds = 30
var wavDirectory: URL?
var splitLongSpeech = true
var inputs: [(id: String, path: String)] = []

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { usage() }
        return arguments.removeFirst()
    }
    switch flag {
    case "--model": modelPath = value()
    case "--threshold": parameters.threshold = Float(value())!
    case "--min-speech": parameters.minimumSpeechMilliseconds = Int32(value())!
    case "--min-silence": parameters.minimumSilenceMilliseconds = Int32(value())!
    case "--pad": parameters.paddingMilliseconds = Int32(value())!
    case "--max-sec": maximumSeconds = Int(value())!
    case "--wav-dir": wavDirectory = URL(fileURLWithPath: value())
    case "--no-split": splitLongSpeech = false
    case "--list":
        let text = try String(contentsOfFile: value(), encoding: .utf8)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { inputs.append((parts[0], parts[1])) }
        }
    default:
        if flag.hasPrefix("--") { usage() }
        inputs.append((URL(fileURLWithPath: flag).deletingPathExtension().lastPathComponent, flag))
    }
}
if inputs.isEmpty { usage() }

// 不要 whisper.cpp 每段一行的紀錄
whisper_log_set({ _, _, _ in }, nil)

/// 讀成 16kHz 單聲道 Float(App 用 FluidAudio 的 AudioConverter,這裡用 AVAudioConverter,結果可能有細微差異)
func loadSamples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    var samples: [Float] = []
    let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
    var finished = false
    while true {
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536)!
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if finished {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: inputBuffer)
            } catch {
                finished = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            if inputBuffer.frameLength == 0 {
                finished = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if let error { throw error }
        let count = Int(outputBuffer.frameLength)
        if count > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: outputBuffer.floatChannelData![0], count: count))
        }
        if status == .endOfStream || (status == .inputRanDry && finished) { break }
        if count == 0 && finished { break }
    }
    return samples
}

func writeWav(_ samples: [Float], to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let byteCount = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(byteCount)
    for sample in samples {
        append(Int16(max(-1, min(1, sample)) * 32_767))
    }
    try data.write(to: url)
}

/// App 用 energyAwareChunks 切太長的講話;這裡只做等分,記一下有幾段用到
var longSpeechSplits = 0
func splitEvenly(_ samples: [Float]) -> [[Float]] {
    longSpeechSplits += 1
    guard splitLongSpeech else { return [samples] }
    let maximumCount = maximumSeconds * 16_000
    let pieces = (samples.count + maximumCount - 1) / maximumCount
    let size = (samples.count + pieces - 1) / pieces
    return stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
}

var listLines: [String] = []
if let wavDirectory {
    try FileManager.default.createDirectory(at: wavDirectory, withIntermediateDirectories: true)
}
for input in inputs {
    let samples = try loadSamples(input.path)
    let vadStarted = Date()
    guard let ranges = TranscribeCppSpeechSegmenter.speechRanges(
        in: samples, modelPath: modelPath, maximumSeconds: maximumSeconds, parameters: parameters)
    else {
        print("{\"id\":\"\(input.id)\",\"error\":\"vad failed\"}")
        continue
    }
    let vadMilliseconds = Date().timeIntervalSince(vadStarted) * 1000
    longSpeechSplits = 0
    let chunks = TranscribeCppSpeechSegmenter.pack(
        ranges, of: samples, maximumCount: maximumSeconds * 16_000, splitLongSpeech: splitEvenly)
    let lengths = chunks.map { Double($0.samples.count) / 16_000 }.sorted()
    let speech = ranges.reduce(0) { $0 + $1.count }
    func r(_ x: Double) -> String { String(format: "%.2f", x) }
    print("{\"id\":\"\(input.id)\",\"seconds\":\(r(Double(samples.count) / 16_000)),\"speechSeconds\":\(r(Double(speech) / 16_000)),"
        + "\"ranges\":\(ranges.count),\"chunks\":\(chunks.count),\"longSplits\":\(longSpeechSplits),"
        + "\"chunkMin\":\(r(lengths.first ?? 0)),\"chunkMedian\":\(r(lengths.isEmpty ? 0 : lengths[lengths.count / 2])),"
        + "\"chunkMax\":\(r(lengths.last ?? 0)),\"vadMs\":\(r(vadMilliseconds))}")
    if let wavDirectory {
        for (index, chunk) in chunks.enumerated() {
            let url = wavDirectory.appendingPathComponent("\(input.id)__\(String(format: "%04d", index)).wav")
            try writeWav(chunk.samples, to: url)
            listLines.append("\(input.id)__\(String(format: "%04d", index))\t\(url.path)")
        }
    }
}
if let wavDirectory {
    try (listLines.joined(separator: "\n") + "\n").write(
        to: wavDirectory.appendingPathComponent("list.tsv"), atomically: true, encoding: .utf8)
}
