#!/bin/sh
# 構文展開（セクション7）の等価性を scheme12 と突き合わせる。
#
#   usage: scheme13/tests/compare_expand.sh
#
# 考え方: 同じフォームを
#   (a) そのまま scheme12 にコンパイルさせたもの
#   (b) scheme13 が展開した式を scheme12 にコンパイルさせたもの
# の命令列が一致すれば、展開は scheme12 と等価だと言える。
# コンパイラと VM がまだ無い段階で展開器を検証できる唯一の手段。
#
# 注意: 処理系の write 出力は再読込できない。NIL / TRUE / FALSE は自分自身に
# 読み戻らない（§2.1 の凍結仕様。'NIL' は空リストでなくシンボルとして読まれる）。
# ここでは読み戻せる綴りに書き換えてから scheme12 に渡している。そのため
# 「NIL / TRUE / FALSE という名前のシンボル」を含むフォームは扱えない。

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

S13=${1:-./scheme13/scheme13}
S12=${2:-./scheme12_debug}
FORMS=scheme13/tests/expand_forms.scm

[ -x "$S13" ] || { echo "scheme13 が見つからない: $S13" >&2; exit 2; }
[ -x "$S12" ] || { echo "scheme12 が見つからない: $S12（make -f Makefile.linux でビルドする）" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
lineno=0
while IFS= read -r line; do
    lineno=$((lineno + 1))
    case "$line" in ''|';'*) continue ;; esac

    # 1フォームずつ別プロセスで展開する（gensym の採番を scheme12 と揃えるため）
    printf '%s\n' "$line" > "$tmp/one.scm"
    expanded=$("$S13" --expand "$tmp/one.scm" |
               sed 's/\bFALSE\b/false/g; s/\bTRUE\b/true/g; s/\bNIL\b/nil/g')

    printf '(compile (quote %s))\n' "$line"     | "$S12" 2>&1 | sed '1d' > "$tmp/a.txt"
    printf '(compile (quote %s))\n' "$expanded" | "$S12" 2>&1 | sed '1d' > "$tmp/b.txt"

    if diff -q "$tmp/a.txt" "$tmp/b.txt" > /dev/null 2>&1; then
        printf '  PASS  %s\n' "$line"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$line"
        printf '        展開結果: %s\n' "$expanded"
        diff "$tmp/a.txt" "$tmp/b.txt" | head -10 | sed 's/^/        /'
        fail=$((fail + 1))
    fi
done < "$FORMS"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
