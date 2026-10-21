// scripts/test-punctuation.sh 用的測試程式：和 ZhTWPunctuation.swift 一起編譯，
// 逐一比對 punctuation-cases.json 裡每個案例的合併結果。
import Foundation

let path = CommandLine.arguments[1]
let data = try Data(contentsOf: URL(fileURLWithPath: path))
let cases = try JSONSerialization.jsonObject(with: data) as! [[String: String]]

var failures = 0
for c in cases {
    let got = ZhTWPunctuation.merge(original: c["original"]!, modelOutput: c["model"]!)
    if got == c["expected"]! {
        print("  ✓ \(c["name"]!)")
    } else {
        failures += 1
        print("  ✗ \(c["name"]!)\n      預期：\(c["expected"]!)\n      實際：\(got)")
    }
}
// MARK: - 長的逐字稿分段(假的模型:在已知的句子結尾加「。」,每段最後也補一個「。」,像真的模型會做的)

let sentences = [
    "今天早上我先去銀行辦事", "然後到公司開會討論新的 API 設計", "下午跟客戶確認需求和時程",
    "晚上回家把文件整理好再寄出去", "明天還要繼續寫報告", "週末想去山上走走放鬆一下",
    "記得幫我預約下週三的牙醫", "這個版本先上線看看使用者的反應", "如果有問題我們再一起討論",
    "最後別忘了更新 README 和 changelog", "會議紀錄我晚點會整理好傳給大家", "下個月要開始準備年度預算",
    "新來的同事需要有人帶他熟悉環境", "咖啡機好像又壞了要找人來修", "停車場的位置改到地下二樓",
]
let longText = sentences.joined()
let ideal = sentences.map { $0 + "。" }.joined()
var ends: Set<Int> = []
var offset = 0
for sentence in sentences {
    offset += sentence.count
    ends.insert(offset)
}

func fakeModel(_ piece: String) -> String {
    let source = Array(longText)
    let chars = Array(piece)
    var start = 0
    while Array(source[start..<min(start + chars.count, source.count)]) != chars { start += 1 }
    var out = ""
    for (k, ch) in chars.enumerated() {
        out.append(ch)
        if ends.contains(start + k + 1) { out.append("。") }
    }
    if out.last != "。" { out.append("。") }
    return out
}

func check(_ name: String, _ got: String, _ expected: String) {
    if got == expected {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name)\n      預期：\(expected)\n      實際：\(got)")
    }
}

var calls = 0
let chunked = try await ZhTWPunctuation.punctuate(longText) { piece in
    calls += 1
    return fakeModel(piece)
}
check("分段:\(longText.count) 字分 \(calls) 段,句尾都在正確位置、沒有段尾多出的「。」", chunked, ideal)

let failed = try await ZhTWPunctuation.punctuate(longText) { _ in "好的,我知道了。" }
check("分段:模型每段都答非所問時,原文一字不漏", failed, longText)

let short = try await ZhTWPunctuation.punctuate("好了沒問題") { _ in "好了，沒問題。" }
check("短句不分段", short, "好了，沒問題。")

let total = cases.count + 3
print("\(total - failures)/\(total) 通過")
exit(failures == 0 ? 0 : 1)
