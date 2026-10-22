import Foundation

/// voiceink-zhtw：台灣繁體中文補標點的文字處理（模型在 ZhTWPunctuator）。
///
/// - 要不要補、給模型看的版本（拿掉原有的全形標點、轉簡體）。
/// - `merge`：只把模型加的標點插回辨識原文，一個字都不改。
enum ZhTWPunctuation {
    // MARK: - CT-Transformer 的輸入（ZhTWPunctuator）

    /// 要不要補：有中文字、原文還沒有句號問號驚嘆號（有的話表示辨識模型自己會加標點）。
    /// 只有英文的不補，不然指令會變成「git push。」。
    static func needsPunctuation(_ text: String) -> Bool {
        guard text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return false }
        return !text.contains { sentenceEnds.contains($0) }
    }

    /// 給模型看的版本：先拿掉原文零星的全形標點（不然模型會再補一個，例如「好的，，」，
    /// 合併時保留原文的標點），再整段轉簡體（字數變了就不轉，和評測一樣）。
    /// 半形的不拿：多半是英文、數字、檔名裡的（59.5、setup.sh）。
    static func modelInput(for text: String) -> String {
        let stripped = String(text.filter { !punctuation.contains($0) })
        guard let converted = stripped.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false),
            converted.count == stripped.count
        else { return stripped }
        return converted
    }

    private static let sentenceEnds: Set<Character> = Set("。？！")

    // MARK: - 只把標點插回原文

    /// 整句對得上的比例低於這個值（例如模型跑去回答問題）就整句放棄；
    /// 高於這個值時，也只採用「前後字在原文裡同樣相鄰」的標點。
    static let minimumMatchRatio = 0.5

    private static let opening: Set<Character> = Set("「『（《")
    private static let closing: Set<Character> = Set("，。、？！：；」』）》…")
    /// 全形標點（ZhTWTranscript 也用來拿掉 TEA-ASR 零星的標點）
    static let punctuation = opening.union(closing)
    private static let halfToFull: [Character: Character] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
    ]
    /// 原文裡本來就有的標點（含半形），對齊時當作「已有標點」
    private static let existingPunctuation = punctuation.union(Set(",.?!:;"))

    static func merge(original: String, modelOutput: String) -> String {
        let source = Array(original)

        // 原文的「核心字」：不含空白、不含標點，記住各自在原文的位置
        let sourceIndices = source.indices.filter {
            !source[$0].isWhitespace && !existingPunctuation.contains(source[$0])
        }
        let sourceCore = sourceIndices.map { source[$0] }
        guard !sourceCore.isEmpty else { return original }

        // 模型輸出：核心字 + 每個標點黏在哪個核心字的前/後
        var modelCore: [Character] = []
        var after: [Int: String] = [:]
        var before: [Int: String] = [:]
        var pendingOpening = ""
        for raw in modelOutput {
            let ch = halfToFull[raw] ?? raw
            if ch.isWhitespace { continue }
            if opening.contains(ch) {
                pendingOpening.append(ch)
            } else if closing.contains(ch) {
                if !modelCore.isEmpty { after[modelCore.count - 1, default: ""].append(ch) }
            } else {
                if !pendingOpening.isEmpty {
                    before[modelCore.count] = pendingOpening
                    pendingOpening = ""
                }
                modelCore.append(ch)
            }
        }

        // 兩邊都先轉簡體再逐字對齊，模型把字改成簡體也對得上；輸出的字一律用原文的
        let (modelToSource, exact) = align(
            source: simplifiedKeys(sourceCore),
            model: simplifiedKeys(modelCore)
        )
        let ratio = Double(exact.count) / Double(max(sourceCore.count, modelCore.count))
        guard ratio >= minimumMatchRatio else { return original }

        // 只採用前後字在原文裡也相鄰的標點；模型改寫的地方附近的標點不要
        let lastSource = sourceCore.count - 1
        var insertAfter: [Int: String] = [:]
        var insertBefore: [Int: String] = [:]
        for (j, mark) in after where exact.contains(j) {
            guard let s = modelToSource[j] else { continue }
            let adjacent: Bool
            if let next = modelToSource[j + 1] {
                adjacent = next == s + 1
            } else {
                adjacent = j == modelCore.count - 1 && s == lastSource
            }
            if adjacent { insertAfter[sourceIndices[s], default: ""] += mark }
        }
        for (j, mark) in before where exact.contains(j) {
            guard let s = modelToSource[j] else { continue }
            let adjacent = j > 0 ? modelToSource[j - 1] == s - 1 : s == 0
            if adjacent { insertBefore[sourceIndices[s], default: ""] += mark }
        }

        var output: [Character] = []
        var i = 0
        while i < source.count {
            if let mark = insertBefore[i], !(output.last.map(opening.contains) ?? false) {
                // 開頭標點前的空白拿掉
                while output.last == " " { output.removeLast() }
                output.append(contentsOf: mark)
            }
            output.append(source[i])
            if let mark = insertAfter[i] {
                // 原文下一個非空白字本來就是標點的話，不重複加
                var k = i + 1
                while k < source.count, source[k].isWhitespace { k += 1 }
                if !(k < source.count && existingPunctuation.contains(source[k])) {
                    output.append(contentsOf: mark)
                    // 全形標點後面的空白拿掉（例如「好了， AWS」→「好了，AWS」）
                    while i + 1 < source.count, source[i + 1] == " " { i += 1 }
                }
            }
            i += 1
        }
        return String(output)
    }

    /// 用 macOS 內建的 ICU 轉換把字轉成簡體，只拿來對齊；長度不同就退回原字。
    private static func simplifiedKeys(_ chars: [Character]) -> [Character] {
        let text = String(chars)
        guard let converted = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false)
        else { return chars }
        let result = Array(converted)
        return result.count == chars.count ? result : chars
    }

    /// 逐字對齊（等同 Python difflib 的 equal 區塊，加上同長度的替換區塊）。
    /// 回傳：模型 index → 原文 index，以及哪些模型字跟原文完全一樣。
    private static func align(
        source: [Character],
        model: [Character]
    ) -> (modelToSource: [Int: Int], exact: Set<Int>) {
        let diff = model.difference(from: source)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // 沒被刪掉的原文字和沒被插入的模型字，依序一一對應（最長共同子序列）
        let keptSource = source.indices.filter { !removed.contains($0) }
        let keptModel = model.indices.filter { !inserted.contains($0) }

        var modelToSource: [Int: Int] = [:]
        var exact = Set<Int>()
        var prevSource = -1
        var prevModel = -1
        func mapGap(upToSource s: Int, model m: Int) {
            // 兩個對應點之間的空隙長度相同 → 視為同長度替換，只拿來判斷相鄰
            let sourceGap = s - prevSource - 1
            let modelGap = m - prevModel - 1
            if sourceGap > 0, sourceGap == modelGap {
                for k in 1...sourceGap { modelToSource[prevModel + k] = prevSource + k }
            }
        }
        for (s, m) in zip(keptSource, keptModel) {
            mapGap(upToSource: s, model: m)
            modelToSource[m] = s
            exact.insert(m)
            prevSource = s
            prevModel = m
        }
        mapGap(upToSource: source.count, model: model.count)
        return (modelToSource, exact)
    }
}
