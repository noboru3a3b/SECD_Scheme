# scheme14 解説文書

SECD 仮想機械方式の Scheme 処理系 **scheme14** の実装解説。
この文書だけで、言語の表面と、`scheme14/scheme14.cpp` と `scheme14/lib14.scm` がどう動くかを読める。
`scheme13解説.md` は、保存してある前の版の記録である。こちらを読む前提にはしない。

対象は次である。

- `scheme14/scheme14.cpp` — コンパイラと仮想機械。単一の C++17 翻訳単位
- `scheme14/lib14.scm` — 起動時に読む Scheme ライブラリ
- リポジトリのルートにある `system_lib.scm` と `rbtree_lib_improved.scm` — 共有資産。処理系のソースではない

scheme14 は 2026-10-01 に、scheme13 の実装を引き継いで始まった。
scheme13 は scheme12 を、振る舞いを保ったまま設計を選び直した版である。
scheme14 はその成果（設計の統一、浮動小数点数、SICP のプログラムが動くこと）を外さず、
そのあと `eval`、`system`、数と文字列の基数、準クオートのネスト、例外ハンドラを足した。
共有の赤黒木には、同じ時期に文字列キーと混合キーを足した。

`scheme13/` と `scheme12_bignum_boost_debug.cpp` は保存してある。scheme14 の作業では直さない。

---

## この文書の位置づけ

| 文書 | 何が書いてあるか | 読む人 |
| --- | --- | --- |
| **この文書** | **scheme14 がどう動くか。** 実装の解説 | 使う人、読む人、直す人 |
| `dev_memo.md` | **なぜそう決めたか。** 設計憲章、凍結仕様、アーキテクチャ | 次に手を入れる人 |
| `log/decisions.md` | 判断の経緯。末尾の「続報」が 2026-10-01 以降 | 根拠を追う人。着手時の正本ではない |
| `micro_scheme8_notes.md` | 原典 `micro_Scheme8.lisp` の読解 | 由来を知りたい人 |
| `scheme13解説.md` | scheme13 の時点の説明。保存版 | 前の版を見る人 |
| `scheme12_debug解説.md` | scheme12 の説明。赤黒木の手続き一覧はここが詳しい | 共有ライブラリの来歴を見る人 |

`scheme13開発.txt` は利用者が出した作業指示の控えである。現行の仕様ではない。

判断の根拠は `dev_memo.md` にある。`eval` は §4.5、`system` は §4.6、基数は §4.7、準クオートのネストは §4.8、例外は §1.4。数の凍結仕様は §2。

振る舞いを変えたら、この文書も直す。ずれやすいのは命令一覧、プリミティブの数、テストの件数、R5RS の不足、エラーの文面である。名前と個数は第16章の `(globals)` で数え直せる。

---

## 目次

