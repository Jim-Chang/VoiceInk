import Foundation

// 用 App 裡同一份 ZhTWPunctuator.swift 補標點(sherpa-onnx 的 C API),核對和離線評測一樣。
// 用 scripts/bench/punct-ct.sh 編譯執行:
//   punct-ct <model.int8.onnx> <輸入.json> <輸出.json>   [{"id","text"}] → 加上 "merged"、"seconds"

struct Row: Codable {
    var id: String
    var text: String
    var merged: String?
    var seconds: Double?
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("用法:punct-ct <model.int8.onnx> <輸入.json> <輸出.json>\n".utf8))
    exit(2)
}
let punctuator = ZhTWPunctuator(modelPath: arguments[1])
let loadStarted = ContinuousClock.now
await punctuator.load()
print("load \(ZhTWTiming.seconds(ContinuousClock.now - loadStarted))s")

var rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
_ = await punctuator.punctuate(rows[0].text)  // 暖機
for index in rows.indices {
    let started = ContinuousClock.now
    rows[index].merged = await punctuator.punctuate(rows[index].text)
    let elapsed = (ContinuousClock.now - started).components
    rows[index].seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(rows).write(to: URL(fileURLWithPath: arguments[3]))
print("\(rows.count) 段,合計 \(String(format: "%.3f", rows.compactMap(\.seconds).reduce(0, +)))s")
