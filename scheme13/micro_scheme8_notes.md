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

---

## 4. 意味論（実測で確認）

`sbcl --script micro_Scheme8.lisp` に流して確認した。

| 式 | 原典の結果 | 備考 |
| --- | --- | --- |
| `(if nil 'y 'n)` | `NIL-IS-TRUE` | **nil は真** |
| `(if '() 'y 'n)` | `EMPTYLIST-TRUE` | 空リストも真 |
| `(if 0 'y 'n)` | `ZERO-TRUE` | 0 も真 |
| `(if false 'y 'n)` | `FALSE-IS-FALSE` | **偽なのはシンボル `false` だけ** |
| `(/ 5)` | `1/5` | **有理数**（CL の数値塔をそのまま使用） |
| `(/ -7 2)` | `-7/2` | 同上 |
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
| CL の数値塔（有理数） | Boost `cpp_int`（整数のみ） | `(/ x)` が使えない。`/` が0方向切り捨て |
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

**scheme13 への示唆**: この機構を復活させれば、**145項目のテストが無料で手に入る**。
ゴールデンテスト（12ファイルの出力比較）は「変わっていないこと」しか見ないが、
こちらは「何が正しいか」を式ごとに主張する。価値が高い。
ただし期待値は CL リーダ前提で**大文字**（`A`）なので、大小文字を保存する
scheme13 のリーダとは食い違う。取り込むなら照合を大小文字無視にするか、
`test-case6.scm` を書き換えるかの判断が要る。→ `dev_memo.md` §9 に保留として記載。

### 6.2 その他

| 失われたもの | 内容 |
| --- | --- |
| `code` 特殊形式 | `(code <命令列>)` で命令列を直接埋め込める |
| `macroexpand-1` / `macroexpand` | マクロ展開をScheme側から呼べるプリミティブ |
| マクロ展開のメモ化 | §3.6。破壊的置き換えによる実質メモ化 |
| 有理数 | `(/ 5)` → `1/5` |
| `print` プリミティブ | `-------------------> ~S` 形式のデバッグ出力 |
| `system` プリミティブ | 外部コマンド実行 |
| `*expr-save*` | エラー時に「どの式か」を保持する仕組み（未完成に見える） |

`trace-print` / `compile-print` / `macro-print` のスイッチは、scheme12 では
`trace-on` / `trace-off` / `compile` / `disassemble` というプリミティブに
置き換わっており、こちらは**機能的に後継がある**（むしろ強化された）。

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
4. **`test-start`/`test-end` の復活を検討する価値がある**（§6.1）。
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
