# micro_Scheme8.lisp 読解メモ（原典の理解）

`scheme12_bignum_boost_debug.cpp` の出自である Common Lisp 実装
`micro_Scheme8.lisp` を読み、実際に動かして確認した記録。

**この文書の位置づけ**: scheme13 の設計判断そのものは
[`dev_memo.md`](dev_memo.md) にある。こちらは「なぜ scheme12 が今の形なのか」を
理解するための参考資料。scheme12 の不可解な部分（デッドコード、奇妙な仕様）の
多くは、原典を見ると由来が分かる。

---

## 1. 概要

| 項目 | 内容 |
| --- | --- |
| 原著者 | Makoto Hiroi（2009年、`secd.l`） |
| 改造 | okada-n（2011〜2013年。ソース中のコメントに日付つきで残っている） |
| 規模 | **545行**（scheme12 は 3552行） |
| 主題 | SECD 仮想マシンによる Scheme コンパイラ。(1)基本機能 (2)伝統的マクロ (3)継続 (4)末尾再帰最適化 |

545行で継続と末尾呼び出し最適化まで実装されている。Common Lisp のリーダ・
数値塔・シンボルプロパティリスト・`apply` をそのまま使えるため、C++ 版が
自前で書かねばならない部分の大半が不要になっている。**scheme12 の 3552行の
うち、かなりの部分はこの「借りていたもの」の再実装。**

---

## 2. 動かし方（この環境での実績）

```sh
sudo apt-get install -y sbcl        # SBCL 2.6.0.debian が入る
sbcl --script micro_Scheme8.lisp    # リポジトリのルートで実行
```

末尾の `(repl "mlib7.scm" "test-case6.scm")` により、
`mlib7.scm`（マクロ・ライブラリ）→ `test-case6.scm`（テスト）の順に読み込んでから
対話 REPL に入る。`quit` で終了。

実行結果:

```
( total: 145  pass: 145  NG: 0 )
```

---

## 3. アーキテクチャ

### 3.1 全体の流れ

```
read（CLのリーダ） → compile-expr → comp/comp-body/complis → 命令リスト → vm
```

命令列は**フラットな Lisp のリスト**。`(ldc 42 ld (0 . 1) app stop)` のように
オペコードとオペランドが一列に並び、VM は `(pop c)` で読み進める。
scheme12 の `struct Instruction` の配列とは対照的で、この違いが
`Instruction` が全フィールドを1つの構造体に詰め込む設計につながっている。

### 3.2 環境（E）

フレームのリスト。`location` が `(フレーム番号 . 変数位置)` を返す。

**可変長引数の扱いが独特**: `position-var` は、リストのドット部分
（`(x y . rest)` の `rest`）に一致したとき **負の値 `-(i+1)`** を返す。
`get-lvar` は `j` が負なら `nthcdr` で残りのリストを取り出す。

```lisp
(defun get-lvar (e i j)
  (if (<= 0 j)
      (nth j (nth i e))
      (nthcdr (- (1+ j)) (nth i e))))
```

引数はそのままリストとしてフレームになっているので、rest 引数は
「そのリストの途中から先」を返すだけでよい。**この設計だから `args` 命令が
引数をリストに固める必要があった。** scheme12 はフレームをベクタに変えた
（2026年の改善）が、`args` によるリスト化はそのまま残ったため、
「リストに固めて → ベクタに戻す」という三重変換が生まれた。

### 3.3 大域変数

シンボルのプロパティリスト `(get sym :gvar)` に直接格納。
マクロは `(macro . クロージャ)` という cons で区別する。
scheme12 の `g_globals` / `g_macros` という2つの `unordered_map` は、この
「1箇所に両方入れて car で見分ける」構造を分割したもの。

### 3.4 命令セット

