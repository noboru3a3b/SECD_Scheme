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
# **既存資産は §2 の凍結仕様を測るためのものではない**（26日目に変異法で測った。
# dev_memo.md §6 の決定133）。既存 .scm は値を計算して表示する筋道しか通らず、
# 処理系固有の表示形式や実数の書式にはほとんど触れない。その穴を埋めるのが
# spec_test.scm で、あちらが §2 の各行を1行ずつ写している。
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
so=$(mktemp)          # 標準出力（エラーと REPL の節で使う）
se=$(mktemp)          # 標準エラー
trap 'rm -f "$tmp" "$so" "$se"' EXIT

# scheme13 が自分で持つテスト。上の FILES と違い、これは scheme12 の出力では
# なく scheme13 の出力をゴールデンにしてある（scheme12 には lib13.scm が
# 無いので比べる相手が存在しない）。**./scheme12_debug を渡すと落ちる。**
OWN_TESTS="scheme13/tests/spec_test.scm scheme13/tests/lib13_test.scm \
           scheme13/tests/port_test.scm \
           scheme13/tests/exit_test.scm scheme13/tests/macro_print_test.scm \
           scheme13/tests/debug_test.scm"

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

# --- エラーの包み（27日目）------------------------------------------------
# scheme13/tests/errors/*.scm は「エラーを出して止まること」自体が主張なので、
# 普通のゴールデンには書けない（処理系ごと止まるため1ファイルに1つしか
# 置けない）。**標準出力・標準エラー・終了状態の3つを別々に**見る。
#
# --selftest の selftest_errors() が見ているのは e.what()、つまり**本文だけ**
# である。`Fatal error: ` の見出し・--load に渡した実際のパス・実行時エラーの
# キャレット行・終了状態が 1 であること・stderr に出て stdout には出ないこと・
# **stderr へ書く前に stdout を流す**ことは、27日目までどのテストも見ていなかった。
# 理由と各ファイルの主張は tests/errors/README.md にある。
for f in scheme13/tests/errors/*.scm; do
    base=$(basename "$f" .scm)
    g="$GOLDEN/errors/$base"
    set +e
    timeout 60 "$INTERP" --load "$f" > "$so" 2> "$se"
    got_exit=$?
    set -e
    if [ "$got_exit" = "1" ] &&
       diff -q "$g.out" "$so" > /dev/null 2>&1 &&
       diff -q "$g.err" "$se" > /dev/null 2>&1; then
        printf '  PASS  %-44s エラーの包み\n' "$f"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s (exit: want 1, got %s)\n' "$f" "$got_exit"
        diff "$g.out" "$so" | head -10 | sed 's/^/        stdout: /'
        diff "$g.err" "$se" | head -10 | sed 's/^/        stderr: /'
        fail=$((fail + 1))
    fi

    # **2つのストリームを混ぜたときの順序**。.out と .err を別々に比べても
    # 順序は現れない（別ファイルなら、どちらが先に書かれても中身は同じ）。
    # main が stderr へ書く前に stdout を流していないと、リダイレクトした
    # ときに「エラーより前の出力」がエラーの**後ろ**へ回る。27日目に変異で
    # 測って分かった穴で、.mix があるファイルだけこれを見る（決定137）。
    if [ -f "$g.mix" ]; then
        set +e
        timeout 60 "$INTERP" --load "$f" > "$so" 2>&1
        set -e
        if diff -q "$g.mix" "$so" > /dev/null 2>&1; then
            printf '  PASS  %-44s 2つのストリームの順序\n' "$f"
            pass=$((pass + 1))
        else
            printf '  FAIL  %s (stdout と stderr を混ぜたときの順序)\n' "$f"
            diff "$g.mix" "$so" | head -10 | sed 's/^/        /'
            fail=$((fail + 1))
        fi
    fi
done

# --- REPL の筋道（27日目）--------------------------------------------------
# 人が REPL を触る道筋（起動する・打つ・エラーを出す・(help) を読む・抜ける）は、
# 27日目までどのテストも通っていなかった（dev_memo §9。15日目に (exit) が
# 無いことへ14日間気づかなかったのと根が同じ）。.in を標準入力に流し込み、
# 標準出力・標準エラー・終了状態の3つを別々に見る。
#
# **プロンプトは tty かどうかを見ずに必ず出る**ので、パイプでも出力が
# 決定的になる。ここはその性質に寄りかかっている（tests/repl/README.md）。
for f in scheme13/tests/repl/*.in; do
    base=$(basename "$f" .in)
    g="$GOLDEN/repl/$base"
    set +e
    timeout 60 "$INTERP" < "$f" > "$so" 2> "$se"
    got_exit=$?
    set -e
    want_exit=$(cat "$g.exit")
    if [ "$got_exit" = "$want_exit" ] &&
       diff -q "$g.out" "$so" > /dev/null 2>&1 &&
       diff -q "$g.err" "$se" > /dev/null 2>&1; then
        printf '  PASS  %-44s REPL の筋道\n' "$f"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s (exit: want %s, got %s)\n' "$f" "$want_exit" "$got_exit"
        diff "$g.out" "$so" | head -10 | sed 's/^/        stdout: /'
        diff "$g.err" "$se" | head -10 | sed 's/^/        stderr: /'
        fail=$((fail + 1))
    fi
done

# --- コマンド行の誤り（27日目）---------------------------------------------
# 引数の誤りは stderr に出て終了状態 1。ここも通っていなかった。
check_cli() {
    want_msg=$1
    shift
    set +e
    "$INTERP" "$@" > /dev/null 2> "$se"
    got=$?
    set -e
    if [ "$got" = "1" ] && head -1 "$se" | grep -q "$want_msg"; then
        printf '  PASS  scheme13 %s\n' "$*"
        pass=$((pass + 1))
    else
        printf '  FAIL  scheme13 %s (exit %s)\n' "$*" "$got"
        sed 's/^/        /' "$se" | head -3
        fail=$((fail + 1))
    fi
}
check_cli 'unknown arg' --bogus
check_cli 'needs a path' --load

# test_improvements.scm / port_test.scm / spec_test.scm が置いていく一時ファイル
rm -f test-eof-temp.txt test-port-temp.txt test-port-temp2.txt test-port-temp3.txt \
      test-spec-temp.txt

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
