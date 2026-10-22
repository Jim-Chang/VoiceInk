#!/usr/bin/env python3
"""把 TEA-ASR 的 Hugging Face 資料夾整理成 transcribe.cpp 的 Qwen3-ASR 轉檔程式吃得下的樣子。

TEA-ASR 只附 tokenizer.json(fast tokenizer)和 chat_template.jinja;
transcribe.cpp 的 scripts/convert-qwen3_asr.py 要的是 Qwen 原版的 vocab.json、merges.txt、
chat_template.json。這支程式從 tokenizer.json 拆出前兩個、把 jinja 包成 json,
其他檔案(權重、config、tokenizer_config.json…)用 symlink。

TEA 的繁體在 token 文字裡:撞名的 token 後面接了私用區字元(U+E000–U+F8FF),
原本靠 tokenizer.json 的 Replace 解碼器刪掉。GGUF 不支援這個解碼器,所以 token 照原樣寫入,
辨識結果要另外刪掉私用區字元(評測程式在讀結果時處理)。

用法:python3 -I tea_prepare.py <TEA 資料夾> <輸出資料夾>
"""
import json
import pathlib
import sys

LINKED = [
    "model.safetensors", "config.json", "preprocessor_config.json", "tokenizer_config.json",
    "generation_config.json", "special_tokens_map.json", "added_tokens.json", "tokenizer.json",
]


def main():
    src, dst = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    for name in LINKED:
        link = dst / name
        if not link.exists():
            link.symlink_to(src / name)

    tok = json.loads((src / "tokenizer.json").read_text(encoding="utf-8"))
    model = tok["model"]
    assert model["type"] == "BPE", model["type"]
    decoders = [d["type"] for d in tok["decoder"].get("decoders", [tok["decoder"]])]
    print(f"vocab {len(model['vocab'])}, merges {len(model['merges'])}, decoder {decoders}")

    (dst / "vocab.json").write_text(json.dumps(model["vocab"], ensure_ascii=False), encoding="utf-8")
    with (dst / "merges.txt").open("w", encoding="utf-8") as f:
        f.write("#version: 0.2\n")
        for merge in model["merges"]:
            pair = merge if isinstance(merge, str) else " ".join(merge)
            assert pair.count(" ") == 1, pair
            f.write(pair + "\n")
    template = (src / "chat_template.jinja").read_text(encoding="utf-8")
    (dst / "chat_template.json").write_text(json.dumps({"chat_template": template}, ensure_ascii=False),
                                            encoding="utf-8")


if __name__ == "__main__":
    main()