| 命令 | 意味 |
| --- | --- |
| `ld` `ldc` `ldg` `ldf` | 局所変数・定数・大域変数・クロージャ の読み込み |
| `ldct` | **継続を作ってスタックに積む** |
| `args` n | スタック上の n 個をリストに固める |
| `args-ap` n | `apply` 用。末尾のリストと結合 |
| `app` `tapp` | 適用（tapp は D に退避しない） |
| `rtn` | 復帰 |
| `sel` `selr` `join` | 条件分岐（`selr` は退避しない末尾版） |
| `pop` `def` `defm` `lset` `gset` `stop` | その他 |

**`selr` は原典に最初からある。** scheme12 では長らく「未使用（将来用）」に
なっていて、2026年8月（`8d3f7a5`）にようやく末尾位置の `if` で使うよう
修正された。**原典にあった設計意図が C++ 化の過程で一度失われ、17年後に
再発見された**ことになる。

### 3.5 継続の実装 ← scheme12 の `LDCT` デッドコードの正体

原典の `call/cc` のコンパイル:

```lisp
((eq (car expr) 'call/cc)
 (list* 'ldct code 'args 1 (comp (cadr expr) env (cons 'app code) nil)))
```

つまり **`ldct` で継続を作る → `args 1` で1引数リストにする → 関数を評価 →
`app` で普通に適用する**。`call/cc` 専用の命令は存在せず、既存の命令の
組み合わせで表現している。美しい。

scheme12 はこれを専用命令 `CALLCC` / `TCALLCC` に置き換えたが、
**`LDCT` の VM 側の実装だけを消し忘れた**。これが「コンパイラが一度も
生成しない命令が VM に残っている」の正体。

### 3.6 マクロ展開は破壊的にメモ化される

```lisp
(let ((new-expr (vm ...)))
  (cond ((consp new-expr)
         (setf (car expr) (car new-expr))     ; ← 元の式を破壊的に置き換える
         (setf (cdr expr) (cdr new-expr))
         (comp expr env code nil))
        ...))
```

展開結果でソース式そのものを書き換えるので、**同じ呼び出し箇所は二度と
展開されない**（実質的なメモ化）。scheme12 は毎回展開し直す。
性能上のアイデアとして記憶しておく価値がある。

`*expr-save*` はこの仕組みの片割れである（16日目に読み直して判明）。
展開結果が**コンサでないとき**（アトムに展開されたとき）は `expr` を
その場で書き換えられないので、`comp-body` / `complis` が控えておいた
「その式を保持しているセル」の `car` を差し替える。

```lisp
(t (setf (car *expr-save*) new-expr)     ; expr がアトムに化けたとき
   (comp new-expr env code nil))
```

**エラー報告のための仕組みではない。**

---

## 4. 意味論（実測で確認）

`sbcl --script micro_Scheme8.lisp` に流して確認した。

| 式 | 原典の結果 | 備考 |
| --- | --- | --- |
| `(if nil 'y 'n)` | `NIL-IS-TRUE` | **nil は真** |
| `(if '() 'y 'n)` | `EMPTYLIST-TRUE` | 空リストも真 |
| `(if 0 'y 'n)` | `ZERO-TRUE` | 0 も真 |
| `(if false 'y 'n)` | `FALSE-IS-FALSE` | **偽なのはシンボル `false` だけ** |
| `(/ 5)` | `1/5` | **有理数**（CL の数値塔をそのまま使用）。scheme13 はエラー |
| `(/ -7 2)` | `-7/2` | 同上。scheme13 は `-3`（整数どうしは切り捨て。決定82） |
| `(modulo -7 2)` | `1` | CL の `mod` |
| `(eq? 'abc 'ABC)` | `TRUE` | **CL リーダが大文字化するので同一シンボル** |
| `(quote AbC)` | `ABC` | 同上 |
| `(display "abc")` | `abc` を出力し `:UNDEF` を返す | scheme12 は引数を返す |
| `(null? nil)` | `TRUE` | |
| `(null? false)` | `FALSE` | |

真偽値は**専用の型ではなくシンボル `true` / `false`**。VM の `sel` は
`(eq (pop s) 'false)` だけを見る。scheme12 が「`#t`/`#f` に加えて
`true`/`false`/`nil` リテラルも受け付ける」のはこの名残。

---

