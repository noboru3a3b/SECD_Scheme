#!/bin/sh
# 既存 .scm 資産の互換性回帰テスト。
#
#   usage: scheme13/tests/run_golden.sh [処理系のパス]
#          （既定は ./scheme13/scheme13）
#
# ゴールデンは scheme12（main の 88db98b 時点）の出力。scheme13 はこれと
# バイト単位で一致しなければならない。これが「既存 .scm を無修正で動かす」
# の唯一の判定基準。
#
# 例外が1件ある: test-case6.scm のゴールデンだけは scheme13 の出力で
# 採り直してある（出力が処理系自身のエラー文言だから。理由は golden/README.md）。
# そのため **./scheme12_debug を渡すと 11/12 になる**。これは正常。
#
# ゴールデンの後に、**起動時ライブラリがどこから起動しても読めること**も見る。
# 7日目まで scheme13 は実行ファイルの隣と cwd しか見ておらず、リポジトリの
# ルート以外から起動すると reverse / map / append などが黙って消えていた。

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

# scheme13 が自分で持つテスト。上の FILES と違い、これは scheme12 の出力では
# なく scheme13 の出力をゴールデンにしてある（scheme12 には lib13.scm が
# 無いので比べる相手が存在しない）。**./scheme12_debug を渡すと落ちる。**
OWN_TESTS="scheme13/tests/lib13_test.scm scheme13/tests/port_test.scm \
           scheme13/tests/exit_test.scm"

run_one() {
    f=$1
    base=$(basename "$f")
    set +e
    timeout 300 "$INTERP" --load "$f" > "$tmp" 2>&1
    got_exit=$?
    set -e
    want_exit=$(cat "$GOLDEN/$base.exit")

    if diff -q "$GOLDEN/$base.out" "$tmp" > /dev/null 2>&1 && [ "$got_exit" = "$want_exit" ]; then
        printf '  PASS  %s\n' "$f"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s (exit: want %s, got %s)\n' "$f" "$want_exit" "$got_exit"
        diff "$GOLDEN/$base.out" "$tmp" | head -20 | sed 's/^/        /'
        fail=$((fail + 1))
    fi
}

for f in $FILES $OWN_TESTS; do
    run_one "$f"
done

# --- 起動時ライブラリの探索（決定39）------------------------------------
# どの cwd から起動しても system_lib.scm が読めること。ここが壊れると
# 約60個の手続きが黙って消えるが、ゴールデンは全部ルートから走るので
# 気づけない。だから cwd を変えて確かめる。
probe=$(mktemp)
echo '(reverse (list 1 2 3))' > "$probe"
ABS_INTERP=$(cd "$(dirname "$INTERP")" && pwd)/$(basename "$INTERP")

for dir in "$ROOT" "$ROOT/scheme13" "$ROOT/scheme13/tests"; do
    set +e
    out=$(cd "$dir" && "$ABS_INTERP" --load "$probe" 2>&1)
    set -e
    if [ "$out" = "(3 2 1)" ]; then
        printf '  PASS  startup library from %s
' "${dir#"$ROOT"/}"
        pass=$((pass + 1))
    else
        printf '  FAIL  startup library from %s
' "${dir#"$ROOT"/}"
        printf '        got: %s
' "$out"
        fail=$((fail + 1))
    fi
done
rm -f "$probe"

# --- 終了コード（15日目の決定64）----------------------------------------
# (exit) が R7RS 6.14 のとおりに終了コードを決めること。ゴールデンは
# 1ファイルにつき一度しか終われないので、ここで式ごとに確かめる。
# exit_test.scm のほうは dynamic-wind との絡みを見ている。
check_exit() {
    expr=$1
    want=$2
    echo "$expr" > "$probe"
    set +e
    "$INTERP" --load "$probe" > /dev/null 2>&1
    got=$?
    set -e
    if [ "$got" = "$want" ]; then
        printf '  PASS  exit status of %s\n' "$expr"
        pass=$((pass + 1))
    else
        printf '  FAIL  exit status of %s (want %s, got %s)\n' "$expr" "$want" "$got"
        fail=$((fail + 1))
    fi
}

probe=$(mktemp)
check_exit '(exit)'    0
check_exit '(exit #t)' 0
check_exit '(exit #f)' 1
check_exit '(exit 3)'  3
check_exit '(quit)'    0
rm -f "$probe"

# test_improvements.scm と port_test.scm が置いていく一時ファイル
rm -f test-eof-temp.txt test-port-temp.txt

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
