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
print("\(cases.count - failures)/\(cases.count) 通過")
exit(failures == 0 ? 0 : 1)
