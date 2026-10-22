import Foundation

// 用 App 裡同一份 ZhTWPunctuator.swift 補標點(sherpa-onnx 的 C API),核對和離線評測一樣。
// 用 scripts/bench/punct-ct.sh 編譯執行:
//   punct-ct <model.int8.onnx> <輸入.json> <輸出.json> [門檻 長度 重疊]   [{"id","text"}] → 加上 "merged"、"seconds"
// 後面三個數字改長文字分段的設定(ZhTWPunctuation.Windowing),比較分段和整段時用。
// 列有 "model"(辨識模型名稱)時,先照 App 的流程用 ZhTWTranscript.clean 整理,結果放在 "cleaned"。

struct Row: Codable {
    var id: String
    var text: String
    var model: String?
    var cleaned: String?
    var merged: String?
    var seconds: Double?
}

let arguments = CommandLine.arguments
guard arguments.count == 4 || arguments.count == 7 else {
    FileHandle.standardError.write(Data("用法:punct-ct <model.int8.onnx> <輸入.json> <輸出.json> [門檻 長度 重疊]\n".utf8))
    exit(2)
}
let windowing = arguments.count == 7
    ? ZhTWPunctuation.Windowing(threshold: Int(arguments[4])!, length: Int(arguments[5])!, overlap: Int(arguments[6])!)
    : .standard
let punctuator = ZhTWPunctuator(modelPath: arguments[1])
let loadStarted = ContinuousClock.now
await punctuator.load()
print("load \(ZhTWTiming.seconds(ContinuousClock.now - loadStarted))s")

var rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
_ = await punctuator.punctuate(rows[0].text)  // 暖機
for index in rows.indices {
    let started = ContinuousClock.now
    let text = rows[index].model.map { ZhTWTranscript.clean(rows[index].text, modelName: $0) } ?? rows[index].text
    if rows[index].model != nil { rows[index].cleaned = text }
    rows[index].merged = await punctuator.punctuate(text, windowing: windowing)
    let elapsed = (ContinuousClock.now - started).components
    rows[index].seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(rows).write(to: URL(fileURLWithPath: arguments[3]))
print("\(rows.count) 段,合計 \(String(format: "%.3f", rows.compactMap(\.seconds).reduce(0, +)))s")
