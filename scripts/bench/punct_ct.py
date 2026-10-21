#!/usr/bin/env python3
"""實驗 C:用 CT-Transformer(FunASR 的中英文標點模型,sherpa-onnx 版)補標點。

用法(要用裝了 sherpa-onnx 的 Python):
  python -I scripts/bench/punct_ct.py --model model.onnx --input rows.json --output out.json [--field simplified] [--threads 2]

輸入是 punct-tool simplify 的輸出;--field 決定給模型繁體原文(text)還是轉好的簡體(simplified)。
輸出每句加上 "model"(模型輸出)和 "seconds"(只算模型本身的時間),再交給 punct-tool merge。
"""
import argparse
import json
import time

import sherpa_onnx


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--field", default="simplified")
    parser.add_argument("--threads", type=int, default=2)
    args = parser.parse_args()

    started = time.monotonic()
    punct = sherpa_onnx.OfflinePunctuation(sherpa_onnx.OfflinePunctuationConfig(
        model=sherpa_onnx.OfflinePunctuationModelConfig(
            ct_transformer=args.model, num_threads=args.threads, provider="cpu")))
    print(f"load {time.monotonic() - started:.2f}s")

    rows = json.load(open(args.input, encoding="utf-8"))
    punct.add_punctuation(rows[0][args.field])  # 暖機
    for row in rows:
        started = time.monotonic()
        row["model"] = punct.add_punctuation(row[args.field])
        row["seconds"] = time.monotonic() - started
    json.dump(rows, open(args.output, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"{len(rows)} 段, 合計 {sum(r['seconds'] for r in rows):.2f}s")


if __name__ == "__main__":
    main()
