#!/usr/bin/env python3
"""產生 VoiceInk/Features/ZhTW/ZhTWSimplifiedOnly.swift:簡體專用字 → 台灣繁體的對照表。

TEA-ASR 偶爾會漏出 tokenizer 沒對應到的簡體字(这、还、记…)。這裡只收「繁體裡不會出現的字」:
OpenCC 的 STCharacters(簡 → 繁的候選)裡,候選字不包含自己、也不是 TSCharacters 的繁體字。
台(→ 臺 檯 颱 台)、后、干、里這種繁體也會用的字不收;整段 s2tw 會把「台」轉成「臺」,所以不用。
有多個候選時取第一個(和 OpenCC 預設相同),再套 TWVariants 的台灣字形(爲 → 為)。

字典固定在 OpenCC ver.1.1.7(commit e5d6c5f,和 Homebrew 的 opencc 1.1.7 相同)。
用法:python3 -I scripts/gen-zhtw-simplified.py   (在 repo 根目錄執行,會覆寫上面那個 Swift 檔)
"""
import pathlib
import urllib.request

COMMIT = "e5d6c5f1b78e28a5797e7ad3ede3513314e544b7"
BASE = f"https://raw.githubusercontent.com/BYVoid/OpenCC/{COMMIT}/data/dictionary"
OUT = pathlib.Path(__file__).resolve().parent.parent / "VoiceInk/Features/ZhTW/ZhTWSimplifiedOnly.swift"


def load(name):
    text = urllib.request.urlopen(f"{BASE}/{name}.txt", timeout=30).read().decode("utf-8")
    table = {}
    for line in text.splitlines():
        if "\t" in line:
            key, values = line.split("\t", 1)
            table[key] = values.split()
    return table


def main():
    st, ts, tw = load("STCharacters"), load("TSCharacters"), load("TWVariants")
    pairs = {}
    for key, candidates in st.items():
        if len(key) != 1 or key in candidates or key in ts:
            continue
        target = candidates[0]
        target = tw.get(target, [target])[0]
        if len(target) == 1 and target != key:
            pairs[key] = target
    body = "".join(k + v for k, v in sorted(pairs.items()))
    OUT.write_text(
        "// 由 scripts/gen-zhtw-simplified.py 產生,不要手改。\n"
        f"// 來源:OpenCC ver.1.1.7(commit {COMMIT[:7]})的 STCharacters、TSCharacters、TWVariants。\n"
        f"// 簡體專用字 → 台灣繁體,{len(pairs)} 個,每兩個字一組。\n"
        "enum ZhTWSimplifiedOnly {\n"
        f'    static let pairs = "{body}"\n'
        "}\n",
        encoding="utf-8",
    )
    print(f"{len(pairs)} 個 → {OUT}")


if __name__ == "__main__":
    main()