## 5. scheme12 が変えたもの（と、その帰結）

| 原典 | scheme12 | 帰結 |
| --- | --- | --- |
| CL のリーダ | 自前のリーダ | **シンボルが大小文字を保存するようになった**。`[` が区切り文字でないのも自前実装ゆえ |
| CL の数値塔（有理数つき、既定は single-float） | Boost `cpp_int`（整数のみ）。**scheme13 は18〜21日目に倍精度実数を足して2階建てにした** | `(/ x)` が使えない。`/` は**整数どうしなら**0方向切り捨て。**有理数の差は残る**（決定83） |
| シンボル `true`/`false` | 本物の `bool` 型 + `#t`/`#f` | リテラルは両方受け付けて互換維持 |
| プロパティリストの大域変数 | `unordered_map` 2つ | `g_globals` と `g_macros` に分裂 |
| 負インデックスによる rest 引数 | 明示的な `rest_param` + ベクタフレーム | `args` のリスト化が不要になったのに残り、三重変換になった |
| `ldct` + `args 1` + `app` | 専用命令 `CALLCC`/`TCALLCC` | `LDCT` がデッドコードとして残存 |
| CL の `apply` でプリミティブ呼出 | `std::function` + `ValueVec` | 引数を毎回ベクタに詰め直す |
| 文字列は CL の文字列、文字は CL の文字 | 文字列のみ（文字＝長さ1の文字列） | 文字型が存在しない |

---

## 6. 原典にあって scheme12 で失われたもの

**ここが今回の読解で最も価値のある発見。**

### 6.1 `test-start` / `test-end` によるテスト機構 ★重要

原典の REPL は、`*test-mode-flag*` が立っている間、**式を1つ評価するごとに
次の S 式を「期待値」として読み込み、`equal` で照合する**。

```lisp
(if *test-mode-flag*
    (let ((ans (read in nil)))
      (setq *test-count* (+ *test-count* 1))
      (cond ((equal output ans) ... "pass")
            (t ... "NG ( expected: ~S )"))))
```

だから `test-case6.scm` は次の形をしている。

```scheme
(test-start)
T

(quote a)
A          ; ← (quote a) の期待値

(if true 'a 'b)
A
```

**原典で実行すると 145 項目すべて pass する。**

scheme12 は `test-start` / `test-end` / `trace-print` / `macro-print` /
`compile-print` を**すべて `LDC true` にコンパイルする無視扱い**にしたため、
この機構が失われた。結果 `test-case6.scm` は「`--load` すると
`unbound global: A` で落ちるファイル」になっている。

> **注記**: 私は以前この状態を見て「`test-case6.scm` は参照用トランスクリプトで、
> テストランナー用の入力ではない」と判断したが、これは不正確だった。
> **原典にとっては正真正銘のテストスイート**であり、機構のほうが失われている。

**scheme13 で復活させた（2026-09-04 6日目）。** `dev_memo.md` §6 の決定29〜32。
スイッチと集計はプリミティブが持ち、照合はファイルを読み進める側が行う。
期待値の大文字問題は「**write 表現を大小文字を無視して比べる**」で解決した
（転写の意図は「表示がこうなる」なので）。結果は

    ( total: 145  pass: 132  NG: 13 )

NG 13件はすべて scheme12 が原典から意図的に変えた点の帰結
（クロージャの表示が10件、`(begin)`/`(if #f 10)` が `NIL` で2件、
`(test-start)` が `TRUE` で1件）。内訳は `tests/golden/README.md` の表にある。

### 6.2 その他

**この表は16日目に総ざらいして取り直した。** 2日目に書いた版は
`quit` が抜けており、そのせいで15日目まで `(exit)` で終われなかった
（`dev_memo.md` 決定64）。取り方は**原典の側から名前を抜いて
scheme13 の `(globals)` と `comm` で突き合わせる**（§8 にコマンド）。
文書を読み直す方式では「書かれていないもの」に気づけない。

