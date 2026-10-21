import Foundation

// 實驗 C 的小工具,和 App 共用 ZhTWPunctuation.swift(用 scripts/bench/punct-tool.sh 編譯)。
//   simplify <輸入.json> <輸出.json>   [{"id","text"}] → 加上 "simplified"(只轉字,長度不變時才用)
//   merge    <輸入.json> <輸出.json>   [{"id","text","model"}] → 加上 "merged"(只把 model 的標點插回 text)

struct Row: Codable {
    var id: String
    var text: String
    var model: String?
    var simplified: String?
    var merged: String?
    var seconds: Double?
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("用法:punct-tool simplify|merge <輸入.json> <輸出.json>\n".utf8))
    exit(2)
}
var rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
for index in rows.indices {
    switch arguments[1] {
    case "simplify":
        let converted = rows[index].text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false)
        rows[index].simplified = converted.flatMap { $0.count == rows[index].text.count ? $0 : nil } ?? rows[index].text
    case "merge":
        rows[index].merged = ZhTWPunctuation.merge(original: rows[index].text, modelOutput: rows[index].model ?? "")
    default:
        exit(2)
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(rows).write(to: URL(fileURLWithPath: arguments[3]))
