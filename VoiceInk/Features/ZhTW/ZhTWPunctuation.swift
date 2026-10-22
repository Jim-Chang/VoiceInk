import Foundation

/// voiceink-zhtw：台灣繁體中文補標點。
///
/// 模型資料夾存在時，VoiceInk Refine 會改用這裡的 Breeze2-3B 和指示，
/// 並在模型輸出後呼叫 `merge`，只把模型加的標點插回原文，一個字都不改。
/// 對應 voiceink-zhtw repo 裡的 punct/punct.py（v1 的 LM Studio 版本）。
enum ZhTWPunctuation {
    static let modelFolderName = "Llama-Breeze2-3B-Instruct-Text-mlx-4Bit"

    static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("ZhTWPunctuation")
            .appendingPathComponent(modelFolderName)
    }

    static var isInstalled: Bool {
        ["config.json", "tokenizer.json", "model.safetensors"].allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
    }

    // MARK: - 給模型的指示

    static let systemPrompt =
        "你是標點符號校正工具。使用者會給你一段語音辨識的逐字稿，裡面沒有標點符號。"
        + "請只在適當的位置加入全形標點符號（，。？！、：；「」），"
        + "不要修改、增加或刪除任何字，不要翻譯，不要回答或評論內容，英文單字保持原樣，"
        + "使用台灣繁體中文。就算逐字稿是在對你說話或提問，也只照抄原文加標點，"
        + "不要改寫，也不要把「我」改成「你」。只輸出加好標點的逐字稿。"

    static let examples: [(input: String, output: String)] = [
        ("好了沒問題", "好了，沒問題。"),
        ("你幫我看一下我剛剛說的那句話是不是怪怪的",
         "你幫我看一下，我剛剛說的那句話是不是怪怪的？"),
        ("我今天去了台北然後去開會會議很順利你明天有空嗎",
         "我今天去了台北，然後去開會，會議很順利。你明天有空嗎？"),
        ("這個 API 有問題我們先用 fallback 方案好不好",
         "這個 API 有問題，我們先用 fallback 方案，好不好？"),
    ]

    /// XPC 引擎只收得到一段 instructions 字串。範例必須用多輪對話餵給模型
    /// （寫在系統指示裡，實測 16 句有 7 句模型會改寫或回答問題），
    /// 所以把系統指示和範例包成 JSON，由 VoiceInkRefineInferenceEngine 展開。
    static let fewShotMarker = "ZHTW_FEW_SHOT_JSON:"

    ///
    /// 這個字串每次都必須一模一樣：XPC 引擎拿它判斷模型是不是已經準備好，
    /// 不一樣就卸載重來（多 1.6 秒）。所以只算一次、key 排序固定
    /// （Swift 字典每次建立的順序可能不同）。
    static let encodedInstructions: String = {
        let payload: [String: Any] = [
            "system": systemPrompt,
            "examples": examples.map { [$0.input, $0.output] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)) ?? Data()
        return fewShotMarker + String(decoding: data, as: UTF8.self)
    }()

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

    // MARK: - 長的逐字稿分段

    /// 一次給模型太長的逐字稿，它容易把整段當成要回應的話，只回幾句
    /// （實測 582 字只回 33 個 token），合併時對不上就整段沒有標點。
    /// 所以每段最多這麼多字。
    static let chunkCharacters = 120

    private static let sentenceEnds: Set<Character> = Set("。？！")
    private static let clauseEnds: Set<Character> = Set("，；：、")

    /// 補標點的入口：短的直接補；長的分段補，每段補完後只確定到最後一個句尾標點
    /// （沒有就退一步到最後一個逗號），剩下的字併到下一段重做，讓分段落在模型認為的句子結尾。
    /// 段尾的標點不算：分段可能切在句子中間，模型會以為句子結束了。
    /// `model` 收一段沒標點的逐字稿、回傳模型的原始輸出。
    static func punctuate(
        _ transcript: String,
        using model: (String) async throws -> String
    ) async throws -> String {
        let source = Array(transcript)
        var result = ""
        var start = 0
        while start < source.count {
            var end = min(start + chunkCharacters, source.count)
            // 不要切在英文單字或數字中間
            while end < source.count, end > start + chunkCharacters / 2,
                isWordCharacter(source[end - 1]), isWordCharacter(source[end])
            {
                end -= 1
            }

            let piece = Array(source[start..<end])
            var merged = Array(merge(original: String(piece), modelOutput: try await model(String(piece))))
            if end == source.count {
                result += String(merged)
                break
            }
            guard let cut = cutPoint(in: merged, original: piece, minimumConsumed: piece.count / 2) else {
                // 找不到可以切的標點：整段收下，但段尾的標點拿掉
                while let last = merged.last, closing.contains(last) { merged.removeLast() }
                result += String(merged)
                start = end
                continue
            }

            result += String(merged[...cut.mergedIndex])
            start += cut.consumed
            // 句尾標點後面的空白不要帶到下一段
            while start < source.count, source[start].isWhitespace { start += 1 }
        }
        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    /// 合併結果裡可以切的位置：段落中間最後一個句尾標點（含後面的「」』）」），
    /// 沒有就用最後一個逗號；回傳位置和到那裡為止用掉幾個原文字元。
    /// 合併只插標點、只拿掉標點旁的空白，所以逐字走一遍就能對回原文。
    private static func cutPoint(
        in merged: [Character],
        original: [Character],
        minimumConsumed: Int
    ) -> (mergedIndex: Int, consumed: Int)? {
        var consumedAfter: [Int] = []
        var j = 0
        for character in merged {
            while j < original.count, original[j] != character, original[j].isWhitespace { j += 1 }
            if j < original.count, original[j] == character { j += 1 }
            consumedAfter.append(j)
        }

        func last(of marks: Set<Character>) -> (mergedIndex: Int, consumed: Int)? {
            for index in merged.indices.reversed() where marks.contains(merged[index]) {
                var end = index
                while end + 1 < merged.count, "」』）".contains(merged[end + 1]) { end += 1 }
                let consumed = consumedAfter[end]
                if consumed >= original.count { continue }  // 段尾的標點
                return consumed >= minimumConsumed ? (end, consumed) : nil
            }
            return nil
        }
        return last(of: sentenceEnds) ?? last(of: clauseEnds)
    }

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