| 失われたもの | 内容 | scheme13 の状態 |
| --- | --- | --- |
| `quit` | 自分自身に束縛された**変数**。REPL が評価結果を見て抜ける | **15日目に復活**（手続き `exit` / `quit` として。決定64〜69） |
| `macroexpand-1` / `macroexpand` | マクロ展開を Scheme 側から呼べるプリミティブ | **7日目に復活** |
| マクロ展開のメモ化 | §3.6。破壊的置き換えによる実質メモ化 | 無い（毎回展開する） |
| `print` プリミティブ | `-------------------> ~S` を出して NIL を返すデバッグ出力 | 無い |
| `system` プリミティブ | 外部コマンド実行。`(system prog arg1 (list ...))` | 無い |
| `code` 特殊形式 | 命令列を直接埋め込む。**囲みのコードは丸ごと捨てられる**（下記） | 無い |
| `macro-print` スイッチ | コンパイラが行う展開を**入れ子まで**順に見せる（下記） | **17日目に復活**（決定76〜79。`scheme13解説.md` 第11.4節） |
| `compile-print` スイッチ | REPL の入力ごとに `Compile => <命令列>` と `Value => ` を自動で出す | `(compile expr)` が後継（**都度指定**） |
| `trace-print` スイッチ | VM のステップ表示を切り替える | `trace-on` / `trace-off` が後継（**機能的に埋まっている**） |
| 有理数 | `(/ 5)` → `1/5` | 無い（`dev_memo.md` §2.3 で凍結済み。入れない） |

`*expr-save*` は「失われたもの」ではなく、メモ化の片割れである（§3.6）。

#### `code` は「埋め込む」ではなく「置き換える」

`comp` が `(cadr expr)` をそのまま返すので、**囲みのコードは捨てられる**。

```
> (display (code (ldc 99 stop)))
99                     ; display は走らない。REPL の値が 99 になる
> (display (code (ldc 99)))
ERROR: unknown opcode  ; 99 が次の命令として読まれる
```

命令セットを試すための生フックであって、利用者向けの機能ではない。

#### `macro-print` は `macroexpand` では代われない

`macroexpand` は**最外のフォームしか展開しない**（原典・scheme13 とも）。

```
scheme13> (macroexpand '(inc (inc 5)))
(+ (inc 5) 1)          ; 内側の (inc 5) は残る
```

原典の `macro-print` は**コンパイラが実際に行う展開**を入れ子まで順に見せ、
さらに完全展開後のソースも出す（メモ化の副産物。§3.6）。

```
> (macro-print)
> (display (inc (inc 5)))
Macro: (INC (INC 5))      Expand: (+ (INC 5) 1)
Macro: (INC 5)            Expand: (+ 5 1)
Expanded: (DISPLAY (+ (+ 5 1) 1))
```

scheme13 の `--expand` も代わりにならない。**評価しないので
`define-macro` が効いておらず**、利用者のマクロを知らないまま素通りする。

**17日目に `(macro-print)` として復活させた。** 名前・切り替え・返り値は
原典のまま。原典が `Macro:` / `Expand:` を出すところを `from:` / `to:` で
出し、**位置を足してある**。`Expanded:`（完全展開後のソース）は出さない。
あれはメモ化の副産物（§3.6）で、scheme13 はメモ化しないため。

---

## 7. scheme13 への示唆

1. **原典は「設計意図の参照先」として有用。** `selr` の件のように、
   C++ 化の過程で失われた意図が原典を見ると分かる。迷ったら原典を見る。
2. **`args` によるリスト化は、フレームがリストだった時代の必然だった。**
   フレームがベクタになった今、存在理由がない。`dev_memo.md` §4.1 の
   「引数をスタック上のまま渡す」方針はこの理解で裏づけられた。
3. **`call/cc` を専用命令にするか、`ldct` + `app` の組み合わせにするか**は
   設計の分かれ目。原典の方が命令セットが小さく美しいが、scheme12 の
   専用命令は末尾位置の最適化（`TCALLCC`）を素直に書ける。
   → scheme13 では専用命令を維持する方針（末尾最適化を落とせないため）。
   ただし `LDCT` は**採用しない**（デッドコードを最初から作らない）。
