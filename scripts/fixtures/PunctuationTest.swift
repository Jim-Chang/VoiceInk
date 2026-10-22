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
var checks = 0
func check(_ name: String, _ got: String, _ expected: String) {
    checks += 1
    if got == expected {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name)\n      預期：\(expected)\n      實際：\(got)")
    }
}

// MARK: - CT-Transformer 的輸入

check("沒有中文字不補(英文指令)", "\(ZhTWPunctuation.needsPunctuation("git push"))", "false")
check("沒有中文字不補(只有 OK)", "\(ZhTWPunctuation.needsPunctuation("OK"))", "false")
check("有中文字要補", "\(ZhTWPunctuation.needsPunctuation("這個 API 有問題我們先用 fallback"))", "true")
check("已經有句號不補(辨識模型自己會加)", "\(ZhTWPunctuation.needsPunctuation("好了，沒問題。"))", "false")
check("半形的點不算句號(小數、檔名)", "\(ZhTWPunctuation.needsPunctuation("右轉 59.5 度執行 setup.sh"))", "true")
check("給模型的版本:拿掉全形標點、轉簡體", ZhTWPunctuation.modelInput(for: "好的，我知道了你什麼時候來"), "好的我知道了你什么时候来")
check("給模型的版本:半形的點和英文不動", ZhTWPunctuation.modelInput(for: "右轉 59.5 度執行 setup.sh"), "右转 59.5 度执行 setup.sh")
check("原文已有的逗號保留、不重複加",
      ZhTWPunctuation.merge(original: "好的，我知道了你什麼時候來", modelOutput: "好的，我知道了。你什么时候来？"),
      "好的，我知道了。你什麼時候來？")

// MARK: - 補標點前整理辨識結果(ZhTWTranscript,TEA-ASR 用)

check("刪掉私用區字元(TEA 的 tokenizer 標記)",
      ZhTWTranscript.clean("數\u{E13A}據放在時\u{E454}間", modelName: "ggml-breeze-asr-25-q8_0"), "數據放在時間")
check("簡體專用字轉繁體",
      ZhTWTranscript.clean("这个还要记下来", modelName: "tea-asr-1.1"), "這個還要記下來")
check("繁體也會用的字不動(台、后、干、里、了)",
      ZhTWTranscript.clean("一台電腦之后干脆放在里面了", modelName: "ggml-breeze-asr-25-q8_0"), "一台電腦之后干脆放在里面了")
check("TEA 零星的全形標點拿掉,交給 CT",
      ZhTWTranscript.clean("好，我知道了。你什麼時候來", modelName: "tea-asr-1.1"), "好我知道了你什麼時候來")
check("拿掉之後 CT 照樣會補",
      "\(ZhTWPunctuation.needsPunctuation(ZhTWTranscript.clean("好，我知道了。你什麼時候來", modelName: "tea-asr-1.1")))", "true")
check("其他模型的標點保留",
      ZhTWTranscript.clean("好，我知道了。", modelName: "ggml-breeze-asr-25-q8_0"), "好，我知道了。")
check("半形的點和英文不動(TEA 也一樣)",
      ZhTWTranscript.clean("執行 setup.sh 跑 59.5 秒", modelName: "tea-asr-1.1"), "執行 setup.sh 跑 59.5 秒")

// MARK: - 長音檔一段碰到產生上限(ZhTWTranscript.collapseTrailingRepetition)

check("鬼打牆:正常文字不變",
      ZhTWTranscript.collapseTrailingRepetition("我們先看這個 API 再決定要不要 deploy"), "我們先看這個 API 再決定要不要 deploy")
check("鬼打牆:只重複兩次不動",
      ZhTWTranscript.collapseTrailingRepetition("好啊好啊"), "好啊好啊")
check("鬼打牆:三次以上縮成一次,前面的內容保留",
      ZhTWTranscript.collapseTrailingRepetition("今天會議先講預算然後下週再看然後下週再看然後下週再看"), "今天會議先講預算然後下週再看")
check("鬼打牆:被上限切斷的半截拿掉",
      ZhTWTranscript.collapseTrailingRepetition("我們先看這個好我們先看這個好我們先看這個好我們先"), "我們先看這個好")
check("鬼打牆:單一字重複",
      ZhTWTranscript.collapseTrailingRepetition("這個的的的的的的的的"), "這個的")
check("鬼打牆:空字串", ZhTWTranscript.collapseTrailingRepetition(""), "")
check("接段:英文和英文之間補空格", "\(ZhTWTranscript.needsSpaceBetween("先看這個 API", "deploy 完再說"))", "true")
check("接段:數字和英文之間補空格", "\(ZhTWTranscript.needsSpaceBetween("版本 2", "beta 的"))", "true")
check("接段:中文和英文之間不補", "\(ZhTWTranscript.needsSpaceBetween("先看這個", "API 再說"))", "false")
check("接段:中文和中文之間不補", "\(ZhTWTranscript.needsSpaceBetween("先看這個", "再說"))", "false")

let total = cases.count + checks
print("\(total - failures)/\(total) 通過")
exit(failures == 0 ? 0 : 1)
