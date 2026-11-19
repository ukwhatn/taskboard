"""認識の結果の CER（文字の誤り率）を出す。
使い方: python3 -I score.py <refs.tsv> <結果.tsv>...
正解と結果を NFKC・小文字にそろえ、空白と句読点を除いた文字の編集距離を正解の字数で割る。全体の値は誤りの合計 ÷ 正解の字数の合計"""
import sys
import unicodedata

DROP = set(" 　、。，．,.?？!！・「」『』()（）:：;；\"'")


def normalize(text):
    return "".join(c for c in unicodedata.normalize("NFKC", text).lower() if c not in DROP)


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]


def read(path):
    rows = {}
    for line in open(path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            rows[parts[0]] = parts[1]
    return rows


refs = read(sys.argv[1])
for path in sys.argv[2:]:
    hyps = read(path)
    errors = total = 0
    for key, ref in sorted(refs.items()):
        r, h = normalize(ref), normalize(hyps.get(key, ""))
        errors += distance(r, h)
        total += len(r)
    print(f"{path}\t{errors / total * 100:.1f}%\t{errors}/{total}")