4. ~~**`test-start`/`test-end` の復活を検討する価値がある**~~ → **6日目に復活させた**（§6.1）。
   145項目が式ごとの主張になり、ゴールデンテストの「変わっていないこと」しか
   見ない弱さを補っている。**次に復活の候補になるのは `macroexpand-1` /
   `macroexpand`**（§6.2）。scheme13 には `expand_form_1` と
   `macro_expand_1_expr` が既にあるので、プリミティブとして出すだけで入る。
5. **545行 vs 3552行の差の大半は「CL から借りていたもの」の再実装。**
   scheme13 でもこの部分は縮まない。膨らむこと自体は問題ではなく、
   問題は「退役させなかった決定」のほう。

---

## 8. 確認に使ったコマンド

```sh
sudo apt-get install -y sbcl
echo quit | sbcl --script micro_Scheme8.lisp          # 145 pass / 0 NG を確認
sbcl --script micro_Scheme8.lisp < probe.txt          # 意味論の実測（§4）
```

**原典との差を洗う**（§6.2 はこれで取った。`dev_memo.md` 決定71）:

```sh
# 大域名（:gvar として登録されるもの）
grep -o "(setf (get '[^ ]* :gvar)" micro_Scheme8.lisp   | sed "s/.*(get '//; s/ :gvar)//" | sort -u > /tmp/orig_gvar
printf '(globals)\n' | ./scheme13/scheme13 | grep ' : ' | sed 's/ : .*//' | sort -u > /tmp/g13
comm -23 /tmp/orig_gvar /tmp/g13        # 原典にあって scheme13 に無いもの

# 特殊形式（comp が名前で分岐しているもの）
sed -n '/^(defun comp /,/^(defun /p' micro_Scheme8.lisp \
  | grep -o "(eq (car expr) '[a-z!/-]*" | sed "s/.*'//" | sort -u > /tmp/orig_sf
comm -23 /tmp/orig_sf /tmp/g13
```

**原典は `(quit)` では終われない。** `quit` は変数なので裸で `quit` と打つ。
`(quit)` は `The value QUIT is not of type LIST` で落ちる。

---

**既存の .scm に実数のリテラルが無いことを確かめる**（`dev_memo.md` 決定89。
リーダに実数を入れても既存の出力が動かないことの根拠）:

```sh
cd /workspaces/SECD_Scheme
for f in system_lib.scm mlib7.scm hashtable_lib.scm rbtree_lib_improved.scm \
         list_test1.scm test_fixes.scm test_improvements.scm test_vector_env.scm \
         rbtree_robustness_test.scm rbtree_stress_test_safe.scm performance_test.scm \
         test-case6.scm scheme13/lib13.scm scheme13/tests/*.scm; do
  # コメントと文字列リテラルを落としてから、実数に見えるトークンを探す
  sed 's/;.*//; s/"[^"]*"//g' "$f" \
    | grep -noE '(^|[^A-Za-z0-9_?!*/<>=~+-])[-+]?([0-9]+\.[0-9]*|\.[0-9]+|[0-9]+[eE][-+]?[0-9]+)|[-+](inf|nan)\.0' \
    | sed "s|^|$f:|"
done
# 出力が無ければ1つも無い（18日目の実測: 無し）
```

**整数の `/` が受け入れ基準の12件で実際に走るか**（`dev_memo.md` 決定82）:

```sh
for f in system_lib.scm mlib7.scm hashtable_lib.scm rbtree_lib_improved.scm \
         list_test1.scm test_fixes.scm test_improvements.scm test_vector_env.scm \
         rbtree_robustness_test.scm rbtree_stress_test_safe.scm performance_test.scm \
         test-case6.scm; do
  sed 's/;.*//; s/"[^"]*"//g' "$f" | grep -nE '(^|[( ])/([) ]|$)' | sed "s|^|$f:|"
done
# 18日目の実測: 4箇所だけ。うち走るのは「割り切れる2式」と「エラーになること」の確認のみ
```
