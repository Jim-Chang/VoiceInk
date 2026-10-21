import Foundation

// 用法:RefineBench <模型資料夾> <輸入.json> <輸出.json> <prefix|session> [whole|chunk]
//   輸入:[{"id": "...", "text": "沒標點的逐字稿"}]
//   prefix  = 現在的做法(prefix cache);session = 原作者的做法(每句從頭讀指示)
//   whole   = 整段一次補;chunk = 長的分段補(App 現在的做法)
// 輸出每句的模型原始輸出、合併後結果、耗時。實際聽寫內容只放私人 repo。

struct Item: Codable {
    let id: String
    let text: String
}

struct Result: Codable {
    let id: String
    let chars: Int
    let raw: [String]
    let merged: String
    let seconds: Double
}

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    FileHandle.standardError.write(Data("用法:RefineBench <模型資料夾> <輸入.json> <輸出.json> <prefix|session> [whole|chunk]\n".utf8))
    exit(2)
}
let modelDirectory = URL(fileURLWithPath: arguments[1])
let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
let outputURL = URL(fileURLWithPath: arguments[3])
let usesPrefix = arguments[4] == "prefix"
let chunked = arguments.count > 5 && arguments[5] == "chunk"

let engine = VoiceInkRefineInferenceEngine(usesPromptPrefixCache: usesPrefix)
let systemPrompt = ZhTWPunctuation.encodedInstructions
let clock = ContinuousClock()

let prepareStart = clock.now
try await engine.prepare(modelDirectory: modelDirectory, systemPrompt: systemPrompt)
print("prepare \(clock.now - prepareStart)")

func seconds(_ duration: Duration) -> Double {
    let (whole, atto) = duration.components
    return Double(whole) + Double(atto) / 1e18
}

var results: [Result] = []
for item in items {
    var raws: [String] = []
    let start = clock.now
    let merged: String
    if chunked {
        merged = try await ZhTWPunctuation.punctuate(item.text) { piece in
            let raw = try await engine.enhance(transcript: piece, modelDirectory: modelDirectory, systemPrompt: systemPrompt)
            raws.append(raw)
            return raw
        }
    } else {
        let raw = try await engine.enhance(transcript: item.text, modelDirectory: modelDirectory, systemPrompt: systemPrompt)
        raws.append(raw)
        merged = ZhTWPunctuation.merge(original: item.text, modelOutput: raw)
    }
    let elapsed = seconds(clock.now - start)
    results.append(Result(id: item.id, chars: item.text.count, raw: raws, merged: merged, seconds: elapsed))
    print(String(format: "%@ %4d 字 %.2f 秒 %d 段", item.id, item.text.count, elapsed, raws.count))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(results).write(to: outputURL)