1. [全体像](#1-全体像)
2. [ビルドと起動](#2-ビルドと起動)
3. [値](#3-値)
4. [ソース位置とエラー](#4-ソース位置とエラー)
5. [例外](#5-例外)
6. [リーダ](#6-リーダ)
7. [構文展開](#7-構文展開)
8. [コンパイラと呼び出し](#8-コンパイラと呼び出し)
9. [命令](#9-命令)
10. [仮想機械と継続](#10-仮想機械と継続)
11. [`eval` と環境](#11-eval-と環境)
12. [プリミティブとライブラリ](#12-プリミティブとライブラリ)
13. [`system`](#13-system)
14. [数と文字列の基数](#14-数と文字列の基数)
15. [ポート、多値、終了](#15-ポート多値終了)
16. [REPL とデバッグ](#16-repl-とデバッグ)
17. [共有の赤黒木](#17-共有の赤黒木)
18. [テスト](#18-テスト)
19. [互換性と制限](#19-互換性と制限)

---

## 1. 全体像

### 1.1 何であるか

scheme14 は Scheme のサブセットを実行する処理系である。ソースを読み、SECD 系の仮想機械の命令列にコンパイルし、その命令列を実行する。式を評価するたびに構文を解釈し直すインタプリタではない。

```
ソース ──リーダ──> S式 ──構文展開──> S式 ──コンパイラ──> 命令列 ──仮想機械──> 値
```

原典は Common Lisp で書かれた `micro_Scheme8.lisp` である。表面の多く（`NIL` / `TRUE` / `FALSE` の表示、`/` が整数どうしなら切り捨てること、`define-macro`）はその系統を継いでいる。R5RS に寄せた部分はあるが、表面を R5RS に合わせるために既存の `.scm` を壊すことはしない。

### 1.2 何を優先するか

迷ったときの順は `dev_memo.md` §1.4 と同じである。

1. 既存の `.scm` 資産を、一字も変えずに動かす。
2. 速度。呼び出し規約は後から変えにくいので、先に決めてある。
3. ソース位置の付いたエラー。

逆アセンブル、トレース、マクロ展開の観察は後付けではない（`dev_memo.md` §1.5）。命令を変えたら逆アセンブラも直す。

依存は C++17、Boehm GC（`-lgc -lgccpp`）、Boost.Multiprecision の `cpp_int`（ヘッダのみ。リンクはしない）だけである。これ以外は足さない。

ソースは分割しない。`scheme14.cpp` を単体で渡してレビューできることを優先している。ファイルの中は次の節に分け、新しいコードは該当する節へ置く。

```
 1. 依存と GC 設定
 2. ソース位置とエラー
 3. 値モデル
 4. 表示
 5. リーダ
 6. 構文検査
 7. 構文展開
 9. 命令セット          ← ファイル上はコンパイラより前
 8. コンパイラ
10. 仮想機械
11. プリミティブ
12. 起動
```

番号 9 が 8 より前にあるのは、コンパイラが命令の定義に依存し、逆は依存しないからである。番号をファイル上の並びに直し直さない。

### 1.3 scheme12 から選び直したこと

scheme12 は動いていたが、退役していない決定が層になっていた。scheme13 でそれを外し、scheme14 はその形を継いでいる。

| scheme12 にあったもの | いま |
| --- | --- |
| コンパイラが一度も出さない命令 `LDCT` | 作らない |
| 環境フレームのベクタ表現とリスト表現が両方生きていた | 表現は一つ |
| 引数を一度リストに固め、すぐにベクタへ戻していた | 引数はスタックに積んだまま渡す |
| Scheme の文字列と、シンボル名の `std::string` が併存し、後者が回収されなかった | 文字列は `GcString` |
| 参照カウントの名残と、説明を省略した足場コメント | 無い。GC は Boehm |

呼び出し 100 万回のベンチは、scheme12 の 3334 ms に対し scheme13 の時点で 107 ms だった（別の機械での実測。`dev_memo.md` §5.3）。scheme14 でも同じ呼び出し規約である。いま測るときは `make -C scheme14 bench`。

### 1.4 起動時に読むもの

起動は次の順である。

1. 特殊形式 19 個と、プリミティブ 149 個を大域の表へ入れる。`scheme-report-environment` はこの時点ではまだ無い。
2. ルートの `system_lib.scm` を読む。
3. `scheme14/lib14.scm` を読む。
4. 読み終わった直後の大域を、報告書の環境へ写す。写しのあとで `scheme-report-environment` を対話環境と報告書の両方へ入れる。

`system_lib.scm` を先に読むのは、定義済みの名前を後の `define` が上書きしないからである。既存資産の `map` や `for-each` は、このファイルの定義が残る。`lib14.scm` が複数リスト版へ広げるときは `set!` で置き換え、1 本のときは元の手続きを内部名で呼ぶ。

探索は、実行ファイルの隣と、カレントディレクトリの両方を見る。`SCHEME14_LIB` が `system_lib.scm` のパス、`SCHEME14_LIB14` が `lib14.scm` のパスを置き換える。見つからなければ、探した場所を列挙して止まる。

---

## 2. ビルドと起動

ルートで `make` すると scheme13 がビルドされる。scheme14 は `scheme14/` で作る。

### 2.1 Linux

`scheme14/Makefile` は Windows 以外では `Makefile.linux` を読む。コンパイラは `clang++`。Boehm GC は `/usr/local` にあればそちら、無ければディストリビューションの `libgc`。Boost のヘッダは `/usr/include`。

```
make -C scheme14
./scheme14/scheme14
```

Ubuntu では `clang`、`libboost-dev`、`libgc-dev` で足りる。2026-11-01 に、この Linux で上のコマンドが通り、`(+ 10 20)` は `30` になった。

`compare` には scheme12 の実行ファイルが要る。ルートで `make -f Makefile.linux scheme12`。

### 2.2 Windows

開発に使っている環境は Windows 11 の w64devkit（MinGW の g++）と、`C:\boost_1_91_0` と、リポジトリ内の `gc-8.2.12` である。

```
make -C scheme14
.\scheme14\scheme14.exe
```

`Makefile` は `scheme14.exe` を作り、`libgc-1.dll` と `libgccpp-1.dll` をその隣へコピーする。プロンプトが何も出さずに戻るときは、この 2 つの DLL が `.exe` の隣に無い。

### 2.3 FreeBSD と NetBSD

FreeBSD では `make -C scheme14` が `Makefile.linux` を読んでしまう。Boost の場所が違うので、次を使う。

```
make -C scheme14 -f Makefile.freebsd
```

NetBSD 8 では pkgsrc の gcc 8 を使う。

```
make -C scheme14 -f Makefile.netbsd
```

どちらも、scheme14 をその機械で起動した記録はまだ無い。通ったと書かない。

### 2.4 対話

```
scheme14 debug REPL. Type (help) for commands, (exit) to quit.
scheme14> (let ((x 10) (y 20)) (+ x y))
30
scheme14> (define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
fact
scheme14> (fact 30)
265252859812191058636308480000000
scheme14> (sqrt 2)
1.4142135623730951
scheme14> (exit)
```

バッチは `--load ファイル`。標準入力へ式を流してもよい。`--selftest` は第18章。

---

## 3. 値

### 3.1 ポインタと即値

値は `ValuePtr`（`Object*`）一つである。小さい整数だけはヒープに置かず、ポインタのビット列に埋める。最下位ビットが 1 なら整数、0 ならオブジェクトである。

```cpp
enum class Tag : std::uint8_t {
    Fixnum,       // ヘッダを持たない。tag_of() だけが返す
    Nil, Boolean, Bignum, Flonum, String, Symbol, Pair, Vector,
    Closure, Continuation, Primitive, Macro, SpecialForm, Environment,
    Port, Eof, Values, ErrorObject
};
```

ヒープのオブジェクトは Boehm GC の `gc` を継承する。ヘッダは 12 バイトで、タグとソース位置（ファイル、行、列）を持つ。`nullptr` は値ではない。空リストは唯一の `g_nil` である。

64 ビットでは即値の上限は `INTPTR_MAX >> 1`（4611686018427387903）である。溢れた整数は `Bignum`（Boost の `cpp_int`）になる。演算結果が再びこの範囲へ戻ったら、必ず即値へ落とす。落とさないと、同じ数でも `eq?` が表現でぶれる。

### 3.2 型

| タグ | 内容 |
| --- | --- |
| `Fixnum` / `Bignum` | 正確な整数。利用者からは区別しない |
| `Flonum` | 不正確な実数。IEEE 754 の binary64。即値にはしない |
| `Nil` | 空リスト。表示は `NIL` |
| `Boolean` | `g_true` と `g_false`。表示は `TRUE` と `FALSE` |
| `String` | 可変のバイト列。文字型は無い。文字は長さ 1 の文字列 |
| `Symbol` | インターンする。大小文字は保存する |
| `Pair` / `Vector` | 通常のコンスとベクタ |
| `Closure` | 命令列の型紙 `Template` と、環境 |
| `Continuation` | スタック、ダンプ、環境、コードの写し |
| `Primitive` | 名前と C++ の関数ポインタ |
| `Macro` | 変換子のクロージャ |
| `SpecialForm` | `if` などの、値としての姿 |
| `Environment` | `eval` に渡す環境指定子。フレームではない |
| `Port` | `FILE*`、入出力の別、閉じたかどうか |
| `Eof` | ファイル終端 |
| `Values` | 多値の箱。値が 1 個のときは作らない |
| `ErrorObject` | 例外ハンドラへ渡す実行時エラー |

`Flonum` はポインタを持たないので、走査しないヒープから確保する。double のビット列を GC がポインタと誤解して掴み続けるのを避けるためである。

偽は `#f` だけである。`NIL` も `0` も空文字列も真である。

`eq?` と `eqv?` は同じ実装である。数は値で比べ、正確さが違えば偽である。`(eqv? 1 1.0)` は `FALSE`、`(= 1 1.0)` は `TRUE`。シンボルは名前で比べる。文字列はポインタで比べるので、`(eq? "a" "a")` は `FALSE`。

### 3.3 表示

`write` の出力は互換性の契約である。`dev_memo.md` §2.1 を変えない。

| 式 | 出力 |
| --- | --- |
| `'()` と `nil` | `NIL` |
| `#t` と `true` | `TRUE` |
| `#f` と `false` | `FALSE` |
| `'AbC` | `AbC` |
| `'(a . b)` | `(a . b)` |
| `'#(1 a "s")` | `#(1 a "s")` |
| `"hi\nthere"` | 引用符の中に、改行そのもの。`\n` とは書かない |
| `(lambda (x y) x)` | `#<closure:(x y)>` |
| `car` | `(PRIMITIVE car)` |
| `if` | `(SPECIAL-FORM if)` |
| 継続 | `#<continuation>` |
| 終端 | `#<eof>` |
| 閉じたポート | `#<closed-port>` |
| 入力ポート / 出力ポート | `#<input-port>` / `#<output-port>` |
| `(values 1 2)` | `#<values 1 2>` |
| `(interaction-environment)` | `#<environment:interaction>` |
| エラーオブジェクト | `#<error 見出しの1行目>` |

実数は、読み戻すと同じ値になる最短の形で出す。`.` も `e` も無ければ `.0` を足す。`(1.0)` は `1.0`、`(+ 0.1 0.2)` は `0.30000000000000004` のまま出す。`0.3` に丸めて見せると、表示が同じなのに等しくない、という組になる。無限大と非数は `+inf.0`、`-inf.0`、`+nan.0`。

`display` と `write` の違いは、文字列を引用符で囲むかどうかだけである。リストの要素の文字列は、`display` でも引用符付きで出る。

`NIL` / `TRUE` / `FALSE` は、リーダにとっては大文字のシンボルである。`write` の出力をそのまま読み戻すと別の値になる。数は例外で、読み戻すとビット列まで一致する。

循環は打ち切る。

```scheme
(define a (list 1 2))
(set-cdr! (cdr a) a)
(write a)    ; (1 2 . #<circular>)

(define b (list 1 2))
(set-car! b b)
(write b)    ; (( . #<circular>) 2)
```

リストの cdr 方向は再帰で辿らない。`equal?`、表示、`length`、`append` はループである。car 方向だけ再帰してよい。循環検出の集合は、いま辿っている経路だけを覚え、戻るときに自分の分を外す。外さないと、共有しているだけの構造を循環と誤る。

### 3.4 数の規則

数は正確な整数と不正確な実数の二階である。有理数と複素数は無い。

整数は表現を一つに正規化する。実数は正規化しない。`(* 2.0 3.0)` は `6.0` であり、`6` ではない。`(floor 2.5)` は `2.0` である。`make_int` の感覚で実数を整数へ落とすと、`exact?` と `eqv?` が壊れる。

- 引数に不正確が一つでもあれば、結果も不正確。`(+ 1 1.5)` は `2.5`。
- `/` は、引数がすべて正確な整数なら 0 方向へ切り捨てる。`(/ 7 2)` は `3`、`(/ 1 3)` は `0`、`(/ 7 2.0)` は `3.5`。`(/ x)` は型にかかわらずエラー。
- `modulo` の符号は除数に一致する。`(modulo -7 2)` は `1`。`remainder` の符号は被除数に一致する。`(remainder -7 2)` は `-1`。
- `modulo`、`quotient`、`remainder`、`even?`、`odd?`、添字、長さ、文字コードは正確な整数だけを受ける。`1.0` は受けない。
- NaN が混ざった比較はどれも偽である。`>=` を「`<` の否定」で書かない。
- 整数と実数の比較は、整数を倍精度へ寄せる。2^53 を超えると桁が落ちる。
- 実数の演算は例外にしない。`(/ 1.0 0.0)` は `+inf.0`、`(log 0)` は `-inf.0`、`(log -1)` は `+nan.0`。例外にするのは `sqrt` の負の引数だけで、答えが虚数だからである。

```scheme
(sqrt 16)     ; => 4          正確な平方なら正確な整数
(sqrt 2)      ; => 1.4142135623730951
(expt 2 100)  ; 正確な整数のまま
(expt 2 -3)   ; => 0.125
```

`sqrt` と `expt` は `lib14.scm` にあり、正確な道を先に試してから、内部の `%sqrt` と `%expt` へ落とす。先に実数へ渡すと、`(expt 2 100)` が倍精度に丸まる。

---

## 4. ソース位置とエラー

### 4.1 位置はオブジェクトに埋める

リーダが作ったオブジェクトのヘッダに、ファイル番号・行・列を書く。ペアから位置への副表は持たない。展開で新しく作ったリストは、元の式の位置を写す。利用者が `cons` で組んだ式は位置を持たない。

ファイルの中身は番号で引く。エラーを出すとき、その行を取り出してキャレットを置く。

### 4.2 止まったときの形

ハンドラが無いとき、実行時エラーは標準エラーへ出て、終了コード 1 で止まる。見出しは `Fatal error:` である。

```
Fatal error: <stdin:6>:1:1: car: wrong type of argument
  expected: a pair
  given: NIL
    (car '())
    ^
```

型が違うときは `expected:` と `given:`、範囲外の添字は上限、引数の個数が違うときは期待する個数を書く。文面を各プリミティブがバラバラに組み立てることはしない。入口は `prim_error`、`prim_type_error`、`prim_range_error`、`need_args` の四つである。位置はプリミティブが付けない。仮想機械が、実行中の命令の位置を後から埋める。

ライブラリの中で起きたエラーは、利用者の式の位置を指す。`lib14.scm` の行を指すと、読んだ人が直せない。この付け替えを `blame_pos` と呼ぶ。

リーダのエラー（閉じ括弧が無い、文字列が閉じていない、想定外のドット）は、実行の前に止まる。`internal error:` は処理系の不変条件が壊れたときで、利用者の式のせいではない。この二つは、第5章のハンドラがあっても止まって終了コード 1 になる。

---

## 5. 例外

2026-10-07 に入った。ハンドラが無い `error` は、今までどおり見出しを出して止まる。

```scheme
(guard (e (else 'caught))
  (car '()))
;; => caught

(with-exception-handler (lambda (e) 42)
  (lambda () (raise-continuable 'x)))
;; => 42
```

### 5.1 何がハンドラへ届くか

実行中の `error`、`(car '())`、`(/ 1 0)` のようなプリミティブの失敗は、エラーオブジェクトになる。`(raise 5)` のように、エラーオブジェクトでない値を上げることもできる。

リーダの失敗と `internal error` は届かない。コンパイルの失敗（`bad syntax` など）は、その式の実行が始まる前なので、実行中のハンドラには乗らない。`eval` に渡した式のコンパイル失敗も同じで、まだ機械へ跳んでいない。

### 5.2 箱と `dynamic-wind`

ハンドラの鎖は、一つの箱である。中身は `#f` か `(手続き . 外側)`。`with-exception-handler` は `dynamic-wind` でこの箱を付け替える。`before` で内側を押し、`after` で外側へ戻す。`call/cc` で外へ抜けると、内側の `after` が内側から走る。継続がハンドラの鎖を別にコピーして持つことはしない。

`raise` は、呼ぶ前に箱を外側へ戻してからハンドラを呼ぶ。ハンドラの中の `raise` が自分へ戻らないようにするためである。ハンドラが普通に戻ったときは、失敗した式の続きは走らない。代わりに `exception handler returned` を外側へ上げる。外側も無ければ、そこで止まる。

`raise-continuable` は、ハンドラの戻り値を、上げた式の値として返す。複数の値もそのまま返す。戻ったあと、箱を内側のハンドラへ戻す。

`guard` はマクロである。節の形は `cond` と同じで、`else` も書ける。どの節にも合わなければ、同じオブジェクトを `raise-continuable` で外側へ渡す。本体が成功したときは、その値（複数ならその全部）が `guard` の値になる。継続は `with-exception-handler` に入る前に取り、ハンドラはそこへ跳んで条件節を走らせる。

### 5.3 エラーオブジェクト

`(error-object? e)` が真なら、実行時エラーである。`(error-object-message e)` は見出しと `given:` の行を返す。ソース位置とキャレットはこの文字列には入らない。`write` すると `#<error 見出しの1行目>` になる。

C++ 側では、捕捉できる失敗は `SchemeError` の `catchable` が真である。仮想機械はそれをエラーオブジェクトにして、箱の先頭の手続きへ渡す。箱が空なら、今までどおり表示して止まる。`%abort-exception` は箱が尽きたあとの停止で、もう一度ハンドラへは行かない。

`%current-exception-handler`、`%set-exception-handler!`、`%make-error-object`、`%abort-exception` は内部名である。利用者のプログラムは `with-exception-handler`、`raise`、`raise-continuable`、`guard`、`error-object?`、`error-object-message` を使う。

---

## 6. リーダ

区切りは空白、括弧、`"`、`;`、`'`、`` ` ``、`,` である。角括弧は区切りではない。

| 入力 | 値 |
| --- | --- |
| `123`、`-4` | 正確な整数 |
| `1.5`、`1e21`、`+inf.0`、`+nan.0` | 不正確な実数 |
| `"abc"` | 文字列。エスケープは `\\` と `\"` だけ |
| `foo`、`AbC` | シンボル。大小文字を保存する |
| `#t` `#f` `#true` `#false`、および小文字の `nil` `true` `false` | 真偽と空リスト |
| `'x` | `(quote x)` |
| `` `x `` | `(quasiquote x)` |
| `,x` | `(unquote x)` |
| `,@x` | `(splice x)` |
| `#(1 2)` | ベクタ |
| `;` から行末 | コメント |

`#b` `#o` `#x` `#e` `#i` は数の接頭辞にしない。`#xff` はシンボルとして読まれ、評価すると `unbound variable: #xff` になる。16 進が欲しいときは `(string->number "xff" 16)` と書く。

ドット対は `(a . b)`。ドットの位置が違えばリーダが止まる。ファイルの途中でリストが閉じなければ `unexpected EOF in list`。文字列、ベクタ、引用の略記にも、それぞれの EOF がある。

位置はトークンの先頭である。式のエラーが指す行と列は、ここから来る。

---

## 7. 構文展開

特殊形式のうち、仮想機械が直接実行するものと、展開してからコンパイルするものがある。展開されるのは `let`、`let*`、`letrec`、名前つき `let`、`and`、`or`、`cond`、`case`、`do`、`quasiquote` である。

`let` は `((lambda (変数 ...) 本体) 初期値 ...)` になる。`let*` は `let` の入れ子、`letrec` は初期値を `:undef` にしてから `set!` する形になる。`and` と `or` は `if` と `let` になる。`cond` は `if` になり、`=>` 節も受ける。`case` は `eqv?` の比較、`do` は名前つき `let` になる。

展開の結果は、元の式のソース位置を持つ。マクロの変換子が返した式も、呼び出しの位置を写してから、もう一度展開する。

### 7.1 内部 `define`

`lambda`、`let`、`let*`、`letrec` の本体の先頭に連続して並ぶ `define` だけを、コンパイルの前に一つの `letrec` へまとめる。式より後ろの `define`、マクロが生成した `define`、本体先頭の `(begin (define ...) ...)` は、この書き換えに入らない。対話環境では大域定義としてコンパイルされる。

先頭を `letrec` にまとめるので、その補助手続きは大域の表を汚さない。空の環境の `eval` でも、この内部 `define` は動く。対話環境以外で大域の `define` をコンパイルすると `bad syntax` になる。

### 7.2 準クオート

リーダは変えない。`,@` が読まれる名前は `splice` のままである。手書きの `unquote-splicing` は認めない。

ネストが無いときは、これまでどおり `cons` と `append` と `(quote ...)` へ展開する。`` `(a ,x) `` は、`x` を評価して `a` と `cons` する。`` `(a ,@xs) `` は `append` で継ぐ。`` `#(1 ,x) `` はベクタになる。`` `(,k . ,v) `` はドット対になる。`` `(a . ,@v) `` は `bad syntax in quasiquote` で止まる。

2026-10-04 以降、バッククオートはネストする。カンマは、同じ深さのバッククオートだけを打ち消す。外側を 1 段目とする。

```scheme
(let ((x 'foo))
  `(a `(b ,,x)))
;; => (a (quasiquote (b (unquote foo))))

(let ((name1 'x) (name2 'y))
  `(a `(b ,,name1 ,',name2 d) e))
;; => (a (quasiquote (b (unquote x) (unquote (quote y)) d)) e)
```

表示は略記に戻さない。上の値は `` `(b ,foo) `` ではなく `(quasiquote (b (unquote foo)))` と出る。`quote` はカンマを止めない。

2 段目のカンマが一つのときは、変数を評価しない。内側のバッククオートとカンマがシンボルのまま残る。カンマが二つあるときだけ、1 段目の式の値が入る。カンマアットは、その深さが有効なときだけリストを継ぐ。深い位置のカンマアットは、`splice` というリストのまま残る。

`` `(a `(b . ,@x)) `` は止まらない。内側に `(splice x)` を残す。`(unquote a b)` のように引数が 1 個でないものは、どの深さでも `expected: (unquote expression)` で止まる。カンマがバッククオートより多い `` `,,x `` は、展開では止まらない。余った `(unquote x)` を式として置くので、実行したときに `unquote` を評価する。

深さ 1 の展開結果（`cons` / `append` / `quote` の形）は、ネストを足す前と同じである。scheme12 との展開比較が、この形を見ている。

### 7.3 マクロ

`define-macro` は変換子を大域のマクロ表へ入れる。変換子は普通の Scheme の手続きで、引数は評価される前の式である。展開はコンパイルの前に、マクロ名が無くなるまで繰り返す。

`(macroexpand-1 式)` は 1 段、`(macroexpand 式)` はマクロが無くなるまで展開する。`(macro-print 式)` は、その途中を表示する。

変換子の中の代入は、そのマクロを定義したときに焼き込まれたセルを書く。`eval` が別の環境でマクロを展開しても、変換子をコンパイルし直さない。`syntax-rules` は無い。

---

## 8. コンパイラと呼び出し

コンパイル環境は、字句的なフレームの列である。名前は、内側から `(フレームの段数 . その中の番号)` になる。大域は名前ではなく、大域セルへのポインタを命令に焼く。実行時にハッシュ表を引き直さない。

未束縛の大域を参照すると、対話環境ではその場で空のセルを表へ作る。あとから `define` が同じセルを埋める。`eval` が対話環境以外を渡したときは、セルを命令のオペランドにはするが、表には入れない。入れると、拒否した定義の入れ物になる。

呼び出しの規約は次のとおりである。

- 引数は左から評価し、スタックに積んだまま渡す。リストに固めない。
- 演算子は引数のあとで評価する。
- 末尾呼び出しは、自分のスタックの床まで捨ててから跳ぶ。ダンプは積まない。
- `let` のように、作ってすぐ呼んで捨てるクロージャは確保しない。仮想機械が一つ持っているスクラッチを書き換える。逆アセンブルには `[no-alloc]` と出る。外へ返るクロージャには印を付けない。

スクラッチは Scheme の値ではない。`LDF` と、それを消費する `APP` のあいだでは何も走らないので、継続がそれを捕まえることはない。

`(define 名前 式)` の値は、そのシンボルである。`(set! 変数 式)` の値は、代入した値である。

---

## 9. 命令

21 個ある。全部をコンパイラが生成し、仮想機械が実行する。使わない命令は置かない。

| 命令 | 動作 |
| --- | --- |
| `LD (n . i)` | n 段外のフレームの i 番目を積む |
| `LDC v` | 定数 v を積む |
| `LDG cell` | 大域セルの値を積む。未束縛ならエラー |
| `LDF tmpl` | クロージャを作って積む。印があれば確保しない |
| `APP n` | スタック上の n 引数と演算子で呼ぶ。戻り先をダンプへ積む |
| `TAPP n` | 同上。末尾なのでダンプは積まず、自分の床まで捨てる |
| `ARGS-AP n` | `apply` 用。n 個の値と末尾のリストを一つの引数列にする |
| `APPLY` / `TAPPLY` | `(apply f args)` を呼ぶ。後者は末尾 |
| `RTN` | ダンプを一段戻す |
| `SEL` / `SELR` | 真偽で枝を選ぶ。`SELR` は末尾で、戻り先を積まない |
| `JOIN` | `SEL` の枝の終わり |
| `POP` | スタックの先頭を捨てる。`begin` の途中の値 |
| `DEF cell` / `DEFM cell` | 大域、またはマクロとして束縛する。シンボル名を返す |
| `LSET (n . i)` / `GSET cell` | 局所、または大域へ代入する。代入した値を返す |
| `CALLCC` / `TCALLCC` | 継続を作り、引数の手続きへ渡す |
| `STOP` | 実行を終える。スタックの先頭が値 |

`eval` が走らせる命令列は `RTN` で終わる。`STOP` は機械の実行全体を戻すので、そこには使わない。

逆アセンブルは枝とクロージャの本体を字下げして見せる。

```
scheme14> (disassemble (lambda (n) (let ((a n)) (lambda () a))))

=== Disassembly ===
Parameters: (n)
Body:
[0] LD (0 . 0)
[1] LDF (a) [no-alloc]
      body:
        [0] LDF ()
              body:
                [0] LD (1 . 0)
                [1] RTN
        [1] RTN
[2] TAPP 1
[3] RTN
Environment: 0 frame(s)
===================
:disassembled
```

`[1]` の `LDF (a)` が `let` の lambda で、印が付いている。中の `LDF ()` は外へ返るので確保する。

命令を足すときは、`Op`、`op_name`、逆アセンブラ、コンパイラ、仮想機械、`dev_memo.md` §4.4 の表を同じときに直す。

---

## 10. 仮想機械と継続

機械の状態はスタック、環境、ダンプ、実行中のコードとプログラムカウンタである。環境はフレームの連結リストである。フレームは Scheme のベクタではなく、`Env` の末尾に値を並べた配列で、呼び出しのたびに一つ確保する。

`call/cc` は、スタックとダンプと環境とコードを継続オブジェクトへ写す。継続を起動すると、その写しへ戻る。多ショットである。一度使うと消える継続にはしない。

`dynamic-wind` の枠は、機械が別に持っている鎖である。継続で枠の内側と外側をまたぐとき、出る側の `after` を内側から、入る側の `before` を外側から実行する。この巻き戻しは、その場で組んだ短い命令列で行う。

`(exit)` は、外へ出る `after` を先に走らせてからプロセスを終える。`after` の中で継続を使って別の場所へ跳んだら、終了は成立しない。跳んだ先が、終了よりあとで決まった行き先だからである。

プリミティブの引数ベクタは、スタック上の区間を指している。プリミティブはその配列を書き換えず、呼び出しが戻ったあとも保持しない。

`eval` は、登録上はプリミティブだが、値を返してから呼んだ側へ戻る経路には入らない。第11章で、同じ機械へ跳ぶ。

---

## 11. `eval` と環境

R5RS 6.5 の四つの手続きである。どれも手続きで、`(procedure? eval)` は `TRUE`。特殊形式にはしていない。

```scheme
(eval '(+ 1 2) (interaction-environment))   ; => 3
```

第 1 引数はすでにデータである式、第 2 引数は環境指定子である。フレーム（呼び出しの局所変数の並び）は値にしない。環境指定子は大域の表を指す別の値で、次の三つだけがある。同じ手続きを 2 回呼んだ結果は `eq?` で真。互いに比べると偽。`read` では作れない。

| 式 | 出力 |
| --- | --- |
| `(interaction-environment)` | `#<environment:interaction>` |
| `(scheme-report-environment 5)` | `#<environment:scheme-report>` |
| `(null-environment 5)` | `#<environment:null>` |

引数は整数 `5` だけを受け付ける。それ以外の整数は `argument out of range`、整数でないものは `wrong type of argument`。

### 11.1 三つの表

対話環境は、REPL と `load` が使っている大域の表そのものである。ここへの `define` と `set!` は、対話で束縛したのと同じセルを書く。

報告書の環境は、起動時ライブラリを読み終わった直後の写しである。セルは別物で、中の手続きオブジェクトは共有する。あとから対話環境で `define` したり、初期手続きを `set!` したりしても、写しの側は動かない。写しは起動の最後に 1 回だけ作る。最初に `scheme-report-environment` が呼ばれるまで遅らせると、その前にした利用者の定義が写しに混ざる。読み込み中にこの手続きを呼ぶと、未束縛になる。写しが終わったあとで、この手続き自身を対話環境と報告書の両方へ入れる。

空の環境には、組み込みの特殊形式と、シンボル `:undef` だけを写す。`+` も利用者の定義も無い。`:undef` を写すのは、`letrec` と `cond` の展開がこの大域を読むからである。無いと、空の環境での内部 `define` が `unbound variable: :undef` になる。

```scheme
(eval '(+ 1 2) (scheme-report-environment 5))   ; => 3
(eval '(+ 1 2) (null-environment 5))            ; unbound variable: +
(eval '((lambda (x) x) 7) (null-environment 5)) ; => 7
(eval 'if (null-environment 5))                 ; 特殊形式 if
```

### 11.2 式は呼び出した機械の上で走る

`eval` は式を、いま動いているのと同じ仮想機械で実行する。別の機械は立てない。

コンパイルは空のコンパイル環境で行う。式は、`eval` を呼んだ手続きの局所変数を見ない。

```scheme
(define x 2)
(let ((x 1))
  (eval 'x (interaction-environment)))   ; => 2
```

`x` は大域の `2` である。`let` の `1` は見えない。

組み込みの特殊形式は、どの環境でも、コンパイラが名前を見て先に判定する。`(let ((if list)) (if 1))` は `if` 式のままである。利用者のマクロは、その評価に渡した環境の表だけを見て展開する。対話環境で定義したマクロは、対話環境の `eval` では展開され、空の環境では展開されない。組み込みの `let` や `cond` の展開は、表を見ない。

本体の命令列は `RTN` で終わる。引数を確かめて式をコンパイルし、クロージャを呼ぶときと同じ栈で、その命令列へ跳ぶ。末尾でなければ、戻り先をダンプに積み、スタックを引数の位置まで縮め、フレームを空にしてから跳ぶ。末尾ならダンプは積まず、いまの呼び出しの床まで縮める。`RTN` が結果を一つ残す。この位置がずれると、呼び出し元のスタックが壊れる。

登録上はプリミティブだが、機械は `eval` を見つけると、普通のプリミティブ呼び出しには入れない。値を返してから跳ぶ実装に戻すと、上の栈が合わなくなる。

コンパイルが失敗したときは、まだ跳んでいない。エラーはそのまま出る。対話環境では、失敗するまでに作った未束縛のセルが表に残ることがある。`load` や REPL も同じなので、`eval` だけでは片付けない。

### 11.3 継続

式は呼び出し元と同じ機械で走るので、式の中の `call/cc` は `eval` の呼び出し元まで含む。

```scheme
(call/cc (lambda (k)
           (eval (list k 9) (interaction-environment))))   ; => 9
```

`(list k 9)` のデータには、継続オブジェクトそのものが入っている。リーダは継続を作れない。コンパイラは、式の中に現れた原子を定数として積む。

```scheme
(call/cc (lambda (kk)
           (eval '(kk 9) (interaction-environment))))
```

こちらはシンボル `kk` を対話環境で引く。その `lambda` の継続にはならない。

式の中で捕まえた継続を、`eval` が戻ったあとから起動すると、その式の続きへ戻り、結果は `eval` の呼び出し元へ届く。`dynamic-wind` の入れ子も、機械が 1 本のまま見る。`(eval '(exit 0) ...)` は、いまの `exit` と同じくプロセスを終える。

別の機械のままにしているものは二つある。マクロ変換子と `load` である。`load` が読む各式は、ロード側の実行である。どちらも、`eval` に渡した式の規則ではない。

### 11.4 定義と未束縛

大域の `define`、`define-macro`、大域への `set!` を受け付けるのは対話環境だけである。報告書や空の環境でコンパイルすると `bad syntax` になり、`note` は `accepted only in the interaction environment` と出る。

`lambda` の本体の先頭にある内部 `define` は、コンパイルの前に `letrec` へ書き換わる。局所変数への `set!` も、大域の表を書かない。どちらも環境指定子を書き換えないので、空の環境でも動く。

```scheme
(eval '(begin (define zz 4) zz) (interaction-environment))  ; => 4
(eval '(define zz 4) (null-environment 5))                  ; bad syntax
```

未束縛の名前は、実行がそこへ到達したときに `unbound variable` で止まる。到達しなければ止まらない。`(if #f 無い名前 1)` は `1` である。

対話環境では、参照をコンパイルした時点でセルを表へ作る。先に使う定義が、これで後から埋まる。

```scheme
(eval '(define (f) later) (interaction-environment))
(eval '(define later 8) (interaction-environment))
(eval '(f) (interaction-environment))   ; => 8
```

### 11.5 エラー

第 2 引数が環境指定子でなければ `eval: wrong type of argument`、`expected: an environment`。引数が 2 個でなければ `wrong number of arguments`。

式の中で起きたエラーの見出しは、その式を直に評価したときと同じである。`eval:` では包まない。ソース位置を持つ式は、そこを指す。`cons` で組んだ式は位置を持たないので、機械が `eval` を呼んだ位置を貼る。

---

## 12. プリミティブとライブラリ

2026-10-07 の時点で、大域名は 290、プリミティブは 150、`lib14.scm` の `define` は 78、マクロは `guard` の一つである。`(globals)` の `(PRIMITIVE ...)` を数えた。プリミティブ 150 には、起動の最後に入る `scheme-report-environment` を含む。静的な表は 149 である。

数え直すときは、処理系を起動して `(globals)` を見る。ソース側は `init_globals` の `table[]` と、そのあとの `freeze_environments` である。

名前の一覧はあとの表にある。先に、対話で使うときの読み方を書く。

### 12.1 手続きと特殊形式

プリミティブは、C++ で実装された手続きである。`car` を表示すると `(PRIMITIVE car)` と出る。`(procedure? car)` は `TRUE`。

特殊形式は、引数を評価する前に処理系が特別扱いする名前である。`if` を表示すると `(SPECIAL-FORM if)` と出る。`(procedure? if)` は `FALSE`。`if` の条件が偽の側は評価されない。手続きには、この「評価しない」が無い。

```scheme
(if #f (car '()) 1)    ; => 1 。(car '()) は走らない
```

プリミティブの引数は、呼び出しの前にすべて評価される。`(car '())` は、`car` に空リストが渡ってから止まる。

自分で書いた `(define (f x) ...)` も手続きである。表示は `#<closure:(x)>` のようになり、プリミティブとは別の型である。呼び出し方は同じで、`(f 1)` と書く。

エラーは、止まった手続きの名前から始まる。次は「`car` の引数の型が違う。ペアを期待した。渡されたのは空リスト」と読む。

```
car: wrong type of argument
  expected: a pair
  given: NIL
```

`expected:` が期待、`given:` が実際に渡った値である。行の下の `^` は、ソースのどこかを指す。

### 12.2 よく使う手続き

#### リスト

リストは、空リストで終わるペアの連なりである。空リストの表示は `NIL` で、`'()` と同じ値である。

```scheme
(cons 1 '())           ; => (1)
(cons 1 2)             ; => (1 . 2)   ドット対。リストではない
(list 1 2 3)           ; => (1 2 3)
(car '(1 2 3))         ; => 1         先頭
(cdr '(1 2 3))         ; => (2 3)     残り
(append '(1 2) '(3))   ; => (1 2 3)
(null? '())            ; => TRUE
(pair? '(1))           ; => TRUE
(length '(1 2 3))      ; => 3
```

`(car '())` と `(cdr '())` はエラーになる。先に `null?` か `pair?` で見る。

`cons` の第 2 引数がリストなら、結果もリストになる。第 2 引数がリストでなければドット対になる。`(cons 1 2)` の `cdr` は `2` であり、`(2)` ではない。

`set-car!` と `set-cdr!` は、いまあるペアの中身を書き換える。返り値は代入した値で、新しいリストは返さない。書き換えたペアを、別の変数が共有していれば、そちらからも見える。

#### 比較

`equal?` は中身を見る。リストや文字列の比較はこれを使う。`eq?` と `eqv?` は同じ実装で、リストと文字列は「同じオブジェクトか」を見る。別々に書いた `'(1 2)` は、中身が同じでも `eq?` では偽になる。

```scheme
(equal? '(1 2) '(1 2))   ; => TRUE
(eq? '(1 2) '(1 2))      ; => FALSE
(eq? "a" "a")            ; => FALSE
(equal? "a" "a")         ; => TRUE
(= 1 1.0)                ; => TRUE    数の大きさ
(eqv? 1 1.0)             ; => FALSE   正確さが違う
```

`<` `>` `<=` `>=` `=` は数に使う。`+nan.0` が混ざった比較は、どれも `FALSE` になる。`(>= +nan.0 1)` も偽なので、「以上」を「より小さいの否定」で書かない。

`memq` と `assq` は、要素を `eqv?` で探す。数は値で一致する。文字列やリストを探すときは `member` と `assoc`（`lib14.scm`）を使う。これらは `equal?` で探す。

#### 数

`+` `-` `*` は引数を何個でも取れる。`(+)` は `0`、`(*)` は `1`。`(- 10 3 1)` は左から引き、`6` になる。

`/` は、引数がすべて正確な整数なら、0 方向へ切り捨てる。小数が欲しいときは、どれか一つを実数にする。

```scheme
(/ 7 2)       ; => 3
(/ 7 2.0)     ; => 3.5
(/ 1 3)       ; => 0
(+ 1 1.5)     ; => 2.5
(sqrt 16)     ; => 4       正確な平方は正確な整数
(sqrt 2)      ; => 1.4142135623730951
```

`(/ 1 0)` は `division by zero` で止まる。`(/ 1.0 0.0)` は止まらず `+inf.0` になる。`quotient`、`remainder`、`modulo` は正確な整数だけを受ける。`1.0` を渡すと型のエラーになる。

`exact?` が真なら正確な整数、`inexact?` が真なら実数である。`(exact->inexact 2)` は `2.0`、`(inexact->exact 2.0)` は `2`。小数部がある実数を正確な整数へは変換できない。

`zero?`、`abs`、`max`、`min`、`gcd`、`even?` は `lib14.scm` の手続きである。プリミティブではないが、起動した直後から使える。

#### 真偽

偽は `#f` だけである。表示は `FALSE`。`NIL` も `0` も `""` も真なので、`if` の条件にリストを置くと、空リストでも「真」の側へ進む。

```scheme
(if '() 'yes 'no)    ; => yes
(not #f)             ; => TRUE
(not 0)              ; => FALSE
```

`#t` と `true` はどちらも真、`#f` と `false` はどちらも偽である。大文字の `TRUE` と `NIL` は、リーダにとってはシンボルである。対話で `#f` や `#t` と書く。

#### 文字列と文字

文字型は無い。1 文字は、長さ 1 の文字列である。

```scheme
(string-length "abc")     ; => 3
(string-ref "abc" 1)      ; => "b"    番号は 0 から
(string-append "a" "b")   ; => "ab"
(substring "abcd" 1 3)    ; => "bc"   終わりの番号は含まない
(string=? "a" "a")        ; => TRUE
(integer->char 65)        ; => "A"
(char->integer "A")       ; => 65
(symbol->string 'AbC)     ; => "AbC"  大小文字はそのまま
(string->symbol "AbC")    ; => AbC
```

`string-length` はバイト数である。`"あ"` は 3 を返す。`char?` が真になるのは、長さ 1 の文字列だけである。

`string-set!` は、すでにある文字列の 1 バイトを書き換える。引数の文字は長さ 1 の文字列で渡し、返り値は `:undef` である。

`number->string` と `string->number` の基数は第14章にある。引数が 1 個なら 10 進である。

#### ベクタ

ベクタは、番号で要素を取り出す並びである。リストと違い、先頭以外も同じ手間で読める。

```scheme
(define v (vector 'a 'b 'c))
(vector-ref v 0)          ; => a
(vector-set! v 1 'z)      ; 書き換え。返り値は :undef
(vector-length v)         ; => 3
(vector->list v)          ; => (a z c)
```

`make-vector` は長さと、埋める値を取る。`(make-vector 3 0)` は `#(0 0 0)`。長さが負なら `argument out of range` になる。`vector-ref` と `string-ref` で、番号が長さ以上または負なら `index out of range` になる。

#### 定義と代入

`define` と `set!` と `lambda` は手続きではない。特殊形式である。

```scheme
(define x 1)          ; 値はシンボル x
(set! x 2)            ; 値は 2
((lambda (n) (+ n 1)) 10)   ; => 11
```

`set!` は、すでに定義された変数を書き換える。無い名前へ `set!` するとエラーになる。`define` を局所定義として書けるのは、手続き本体の先頭に連続して並ぶときだけである。それより後ろに書いた `define` は構文エラーにはならず、対話環境では大域定義になる。

### 12.3 特殊形式（19）

```
quote  if  lambda  define  define-macro  set!
call/cc  call-with-current-continuation  apply  begin
let  let*  letrec  and  or  cond  case  do  quasiquote
```

値としては特殊形式オブジェクトである。`(procedure? call/cc)` は `FALSE`、`(procedure? car)` は `TRUE`。`apply` も特殊形式である。`(apply system (list "git" "status"))` のように、最後の引数はリストである。

`guard` は特殊形式ではない。`lib14.scm` のマクロである。

### 12.4 プリミティブ一覧

```cpp
using PrimitiveFn = ValuePtr (*)(ValuePtr* argv, std::size_t argc);
```

`argv` は仮想機械のスタック上の区間である。書き換えても、保持してもいけない。

| 分類 | 名前 |
| --- | --- |
| 算術 | `+` `-` `*` `/` `quotient` `remainder` `modulo` |
| 比較 | `=` `<` `>` `<=` `>=` |
| 正確さ | `exact?` `inexact?` `integer?` `rational?` `real?` `complex?` `exact->inexact` `inexact->exact` |
| 丸め | `floor` `ceiling` `truncate` `round` |
| 超越関数 | `%sqrt` `%expt` `exp` `log` `sin` `cos` `tan` `asin` `acos` `atan` |
| ペアとリスト | `cons` `car` `cdr` `set-car!` `set-cdr!` `caar` `cadr` `cdar` `cddr` `caddr` `cdddr` `list` `length` `append` `list?` `memq` `memv` `assq` |
| 述語 | `eq?` `eqv?` `equal?` `null?` `pair?` `atom?` `number?` `string?` `symbol?` `vector?` `boolean?` `procedure?` `eof-object?` `not` |
| 文字列 | `string-length` `string-ref` `string-set!` `make-string` `string-append` `substring` `string=?` `string<?` `string>?` `string<=?` `string>=?` `char->integer` `integer->char` `string->list` `list->string` `symbol->string` `string->symbol` `number->string` `string->number` |
| ベクタ | `make-vector` `vector` `vector-length` `vector-ref` `vector-set!` `vector->list` `list->vector` |
| 入出力 | `display` `write` `newline` `write_newline` `write-char` `open-input-file` `open-output-file` `close-input-port` `close-output-port` `read` `read-char` `peek-char` `char-ready?` `read-line` `read-expr` `current-input-port` `current-output-port` `%set-current-input-port!` `%set-current-output-port!` `input-port?` `output-port?` `load` `system` |
| 多値と dynamic-wind | `values` `%values->list` `%wind-push` `%wind-pop` `%wind-top-after` |
| 例外の内部 | `error` `%exit` `%current-exception-handler` `%set-exception-handler!` `%make-error-object` `%abort-exception` `error-object?` `error-object-message` |
| その他 | `gensym` `random` `random-seed` `gc-collect` `gc-heap-size` `gc-free-bytes` |
| テスト | `test-start` `test-end` |
| デバッグ | `compile` `disassemble` `trace-on` `trace-off` `macro-print` `globals` `macros` `help` `macroexpand-1` `macroexpand` |
| 評価 | `eval` `interaction-environment` `null-environment` `scheme-report-environment` |

`write_newline` は scheme12 が残していた名前で、`newline` の別名である。`memv` は `memq` と同じ実装で、数はポインタではなく値で比べる。`%sqrt` と `%expt` は `lib14.scm` の `sqrt` と `expt` が使う。`rational?` は正確な整数なら真、実数なら偽である。有理数型は無い。`complex?` は実数に対して R5RS が定める範囲で答え、虚部を持つ数は作れない。

定義域の外の実数関数は例外にしない。`(log 0)` は `-inf.0`、`(asin 2)` は `+nan.0`。

`number->string` と `string->number` の基数は第14章、`system` は第13章、`eval` は第11章である。

プリミティブを足すときは、セクション 11 に関数を書き、`need_args` と型の入口を使い、`table[]` に名前を足し、`--selftest` に項目を足す。Scheme で書けるものは `lib14.scm` に書く。

### 12.5 `system_lib.scm`

scheme12 と共有している。scheme14 では編集しない。`map`、`filter`、`for-each`、`fold-left`、`fold-right`、`reverse`、遅延評価（`delay` と `force`）、キュー、素数の試し割りなどが入っている。`define` は 34、マクロは `delay` の一つだが、`cdddr` と `memv` はプリミティブが先に定義してあるので読み飛ばされ、実際に増えるのは 33 である。

コメントには、C++ の `map` を上書きして `call/cc` を通す、と書いてある。いまの `table[]` にそのプリミティブは無い。コメントはより古い版の事情である。C++ のループでコールバックを呼ぶと、継続が C のスタックを飛び越えられない。これらをプリミティブに戻すときは、その点を思い出して Scheme 側に残す。

### 12.6 `lib14.scm`

入れる基準は「R5RS にあって、まだ無いもの」である。`sort` や `reduce` のような非標準の便利手続きは入れない。例外は二つで、どちらも理由が別にある。`exit` と `quit` は、原典にあった `quit` を戻したものである。`with-exception-handler`、`raise`、`raise-continuable`、`guard` は、ライブラリの `error` を呼び出し元が受けて続行できるようにするためのものである。

| 分類 | 名前 |
| --- | --- |
| 数値述語 | `zero?` `positive?` `negative?` `even?` `odd?` |
| 算術 | `abs` `max` `min` `gcd` `lcm` `expt` `sqrt` |
| リスト | `list-tail` `list-ref` `member` `assoc` |
| c…r の 4 段（16） | `caaaar` `caaadr` `caadar` `caaddr` `cadaar` `cadadr` `caddar` `cadddr` `cdaaar` `cdaadr` `cdadar` `cdaddr` `cddaar` `cddadr` `cdddar` `cddddr` |
| 文字列とベクタ | `string` `string-copy` `string-fill!` `vector-fill!` |
| 文字（18） | `char?` `char=?` `char<?` `char>?` `char<=?` `char>=?` `char-ci=?` `char-ci<?` `char-ci>?` `char-ci<=?` `char-ci>=?` `char-upcase` `char-downcase` `char-alphabetic?` `char-numeric?` `char-whitespace?` `char-upper-case?` `char-lower-case?` |
| 大小文字を無視する文字列比較 | `string-ci=?` `string-ci<?` `string-ci>?` `string-ci<=?` `string-ci>=?` |
| 多値と dynamic-wind | `call-with-values` `dynamic-wind` |
| ファイル | `call-with-input-file` `call-with-output-file` `with-input-from-file` `with-output-to-file` |
| 終了 | `exit` `quit` |
| 例外 | `with-exception-handler` `raise` `raise-continuable`。マクロ `guard` |
| 内部 | `%isqrt` `%list-tail-checked` `%map-1` `%map-n` `%any-null?` `%for-each-1` `%for-each-n` `%string-downcase` |

文字は長さ 1 の文字列である。18 個の文字手続きは、長さの検査を `char->integer` に預ける。`char?` だけは自分で「長さ 1 の文字列か」を見る。大小文字と文字種は ASCII だけを見る。`string-length` はバイト数を返すので、`(string-length "あ")` は 3 であり、この処理系で文字と呼べるのは 1 バイトのものだけである。

`map` と `for-each` は、引数が 1 本のとき `system_lib.scm` の手続きを呼ぶ。2 本以上のときは `lib14.scm` の手続きが、最短のリストで止まる。

`%` で始まる名前は、利用者が呼ぶものではない。

---

## 13. `system`

2026-10-02 に入った。プログラム名と引数の列で子プロセスを起動し、終了コードの整数を返す。`(procedure? system)` は `TRUE`。

```scheme
(system "git" "status")
(system "git")
```

第 1 引数はプログラム名、第 2 引数以降はそのプログラムの引数である。すべて文字列で、第 1 引数は必須、以降は何個でもよい。

引数はデータである。`&&` や `|` や引用符を、この手続きはシェルの文法として解釈しない。実行されるプログラムは第 1 引数だけである。`(system "echo" "a && rm x")` は、`echo` にその文字列を 1 引数として渡す。

原典は Common Lisp の `run-program` に合わせ、引数を一つと残りのリストとに分けていた。Scheme では残りの引数をそのまま並べる。

### 13.1 OS の差は、この手続きの中だけにある

プログラム名と引数の列でプロセスを起動する関数は、C++17 の標準には無い。Windows のビルドと、Linux および Unix のビルドとで、起動処理はコンパイル時にどちらか一方だけが残る。Scheme のプログラムが OS の名前を見て分岐する手続きは足さない。

- Linux と Unix では `posix_spawnp` で PATH を探し、`waitpid` で待つ。`fork` は使わない。この処理系は Boehm GC を使っていて、`fork` した子が GC のロックを抱えたままになることがある。
- Windows では `CreateProcess` で起動し、終了を待つ。プログラム名は `open-input-file` と同じバイト列で渡す。この処理系の中でワイド文字列へ変換しない。ディレクトリ区切りの無い名前は PATH から探し、拡張子が無ければ `.exe` を補う。引数の列は、Windows がコマンドラインを引数へ戻すときの規則で、この手続きが引用符を付けてから渡す。空の引数と、空白かタブを含む引数は二重引用符で囲む。引用符の直前にあるバックスラッシュは、引用符と合わせて倍にする。利用者が OS ごとに引用符を書くことはない。

新しいライブラリは足さない。`posix_spawnp` は libc、`CreateProcess` は Windows のビルドが既にリンクしている範囲である。`char-ready?` が POSIX と Windows で本体を分けているのと同じ置き方である。

標準 C の `system` にコマンドライン文字列を一つ渡す形にはしない。Windows の C ライブラリはその文字列を `cmd.exe` に、Unix の C ライブラリは `sh` に渡す。同じ式が、ビルド先で別の言語になる。

### 13.2 入出力と戻り値

子プロセスには、scheme14 自身が OS から受け取った標準入力・標準出力・標準エラーを継がせる。出力は端末へそのまま出る。Scheme の `current-output-port` には従わない。

```scheme
(with-output-to-file "out"
  (lambda () (system "echo" "hi")))
```

この式は、ファイル `out` に `hi` を書かない。

`system` は子が終わるまで戻らない。裏で走らせる引数は無い。出力を文字列として返す引数も無い。中身を Scheme で読むときは、シェルにファイルへ書かせてから `open-input-file` で開く。

```scheme
(define read1
  (lambda (path)
    (let* ((p (open-input-file path))
           (line (read-line p)))
      (close-input-port p)
      line)))
```

戻り値は終了コードの整数である。`0` が成功。POSIX でプロセスがシグナルで終わったときは、`128` にそのシグナル番号を足した値を返す。Windows の終了コードは、255 を超えていても切らずに整数のまま返す。

起動できなかったとき（プログラムが無い、など）は終了コードを返さない。`system: cannot run program` とし、`given:` にプログラム名を書く。見出しの形は `open-input-file` がファイルを開けなかったときと同じである。

引数が 0 個なら `system: wrong number of arguments`。文字列でない引数は `system: wrong type of argument`、`expected: a string`。

子の中で作業ディレクトリを変えても、その子が終わると変更は残らない。scheme14 自身の作業ディレクトリは動かない。

### 13.3 シェルの文法が要るとき

`cd` や `>` や `&&` や `|` は、プログラムの引数にはならない。使うときだけ、シェルを第 1 引数にし、スクリプト全体をその次の 1 文字列にする。

- Windows では `(system "cmd.exe" "/c" "スクリプト")`。
- Linux と Unix では `(system "sh" "-c" "スクリプト")`。

`(system "echo" "a > note.txt")` は、`echo` に `a > note.txt` という文字列を 1 引数で渡す。ファイルはできない。

空白を含むパスは、その 1 個の文字列の中に空白を書く。OS に渡すための引用符を、文字列の中へ足すことはない。

```scheme
(system "git" "diff" "--" "my file.scm")
```

`>` は、そのリダイレクトが付いているコマンドを実行するときの作業ディレクトリから解決される。`cd` のあとの `>` は、移動した先からの相対パスになる。

### 13.4 Linux と Unix

この節の式は、2026-10-03 に Linux で実行し、下の結果になった。子の表示は端末へ出る。`system` の値は終了コードだけである。

`ls`、`mkdir`、`cp`、`mv`、`rm`、`cat`、`grep` は実行ファイルなので、第 1 引数にその名前を書く。PATH から探す。`/bin/ls` のように区切りを含む名前は、そのパスをそのまま使う。

```scheme
(system "mkdir" "work")
(system "mkdir" "work/sub")
(system "mkdir" "work/my files")
(system "sh" "-c" "echo hello from system > work/note.txt")
(read1 "work/note.txt")                                          ; => "hello from system"
(system "ls" "-l" "work")                                        ; 端末に一覧が出て、値は 0
(system "cat" "work/note.txt")                                   ; 端末に中身が出て、値は 0
(system "grep" "hello from" "work/note.txt")                     ; 見つかれば 0
(system "sh" "-c" "cd work/sub && pwd > ../cwd.txt")
(read1 "work/cwd.txt")                                           ; 行末は "/sub"
(system "cp" "work/note.txt" "work/note-copy.txt")
(system "mv" "work/note-copy.txt" "work/sub/moved.txt")
(read1 "work/sub/moved.txt")                                     ; => "hello from system"
(system "rm" "work/note.txt")
(system "sh" "-c" "echo spaced > 'work/my files/inside.txt'")
(read1 "work/my files/inside.txt")                               ; => "spaced"
(system "true")                                                  ; => 0
(system "sh" "-c" "exit 7")                                      ; => 7
(system "sh" "-c" "kill -TERM $$")                               ; => 143
(system "scheme14-no-such-program")                              ; system: cannot run program
(system "ls" "no-such-dir")                                      ; => 2
```

`SIGTERM` の番号は 15 なので、`128 + 15` で 143 になる。起動できたあとにコマンドが失敗したときは、エラーにせず終了コードを返す。この Linux の `ls` は、無いパスに対して 2 を返した。

`sh` はスクリプトの中の引用符を自分で読む。空白のあるパスへ書くときは、その引用符をスクリプトの 1 文字列の中に置く。

### 13.5 Windows

第 1 引数は実行ファイルの名前である。`where.exe` や `git.exe` はディスク上のプログラムなので、名前をそのまま第 1 引数にする。`mkdir` や `dir`、`type`、`copy`、`move`、`del`、`echo`、`cd` は `cmd.exe` が自分の中に持っているコマンドである。`C:\Windows\System32` に `mkdir.exe` は無い。第 1 引数は `"cmd.exe"`、第 2 引数は `"/c"` にする。

```scheme
(system "where.exe" "cmd")
(system "cmd.exe" "/c" "mkdir" "work")
(system "cmd.exe" "/c" "echo hello from system>work\\note.txt")
(read1 "work/note.txt")                                          ; => "hello from system"
```

拡張子の無い名前は、ディレクトリ区切りが無ければ `.exe` を補って PATH から探す。`(system "where" "cmd")` は `where.exe` を探す。`mkdir` には補う先が無い。

`cmd.exe` は、引用符の外にある `/` をスイッチとして読む。`cmd.exe` へ渡す経路の区切りは `\` にする。Scheme の `open-input-file` は、同じファイルを `/` 区切りでも開けた。

`dir /b work > work\listing.txt` のように `>` を解釈させるときは、1 文字列にする。引数を `"dir"` `"/b"` `"work"` と分けない。

```scheme
(system "cmd.exe" "/c" "dir /b work > work\\listing.txt")
(system "cmd.exe" "/c" "cd /d work\\sub && cd > ..\\cwd.txt")
(read1 "work/cwd.txt")                                           ; 行末は "\sub"
(system "cmd.exe" "/c" "exit" "7")                               ; => 7
(system "scheme14-no-such-program")                              ; system: cannot run program
```

2026-10-02 に、`scheme14/tests/system_win_test.scm` がこの一連（ディレクトリの作成、書き込み、読み戻し、コピー、移動、削除、空白を含む名前、終了コード）を通し、`*** ALL SYSTEM CHECKS PASSED ***` になった。子のメッセージは端末へ出る。このスクリプトは OS の表示に依存するので、ゴールデンには入れていない。

`cmd /c` に渡す 1 文字列の中へ、空白のあるパスを引用符付きで書くと、cmd が引用符を剥がす規則と、この手続きが引用符を付ける規則が重なる。空白のあるパスへ書くときは、一度空白の無い名前で書いてから `move` する。

---

## 14. 数と文字列の基数

2026-10-03 に、`number->string` と `string->number` が第 2 引数の基数を受けるようになった。ソースに直接書ける数は 10 進のままである。機械の中の値は正確な整数で、何進かは、文字列に出すときと文字列から読むときにだけ付く。

```scheme
(number->string 255)       ; => "255"
(number->string 255 16)    ; => "ff"
(string->number "ff" 16)   ; => 255
(string->number "1.5")     ; => 1.5
```

引数が 1 個のときと、基数が 10 のときは、これまでの 10 進の経路を使う。`number->string` は `write` と同じ表示、`string->number` はリーダと同じ読み取りである。実数、`+inf.0`、`+nan.0` も読む。

基数は正確な整数で、2、8、10、16 のいずれかである。2、8、16 の対象は正確な整数だけである。

```scheme
(number->string 255 16)        ; => "ff"
(number->string 255 8)         ; => "377"
(number->string 255 2)         ; => "11111111"
(number->string -255 16)       ; => "-ff"
(number->string 0 2)           ; => "0"
(string->number "FF" 16)       ; => 255
(string->number "+10" 16)      ; => 16
(string->number "-0" 16)       ; => 0
(string->number "00ff" 16)     ; => 255
```

出力に `#x` や `#b` は付けない。16 進の `a` から `f` は小文字である。負なら先頭に `-` を付ける。正に `+` は付けない。余分な先頭の 0 は付けない。0 は `"0"` である。桁数の上限は置かない。

読み取りは、文字列全体が「符号が任意で一つ、その後にその基数の数字が一つ以上」のときだけ正確な整数を返す。空白、小数点、指数、`#` で始まる接頭辞は受けない。形が外れたらエラーにせず `false` を返す。

```scheme
(string->number "1.5" 16)      ; => false
(string->number "#xff" 16)     ; => false
(string->number "ff" 2)        ; => false
```

正確な整数 `n` と基数 `r`（2、8、10、16）について、`(eqv? n (string->number (number->string n r) r))` は真である。

個数は 1 個または 2 個である。0 個や 3 個以上は `wrong number of arguments`、`expected: 1 to 2 arguments`。基数の検査は、第 1 引数が手続きの求める型だと分かったあとで行う。数でないものを `number->string` に渡すと `expected: a number`、文字列でないものを `string->number` に渡すと `expected: a string`。基数そのものが正確な整数でなければ `expected: an integer`。`16.0` はここである。正確な整数だが 2、8、10、16 のどれでもなければ `argument out of range`、`expected: 2, 8, 10, or 16`。基数が 2、8、16 で、変換する数が正確な整数でなければ `expected: an exact integer`。

2、8、16 で不正確な数も出す形、リーダに `#xff` を足す形、2、8、10、16 以外の基数、大文字での出力、`#x` を付ける出力は採っていない。往復で戻る文字列を一つに決めるためである。

---

## 15. ポート、多値、終了

### 15.1 ポート

ファイルポートは `fopen` の `FILE*` を持つ。作る経路は `make_port` だけである。GC が回収するときに閉じるため、作った直後にファイナライザを登録する。`gc` を継承しただけではデストラクタは呼ばれない。開こうとして `EMFILE` か `ENFILE` になったときは、GC とファイナライザを走らせてから 1 回だけ開き直す。

標準入力と標準出力は、起動時に作ったポートオブジェクトである。`with-input-from-file` と `with-output-to-file` は、このオブジェクトを指す変数を差し替える。戻すのは `dynamic-wind` の `after` である。差し替えの個数をライブラリが自分で数えることはしない。

継続で外へ跳んだとき、ファイルポートは閉じない。R5RS はその点を処理系依存としている。閉じる約束は足していない。標準ポートを戻すのは `dynamic-wind` である。

`read` が引数無しで読む相手は、いまの入力ポートである。`display` と `write` と `newline` の出力先は、いまの出力ポートである。`system` の子プロセスだけは、このポートを見ない。第13章のとおり、OS の標準ストリームを継ぐ。

`char-ready?` の本体は、POSIX と Windows でコンパイル時に分かれる。

Windows の標準出力はテキストモードで、改行は CRLF になる。ゴールデンも CRLF で採ってある。

### 15.2 多値

`(values 1 2 3)` は 3 個の値を返す。受け手が `call-with-values` で無いとき、REPL は `#<values 1 2 3>` と表示する。値が 1 個のときは箱を作らず、普通の値として返す。`(values)` は 0 個である。

`call-with-values` は `lib14.scm` にある。生成側が返した値の個数と、受け手が受け取る引数の個数が違うときは、引数の個数のエラーになる。

### 15.3 `exit` と `quit`

`(exit)` と `(exit 0)` と `(exit #t)` は終了コード 0、`(exit #f)` は 1、`(exit n)` は整数 `n` の下位 8 ビットである。親プロセスに届くのが下位 8 ビットだから、C++ 側で先に畳む。`(quit)` は `exit` の別名である。

原典の `quit` は、評価結果がシンボル `quit` かどうかで REPL が抜ける変数だった。それを戻すと `(display 'quit)` まで終了の合図になるので、手続きにしてある。

`exit` は、外へ出る `dynamic-wind` の `after` を内側から順に呼んでから `%exit` する。`%wind-pop` を `after` より先に呼ぶ。`after` の中からまた `exit` しても、同じ枠を二度巻き戻さない。

---

## 16. REPL とデバッグ

対話は、式を読んで結果を表示することを繰り返す。最初に `(help)` と打つと、デバッグのコマンド一覧と、数や文字についての注意が英語で出る。この章は、そのコマンドをどの順で使うかを書く。

```
scheme14> (+ 1 2)
3
scheme14> (car 5)
Error: <stdin:2>:1:1: car: wrong type of argument
  expected: a pair
  given: 5
    (car 5)
    ^
```

エラーが出ても対話は終わらない。次の式を打てる。`<stdin:2>` の `2` は、対話で読んだ式の通し番号である。`^` は、その式のどこで止まったかを指す。

抜けるのは `(exit)`、`(quit)`、入力の終わり（端末では Ctrl-D）である。Ctrl-D のときだけ `Bye!` が出て、終了コードは 0 になる。`(exit 1)` は何も表示せず、終了コード 1 で終わる。

括弧が閉じていない行は、続きを待つ。ファイルをまとめて実行するときは `scheme14 --load ファイル` である。

| 見たいもの | 使うコマンド |
| --- | --- |
| 名前が定義されているか | `(globals)` と `(macros)` |
| マクロや `let` がどの式になるか | `(macroexpand-1 ...)`、入れ子まで見るなら `(macro-print)` |
| 式がどの命令になるか | `(compile '式)` |
| すでに定義した手続きの中身 | `(disassemble 手続き)` |
| 命令がどの順で、スタックがどう変わるか | `(trace-on)` |
| ファイルを評価せず、読んだ形だけ | `scheme14 --read ファイル` |
| ファイルを評価せず、組み込みの展開だけ | `scheme14 --expand ファイル` |

### 16.1 名前を探す

`(globals)` は大域の名前と値を、名前の順に出す。手続きの中身は出さず、`#<closure>` とだけ書く。プリミティブは `(PRIMITIVE 名前)`、特殊形式は `(SPECIAL-FORM 名前)` と出る。値はシンボル `:globals-listed` である。一覧そのものが値になるわけではない。

`(macros)` は、マクロとして定義された名前だけを出す。起動時にあるのは `delay` と `guard` である。自分で `define-macro` した名前もここへ出る。`let` や `cond` は特殊形式なので、`(macros)` には出ない。

`unbound variable` で止まったときは、綴りを `(globals)` の出力で確認する。大小文字は区別する。`Car` と `car` は別の名前である。

### 16.2 展開を見る

`let` や `cond` やマクロは、命令になる前に別の式へ書き換わる。書き換えを見る道具が三つある。どれも「引数は評価される」ので、式そのものを渡すときはクオートする。クオートしないと、先に計算した結果が渡る。

`(macroexpand-1 '式)` は、一番外側を 1 回だけ書き換える。内側には降りない。

```scheme
(define-macro (inc x) (list '+ x 1))
(macroexpand-1 '(inc (inc 5)))    ; => (+ (inc 5) 1)
(macroexpand '(inc (inc 5)))      ; => (+ (inc 5) 1)  同じ
```

`(macroexpand '式)` は、一番外側が変わらなくなるまで繰り返す。上の例では 1 回で外側が `+` になるので、内側の `(inc 5)` は残る。内側まで見たいときは、残った式をもう一度渡すか、次の `(macro-print)` を使う。1000 回書き換え続けても止まらなければ、`expansion did not terminate` で止まる。自分を自分へ展開するマクロを見つけるためである。

`(macro-print)` は引数を取らない。呼ぶたびに、表示のオンとオフが入れ替わる。オンのあいだに評価した式について、コンパイラが実際に行った書き換えを、入れ子も含めて出す。

```
scheme14> (define-macro (inc x) (list '+ x 1))
inc
scheme14> (macro-print)
Macro expansion trace: ON
TRUE
scheme14> (let ((a (inc 3))) a)

==== Expand (special form) <stdin:3>:1:1 ====
from: (let ((a (inc 3))) a)
  to: ((lambda (a) a) (inc 3))

==== Expand (macro) <stdin:3>:1:10 ====
from: (inc 3)
  to: (+ 3 1)
4
scheme14> (macro-print)
Macro expansion trace: OFF
FALSE
```

`(special form)` は `let` や `cond` などの組み込み、`(macro)` は `define-macro` で定義したものである。出る順序はコンパイルの順序である。上の例では、先に `let` が `lambda` になり、そのあと引数の `(inc 3)` が展開される。見出しの位置は、エラーのときと同じく「ファイル、行、列」である。

`(macroexpand ...)` の値は展開後の式である。画面に説明を出したいだけで、式の値としては使わないなら `(macro-print)` のほうが、内側まで一度に見える。

`--expand` は、この二つとは別である。ファイルを評価しないので、そのファイルの中で `define-macro` したマクロは知らない。見えるのは `let` や `cond` のような組み込みの展開だけである。利用者のマクロを見るときは、対話で定義してから `(macro-print)` するか、`--load` する。

### 16.3 命令列を見る

`(compile '式)` は、式をコンパイルして命令を表示する。値はシンボル `:compiled` で、表示はその前に標準出力へ出る。クオートを忘れると、式の結果をコンパイルしようとする。`(+ 1 2)` の結果は数の `3` なので、`(compile (+ 1 2))` が見せるのは「定数 3 を積んで止まる」命令列である。

```
scheme14> (compile '(let ((x 10) (y 20)) (+ x y)))

=== Compiled Code ===
[0] LDC 10
[1] LDC 20
[2] LDF (x y) [no-alloc]
      body:
        [0] LD (0 . 0)
        [1] LD (0 . 1)
        [2] LDG +
        [3] TAPP 2
        [4] RTN
[3] APP 2
[4] STOP
=====================
:compiled
```

番号は、その命令列の中の位置である。この例は次の順で動く。

1. `LDC 10` と `LDC 20` が、定数をスタックへ積む。
2. `LDF (x y)` が、仮引数 `x` と `y` を持つ手続きを作る。`[no-alloc]` は、この手続きがすぐ呼ばれて捨てられるので、新しいクロージャを確保しない、という印である。`let` はそうなる。
3. 字下げされた `body:` が、その手続きの中身である。`LD (0 . 0)` はいまのフレームの 0 番、つまり `x`。`LD (0 . 1)` は `y`。`LDG +` は大域の `+`。`TAPP 2` は、引数 2 個で `+` を末尾呼び出しする。
4. 外側の `APP 2` が、その手続きを引数 2 個で呼ぶ。`STOP` で対話へ戻る。

命令の意味の一覧は第9章にある。ここでは「定数を積む `LDC`、変数を取る `LD` と `LDG`、呼ぶ `APP` と末尾の `TAPP`、終わる `RTN` と `STOP`」が分かれば読める。

`(disassemble 手続き)` は、すでに定義された手続きの中身を見る。`(compile ...)` が「この式をいまコンパイルするとどうなるか」なのに対し、こちらは「このクロージャが持っている命令」である。マクロを渡すと、変換子の手続きを逆アセンブルする。手続きでもマクロでもなければ `Not a closure or macro:` と出て、値は `:not-disassemblable` になる。

```scheme
(define (add2 n) (let ((a n)) (lambda () a)))
(disassemble add2)
```

`Parameters:` が仮引数、`Environment:` がその手続きが捕まえた外側のフレームの数である。大域で定義した直後の `add2` は、外側のフレームを持たないので `0 frame(s)` になる。

### 16.4 1 命令ずつ見る

`(trace-on)` は、このあと実行する命令ごとに、プログラムカウンタ、命令、スタック、環境、ダンプを出す。出力量が多いので、短い式で使う。

```
scheme14> (trace-on)
Trace mode: ON
:trace-on
scheme14> (+ 2 3)

==== Step 0 ====
PC: 0
Instruction: LDC 2
Stack: (empty)
Environment: (empty)
Dump: 0 frame(s)

==== Step 1 ====
PC: 1
Instruction: LDC 3
Stack:
  [0] 2
Environment: (empty)
Dump: 0 frame(s)

==== Step 2 ====
PC: 2
Instruction: LDG +
Stack:
  [0] 3
  [1] 2
Environment: (empty)
Dump: 0 frame(s)

==== Step 3 ====
PC: 3
Instruction: APP 2
Stack:
  [0] (PRIMITIVE +)
  [1] 3
  [2] 2
Environment: (empty)
Dump: 0 frame(s)

==== Step 4 ====
PC: 4
Instruction: STOP
Stack:
  [0] 5
Environment: (empty)
Dump: 0 frame(s)
5
```

読み方は次のとおりである。

- `PC` は、これから実行する命令の番号である。`(compile ...)` の `[0]` や `[1]` と同じ番号になる。Step 0 の命令は `LDC 2` で、スタックはまだ空である。
- `Stack` の `[0]` が先頭、つまり最後に積んだ値である。表示されているのは、その命令を実行する前の状態である。`LDC 2` の結果は次の Step に出て、`[0]` が `2` になる。`LDC 3` のあとの Step では `[0]` が `3`、`[1]` が `2` になる。
- `APP 2` の直前には、演算子が `[0]`、その下に引数が積まれている。
- `Environment` は、局所変数のフレームが何段あるかである。この例は大域の式なので空である。手続きの中に入ると `1 frame(s)` のように増える。
- `Dump` は、呼び出しの戻り先が何段積んであるかである。末尾呼び出しでは、ここを増やさない。

`(trace-off)` も一つの式なので、オフにする命令自体はトレースに混ざる。`Trace mode: OFF` と値 `:trace-off` が出れば切れている。`(trace-on)` を実行している途中でフラグが立つので、その式の最後の `STOP` が一歩だけトレースされることがある。次の式からが、見たい本体である。

### 16.5 ファイルを評価せずに見る

```
scheme14 --read ファイル      読んだ S 式を表示して終わる
scheme14 --expand ファイル    組み込みの特殊形式を展開して表示して終わる
scheme14 --load ファイル      評価して終わる
scheme14 --selftest           処理系自身の検査
scheme14 --help               起動オプションの説明
```

`--read` はリーダの結果だけを見る。マクロもコンパイルも走らない。`'x` が `(quote x)` になっているか、数や文字列がどう読まれたかを確認するときに使う。

`--expand` は、評価しない展開である。`define-macro` は実行されないので、自分で定義したマクロは展開されない。`let` が `lambda` になっているかを、ファイル単位で見るときに使う。

`--load` は対話と同じ評価をする。ファイルの中に `(trace-on)` や `(macro-print)` を書いておけば、そのファイルの実行を追える。

### 16.6 どれから使うか

止まった理由が「名前が無い」「引数の型が違う」なら、エラーの `expected:` と `(globals)` で足りる。式の形が怪しいときは `(macroexpand-1 ...)` か `(macro-print)`。命令に落ちたあとの動きが怪しいときは `(compile '式)` を見て、それでも追えない短い式だけ `(trace-on)` する。定義済みの手続きの中を直接見るときは `(disassemble 手続き)` である。

---

## 17. 共有の赤黒木

`rbtree_lib_improved.scm` はリポジトリのルートにあり、scheme12、scheme13、scheme14 が同じファイルを読む。処理系のソースには入っていない。手続きの細目は `scheme12_debug解説.md` の赤黒木の節にある。ここには、scheme14 から使うときの形を書く。

ノードを直接いじる `rb-insert` などは、今までどおり数のキーである。返った根を、次の呼び出しに渡す。ハッシュ表はこの形を使う。

文字列、または数と文字列を一つの木に入れるときは、ハンドルを作る。比較関数は木が持つ。`123` と `"123"` は別のキーである。混合の木では、数をすべて文字列より前に置く。

```scheme
(load "rbtree_lib_improved.scm")

(define s (rb-new-string))
(rb-db-insert s "10" "ten")
(rb-db-insert s "2" "two")
(rb-db-to-list s)          ; => ("10" "2")

(define m (rb-new-mixed))
(rb-db-insert m 123 "num")
(rb-db-insert m "123" "str")
(rb-db-search m 123)       ; => "num"
(rb-db-search m "123")     ; => "str"
```

`rbtree_key_test.scm` で確認した混合の並びは `(3 20 100 123 "100" "123" "20" "3")` である。数の木に文字列を入れると、木を書く前に `error` を呼ぶ。文字列の木に数を入れるとき、混合の木にシンボルを入れるときも同じである。scheme14 では `guard` で受けられる。`error` の次の行へは戻らない。数だけのハンドルは `(rb-new-number)`。比較関数を渡すときは `(rb-new-with cmp)`。

```scheme
(define db (rb-new-number))
(rb-db-insert db 123 "from-number")
(guard (e (else 'refused))
  (rb-db-insert db "123" "from-string"))
;; => refused 。木には数の 123 だけが残る
```

無いキーの削除が木の形を動かすことと、`rb-search` が `false` を「値が偽」と「無い」の両方に返すことは、直していない。

---

## 18. テスト

```
make -C scheme14 selftest    # 379 checks, 0 failed
make -C scheme14 compare     # 展開が scheme12 と一致するか。scheme12 のビルドが要る
make -C scheme14 test        # 既存資産とのバイト比較、エラーの包み、REPL
make -C scheme14 sicp        # SICP のプログラム
make -C scheme14 bench       # 呼び出し 100 万回
```

2026-11-01 に、この Linux で `--selftest` を実行した。379 checks, 0 failed。`compare`、`test`、`sicp` の最新の一式は、2026-10-07 に Windows で記録された結果である。`test` は 50 passed、`compare` は 15 passed、`sicp` は 25 passed（主張 1050 件）。この Linux では、その日のあとソースは動いていない。

`--selftest` はプロセスの中で、凍結仕様の表示、リーダ、展開、エラーの文面、ソース位置、`eval`、基数、準クオートのネストを見る。外部のゴールデンファイルは要らない。

`make test` がバイト単位で合わせる相手は `scheme14/tests/golden/` である。改行は CRLF。scheme12 の LF 出力へ、CR を除いて合わせ直さない。床になっている既存資産は次の 12 件である。

`system_lib.scm`、`mlib7.scm`、`hashtable_lib.scm`、`rbtree_lib_improved.scm`、`list_test1.scm`、`test_fixes.scm`、`test_improvements.scm`、`test_vector_env.scm`、`rbtree_robustness_test.scm`、`rbtree_stress_test_safe.scm`、`performance_test.scm`、`test-case6.scm`。

`test-case6.scm` だけは、処理系自身の照合結果が本文に入る。145 項目のうち NG は 13 件のままである。内訳は `tests/golden/README.md`。scheme12 にこのファイルを渡すと落ちる。ゴールデンは、その落ち方ではなく、scheme14 の照合結果である。

同じ `test` には、scheme14 自身のテストが加わっている。赤黒木のキー試験、`guard` で受ける拒否 3 本、例外ハンドラの試験、エラーの包み、REPL の筋道、デバッグ表示、終了コードがそこにある。`system` の Windows スクリプトは、表示が OS に依存するので入れてない。ポートを大量に開いてディスクリプタの回収を見る試験は、`ulimit` を下げられる環境でだけ走る。Windows では SKIP になる。

展開の比較は、同じ式を scheme12 と scheme14 でマクロ展開し、結果の表示が一致するかを見る。準クオートの深さ 1 の形は、ここで守っている。

---

## 19. 互換性と制限

### 19.1 既存のプログラム

第18章の 12 件は、scheme12 の出力と、`test-case6.scm` を除いてバイト単位で一致する契約がある。一致させているものは、表示、`/` の切り捨て、内部 `define` の意味、継続が多ショットであること、共有ライブラリの手続き名である。

意図的に違うものは次である。

- エラーにはソース位置とキャレットが付く。scheme12 は付けない。
- 実数がある。`(sqrt 2)` は実数、`(sqrt 16)` は正確な 4。
- `eq?` と `eqv?` は数を値で比べる。scheme12 の `memq` はポインタ比較だった。
- `exit` と `quit` がある。
- 文字型は無く、文字手続きはある。文字は長さ 1 の文字列である。

### 19.2 R5RS にあって無いもの

| 名前 | 理由 |
| --- | --- |
| `numerator` `denominator` `rationalize` | 有理数が無い。`(numerator 0.5)` を正しく答えられない |
| `real-part` `imag-part` `magnitude` `angle` `make-rectangular` `make-polar` | 複素数が無い |
| `transcript-on` `transcript-off` | 選んで入れていない。R5RS でも任意である |

以前ここに入っていた `eval` の四つと、`number->string` の基数は、scheme14 にある。第11章と第14章。

有理数を入れると `/` の意味がもう一度変わる。複素数は使う当てが無い。どちらも入れない。`syntax-rules`、角括弧、`code` 特殊形式も入れない。`code` は原典にあるが、囲みのコードを捨てるフックで、利用者向けではない。

名前の差分だけでは足りない取りこぼしが、過去に三つあった。一覧で 1 行にまとめた `cadddr` のような名前、名前はあるが引数の形が足りない `map`、そして「文字型が無いので文字手続きも該当しない」と閉じた領域である。最後のものは、`char->integer` が最初から在ったのに、領域ごと閉じると見えなくなった。構文（`cond` の `=>` など）は `(globals)` の差分には出ない。名前と構文は別々に数える。

### 19.3 まだ入れていないもの

原典にあって、まだ入れていないのは `print` と `compile-print` である。急がない。`compile` と重なる。

FreeBSD と NetBSD では、ビルド手順はある。起動の確認はまだである。

---

## 付録 A. 逆アセンブルの例

`(let ((x 10) (y 20)) (+ x y))` は、使い捨てのクロージャになる。

```
[0] LDC 10
[1] LDC 20
[2] LDF (x y) [no-alloc]
      body:
        [0] LD (0 . 0)
        [1] LD (0 . 1)
        [2] LDG +
        [3] TAPP 2
        [4] RTN
[3] APP 2
[4] STOP
```

`if` は `SEL` と `JOIN` になる。条件のあとに両方の枝が命令列として埋め込まれ、`SEL` がどちらかへ跳ぶ。末尾の `if` は `SELR` になり、枝の終わりで `JOIN` せず、そのまま呼び出し元へ戻る。

再帰の末尾呼び出しは `TAPP` である。`(fact 30)` がスタックを 30 段積まないのは、このためである。

## 付録 B. 継続

```scheme
(call/cc (lambda (k) (k 1) 2))                 ; => 1
(call/cc (lambda (k) 2))                       ; => 2

(define saved #f)
(cons (call/cc (lambda (k) (set! saved k) 1)) '(2))
(saved 9)                                      ; => (9 2)
```

`dynamic-wind` をまたいで出ると、出る側の `after` が走る。もう一度入ると `before` が走る。`guard` と `with-exception-handler` はこの枠の上に載っている。ハンドラの鎖を、継続が別に持って歩かない。

## 付録 C. エラーの見出し

共通の形は `名前: 何が悪いか` で、その下に `expected:` と `given:` が付く。

| 状況 | 見出しの核 |
| --- | --- |
| 型が違う | `wrong type of argument` |
| 個数が違う | `wrong number of arguments` |
| 文字列・ベクタの添字 | `index out of range` |
| 長さ、基数、文字コードなど、値そのものの範囲 | `argument out of range` |
| 正確な整数の 0 除算 | `division by zero` |
| 構文 | `bad syntax` と、対象の名前 |
| 名前が無い | `unbound variable` |
| 手続きでないものを呼んだ | `attempt to call a non-procedure` |
| プログラムが起動できない | `system: cannot run program` |
| ハンドラが値を返した | `exception handler returned` |
| ファイルが開けない | `cannot open file for reading` など |
| 処理系の不変条件 | `internal error` |

実数の 0 除算はエラーにしない。`(/ 1.0 0.0)` は `+inf.0`。`(/ 1 0)` はエラーで、ハンドラがあればエラーオブジェクトになる。

## 付録 D. GC の規律

scheme12 で実際に起きたことを、繰り返さないための規則である。

1. ポートのように後始末が要るオブジェクトは、作る関数の中でファイナライザを登録する。登録箇所は `make_port` だけである。
2. GC オブジェクトが持つ文字列は `GcString` にする。`std::string` を持たせると、バッファが回収されない。
3. GC オブジェクトのコンテナは `gc_allocator`、大域表のようなルートは `traceable_allocator` を使う。
4. `cpp_int` の桁配列には `gc_allocator` を渡し、その要素型をポインタを含まないものとして宣言する。
5. ファイルを開く関数は、ディスクリプタ枯渇のとき GC とファイナライザを走らせてから 1 回だけ試す。`GC_gcollect` だけではファイナライザは走らない。

`fork` を足さない理由もここにある。子が GC のロックを持ったままになる。プロセスを分けるときは `posix_spawnp` か `CreateProcess` を使う。それが `system` である。
