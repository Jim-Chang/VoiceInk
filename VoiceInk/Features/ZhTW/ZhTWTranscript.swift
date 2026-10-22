import Foundation

/// voiceink-zhtw：辨識完、補標點之前整理文字。三個流程（聽寫、匯入音檔、在紀錄裡重新辨識）
/// 都在 `ZhTWPunctuator.punctuate` 前面呼叫。設計見 docs/plan/2026-10-22-tea-asr.md。
///
/// 1. 刪掉私用區字元（U+E000–U+F8FF）：TEA-ASR 的 tokenizer 用它們標記撞名的 token，
///    原本由 tokenizer.json 的解碼器刪掉，GGUF 不支援那個解碼器，所以 transcribe.cpp 的輸出裡會有。
/// 2. 簡體專用字轉台灣繁體（这→這）：TEA-ASR 偶爾漏出 tokenizer 沒對應到的字。
///    只轉繁體裡不會出現的字（`ZhTWSimplifiedOnly`），台、后、干、里這種不動。
/// 3. 不太會加標點的模型（TEA-ASR）：拿掉它零星的全形標點，一律交給 CT 補。
///    不然有一個句號，`ZhTWPunctuation.needsPunctuation` 就整段不補了。
enum ZhTWTranscript {
    /// 自己會加零星標點、但加得不夠的辨識模型（模型名稱，和 TranscribeCppModelCatalog 相同）
    static let modelsWithSparsePunctuation: Set<String> = ["tea-asr-1.1"]

    static func clean(_ text: String, modelName: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !(0xE000...0xF8FF).contains(scalar.value) {
            scalars.append(scalar)
        }
        var result = ""
        for character in String(scalars) {
            if modelsWithSparsePunctuation.contains(modelName), ZhTWPunctuation.punctuation.contains(character) {
                continue
            }
            result.append(simplifiedOnly[character] ?? character)
        }
        return result
    }

    // MARK: - 長音檔分段辨識（OfflineTranscribeCppService，見 docs/plan/2026-10-22-long-audio-segmentation.md）

    /// 一段碰到產生上限時，模型多半在「鬼打牆」：結尾同一個片段一直重複，最後被上限切斷。
    /// 找結尾連續重複 3 次以上的片段（1–40 字），只留一次，被切斷的半截也拿掉。
    /// 只用在碰到上限的那段，所以「對對對」這種正常說法不會進來。
    static func collapseTrailingRepetition(_ text: String) -> String {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let count = chars.count
        guard count >= minimumRepeats else { return String(chars) }

        var best: (start: Int, unit: ArraySlice<Character>)?
        var mostRemoved = 0
        for length in 1...min(maximumRepeatLength, count / minimumRepeats) {
            for tail in 0..<length {
                let end = count - tail
                let unit = chars[(end - length)..<end]
                // 被上限切斷的半截要是這個片段的開頭
                guard chars[end..<count].elementsEqual(unit.prefix(tail)) else { continue }
                var start = end - length
                var repeats = 1
                while start >= length, chars[(start - length)..<start].elementsEqual(unit) {
                    start -= length
                    repeats += 1
                }
                let removed = count - start - length
                if repeats >= minimumRepeats, removed > mostRemoved {
                    mostRemoved = removed
                    best = (start, unit)
                }
            }
        }
        guard let best else { return String(chars) }
        return String(chars[..<best.start]) + String(best.unit)
    }

    private static let minimumRepeats = 3
    private static let maximumRepeatLength = 40

    /// 分段辨識的結果接起來時，前一段結尾和下一段開頭都是英文字母或數字就要補空格，
    /// 不然會黏成「APIdeploy」。
    static func needsSpaceBetween(_ previous: String, _ next: String) -> Bool {
        guard let last = previous.last, let first = next.first else { return false }
        return isLatinLetterOrDigit(last) && isLatinLetterOrDigit(first)
    }

    private static func isLatinLetterOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private static let simplifiedOnly: [Character: Character] = {
        let chars = Array(ZhTWSimplifiedOnly.pairs)
        var table: [Character: Character] = [:]
        table.reserveCapacity(chars.count / 2)
        for index in stride(from: 0, to: chars.count - 1, by: 2) {
            table[chars[index]] = chars[index + 1]
        }
        return table
    }()
}
