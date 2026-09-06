#!/bin/sh
# SICP を教材にした scheme13 の実地確認。
#
#   usage: scheme13/sicp/run_sicp.sh [処理系のパス] [章のディレクトリ...]
#          （既定は ./scheme13/scheme13 と scheme13/sicp/ch* の全部）
#
# 各 .scm は自分で主張を数え、最後に
#     === SICP 1.1  total: 46  NG: 0 ===
# の形で締める。この行の NG が 0 で、終了状態が 0 なら合格。
#
# ゴールデン比較（tests/run_golden.sh）とは役割が違う。あちらは
# 「scheme12 と1バイトも違わないこと」を見る互換性の回帰で、こちらは
# 「教科書の題材が書き写したまま動くこと」を見る。**期待値は書籍が本文に
# 印字している数**にしてあるので、実数の演算と印字がずれれば落ちる。
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

INTERP=${1:-./scheme13/scheme13}
# shift は特殊組み込みなので、引数が無いときに叩くと dash はその場で終了する。
if [ $# -gt 0 ]; then shift; fi
if [ $# -gt 0 ]; then DIRS="$*"; else DIRS=$(ls -d scheme13/sicp/ch* 2>/dev/null); fi

if [ ! -x "$INTERP" ]; then
    echo "処理系が見つからない: $INTERP" >&2
    exit 2
fi

pass=0
fail=0
checks=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for d in $DIRS; do
    for f in "$d"/*.scm; do
        [ -e "$f" ] || continue
        set +e
        timeout 300 "$INTERP" --load "$f" > "$tmp" 2>&1
        got_exit=$?
        set -e

        # *_error.scm は「エラーで落ちること」自体が主張。scheme13 に Scheme
        # レベルの例外捕捉は無い（dev_memo §1.4-3）ので、エラーの確認だけは
        # ファイルを分けてシェル側で見るしかない。期待する文面はファイルの
        # `; expect-error: ...` 行に書いてある。
        case "$f" in
        *_error.scm)
            want=$(sed -n 's/^; expect-error: //p' "$f" | head -1)
            if [ "$got_exit" = "1" ] && grep -q "$want" "$tmp"; then
                printf '  PASS  %-44s エラーを出して止まる\n' "$f"
                pass=$((pass + 1))
                checks=$((checks + 1))
            else
                printf '  FAIL  %s (exit %s, 期待した文面: %s)\n' "$f" "$got_exit" "$want"
                fail=$((fail + 1))
            fi
            continue
            ;;
        esac

        line=$(grep '^=== SICP' "$tmp" | tail -1)
        ng=$(printf '%s' "$line" | sed -n 's/.*NG: \([0-9]*\).*/\1/p')
        total=$(printf '%s' "$line" | sed -n 's/.*total: \([0-9]*\).*/\1/p')
        if [ "$got_exit" = "0" ] && [ "$ng" = "0" ] && [ -n "$total" ]; then
            printf '  PASS  %-44s %s 項目\n' "$f" "$total"
            pass=$((pass + 1))
            checks=$((checks + total))
        else
            printf '  FAIL  %s (exit %s)\n' "$f" "$got_exit"
            sed 's/^/        /' "$tmp" | grep -E 'NG|error|Fatal' | head -20
            fail=$((fail + 1))
        fi
    done
done

echo
printf '  %d passed, %d failed  （主張 %d 件）\n' "$pass" "$fail" "$checks"
[ "$fail" = "0" ]
