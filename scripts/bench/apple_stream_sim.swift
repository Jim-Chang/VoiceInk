// 邊講邊出字的調查:用 macOS 26 內建的 SpeechTranscriber(zh-TW,在本機跑)照真實時間餵錄音,
// 記錄中途顯示的文字(volatile results)和定稿的文字。
//
// 每 100 毫秒餵一小段(和錄音時一樣),錄音長度多少秒就跑多少秒。結束時呼叫
// finalizeAndFinishThroughEndOfInput(),記錄要等多久才拿到最後的定稿(App 裡只拿它當預覽,
// 結束時直接取消,不等這一步)。
//
// --start-at EPOCH --slack S:第 i 段在 EPOCH + Σ(前面各段長度 + S) 秒開始,用來和 tc_stream_sim
// 同時跑、每段對齊(量兩個同時跑會不會互相拖慢)。
//
// 編譯:swiftc -O -parse-as-library apple_stream_sim.swift -o apple_stream_sim
// 用法:apple_stream_sim -i list.tsv -o out.jsonl [--locale zh-TW] [--start-at EPOCH --slack 10] [--gap 5]
// list.tsv 每行「id<TAB>wav 路徑」。每次更新輸出一行 JSON。

import AVFoundation
import Foundation
import Speech

struct Options {
    var list = ""
    var out = ""
    var locale = "zh-TW"
    var startAt: Double?
    var slack = 10.0
    var gap = 5.0
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        let v = args.isEmpty ? "" : args.removeFirst()
        switch a {
        case "-i": o.list = v
        case "-o": o.out = v
        case "--locale": o.locale = v
        case "--start-at": o.startAt = Double(v)
        case "--slack": o.slack = Double(v) ?? 10
        case "--gap": o.gap = Double(v) ?? 5
        default:
            FileHandle.standardError.write("unknown option \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    if o.list.isEmpty || o.out.isEmpty {
        FileHandle.standardError.write("usage: apple_stream_sim -i list.tsv -o out.jsonl\n".data(using: .utf8)!)
        exit(2)
    }
    return o
}

func now() -> Double { Date().timeIntervalSince1970 }

func sleepUntil(_ t: Double) async {
    let d = t - now()
    if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
}

final class Writer: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)!
    }
    func write(_ obj: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        lock.lock()
        handle.write(data)
        handle.write("\n".data(using: .utf8)!)
        lock.unlock()
    }
}

func readWav(_ path: String) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return buffer
}

func slice(_ src: AVAudioPCMBuffer, from start: Int, count: Int) -> AVAudioPCMBuffer {
    let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(count))!
    out.frameLength = AVAudioFrameCount(count)
    for ch in 0..<Int(src.format.channelCount) {
        memcpy(out.floatChannelData![ch], src.floatChannelData![ch] + start, count * MemoryLayout<Float>.size)
    }
    return out
}

func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer {
    guard let converter else { return buffer }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
    let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if fed {
            status.pointee = .noDataNow
            return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
    }
    return out
}

func runOne(id: String, path: String, locale: Locale, writer: Writer) async throws {
    let audio = try readWav(path)
    let rate = audio.format.sampleRate
    let total = Int(audio.frameLength)
    let duration = Double(total) / rate

    let setupStart = now()
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: [.audioTimeRange]
    )
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        throw NSError(domain: "apple_stream_sim", code: 1)
    }
    try await analyzer.prepareToAnalyze(in: format)
    let converter = format == audio.format ? nil : AVAudioConverter(from: audio.format, to: format)
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let setupSeconds = now() - setupStart

    let t0 = now()
    let resultsTask = Task {
        var n = 0
        for try await result in transcriber.results {
            let t = now() - t0
            let text = String(result.text.characters)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
            let start = CMTimeGetSeconds(result.range.start)
            writer.write([
                "id": id, "kind": result.isFinal ? "final" : "volatile", "t": t, "range_start": start,
                "range_end": end, "text": text,
            ])
            n += 1
        }
        return n
    }
    try await analyzer.start(inputSequence: stream)

    let chunk = Int(rate / 10)  // 100 毫秒
    var pos = 0
    while pos < total {
        let count = min(chunk, total - pos)
        await sleepUntil(t0 + Double(pos + count) / rate)
        let piece = convert(slice(audio, from: pos, count: count), with: converter, to: format)
        continuation.yield(AnalyzerInput(buffer: piece))
        pos += count
    }
    let stopAt = now() - t0
    continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let finishedAt = now() - t0
    let updates = try await resultsTask.value
    writer.write([
        "id": id, "kind": "summary", "duration": duration, "setup_s": setupSeconds, "stop_at": stopAt,
        "finished_at": finishedAt, "finalize_wait_s": finishedAt - duration, "results": updates,
        "epoch_start": t0, "epoch_end": now(), "audio_format": "\(format)",
    ])
}

@main
struct AppleStreamSim {
    static func main() async {
        let o = parse()
        let locale = Locale(identifier: o.locale)
        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        guard supported.contains(locale.identifier(.bcp47)) else {
            FileHandle.standardError.write("locale \(o.locale) not supported\n".data(using: .utf8)!)
            exit(1)
        }
        let writer = Writer(path: o.out)
        let lines = (try? String(contentsOfFile: o.list, encoding: .utf8)) ?? ""
        var slot = o.startAt
        for line in lines.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if let s = slot { await sleepUntil(s) }
            FileHandle.standardError.write("\(parts[0])\n".data(using: .utf8)!)
            do {
                try await runOne(id: parts[0], path: parts[1], locale: locale, writer: writer)
            } catch {
                writer.write(["id": parts[0], "kind": "error", "error": "\(error)"])
            }
            if let s = slot {
                let file = try? AVAudioFile(forReading: URL(fileURLWithPath: parts[1]))
                let dur = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
                slot = s + dur + o.slack
            } else {
                try? await Task.sleep(nanoseconds: UInt64(o.gap * 1e9))
            }
        }
    }
}
