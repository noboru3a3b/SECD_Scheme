#!/bin/sh
# 既存 .scm 資産の互換性回帰テスト。
#
#   usage: scheme13/tests/run_golden.sh [処理系のパス]
#          （既定は ./scheme13/scheme13。./scheme12_debug を渡せば自己確認になる）
#
# ゴールデンは scheme12（main の 88db98b 時点）の出力。scheme13 はこれと
# バイト単位で一致しなければならない。これが「既存 .scm を無修正で動かす」
# の唯一の判定基準。
#
# 注意: 処理系は起動時に cwd から system_lib.scm を読むため、必ず
# リポジトリのルートで実行すること（このスクリプトが自分で移動する）。

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

INTERP=${1:-./scheme13/scheme13}
GOLDEN=scheme13/tests/golden

if [ ! -x "$INTERP" ]; then
    echo "処理系が見つからない: $INTERP" >&2
    exit 2
fi

FILES="system_lib.scm mlib7.scm hashtable_lib.scm rbtree_lib_improved.scm \
       list_test1.scm test_fixes.scm test_improvements.scm test_vector_env.scm \
       rbtree_robustness_test.scm rbtree_stress_test_safe.scm \
       performance_test.scm test-case6.scm"

pass=0
fail=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for f in $FILES; do
    set +e
    timeout 300 "$INTERP" --load "$f" > "$tmp" 2>&1
    got_exit=$?
    set -e
    want_exit=$(cat "$GOLDEN/$f.exit")

    if diff -q "$GOLDEN/$f.out" "$tmp" > /dev/null 2>&1 && [ "$got_exit" = "$want_exit" ]; then
        printf '  PASS  %s\n' "$f"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s (exit: want %s, got %s)\n' "$f" "$want_exit" "$got_exit"
        diff "$GOLDEN/$f.out" "$tmp" | head -20 | sed 's/^/        /'
        fail=$((fail + 1))
    fi
done

# test_improvements.scm が消し損ねる一時ファイル
rm -f test-eof-temp.txt

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
