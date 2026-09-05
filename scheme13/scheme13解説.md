# scheme13 解説文書（v1.1）

SECD 仮想機械方式の Scheme 処理系 **scheme13** の設計・実装解説。
対象は `scheme13/scheme13.cpp`（単一ファイル、4,674 行）と
`scheme13/lib13.scm`（221 行）。

`scheme12_debug`（`scheme12_bignum_boost_debug.cpp`）を、一貫した設計思想の
もとで書き直したものである。**振る舞いは互換、設計は選び直した。**

---

## この文書の位置づけ

このリポジトリには scheme13 に関する文書が3つあり、役割が違う。

| 文書 | 何が書いてあるか | 読む人 |
| --- | --- | --- |
| **この文書** | **いま何がどう動いているか。** 実装の解説 | 使う人、読む人、直す人 |
| `dev_memo.md` | **なぜそう決めたか。** 設計憲章、凍結仕様、決定ログ | 次に手を入れる人 |
| `micro_scheme8_notes.md` | 原典 `micro_Scheme8.lisp`（Common Lisp 版）の読解 | 由来を知りたい人 |

判断の根拠を知りたくなったら `dev_memo.md` の §6「決定ログ」を見ること。
この文書が「こうなっている」と書く箇所の多くには、あちらに「なぜそうしたか」と
「何を却下したか」が残っている。本文でも要所で決定番号を示す。

**この文書は実装に追随させる。** 処理系の振る舞いを変えたら、ここも直すこと。
とくにずれやすいのは第7章（命令一覧）、第10章（プリミティブ一覧と個数）、
第12章（テストの件数）、第13章（互換性）、付録C（エラー一覧）である。

追随できているかは**機械的に確かめられる**。名前と個数は第10.1節のコマンドで、
出力例はすべて実機から採ってあるので、そのまま流し直せば合っているか分かる。

> **v1.1 で追ったもの**: ポートと標準ポート（第10.9節）、多値と `dynamic-wind`
> （第10.10節・第8.3節）、`let` がクロージャを確保しないこと（第7.3節）、
> マクロ展開後のエラー位置（第3.1節）、性能の実測（第8.4節・第14.5節）。

---

## 目次

1. [全体像と設計思想](#1-全体像と設計思想)
2. [値モデル](#2-値モデル)
3. [ソース位置とエラー](#3-ソース位置とエラー)
4. [リーダ](#4-リーダ)
5. [構文検査と構文展開](#5-構文検査と構文展開)
6. [コンパイラ](#6-コンパイラ)
7. [命令セット](#7-命令セット)
8. [VM と継続](#8-vm-と継続)
9. [マクロ](#9-マクロ)
10. [プリミティブと標準ライブラリ](#10-プリミティブと標準ライブラリ)
11. [REPL とデバッグ機能](#11-repl-とデバッグ機能)
12. [テストと受け入れ基準](#12-テストと受け入れ基準)
13. [scheme12 との互換性](#13-scheme12-との互換性)
14. [既知の制限と拡張ポイント](#14-既知の制限と拡張ポイント)

付録
- [付録A. 逆アセンブル例](#付録a-逆アセンブル例)
- [付録B. 継続の動作例](#付録b-継続の動作例)
- [付録C. エラーメッセージ一覧](#付録c-エラーメッセージ一覧)
- [付録D. ビルドと起動](#付録d-ビルドと起動)

---

## 1. 全体像と設計思想

### 1.1 何であるか

scheme13 は Scheme のサブセットを実行する処理系である。ソースを読み、
SECD 系の仮想機械の命令列にコンパイルし、その命令列を VM で実行する。

```
  ソース ──[リーダ]──> S式 ──[構文展開]──> S式 ──[コンパイラ]──> 命令列 ──[VM]──> 値
           §5節           §7節              §8節                §10節
```

インタプリタではなく**コンパイラ + VM** である点が最初の分かれ目で、
これは原典 `micro_Scheme8.lisp` から受け継いだ構造である。式を評価する
たびに構文解析をやり直さないので、ループや再帰が速い。

### 1.2 scheme12 との関係

scheme12 は機能的には完成していたが、複数の書き手の判断が層として積み重なり、
構造的な澱みが残っていた。scheme13 の目的は **「新機能」ではなく
「同じ振る舞いを、選び直した設計で実現する」** ことである
（`dev_memo.md` §1.1）。

解消した澱みの例:

| scheme12 にあったもの | scheme13 での扱い |
| --- | --- |
| `Op::LDCT` — コンパイラが一度も生成しない命令 | 作らない |
| `Op::LD` にフレームのベクタ表現とリスト表現が両方生きていた | 表現は1つ |
| `Op::ARGS` が引数をリストに固め、`APP` が即座にベクタへ戻す | `ARGS` を廃止。引数はスタックに積んだまま渡す |
| 文字列型が二重（`GcString` と `std::string`）でリークしていた | `GcString` 一本 |
| ソース中の `// ... は以前と同じなので省略` という AI 生成時の足場 | 無い |

結果として **呼び出し性能が約 27 倍**になった（第8章参照）。これは設計の
選び直しの副産物であって、目的ではない。

### 1.3 三つの優先順位

利用者と合意済みの優先順位。迷ったらこの順で決める（`dev_memo.md` §1.4）。

1. **既存の `.scm` 資産を一字も変えずに動かすこと。** 最優先
2. **診断の質。** 何が起きたか読んで分かること
3. **速度。** 上の2つを損なわない範囲で

第2項が第3項より上にあるのは意図的である。scheme13 はデバッグ処理系であり、
**デバッグ機能は一級市民**として扱う（`dev_memo.md` §1.5）。逆アセンブル、
トレース、マクロ展開の観察は「おまけ」ではなく、命令セットを変えたら
逆アセンブラも直す、という関係にある。

### 1.4 依存

| 項目 | 決定 |
| --- | --- |
| 言語 | C++17 |
| GC | Boehm GC（`gc.h` / `gc_cpp.h` / `gc_allocator.h`、`-lgc -lgccpp`） |
| 多倍長整数 | Boost.Multiprecision `cpp_int` |
| これ以外 | **増やさない** |

**単一ファイル構成**である。分割しない。利用者はこのファイルを単体で AI に
渡してレビュー・改修を依頼する運用をしており、分割するとその運用が壊れる。
また、そもそも scheme12 の問題はファイル数ではなく「退役させなかった決定が
層になったこと」であり、分割は解決策ではない（`dev_memo.md` §1.3）。

代わりに**セクション構造を厳格に守る**。

### 1.5 ソースのセクション構造

`scheme13.cpp` は以下の順序と見出しを守る。**新しいコードを「とりあえず
近くに」置かない。** 該当セクションがなければセクションごと作る。

```
 1. 依存と GC 設定       インクルード、GC_DECLARE_PTRFREE、GcString、アロケータ別名
 2. ソース位置とエラー   SourcePos、SchemeError、format_error、detail、internal_error
 3. 値モデル             Object と各型、コンストラクタ、述語、アクセサ
 4. 表示                 to_string / display / write、循環検出
 5. リーダ               トークナイザ、S式パーサ（位置を記録する）
 6. 構文検査             syntax_error / check_arity / check_bindings
 7. 構文展開             let/let*/letrec/and/or/cond/case/do/quasiquote
 9. 命令セット           Op と Instruction、GlobalCell、Env、逆アセンブル
 8. コンパイラ           命令生成、環境解決、内部 define の scan out
10. VM                   実行ループ、呼び出し、継続、トレース
11. プリミティブ         算術・リスト・述語・文字列・ベクタ・I/O・GC・デバッグ
12. 起動                 グローバル初期化、ライブラリ読み込み、REPL、main
```

**ファイル上は 9 が 8 より前にある。** コンパイラは命令の定義に依存するが、
逆は依存しないため。番号は論理的な順序、配置は依存の順序である
（`dev_memo.md` 決定24）。

### 1.6 GC の規律

scheme12 はメモリリークを抱えていた。原因は「GC 管理オブジェクトの中に
GC 管理外のバッファを持たせた」ことに尽きる。scheme13 は次を規律とする
（`dev_memo.md` §1.6）。

1. **`gc` を継承したクラスのデストラクタは呼ばれない。**
   だから中に `std::string` や `std::vector`（既定アロケータ）を持たせない
2. **GC オブジェクトが持つ文字列は必ず `GcString`。**
   `std::basic_string<char, ..., gc_allocator<char>>`
3. **コンテナのアロケータを使い分ける。**
   GC オブジェクトの中は `GcVec`（= `gc_allocator`）、GC 管理外のグローバル
   表は `RootVec`（= `traceable_allocator`）
4. **`cpp_int` の limb 配列も GC 管理下に置く。**
   `GC_DECLARE_PTRFREE(unsigned long long)` を宣言したうえで
   `gc_allocator<unsigned long long>` を backend に渡す。これで limb 配列が
   `GC_MALLOC_ATOMIC` から確保され、スキャン対象から外れる（数値のビット列が
   ポインタと誤認されてゴミを保持する保守的 GC の偽 retention も防げる）

```cpp
using BigInt = boost::multiprecision::number<
    boost::multiprecision::cpp_int_backend<0, 0,
        boost::multiprecision::signed_magnitude,
        boost::multiprecision::unchecked,
        gc_allocator<unsigned long long> > >;
```

---

## 2. 値モデル

### 2.1 Object と即値 fixnum

値は `Object*`（別名 `ValuePtr`）ひとつで表す。scheme12 の
`Value{std::variant<...>}` + 別確保の実体という二段構えをやめ、
**タグ付きの基底クラス `Object` を各型が継承する**形にした。

```cpp
enum class Tag : std::uint8_t {
    Fixnum,       // ヘッダを持たない即値。tag_of() だけが返す
    Nil, Boolean, Bignum, String, Symbol, Pair, Vector,
    Closure, Continuation, Primitive, Macro, SpecialForm, Port, Eof
};

// ヘッダ 12 バイト（tag / src_col / src_file / src_line）
struct Object : public gc {
    Tag           tag;
    std::uint16_t src_col  = 0;
    std::uint16_t src_file = 0;
    std::uint32_t src_line = 0;
    explicit Object(Tag t) : tag(t) {}
};
```

これで cons 1 個が **2 回の確保・56 バイトから、1 回の確保・32 バイト**に
なった。`variant` は最大要素に合わせて全 `Value` が太るが、継承なら型ごとに
必要なだけで済む。ヘッダの詰め物にソース位置を置けたのも副産物である
（第3章）。

さらに **小さい整数はポインタに埋め込む（即値 fixnum）。**

```cpp
static inline bool is_fixnum(ValuePtr v) {
    return (reinterpret_cast<std::uintptr_t>(v) & 1u) != 0;
}
static inline std::intptr_t fixnum_value(ValuePtr v) {
    return reinterpret_cast<std::intptr_t>(v) >> 1;
}
static inline ValuePtr make_fixnum(std::intptr_t n) {
    return reinterpret_cast<ValuePtr>((static_cast<std::uintptr_t>(n) << 1) | 1u);
}
```

最下位ビットが 1 なら整数、0 ならヒープ上のオブジェクト。`(+ acc 1)` の
ような算術が**1 回も確保しなくなる**。64bit 環境で `FIXNUM_MAX` は
`INTPTR_MAX >> 1` = 4611686018427387903。

保守的 GC との相性: 奇数のビット列はヒープオブジェクトの誤保持
（偽 retention）を起こしうるだけで、破壊は起きない。

**`nullptr` は値ではない。** 空リストは必ず `g_nil`（唯一のシングルトン）。

### 2.2 型の一覧

| Tag | C++ の型 | 内容 |
| --- | --- | --- |
| `Fixnum` | （ポインタに埋め込み） | 小さい整数 |
| `Bignum` | `Bignum` | `BigInt` を持つ多倍長整数 |
| `Nil` | シングルトン `g_nil` | 空リスト |
| `Boolean` | シングルトン `g_true` / `g_false` | 真偽値 |
| `String` | `Str` | 可変長文字列（`GcString`）。**文字型は存在しない** |
| `Symbol` | `Symbol` | インターンされる。**大小文字を保存する** |
| `Pair` | `Pair` | `car` と `cdr` |
| `Vector` | `Vector` | `GcVec<ValuePtr>` |
| `Closure` | `Closure` | `Template*` と `Env*` |
| `Continuation` | `Continuation` | スタック・ダンプ・環境・コードのスナップショット |
| `Primitive` | `Primitive` | 名前と関数ポインタ |
| `Macro` | `Macro` | 変換子（クロージャ） |
| `SpecialForm` | `SpecialForm` | `if` などの値としての姿 |
| `Port` | `Port` | `FILE*`、入出力の別、閉じたかどうか |
| `Eof` | シングルトン `g_eof` | ファイル終端 |
| `Values` | `Values` | 多値の箱。**1個のときは作らない**（第10.10節） |

**重要な帰結**（`dev_memo.md` §2.2）:

- **文字型が存在しない。文字は長さ1の文字列。**
  `(string-ref "abc" 1)` は `"b"`、`(integer->char 65)` は `"A"`
- `eq?` と `eqv?` は同一実装。**数値は値比較**、シンボルは名前比較、
  文字列はポインタ比較（`(eq? "a" "a")` は `FALSE`）
- **整数のみ。** 有理数・実数・複素数はない
- 偽は `#f` ただ一つ。`nil` も `0` も空文字列も真

`Template` はクロージャの「型紙」で、複数のクロージャが共有する。

```cpp
struct Template : public gc {
    GcVec<GcString>         params;
    std::optional<GcString> rest;
    CodePtr                 body = nullptr;
    GcString                name;   // 逆アセンブル表示用（define で付く）
};
```

### 2.3 表示（凍結仕様）

`write` による出力は**互換性契約**であり、変更しない
（`dev_memo.md` §2.1）。すべて scheme12 で実測した値である。

| 式 | 出力 |
| --- | --- |
| `'()` および `nil` | `NIL` |
| `#t` および `true` | `TRUE` |
| `#f` および `false` | `FALSE` |
| `'AbC` | `AbC`（**シンボルは大小文字を保存する**） |
| `'(a B c)` | `(a B c)` |
| `'(a . b)` | `(a . b)` |
| `'#(1 a "s")` | `#(1 a "s")` |
| `"hi\nthere"` | `"hi` 改行 `there"`（**`write` は改行をエスケープしない**） |
| `(lambda (x y) x)` | `#<closure:(x y)>` |
| `(lambda (x . r) x)` | `#<closure:(x . r)>` |
| `car` | `(PRIMITIVE car)` |
| `if` | `(SPECIAL-FORM if)` |
| 継続 | `#<continuation>` |
| `eof-object` | `#<eof>` |
| 閉じたポート | `#<closed-port>` |

**scheme12 に無い型の表示**（凍結仕様の表は1行も変えていない。
新しい型が増えたぶんだけ増える）:

| 式 | 出力 |
| --- | --- |
| `(current-output-port)` | `#<output-port>` |
| `(values 1 2)` | `#<values 1 2>` |
| `(values)` | `#<values>` |

`display` と `write` の違いは**文字列を引用符で囲むかどうかだけ**。
リストの要素にある文字列は `display` でも引用符つきで出る（`("x" y)`）。

> **この表示は読み戻せない。** `NIL` / `TRUE` / `FALSE` はリーダにとって
> （小文字の `nil` / `true` / `false` と違い）ただのシンボルなので、書いた
> 出力をもう一度読むと別の値になる。`write` の出力を入力に使う道具
> （`--read` / `--expand`）はこの前提で作られている。文字列のエスケープを
> しない仕様も同じ性質を持つ。

### 2.4 循環構造

`to_string` は循環を検出して打ち切る。実機での出力:

```scheme
(define a (list 1 2))
(set-cdr! (cdr a) a)
(write a)              ; => (1 2 . #<circular>)

(define b (list 1 2))
(set-car! b b)
(write b)              ; => (( . #<circular>) 2)

(define v (vector 0 0))
(vector-set! v 0 v)
(write v)              ; => #(#<circular-vector> 0)
```

実装上の規律が2つある（`dev_memo.md` §4.3）。scheme12 はここで C スタックを
溢れさせる不具合を2件抱えていた。

1. **リストの cdr 方向を再帰で辿らない。**
   `equal?`、`to_string`、`length`、`append` などは必ずループにする。
   car 方向のみ再帰してよい
2. **循環検出の `visited` は「経路上のノード集合」として扱い、走査後に
   自分が入れた分を必ず取り除く**（バックトラック）。そうしないと
   `(let ((x '(1))) (list x x))` のような**共有はあるが循環でない**構造を
   循環と誤検出する

### 2.5 数値: fixnum と bignum の境界

**規律**（`dev_memo.md` §9）。算術に手を入れるときは必ず守ること。

- fixnum どうしの演算は `__builtin_*_overflow` で検査し、溢れたら bignum へ
- **bignum 演算の結果が fixnum に収まったら必ず fixnum に落とす**
  （`make_int(const BigInt&)` がそうしている。専用の経路を増やさないこと）

これを破ると §2.2 の「数値は値比較」が表現によってぶれ、`eq?` の結果が
変わる。`--selftest` に境界のテストが入っている（`"fixnum overflow"` と
`"normalize back"`）。

```scheme
(* 99999999999 99999999999)   ; => 9999999999800000000001
(= (* 4611686018427387903 2) 9223372036854775806)   ; => TRUE
(eq? (- (* 4611686018427387903 2) 9223372036854775805) 1)   ; => TRUE
```

算術の凍結仕様（`dev_memo.md` §2.3）:

- `(/ -7 2)` は `-3`（0方向への切り捨て。`quotient` 相当）
- `(/ x)` は**エラー**。単項の逆数は整数では表せない
- `(modulo -7 2)` は `1`、`(modulo 7 -2)` は `-1`（符号は除数に一致）
- `(remainder -7 2)` は `-1`、`(remainder 7 -2)` は `1`（符号は被除数に一致）

---

## 3. ソース位置とエラー

### 3.1 位置の持たせ方

**オブジェクトのヘッダに直接埋める。** 副表（`Pair*` → `SourcePos` の
`unordered_map`）は採らない（`dev_memo.md` 決定12）。

理由:
- 副表はキーが強参照になるので、読み込んだペアが永久に回収されない
- ヘッダには `tag`（1バイト）の後ろにどのみち詰め物が入る。そこへ
  `col` / `file` / `line` を置けば、ペア1個あたりの増分は 32-16=16 バイトで済む
- 参照がハッシュ引きでなくフィールド読み出しになる

```cpp
struct SourcePos {
    std::uint16_t file = 0;  // g_sources の添字。0 なら位置なし
    std::uint16_t col  = 0;  // 1 起点
    std::uint32_t line = 0;  // 1 起点
    bool known() const { return file != 0 && line != 0; }
};
```

**位置を持つのはリーダが作ったオブジェクトだけ。** 実行時に `cons` した
ペアの位置は 0（＝位置なし）。シンボルはインターンされる（＝共有される）ので
位置を持てない。エラーは「最も内側の、位置を持つ囲みフォーム」を指す。

ソース全文は `g_sources` に保持する。エラー時にキャレット行を描くため。

#### 展開後の位置（マクロと構文展開）

マクロや構文展開が作ったペアは**リーダを通っていないので位置を持たない**。
そのままでは `(deep 5)` のような1行が、位置なしのエラーになってしまう。
二段構えで埋める。

1. **展開結果の先頭ペアに、元のフォームの位置を貼る**（`with_pos_of`）。
   `expand_form_1` の全経路と `macro_expand_1_expr` が通る。利用者が渡した
   部分式は自分の位置を保ったままなので、そちらが優先される
2. **それでも位置を持たない部分式には、囲みフォームの位置を継がせる**
   （`comp` / `comp_body` の `inherited` 引数）

```cpp
static void comp(ValuePtr expr, ..., SourcePos inherited) {
    SourcePos pos = nearest_pos(expr);
    if (!pos.known()) pos = inherited;   // ここで鎖がつながる
```

**この鎖は一箇所でも切ると、そこから下が丸ごと位置を失う。**
`compile_lambda` が `nearest_pos(whole)` を引き直していたために、
展開が生んだ `lambda` の本体が位置を失っていた（11日目の決定52）。
`lambda` を作る場所を足すときは、`comp` が解決済みの `pos` を必ず渡すこと。

結果として、エラーは**利用者が書いた行**を指す。

```scheme
(define-macro (deep x) `(let ((y 1)) (begin (car ,x))))
(deep 5)
;  scheme13/t.scm:2:1: car: wrong type of argument
;    (deep 5)
;    ^

(define-macro (unless c . body) `(if ,c #f (begin ,@body)))
(unless #f (car 5))
;  利用者が渡した (car 5) は自分の位置を持つので、そちらを指す
;    (unless #f (car 5))
;               ^
```

**展開結果の内部を指すことはしない。** 利用者はその行を書いていないので、
指されても直しようがない。同じ理由でライブラリの中も指さない（第3.4節）。

### 3.2 エラー本文の形

**見出し1行 + 字下げした詳細行**に揃える（`dev_memo.md` 決定33、§4.2）。

```
Fatal error: t.scm:1:1: car: wrong type of argument
  expected: a pair
  given: 5
    (car 5)
    ^
```

- 1行目は `位置: 見出し`。見出しは「**誰が**」「**何をしくじったか**」だけを言う
- 2行目以降は字下げ2の**詳細行**で、`expected:` → `given:` の順
- 最後に問題のソース行とキャレット（字下げ4）

**見出しの語彙は次に限る。** 増やすときはこの表に足してから使うこと。

| 見出し | 使うところ |
| --- | --- |
| `<who>: wrong type of argument` | 型が違う |
| `<who>: wrong number of arguments` | 引数の数が違う（クロージャもプリミティブも） |
| `<who>: index out of range` | 文字列・ベクタへの添字 |
| `<who>: argument out of range` | 値そのものの範囲（ASCII コード、長さ、乱数の上限） |
| `bad syntax in <form>` | 構文検査 |
| `unbound variable: <name>` | 未束縛の参照 |
| `attempt to call a non-procedure` | 呼べないものを呼んだ |
| `internal error: <what>` | **処理系自身の不具合。利用者の誤りではない** |

詳細行のラベルは `expected` / `given` / `note` の3つ。綴りは
`detail()` / `expected_given()`（セクション2）に閉じ込め、各所で文字列を
組み立てない。

**`given:` には「悪い部分そのもの」を出す。** フォーム全体はキャレット行が
見せている。

```
Fatal error: t.scm:1:1: bad syntax in let
  expected: each binding to be (variable expression)
  given: (x)
    (let ((x)) x)
    ^
```

前置きは2種類ある。**REPL は `Error:` を付けて次の入力へ進み、`--load` 中は
`Fatal error:` を付けて終了コード1で止まる。** 読み進めるかどうかの違いを
前置きで表す。文面は同じものを使う。

### 3.3 内部エラーとの切り分け

処理系自身の不変条件が壊れた場合は、**利用者の書いたプログラムの誤りではない**
ので明示的に分ける（`dev_memo.md` 決定34）。

```
internal error: as_pair on a non-pair
  note: this is a bug in scheme13 itself, not in the program being run
```

該当するもの:
- VM のスタック不足、命令の添字外れ、ダンプ不足
- セクション3 のアクセサ（`as_pair` / `as_string` / `as_vector` /
  `as_symbol_name` / `as_bigint`）の型違い

これらのアクセサは**処理系の内部用で、利用者のプログラムからは直に到達
しない**。利用者の値を検査するのは構文検査（第5章）とプリミティブ（第10章）の
仕事で、そこを素通りしてここに落ちたなら scheme13 側の検査漏れである。
scheme12 はアクセサが `expected pair` を返していて、利用者の型エラーと
見分けがつかなかった。

### 3.4 ライブラリを指さない（blame_pos）

エラーの位置は**利用者が書いた行**を指す（`dev_memo.md` 決定43）。

素直に「いま実行中の命令」を指すと、`(sqrt -4)` が `lib13.scm` の中
（`sqrt` が `error` を呼んでいる行）を指してしまう。
**利用者はその行を書いていないので直しようがない。**

`SourceFile` に `is_library` を持たせて起動時ライブラリに印を付け、
位置を埋めるときに実行中の命令がライブラリの中なら、ダンプを内側から外へ
辿って**最初に見つかるライブラリ外の呼び出し位置**を選ぶ。

```
Fatal error: t.scm:1:1: sqrt: argument out of range
  given: -4
    (sqrt -4)
    ^
```

末尾呼び出しはダンプを積まないので、`(define (f n) (sqrt n))` に対する
`(f -9)` は `(sqrt n)` ではなく `(f -9)` を指す。**これは正しい。**
末尾呼び出しでフレームが消えるのは SECD の設計そのもので、どの Scheme でも
同じことが起きる。

---

## 4. リーダ

トークナイザと S 式パーサ。**位置を記録しながら読む**のが scheme12 との違い。

### 4.1 構文要素

| 記法 | 読まれ方 |
| --- | --- |
| `123` `-45` | 整数（fixnum または bignum） |
| `abc` `AbC` | シンボル（**大小文字を保存**） |
| `"..."` | 文字列。`\n` `\t` `\\` `\"` のエスケープを解釈する |
| `#t` `#f` | 真偽値 |
| `true` `false` `nil` | 同じく真偽値と空リスト（リテラルとして受け付ける） |
| `'x` | `(quote x)` |
| `` `x `` | `(quasiquote x)` |
| `,x` | `(unquote x)` |
| `,@x` | `(splice x)` — **`unquote-splicing` ではない** |
| `#(...)` | ベクタリテラル |
| `;` 以降 | 行末までコメント |

**凍結仕様として押さえておくこと**（`dev_memo.md` §2.5）:

- **角括弧 `[` `]` は区切り文字ではない。** `'[1 2]` は `[1` と `2]` という
  2つのシンボルとして読まれる（結果として `unbound variable: 2]`）
- `,@` は内部的に `splice` というシンボルに読まれる
- 準クオートのネスト（`` `(a `(b ,,x)) ``）は未対応

### 4.2 位置の記録

`Reader` はファイル id を持ち、各トークンの開始位置（行・列）を覚えている。
ペアとベクタを作るときに、その開始位置をヘッダへ書き込む。

`read_all(id)` はファイル全体を読んで `TopForm{expr, pos}` の列を返す。
**先に全部読む**のが scheme12 との違いで、これがテスト機構（第12章）で
「次のフォームを覗く」ことを可能にしている。

### 4.3 リーダのエラー

位置つきで報告する。実機の出力:

```
$ scheme13 --load r1.scm          # 中身: (foo\n  bar
Fatal error: r1.scm:1:1: unexpected EOF in list
    (foo
    ^

$ scheme13 --load r2.scm          # 中身: (a b))
Fatal error: r2.scm:1:6: unexpected ')'
    (a b))
         ^

$ scheme13 --load r3.scm          # 中身: "abc
Fatal error: r3.scm:1:1: unexpected EOF in string literal
    "abc
    ^
```

**閉じ忘れは「開いた場所」を、余った括弧は「その括弧自身」を指す。**
閉じ忘れはファイル末尾で気づくので、末尾を指しても直しようがない。

---

## 5. 構文検査と構文展開

### 5.1 なぜ検査が独立しているか

素の `car`/`cdr` に構文検査を任せると、`(define x)` も `(if)` も `(set! 1 2)` も
すべて `expected pair` という同じメッセージになり、どのフォームのどこが悪いのか
分からない。**scheme12 がそうだった。**

セクション6 はフォーム名・期待する形・そのフォームのソース位置を添えて
報告する道具を持つ。

| 関数 | 役割 |
| --- | --- |
| `syntax_error(form, what, whole)` | `bad syntax in <form>` + 詳細 + 位置 |
| `form_arity(rest)` | 真リストの長さ。ドットリスト・循環なら `nullopt` |
| `check_arity(form, whole, rest, min, max)` | 部分式の個数を検査 |
| `check_bindings(form, whole, bindings)` | `((var expr) ...)` の形を検査 |
| `arity_detail(min, max, got)` | `expected:` / `given:` の文面（プリミティブと共用） |

`form_arity` は cdr 方向を再帰せず、**Floyd の2ポインタ法**で循環も検出する。

### 5.2 構文展開

`expand_form_1(form)` は「書き換えで済む特殊形式」を1段展開する。
展開されないものはそのまま返る。

| フォーム | 展開先 |
| --- | --- |
| `(let ((v e) ...) body)` | `((lambda (v ...) body) e ...)` |
| `(let name ((v e) ...) body)` | 名前つき let。`letrec` 経由 |
| `(let* ((v e) ...) body)` | `let` の入れ子 |
| `(letrec ((v e) ...) body)` | `:undef` で初期化してから `set!` |
| `(and a b)` | `(if a b FALSE)` |
| `(or a b)` | `(let ((or1 a)) (if or1 or1 b))` — 一時変数で二重評価を避ける |
| `(cond ...)` | `if` の入れ子 |
| `(case ...)` | `memv` を使った `cond` |
| `(do ...)` | `letrec` による名前つきループ |
| `` `(...) `` | `cons` / `append` の呼び出し列 |

実機で見る:

```scheme
(macroexpand-1 '(let ((x 1) (y 2)) (+ x y)))
; => ((lambda (x y) (+ x y)) 1 2)

(macroexpand-1 '(and a b c))
; => (if a (if b c FALSE) FALSE)

(macroexpand-1 '(or a b))
; => (let ((or1 a)) (if or1 or1 b))

(macroexpand-1 '(let* ((a 1) (b 2)) a))
; => (let ((a 1)) (let* ((b 2)) a))

(macroexpand-1 '(cond ((> x 1) 'big) (else 'small)))
; => (if (> x 1) (quote big) (quote small))

(macroexpand-1 '(do ((i 0 (+ i 1))) ((= i 3) i)))
; => (letrec ((loop2 (lambda (i) (if (= i 3) i (loop2 (+ i 1)))))) (loop2 0))
```

`let*` が**自分自身へ**1段だけ展開されるのに注目。`macroexpand-1` は
1段しか進まないので、入れ子は残る。全部見たければ `macroexpand` を使う。

**展開結果の先頭ペアには元フォームの位置を貼る**（`with_pos_of`。
`dev_memo.md` 決定21）。そうしないと `let` の中のエラーが位置を失う。

`or` と `cond` の本体なし節は一時変数を要するので `gensym` を使う。
`(or a b)` は `a` を2回評価してはいけないため。

### 5.3 内部 define

本体**先頭**の連続した `define` のみ `letrec` に変換される
（`scan_out_defines`）。

```scheme
(define (outer x)
  (define (helper y) (* y 2))   ; letrec になる
  (helper x))
```

**式より後ろの `define`、マクロが生成した `define`、本体先頭の
`(begin (define ...) ...)` のスプライスは、グローバル定義になる。**
これは scheme12 と同じ振る舞いで、凍結仕様である（`dev_memo.md` §2.6）。

本体が `define` だけなら `:undef` を足す:

```
((define x 1))  ->  ((letrec ((x 1)) :undef))
```

---

## 6. コンパイラ

### 6.1 コンパイルの流れ

`comp(expr, env, code, tail, pos)` が命令を `code` に追記する。

```
comp(式)
  ├ 自己評価する値（数・文字列・ベクタ・真偽値・nil） -> LDC
  ├ シンボル -> 局所なら LD、そうでなければ LDG
  └ ペア
      ├ 先頭が特殊形式 -> それぞれの生成規則
      │    ├ 書き換えで済むもの -> expand_form_1 して作り直す
      │    └ quote / if / lambda / define / define-macro / set! /
      │       begin / call/cc / apply
      ├ 先頭がマクロ -> macro_expand_1_expr して作り直す
      └ それ以外 -> 通常の適用
```

**順序に意味がある。** 特殊形式が先、ユーザマクロが後。利用者が
`(define-macro (let ...))` と書いても特殊形式の `let` が勝つ。
`macroexpand-1` もこの順序に揃えてある（第9章）。

### 6.2 環境の解決

コンパイル時に**フレーム番号と位置**へ解決する。実行時に名前で探さない。

```cpp
// LD (深さ . 位置)
[0] LD (0 . 0)     // いまのフレームの 0 番目
[1] LD (1 . 0)     // 1 つ外のフレームの 0 番目
```

大域変数は名前でなく `GlobalCell*` で引く。

```cpp
struct GlobalCell : public gc {
    ValuePtr value = nullptr;   // nullptr なら未束縛
    ValuePtr macro = nullptr;   // マクロなら変換子
    GcString name;
};
```

**名前によるハッシュ検索はコンパイル時に1回だけ。** 実行時の `LDG` は
セルからの読み出しで済む。未束縛でもセルは作るので、前方参照が自然に解決する。

`value` と `macro` を1つのセルに同居させたのは、scheme12 の
`g_globals` / `g_macros` という2つの表を統合したもので、原典がシンボルの
プロパティリスト1箇所に両方入れていた形に戻る。

### 6.3 呼び出し規約

**引数はスタックに積んだまま渡す。** これが性能設計の中心である
（`dev_memo.md` §4.1）。

scheme12 は `ARGS` 命令が引数をリストに固め、`APP` が即座にベクタへ戻して
いた（三重変換）。scheme13 に `ARGS` は無い。

```
通常の適用 (f a b) のコンパイル結果:
  arg0 を評価  -> スタックに積む
  arg1 を評価  -> スタックに積む
  f を評価     -> スタックに積む
  APP 2
```

**引数を左から順に評価してから演算子**を評価する（scheme12 と同じ順）。
スタックは下から `arg0 .. arg_{n-1} callee` になる。

プリミティブはこのスタック上の区間を `ValuePtr*` としてそのまま受け取る。
**詰め替えない。** したがってプリミティブは `argv` を書き換えてはならず、
保持してもいけない。

### 6.4 末尾呼び出し

`tail` フラグを引き回し、末尾位置では `TAPP` / `TAPPLY` / `TCALLCC` /
`SELR` を出す。末尾呼び出しはダンプを積まないので、末尾再帰がスタックを
食わない。

```scheme
(define (loop i acc) (if (= i 0) acc (loop (- i 1) (+ acc 1))))
(loop 1000000 0)   ; => 1000000。100万回で約 0.12 秒
```

---

## 7. 命令セット

### 7.1 機械の状態

古典的な SECD の4レジスタだが、表現を選び直してある
（`dev_memo.md` §4.4.2）。

| レジスタ | scheme13 での表現 |
| --- | --- |
| **S**（スタック） | 単一の連続スタック。呼び出しでコピーせず、床を `base` で覚える |
| **E**（環境） | フレームの連結リスト `Env*`。1呼び出し = 1確保 |
| **C**（コード） | `Code*` と `pc` |
| **D**（ダンプ） | `{c, pc, env, base}` の POD の連続配列 |

**scheme12 は呼び出しごとに S と E を丸ごとコピーしていた**（環境の深さに
比例するコスト）。ここが最大の違いである。

環境フレームは可変長の末尾配列を持ち、1フレーム = 1回の確保で済ませる。

```cpp
struct Env {
    Env*          next;
    std::uint32_t size;
    ValuePtr      vals[1];   // 実際は size 個
};
```

### 7.2 命令の表現

固定長 32 バイト。`p1` / `p2` の意味は命令ごとに決まる。

```cpp
struct Instruction {
    Op            op;
    std::uint16_t a = 0;
    std::uint16_t b = 0;
    SourcePos     pos;
    void*         p1 = nullptr;
    void*         p2 = nullptr;
};
```

| 命令 | `p1` / `p2` / `a` / `b` の意味 |
| --- | --- |
| `LDC` | `p1` = 定数（`ValuePtr`） |
| `LDG` `DEF` `DEFM` `GSET` | `p1` = `GlobalCell*` |
| `LDF` | `p1` = `Template*` |
| `SEL` `SELR` | `p1` = 真の枝（`Code*`）、`p2` = 偽の枝 |
| `LD` `LSET` | `a` = フレーム番号、`b` = 位置 |
| `APP` `TAPP` `ARGS_AP` | `a` = 個数 |

**すべての命令がソース位置を持つ。** 実行時エラーに位置が付くのはこれによる。

### 7.3 命令一覧

**21 命令すべてをコンパイラが生成し、VM が実装している。**
使われない命令は作らない（`dev_memo.md` 決定7）。scheme12 の `LDCT` の
ような「生成されない命令」を残さないための確認:

```sh
# セクション8（コンパイラ）が生成する命令
sed -n '/セクション 8. コンパイラ/,/セクション 10. VM/p' scheme13/scheme13.cpp \
  | grep -o 'Op::[A-Z_]*' | sort -u
# セクション10（VM）が実装する命令
sed -n '/セクション 10. VM/,/セクション 11/p' scheme13/scheme13.cpp \
  | grep -o 'case Op::[A-Z_]*' | sort -u
```

両者が一致し、`Op` の定義とも一致することを確認済み。

| 命令 | 動作 |
| --- | --- |
| `LD (n . i)` | 環境の n 段外のフレームの i 番目を積む |
| `LDC v` | 定数 v を積む |
| `LDG cell` | 大域セルの値を積む。未束縛ならエラー |
| `LDF tmpl` | 現在の環境を捕まえてクロージャを作り、積む。**印が付いていれば確保しない**（下記） |
| `APP n` | スタック上の n 引数 + 演算子で呼ぶ。ダンプを積む |
| `TAPP n` | 同上、末尾。ダンプを積まず、自分の床まで捨てる |
| `ARGS_AP n` | `apply` 用。n 個の値と末尾リストを1本の引数列にまとめる |
| `APPLY` | `(apply f args)` を呼ぶ |
| `TAPPLY` | 同上、末尾 |
| `RTN` | ダンプを1段戻す |
| `SEL` | 真偽で枝を選び、ダンプに戻り先を積む |
| `SELR` | 同上、末尾。戻り先を積まない |
| `JOIN` | `SEL` の枝の終わり。ダンプを1段戻す |
| `POP` | スタックの先頭を捨てる（`begin` の中間式） |
| `DEF cell` | スタック先頭を大域に束縛し、**シンボル名を返す** |
| `DEFM cell` | 同上、マクロとして |
| `LSET (n . i)` | 局所変数へ代入。**代入した値を返す** |
| `GSET cell` | 大域変数へ代入。同上 |
| `CALLCC` | 現在の状態を継続として捕捉し、引数の手続きに渡す |
| `TCALLCC` | 同上、末尾 |
| `STOP` | 実行終了。スタック先頭が値 |

`(define zz 1)` がシンボル `zz` を返し、`(set! v 2)` が `2` を返すのは
凍結仕様である（`dev_memo.md` §2.4）。

#### `LDF` の「使い捨て」の印

`let` / `let*` / `letrec` / 名前つき `let` / `do` はすべて
`((lambda (p ...) body) a ...)` に展開される（第5.2節）。素直にコンパイルすると
`LDF` がクロージャを1つ作り、次の `APP` がそれを呼んで即座に捨てる。
**赤黒木のワークロードでは、作られたクロージャ 2613万個のうち 99.9996% が
これだった。**

**演算子は最後に評価される**ので、`APP` の直前の命令は必ず被呼び出しを作る
命令である。それが `LDF` なら、そのクロージャはこの `APP` に消費されて即座に
死ぬ。コンパイラはそういう `LDF` に印を付け、VM は確保せずに**VM が1つ持つ
スクラッチ**を書き換えて積む（`dev_memo.md` 決定54）。

```
scheme13> (disassemble (lambda (n) (let ((a n)) (lambda () a))))

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
```

`[1]` の `LDF (a)` が `let` の lambda で、印が付いている。その中の
`LDF ()` は**外へ返るクロージャ**なので印が無く、ちゃんと確保される。

**スクラッチは呼び出し規約の一部であって Scheme の値ではない。**
プリミティブの `argv` がスタック上の区間を借りているのと同じ約束で、
保持してはならない。`LDF` と `APP` の間では何も走らないので、継続の捕捉も
再入も起こり得ず、1つで足りる。逆アセンブルが `[no-alloc]` を出すのは、
**同じ表示で違う挙動をさせない**ため。

### 7.4 逆アセンブラ

**命令セットを変えたら必ず逆アセンブラも直す。** これは義務である
（§1.3 の優先順位2）。`SEL` の枝と `LDF` の本体は字下げして入れ子で見せる。
付録A に実機の出力を載せた。

---

## 8. VM と継続

### 8.1 実行ループ

```cpp
for (;;) {
    if (!c || pc >= c->ins.size()) internal_error(...);
    const Instruction& ins = c->ins[pc++];
    if (g_trace_mode) trace_step(ins);
    try {
        switch (ins.op) { ... }
    } catch (SchemeError& e) {
        if (!e.pos.known()) {
            SourcePos p = blame_pos(ins.pos);
            if (p.known()) throw SchemeError(e.what(), p);
        }
        throw;
    }
}
```

**C++ の再帰はしない。** クロージャの呼び出しは `c` / `pc` / `env` /
`base` を差し替えるだけで、C スタックは伸びない。だから Scheme 側の深い
再帰（実測で 20 万段）でも落ちない。伸びるのは `dump`（ヒープ上の
`std::vector`）である。

**位置の無いエラーはここで位置を貰う**（第3.4節）。プリミティブは位置を
知らないまま投げてよい。

### 8.2 呼び出し

`do_call` が呼ばれた対象で分岐する。

| 対象 | 動作 |
| --- | --- |
| `Primitive` | 関数ポインタを呼び、スタックを引数の分だけ縮めて結果を積む |
| `Closure` | `make_frame` で環境を作る。非末尾ならダンプを積む |
| `Continuation` | 機械の状態を**まるごと差し替える** |
| それ以外 | `attempt to call a non-procedure` |

`make_frame` は引数の個数を検査し、余りがあれば `rest` のリストを作る。
引数不足・過多は呼ばれた側の名前を出す。

```
Fatal error: t.scm:2:1: f: wrong number of arguments
  expected: 2 arguments
  given: 1
    (f 1)
    ^
```

名前は `Template::name`（`define` で付く）。無名なら表示形
`#<closure:(a b)>` で代用する。**表示形そのものは §2.1 で凍結されていて
名前を含められない**ので、`callee_name()` として別に持ち出している。

### 8.3 継続

`CALLCC` は現在の機械の状態をスナップショットして `Continuation` を作る。

```cpp
Continuation* k = new Continuation();
k->stack = stack;      // コピー（何度でも起動できるように）
k->dump  = dump;
k->winds.assign(g_winds.begin(), g_winds.end());   // dynamic-wind の入れ子
k->c = c; k->pc = pc; k->env = env; k->base = base;
```

起動は状態をまるごと差し替える。捕捉したスナップショットは **move ではなく
copy** する。1つの継続を何度でも起動できるようにするため。

#### dynamic-wind との噛み合わせ

継続は**捕捉した時点の `dynamic-wind` の入れ子**（`g_winds` のコピー）も
持つ。起動するとき、いまの入れ子と捕捉時の入れ子を比べ、違えば
**差分だけ巻き戻してから**状態を差し替える（`dev_memo.md` 決定59）。

1. 共通の先頭を求める（枠の通し番号 `id` で比べる。同じ `before`/`after` の
   組が入れ子で二度積まれても別物と分かる）
2. **出る枠の `after` を内側から**、**入る枠の `before` を外側から**呼ぶ
3. 最後にこの継続をもう一度起動する。二度目は入れ子が一致しているので
   まっすぐ差し替わる

2 と 3 は**その場で組んだ命令列**（`build_rewind_code`）で行う。
コンパイラは通さない。中身は「定数を積んで呼んで捨てる」の繰り返しでしかない。

```
LDC <after>   APP 0   POP      ← 出る枠のぶんだけ繰り返す
LDC <before>  APP 0   POP      ← 入る枠のぶんだけ繰り返す
LDC <値>      LDC <継続>  APP 1
```

**なぜ VM の中でやるのか。** `dynamic-wind` の普通の道（`before` → `thunk`
→ `after`）は Scheme で書けるが（`lib13.scm`）、脱出と再入は
**継続を起動する側にしか分からない**。プリミティブから Scheme を呼び戻す
入口は `apply_callable`（VM をもう1つ回す）しか無く、そこで継続を捕捉すると
内側の VM だけを捕まえてしまう。だから巻き戻しは `do_call` に置いた。

凍結仕様（`dev_memo.md` §2.7）:

- `call/cc` と `call-with-current-continuation` の両方を受け付ける
- `call/cc` と `apply` は**特殊形式であって値ではない**。
  `(procedure? call/cc)` は `FALSE`
- **トップレベルのフォームは個別に評価される**ため、フォームを跨いで継続を
  起動すると、そのフォームの残りは実行されず次のフォームへ進む

最後の項目は挙動が直観に反するので、付録B に実機の出力を載せた。

### 8.4 性能

```
$ make -C scheme13 bench
1000000

real    0m0.123s
```

100万回の末尾再帰的な呼び出しで **約 0.12 秒**。scheme12 は同じもので
約 3.3 秒だったので **約 27 倍**である。効いているのは順に:

1. 呼び出しで S と E をコピーしないこと（scheme12 は環境の深さに比例）
2. 引数をリストに固めないこと（`ARGS` の廃止）
3. 大域変数のハッシュ検索がコンパイル時に消えること（`GlobalCell*`）
4. 小さい整数が確保を起こさないこと（即値 fixnum）
5. `let` がクロージャを確保しないこと（第7.3節の `[no-alloc]`）

**このベンチは当たる範囲が狭い。** `let` も非末尾の `if` も含まないので、
実際のプログラムの姿とは違う。実ワークロードも併せて見ること。

| 測定 | 時間 |
| --- | --- |
| 呼び出しベンチ 100万回（`make bench`） | 0.12 s |
| 赤黒木 4万件の挿入と探索 | 3.9 s |
| ゴールデン12件の総実行時間 | 1.5 s |

#### 何が実行されているか

**どこが重いかを推測しない。** VM の命令実行回数を数えるのが一番速い
（`run()` の頭に `++g_opcount[op]` を置いて `atexit` で出す）。
赤黒木4万件で 4億67万命令、内訳は:

| 命令 | 割合 | | 命令 | 割合 |
| --- | --- | --- | --- | --- |
| `LDG` | 24.6% | | `SELR` | 9.2% |
| `LD` | 24.0% | | `LDF` | 6.4% |
| `APP` | 12.4% | | `RTN` | 5.6% |
| `TAPP` | 12.1% | | `LDC` | 2.7% |
| | | | `SEL` / `JOIN` | 1.1% / 1.1% |

読み方の例: `SEL` と `JOIN` は合わせて 2.2% しかないので、`if` を
ジャンプ命令に変えても効く余地はその範囲を超えない。一方 `LDF` の 6.4% は
**そのすべてがヒープ確保**だったので、そこを消すのが効いた。

**測定の床は ±2%。** 意味のないダミー関数を1つ足しただけの版で同じベンチが
±2% 動く。単発の `time` ではなく、版を交互に走らせた最小値で比べること
（`dev_memo.md` 決定57）。

**`gprof` の呼び出し回数は当てにならない。** `-O2` で同じ本体の関数が
マージされるため、実際には1回しか呼ばれない `make_port` が91万回と出る。
自分で数えるほうが速く、正しい。

---

## 9. マクロ

### 9.1 define-macro

**`define-macro` によるマクロのみ。`syntax-rules` はない**（凍結仕様）。

```scheme
(define-macro (my-if c t e) `(cond (,c ,t) (else ,e)))
(my-if #t 'yes 'no)   ; => yes
```

`DEFM` 命令が変換子（クロージャ）を `GlobalCell::macro` に入れる。
コンパイラは適用をコンパイルする直前に `macro_expand_1_expr` を呼び、
展開されたら作り直す。

変換子の呼び出しには VM を1回まわす（`apply_callable`）。つまり
**マクロは Scheme のプログラムであり、処理系の全機能が使える。**

展開結果の位置は第3.1節の「展開後の位置」を見ること。**エラーはマクロの
定義側ではなく、マクロを呼んだ行を指す。**

衛生的ではないので、変数捕捉は `gensym` で自分で避ける。

```scheme
(define-macro (swap! a b)
  (let ((tmp (gensym "tmp")))
    `(let ((,tmp ,a)) (set! ,a ,b) (set! ,b ,tmp))))
```

### 9.2 準クオート

`` ` `` `,` `,@` を `cons` / `append` の呼び出し列に落とす。

- `,@` は内部的に `splice` というシンボル（`unquote-splicing` ではない）
- **ネストは未対応。** `` `(a `(b ,,x)) `` は正しく展開されない
- `` `(a . ,@v) `` は R5RS で不正。黙って壊れた結果を返さずにエラーにする

### 9.3 展開を観察する

`macroexpand-1` / `macroexpand` は原典 `micro_Scheme8.lisp` にあって
scheme12 で失われていた道具で、scheme13 で復活させた
（`dev_memo.md` 決定38）。

```scheme
(macroexpand-1 '(let ((x 1) (y 2)) (+ x y)))
; => ((lambda (x y) (+ x y)) 1 2)

(define-macro (swap! a b) `(let ((tmp ,a)) (set! ,a ,b) (set! ,b tmp)))
(macroexpand-1 '(swap! p q))
; => (let ((tmp p)) (set! p q) (set! q tmp))
(macroexpand '(swap! p q))
; => ((lambda (tmp) (set! p q) (set! q tmp)) p)
```

**1段の順序はコンパイラと同じ**（特殊形式が先、ユーザマクロが後）。
ここを違えると、この道具で見た展開と実際にコンパイルされる展開がずれて、
道具として意味が無くなる。`expand_one_step()` に1箇所だけ書いてある。

`macroexpand` は CL と同じく**外側だけ**を繰り返す。部分式へは降りない。
自分自身に展開するマクロで止まらなくなるので上限1000段を置いてある。

```
Fatal error: t.scm:1:8: macroexpand: expansion did not terminate
  note: the outermost form still expands after 1000 steps;
        a macro is probably expanding into itself
```

---

## 10. プリミティブと標準ライブラリ

### 10.1 三層構造

| 層 | 実体 | 個数 |
| --- | --- | --- |
| 特殊形式 | コンパイラの生成規則 | 19 |
| プリミティブ | C++ の関数ポインタ | 110 |
| ライブラリ | Scheme で書かれた定義 | 68（`system_lib.scm` 33 + `lib13.scm` 35） |
| 定数 | `T` `TRUE` `true` `FALSE` `false` `NIL` `nil` `:undef` `eof-object` | 9 |

合計 **206 個**の大域名が起動時に定義される。数え方:

```sh
printf '(globals)\n' | ./scheme13/scheme13 | grep -c ' : '            # 206
printf '(globals)\n' | ./scheme13/scheme13 | grep -c PRIMITIVE        # 110
printf '(globals)\n' | ./scheme13/scheme13 | grep -c SPECIAL-FORM     #  19
```

`%` で始まる3つ（`%values->list` / `%wind-push` / `%wind-pop`）は
**`lib13.scm` が使うための内部名**で、利用者が直接呼ぶものではない
（第10.10節）。

`system_lib.scm` は 34 個の `define` と 1 個の `define-macro`（`delay`）を
持つが、`cdddr` と `memv` はプリミティブが先に定義済みなので読み飛ばされ、
実際に増えるのは 33 個である（第10.5節の読み込み順）。

### 10.2 特殊形式（19）

```
quote  if  lambda  define  define-macro  set!
call/cc  call-with-current-continuation  apply  begin
let  let*  letrec  and  or  cond  case  do  quasiquote
```

**値としては特殊形式オブジェクト**として大域に束縛されている。
`(procedure? call/cc)` が `FALSE` なのはこのため。

### 10.3 プリミティブ（110）

```cpp
using PrimitiveFn = ValuePtr (*)(ValuePtr* argv, std::size_t argc);
```

`argv` は **VM のスタック上の区間をそのまま指す**。書き換えても保持しても
いけない。

| 分類 | 名前 |
| --- | --- |
| 算術 | `+` `-` `*` `/` `modulo` |
| 比較 | `=` `<` `>` `<=` `>=` |
| ペア・リスト | `cons` `car` `cdr` `set-car!` `set-cdr!` `caar` `cadr` `cdar` `cddr` `caddr` `cdddr` `list` `length` `append` `list?` `memq` `memv` `assq` |
| 述語 | `eq?` `eqv?` `equal?` `null?` `pair?` `atom?` `number?` `string?` `symbol?` `vector?` `boolean?` `procedure?` `eof-object?` `not` |
| 文字列 | `string-length` `string-ref` `string-set!` `make-string` `string-append` `substring` `string=?` `string<?` `string>?` `string<=?` `string>=?` `char->integer` `integer->char` `string->list` `list->string` `symbol->string` `string->symbol` `number->string` `string->number` |
| ベクタ | `make-vector` `vector` `vector-length` `vector-ref` `vector-set!` `vector->list` `list->vector` |
| 入出力 | `display` `write` `newline` `write_newline` `write-char` `open-input-file` `open-output-file` `close-input-port` `close-output-port` `read` `read-char` `peek-char` `char-ready?` `read-line` `read-expr` `current-input-port` `current-output-port` `input-port?` `output-port?` `load` |
| 多値・動的拡張 | `values` `%values->list` `%wind-push` `%wind-pop` |
| その他 | `error` `gensym` `random` `random-seed` `gc-collect` `gc-heap-size` `gc-free-bytes` |
| テスト機構 | `test-start` `test-end` |
| デバッグ | `compile` `disassemble` `trace-on` `trace-off` `globals` `macros` `help` `macroexpand-1` `macroexpand` |

`write_newline` は scheme12 が残していた旧 API 名で、互換のために
`newline` の別名として登録してある。

`memv` は `memq` と同じ実装。**`memq` / `assq` は数値を値で比べる**
（scheme12 はポインタ比較）。理由は第13章。

### 10.4 エラー報告の入口

プリミティブのエラーは3種類しかない。文面を各プリミティブに組み立てさせない
（`dev_memo.md` 決定33）。

| 入口 | 使うとき |
| --- | --- |
| `prim_error(who, what)` | 見出しだけで足りるもの（`division by zero` など） |
| `prim_type_error(who, expected, got)` | 型が違う → `expected:` / `given:` |
| `prim_range_error(who, what, subject, got, limit)` | 範囲外の添字 |
| `need_args(who, argc, lo, hi)` | 引数の個数 |

位置は付けない。VM が実行中の命令の位置を後から埋める。

### 10.5 標準ライブラリ

起動時に**2つのファイル**を、この順で読む。

| ファイル | 中身 | 所有 |
| --- | --- | --- |
| `system_lib.scm` | `map` `filter` `for-each` `fold-left` `fold-right` `reverse` `memv` `assv` `caaar` 系、遅延評価（`delay`/`force`）、キュー、素数、その他 | **scheme12 と共有。触らない** |
| `scheme13/lib13.scm` | R5RS にあって scheme13 に無かった 35 個 | scheme13 |

**順序に意味がある。** `load_library_dedup` は定義済みの名前を飛ばすので、
先に読んだほうが勝つ。`system_lib.scm` を先に読むことで、**既存資産の
振る舞いを scheme13 が変えないことを保証している。**

`system_lib.scm` の `map` / `filter` / `for-each` / `fold-*` には
「C++ のプリミティブ版を上書きして、コールバック内の `call/cc` による脱出が
正しく伝わるようにする」という趣旨のコメントが付いている。

**ただし scheme13 にも scheme12 にも、これらのプリミティブは存在しない**
（`table[]` に無い）。コメントはより古い版の事情を写したものと思われ、
実際には上書きは起きておらず、これらは単にライブラリの定義である。
理由づけ自体は正しい（C++ のループフレームは継続に素通りされない）ので、
**将来これらをプリミティブ化しようとするときは、この点を思い出すこと。**

### 10.6 lib13.scm（35）

入れる基準は **「R5RS にあって scheme13 に無いもの」の一本**。
`sort` / `reduce` / `string-upcase` のような便利な非標準手続きは入れない
（`dev_memo.md` 決定42）。

| 分類 | 名前 |
| --- | --- |
| 数値述語 | `integer?` `rational?` `real?` `complex?` `exact?` `inexact?` `zero?` `positive?` `negative?` `even?` `odd?` |
| 算術 | `abs` `max` `min` `quotient` `remainder` `gcd` `lcm` `expt` `sqrt` |
| 丸め | `floor` `ceiling` `truncate` `round` |
| リスト | `list-tail` `list-ref` `member` `assoc` |
| 文字列・ベクタ | `string` `string-copy` `string-fill!` `vector-fill!` |
| 多値・動的拡張 | `call-with-values` `dynamic-wind` |
| 内部ヘルパ | `list-tail-checked` |

凍結仕様に合わせた判断:

- 整数しか無いので、数値塔の述語（`integer?` / `rational?` / `real?` /
  `complex?`）はすべて `number?` に潰れる。整数は有理数でも実数でも複素数でも
  あるので嘘ではない。`exact?` は常に真、`inexact?` は常に偽
- **`sqrt` は平方根の整数部**を返す。R5RS の「正確でなければ不正確な数を
  返す」は、不正確な数が無いので採れない
- **`expt` の負の指数と `sqrt` の負の引数はエラー。** 黙って 0 を返さない
- `floor` / `ceiling` / `truncate` / `round` は整数では恒等。名前を
  受け付けること自体に意味がある（他所のコードがそのまま動く）
- `string` は文字が長さ1の文字列なので `string-append` そのもの

`list-tail-checked` は `list-tail` と `list-ref` が共有する内部ヘルパで、
利用者が呼ぶものではない。**報告する添字は元の `k`** でなければならず
（内側で減った途中の値を出すと利用者が渡していない数が `given:` に出る）、
**見出しの名前も呼んだ側のもの**でなければならない（`list-ref` から来たときに
`list-tail` と名乗らない）。その2つを一箇所に閉じ込めるために切り出してある。

> この名前だけ、決定60 の「内部名には `%` を付ける」に従っていない。
> 8日目に置いたもので、規約は13日目に決めたためである。

### 10.7 ライブラリの探索

**見つからないと約60個の手続きが消える**ので、探索は5箇所を見て、
失敗したら黙らずに警告する（`dev_memo.md` 決定39）。

```
1. 環境変数（SCHEME13_LIB / SCHEME13_LIB13）
2. 実行ファイルの隣
3. 実行ファイルの1つ上   <- scheme13/scheme13 ならリポジトリのルート
4. カレントディレクトリ
5. カレントディレクトリの1つ上
```

見つからないとき:

```
scheme13: warning: system_lib.scm not found; the shared library
(reverse, map, append, ...) is unavailable.
  looked in:
    ./system_lib.scm
    ...
  set SCHEME13_LIB to its path, or run from the directory that holds it.
```

### 10.8 データ構造ライブラリ

`rbtree_lib_improved.scm`（赤黒木）と `hashtable_lib.scm`（ハッシュテーブル）は
**scheme12 から一字も変わっていない共有資産**で、scheme13 でもそのまま動く
（ゴールデンで確認済み。第12章）。

アルゴリズムの詳細解説は `scheme12_debug解説.md` の §10 と付録C にある。
**同じ内容をここに複製しない。** 二重管理はずれる元で、あちらの記述は
ファイルが変わっていない限り有効である。

使い方だけ挙げておく:

```scheme
(load "rbtree_lib_improved.scm")
(define t (rb-empty))
(set! t (rb-insert t 5 'five))
(rb-lookup t 5)
```

### 10.9 ポート

ポートは `Port` オブジェクト1種類で、`FILE*` と向き（入力か出力か）を持つ。
`open-input-file` / `open-output-file` が作り、`close-input-port` /
`close-output-port` が閉じる。閉じたポートは `#<closed-port>` と表示される
（第2.3節）。**閉じてもポートであることと向きは変わらない**ので、
`(input-port? p)` は閉じたあとも真を返す（R5RS）。

**確保の経路は `make_port` / `make_std_port` の2つに限る。** ファイルを
開くポートには必ずファイナライザを登録する。登録を忘れるとディスクリプタが
枯渇する（scheme12 の実バグ。第1.6節）。開くときは `EMFILE` / `ENFILE` を
見て、`GC_gcollect()` に加えて **`GC_invoke_finalizers()` まで呼んでから**
1回だけやり直す。前者だけではファイナライザがキューに積まれるだけで、
まだ閉じられていない。

#### 標準ポート

`stdin` と `stdout` は**値として1つずつ**あり、`(current-input-port)` /
`(current-output-port)` がそれを返す。R5RS では**変数ではなく手続き**なので、
`(procedure? current-output-port)` は `TRUE`。

```scheme
(current-output-port)                 ; => #<output-port>
(eq? (current-output-port) (current-output-port))   ; => TRUE
(output-port? (current-output-port))  ; => TRUE
(input-port? (current-output-port))   ; => FALSE
```

`display` / `write` / `newline` / `write-char` は port 引数を省くと、
この値の `FILE*` へ書く。**`stdout` を直に書く場所はもう無い。**
`read-char` / `peek-char` / `char-ready?` / `read-line` / `read` /
`read-expr` も同様に、省けば `(current-input-port)` から読む。

標準ポートは `FILE*` を**所有しない**（`owns_fp` が偽）。所有しない
ポートは `close()` が何もしないので、`(close-output-port (current-output-port))`
は真を返すが実際には閉じない。`fclose(stdout)` を一度でも許すと、
以後の出力がすべて黙って消えるためである。ファイナライザも登録しない。

いまのところ差し替えの仕組みは無い（`with-output-to-file` は未実装）。
入れるとすれば `g_stdout_port` を差し替えるだけで済むように、既定の
出力先はすべてこの値を経由させてある。

#### 先読みと char-ready?

`Port` は1文字の先読み（`has_peek` / `peek_ch`）を持つ。`peek-char` は
1文字読んでここに置き、`read-char` は先に取り出す。**入力は必ず
`get_char` / `peek_char` / `unget_char` を通すこと。** `std::fgetc` を
直に呼ぶと先読みの1文字が消える。`read-line` と `read` も通している。

```scheme
(define in (open-input-file "x.txt"))   ; 中身は abc
(peek-char in)   ; => "a"
(peek-char in)   ; => "a"   消費しない
(read-char in)   ; => "a"
(read-char in)   ; => "b"
```

`char-ready?` は「いま読んでも待たされないか」を答える。R5RS の契約は
**「真なら次の `read-char` は待たない」の一方向だけ**なので、判断が付かない
ときは偽へ倒すのが安全である。

- 先読みを持っていれば無条件に真
- そうでなければ POSIX の `poll(2)` をタイムアウト 0 で引く。通常ファイルは
  常に読めるので真（EOF も「待たない」ので真）
- `_WIN32` では対応する術がないので常に真を返す

```scheme
(char-ready? (current-input-port))
;  端末で入力待ちなら FALSE、パイプにデータが来ていれば TRUE
```

### 10.10 多値

**多値は「1個なら値そのもの、それ以外は `Values` の箱」**とした
（`dev_memo.md` 決定58）。VM が返り値を複数運ぶ設計にはしていない。

```scheme
(values 5)                                        ; => 5          箱に入れない
(values 1 2)                                      ; => #<values 1 2>
(values)                                          ; => #<values>
(call-with-values (lambda () (values 4 5)) (lambda (a b) b))   ; => 5
(call-with-values (lambda () 7) list)             ; => (7)       1値も同じ扱い
(call-with-values * -)                            ; => -1        R5RS 6.4 の例
```

`call-with-values` は `lib13.scm` に3行で書ける。

```scheme
(define call-with-values
  (lambda (producer consumer)
    (apply consumer (%values->list (producer)))))
```

`%values->list` は箱ならその中身のリスト、箱でなければ1要素のリストを返す。
だから producer が1値を返しても多値を返しても同じ道で扱える。

**R5RS との差**: 多値を受け取る用意のない継続へ渡したとき、R5RS は未規定
（多くの処理系ではエラー）だが、scheme13 では `#<values 1 2>` という**値が
1つ**流れる。踏むと型エラーになって場所も出るので、黙って壊れることはない。

```
(car (values 1 2))
;  car: wrong type of argument
;    expected: a pair
;    given: #<values 1 2>
```

`dynamic-wind` の実装は第8.3節を見ること。

---

## 11. REPL とデバッグ機能

### 11.1 起動オプション

```
scheme13                Start interactive REPL
scheme13 --load FILE    Evaluate file and exit
scheme13 --selftest     Check against the frozen spec
scheme13 --read FILE    Print the S-expressions as read
scheme13 --expand FILE  Print the S-expressions after syntax expansion
scheme13 --help         Show this help
```

`--read` と `--expand` はリーダと展開器を単体で動かす道具である。
**`--expand` はコンパイラの経路とは別物**で、フォームとその部分式を
書き換えられなくなるまで展開する。展開器が実コードで落ちないことを見るための
もので、`tests/compare_expand.sh` がこれを使って scheme12 との等価性を
確かめている。

### 11.2 REPL

複数行の入力に対応する。括弧が閉じるまで `...>` を出して読み続ける。
エラーは `Error:` を付けて報告し、**次の入力へ進む**（終了しない）。

```
$ scheme13
scheme13 debug REPL. Type (help) for commands.
scheme13> (car 5)
Error: <stdin:1>:1:1: car: wrong type of argument
  expected: a pair
  given: 5
    (car 5)
    ^
scheme13> (+ 1 2)
3
scheme13>
Bye!
```

REPL で入力した式は `<stdin:N>` という名前のソースとして登録されるので、
**キャレット行が REPL でも出る。** N は入力の通し番号。

### 11.3 デバッグコマンド

```
Inspection:
  (globals)              List all global variables
  (macros)               List all macros

Compilation:
  (compile expr)         Compile and show bytecode
  (disassemble closure)  Show closure internals

Expansion:
  (macroexpand-1 'form)  Expand the form one step, as the compiler would
  (macroexpand 'form)    Expand the outermost form until it stops changing

Tracing:
  (trace-on)            Enable VM step-by-step trace
  (trace-off)           Disable trace
```

`(compile expr)` は式をコンパイルして命令列を見せる。**引数は評価されるので、
式そのものを見たければクオートする**（`(compile '(+ 1 2))`）。

`(disassemble closure)` はクロージャの中身を見せる。マクロを渡すと変換子を
逆アセンブルする。

```
=== Disassembly ===
Parameters: (x)
Body:
[0] LD (0 . 0)
[1] LD (1 . 0)
[2] LDG +
[3] TAPP 2
[4] RTN
Environment: 1 frame(s)
===================
```

`(trace-on)` は命令ごとに PC・命令・スタック・環境・ダンプを表示する。
出力量が多いので、絞り込んでから使うこと。

```
==== Step 1 ====
PC: 1
Instruction: LDC 3
Stack:
  [0] 2
Environment: (empty)
Dump: 0 frame(s)
```

### 11.4 GC の観察

```scheme
(gc-heap-size)    ; ヒープの大きさ
(gc-free-bytes)   ; 空き
(gc-collect)      ; 明示的な回収
```

---

## 12. テストと受け入れ基準

4つの層がある。**セクションに手を入れたら3つ全部を通すこと。**

```sh
make -C scheme13 selftest   # 150 checks — 凍結仕様との突き合わせ（C++ 単体）
make -C scheme13 compare    #  15 passed — 構文展開が scheme12 と等価か
make -C scheme13 test       #  17 passed — 既存 .scm 資産との互換性（受け入れ基準）
make -C scheme13 bench      # 呼び出し性能
```

### 12.1 --selftest（183項目）

処理系を C++ 単体で検査する。**起動時ライブラリを読む前に走る**ので、
ここで見られるのは処理系そのものだけである。

| 群 | 見るもの |
| --- | --- |
| `selftest_display` | §2.1 の表示をすべて固定 |
| `selftest_reader` | 読み方（角括弧、コメント、エスケープ） |
| `selftest_expand` | 構文展開と内部 define |
| `selftest_positions` | 位置の記録とキャレット行 |
| `selftest_eval` | 評価（算術・クロージャ・末尾呼び出し・継続・fixnum 境界） |
| `selftest_errors` | **エラー本文の形**（第3.2節） |
| `selftest_macro_positions` | **展開後のエラーがどこを指すか**（第3.1節） |
| `selftest_macroexpand` | 展開の観察 |
| `selftest_test_matching` | テスト機構の照合規則 |

### 12.2 ゴールデン（14件）+ 起動時ライブラリ（3件）

既存 `.scm` 資産を走らせ、**出力全体をバイト単位で**ゴールデンと比べる。
これが「既存 `.scm` を無修正で動かす」の唯一の判定基準である。

ゴールデンは scheme12 の出力である。ただし3件だけ例外がある。

| ファイル | 例外の理由 |
| --- | --- |
| `test-case6.scm` | scheme13 でテスト機構を復活させたため、出力そのものが別物 |
| `scheme13/tests/lib13_test.scm` | scheme13 自身のテスト。scheme12 に比べる相手が無い |
| `scheme13/tests/port_test.scm` | 同上（ポート。第10.9節） |

加えて **cwd を変えて起動する回帰が3件**入っている（合計 17 件）。
ゴールデンは全部リポジトリのルートから走るので、これが無いと
ライブラリ探索の壊れ方に気づけない（第10.7節）。

### 12.3 原典のテスト機構

`test-case6.scm` は原典 `micro_Scheme8.lisp` の対話記録で、
**式とその期待値が交互に並んだ 145 項目のテストスイート**である。

```scheme
(test-start)
T

(quote a)
A

(car '(a b c))
A
```

`(test-start)` でモードが立ち、以後**フォームを1つ評価するごとに次の
S 式を期待値として読み、照合して結果を印字する。** `(test-end)` で降りる。

照合は **`write` 表現を大小文字を無視して比べる**（`dev_memo.md` 決定30）。
期待値は Common Lisp のリーダを通った綴りなのですべて大文字だが、scheme13 の
リーダは大小文字を保存するので、値そのものの `equal?` では一致しない。
転写の意図は「**表示がこうなる**」なので、表示を比べるのが最も素直である。

```
( total: 145  pass: 132  NG: 13 )
```

**NG 13件は直すべきバグではなく、凍結仕様の帰結である。**

| 件数 | 内容 |
| --- | --- |
| 10 | クロージャ・継続の表示。原典は `(CLOSURE <命令列> <環境>)`、scheme13 は `#<closure:(x)>` |
| 2 | `(begin)` と `(if #f 10)` が `NIL`。原典は `:UNDEF` |
| 1 | `(test-start)` が `TRUE`。原典は CL の `T` |

**この 13 という数が動いたら回帰**である。ゴールデンが出力全体を押さえて
いるので、どの項目が変わったかまで差分に出る。

### 12.4 展開の等価性（15件）

`tests/compare_expand.sh` は、同じフォームを

- (a) そのまま scheme12 にコンパイルさせたもの
- (b) scheme13 が展開した式を scheme12 にコンパイルさせたもの

の2通りで比べ、**命令列が一致すること**を見る。構文展開だけを取り出して
検証する仕掛けで、コンパイラと VM がまだ無い段階でも走った。

**制約が1つある。** §2.1 のとおり `write` の出力は読み戻せず、
`NIL` / `TRUE` / `FALSE` は自分自身に読み戻らない（空リストではなく
シンボルとして読まれる）。スクリプトは読み戻せる綴りに書き換えてから
scheme12 に渡しているので、**`NIL` / `TRUE` / `FALSE` という名前の
シンボルを含むフォームは扱えない。**

---

## 13. scheme12 との互換性

### 13.1 実測で一致していること

| 観点 | 結果 | 測り方 |
| --- | --- | --- |
| 大域名 | **差ゼロ**（scheme12 の 156 個すべてあり） | `(globals)` の集合を `comm` |
| 既存 `.scm` 資産の出力 | **11/12 がバイト単位で一致** | ゴールデン |
| 構文・マクロ展開 | 15件一致 | `make compare` |
| 凍結仕様 §2 | 183項目で固定 | `make selftest` |

名前の集合を測る手順（主張するなら必ずこれで測ること。
`dev_memo.md` 決定40）:

```sh
printf '(globals)\n' | ./scheme12_debug    | grep ' : ' | sed 's/ : .*//' | sort > /tmp/g12
printf '(globals)\n' | ./scheme13/scheme13 | grep ' : ' | sed 's/ : .*//' | sort > /tmp/g13
comm -23 /tmp/g12 /tmp/g13    # scheme12 にあって scheme13 に無いもの -> 空
```

### 13.2 意図的に違えていること

**1. `memq` / `assq` の数値比較**（`dev_memo.md` 決定28）。
唯一の、正常系の振る舞いの差である。

```scheme
(memq 100000000000 '(100000000000 2))
;  scheme12 -> FALSE                    ポインタ比較なので数値は絶対に一致しない
;  scheme13 -> (100000000000 2)
```

scheme12 の `prim_memq` は生のポインタ比較なので `(memq 3 '(1 2 3))` すら
`FALSE` になる。scheme13 は小さい整数が即値なのでポインタ比較でも一致して
しまい、**どちらにしても scheme12 とは違う結果になる。** それなら §2.2 の
凍結仕様「`eq?` は数値を値比較」と揃えるほうが筋が通る。

影響範囲: `case` は `memv` に展開されるので無影響。ゴールデン17件にも無影響。

**2. エラーメッセージの文面。** 第3章の形に全面的に書き直した。
**正常に走るプログラムの出力には影響しない。**

**3. `test-case6.scm` の出力。** テスト機構を復活させたため別物になった。

### 13.3 上位互換であること

scheme13 は **206 名**、scheme12 は **156 名**。scheme12 のコードは
scheme13 で動くが、**逆は動かない場合がある**。

差分の 50 個: `lib13.scm` の 35 個 + `error` + `macroexpand-1` +
`macroexpand` + `test-start` + `test-end` + ポートの 6 個
（`current-input-port` `current-output-port` `input-port?` `output-port?`
`peek-char` `char-ready?`）+ 多値と動的拡張の 4 個
（`values` と内部名 3 つ）。

port 引数を**省けるようになった**手続きもある（`write-char` `read-char`
`read-line` `read` `read-expr`）。scheme12 は必ずポートを要求した。
引数を増やす方向ではないので、既存のコードは影響を受けない。

### 13.4 証拠の範囲

一致の根拠は**リポジトリにある 12 個の `.scm` 資産と selftest 183 項目**で、
証明ではない。とくに、**既存資産はどれもエラーを踏まずに走りきる**ので、
ゴールデンが押さえているのは「正常に走るプログラムの出力」だけである。
エラー経路の互換性は測っていない（意図的に変えたので、測る意味も薄い）。

### 13.5 原典 micro_Scheme8.lisp との差異

| 項目 | 原典 | scheme13 |
| --- | --- | --- |
| クロージャの表示 | `(CLOSURE <命令列> <環境>)` | `#<closure:(x)>` |
| `(begin)` `(if #f 10)` | `:UNDEF` | `NIL` |
| シンボルの大小文字 | CL のリーダが大文字化 | **保存する** |
| `macroexpand` | あり | あり（scheme13 で復活） |
| `code` 特殊形式 | あり | **入れない**（使い道がない） |
| 有理数 | あり | **入れない**（§2.2 の「整数のみ」を壊す） |

---

## 14. 既知の制限と拡張ポイント

### 14.1 R5RS で未実装のもの

**8日目に数え上げた 40 件の不足は、13日目にすべて埋まった。**

| 日 | 埋めたもの | 残り |
| --- | --- | --- |
| 8日目 | `lib13.scm`（33個） | 8 |
| 10日目 | ポート6個（第10.9節） | 2 |
| 13日目 | `values` `call-with-values` `dynamic-wind` | **0** |

いま無いのは、8日目の数え上げに入っていなかったファイル入出力の便宜手続きである。

| 名前 | いま何が要るか |
| --- | --- |
| `call-with-input-file` / `call-with-output-file` | **Scheme で3行ずつ書ける。** 開いて渡して閉じるだけ |
| `with-input-from-file` / `with-output-to-file` | 標準ポートを差し替える口（`g_stdout_port` を入れ替えるプリミティブ）が1つ要る。戻す責任は `dynamic-wind` が持てるようになった |

**どれも「無くて困った」という報告は来ていない。**
入れるかどうかは `lib13.scm` の基準（第10.6節）ごと利用者と決める話である。

### 14.2 設計として入れないもの

- **有理数・実数・複素数。** §2.2 の「整数のみ」を壊す
- **文字型。** 文字は長さ1の文字列（§2.2）
- **`syntax-rules`。** `define-macro` のみ
- **準クオートのネスト。** `` `(a `(b ,,x)) ``
- **角括弧 `[` `]`。** 区切り文字ではない
- **`code` 特殊形式。** 原典にはあるが使い道がない
- **`sort` / `reduce` などの非標準手続き。** `lib13.scm` の基準は
  「R5RS にあって無いもの」の一本（第10.6節）

### 14.3 プリミティブを足すには

1. セクション11 に `static ValuePtr prim_xxx(ValuePtr* a, std::size_t n)` を書く
2. 先頭で `need_args("xxx", n, lo, hi)`
3. 型検査は `num_of` / `str_of` / `vec_of` / `port_of`、
   エラーは `prim_type_error` / `prim_range_error` / `prim_error`
4. `init_globals` の `table[]` に `{"xxx", prim_xxx}` を足す
5. **`argv` を書き換えない・保持しない**（VM のスタックを直接指している）
6. `--selftest` に項目を足す

**Scheme で書けるものは `lib13.scm` に書く。** プリミティブを増やす理由が
無いものを C++ に足さない。

### 14.4 命令を足すには

1. セクション9 の `Op` に足す
2. `op_name()` に足す
3. **逆アセンブラ（`disassemble_ins`）に足す。** これは義務
4. セクション8 のコンパイラで生成する
5. セクション10 の VM で実装する
6. `dev_memo.md` §4.4.5 の表を更新する
7. **使わない命令を作らない**（`dev_memo.md` 決定7）

### 14.5 性能の次の一手

**かつてここに並べていた3つは、実測で片が付いた**（`dev_memo.md` 決定54〜57）。
同じ道を二度歩かないために結果を残す。

| かつての候補 | 実測 |
| --- | --- |
| `if` を `SEL`/`JOIN` からジャンプ命令へ | `SEL`+`JOIN` は実行命令の **2.2%**。試作は人工ベンチで -8%、実ワークロードでは測定の床以下 |
| マクロ展開のメモ化 | **効く場所が無い。** 原典は実行時に展開するが、scheme13 の展開はコンパイル時に1度きり |
| `LD` の深さ0特化 | **利得ゼロ。** 深さ5の `LD` と `LDC` が同じ時間 |

代わりに効いたのは `let` のクロージャ確保をやめること（第7.3節）で、
実ワークロード **-23%** だった。

いま残っている当たりそうな場所は、測った上での見立てで:

- `LDG`（24.6%）と `LD`（24.0%）が実行命令の半分。どちらも既に
  「ポインタを1つ辿って積む」だけで、削る余地は見えない
- 呼び出し（`APP`+`TAPP` で 24.5%）。`make_frame` の1確保をさらに減らすなら、
  **引数が固定数のときフレームをスタック上に置く**案があるが、継続が
  スタックをコピーする設計（第8.3節）と噛み合うか要検討。**重い**
- 命令ディスパッチそのもの（computed goto）。**第7.4節の逆アセンブラと
  第11.3節のトレースの読みやすさを確実に損なうので、必要になるまでやらない**

**新しい候補を足すときは、先に命令の実行回数を数えること**（第8.4節）。

---

## 付録A. 逆アセンブル例

実機の出力をそのまま貼る。

### A.1 単純な式

```
scheme13> (compile '(+ 1 2))

=== Compiled Code ===
[0] LDC 1
[1] LDC 2
[2] LDG +
[3] APP 2
[4] STOP
=====================
```

**引数を左から積んでから演算子を積む**のが分かる（第6.3節）。

### A.2 条件分岐

```
scheme13> (compile '(if (> x 0) 'pos 'neg))

=== Compiled Code ===
[0] LDG x
[1] LDC 0
[2] LDG >
[3] APP 2
[4] SEL
      then:
        [0] LDC pos
        [1] JOIN
      else:
        [0] LDC neg
        [1] JOIN
[5] STOP
=====================
```

末尾でない `if` なので `SEL` + `JOIN`。枝は別の `Code` になっていて、
逆アセンブラが字下げして入れ子で見せている。

### A.3 再帰関数

```
scheme13> (compile '(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))))

=== Compiled Code ===
[0] LDF (n) ; fact
      body:
        [0] LD (0 . 0)
        [1] LDC 0
        [2] LDG =
        [3] APP 2
        [4] SELR
              then:
                [0] LDC 1
                [1] RTN
              else:
                [0] LD (0 . 0)
                [1] LD (0 . 0)
                [2] LDC 1
                [3] LDG -
                [4] APP 2
                [5] LDG fact
                [6] APP 1
                [7] LDG *
                [8] TAPP 2
                [9] RTN
        [5] RTN
[1] DEF fact
[2] STOP
=====================
```

読みどころ:

- `LDF (n) ; fact` — `Template::name` が付いているので `; fact` が出る
- `SELR` — **末尾位置の `if`**。`JOIN` を使わず、枝がそのまま `RTN` する
- `[8] TAPP 2` — `(* n ...)` が末尾なので `TAPP`。**`fact` の再帰呼び出し
  自体は `APP`**（`*` の引数だから末尾ではない）。この関数は末尾再帰では
  ないので、深さに比例してダンプが伸びる

### A.4 クロージャ

```
scheme13> (define (make-adder n) (lambda (x) (+ x n)))
scheme13> (define add5 (make-adder 5))
scheme13> (disassemble add5)

=== Disassembly ===
Parameters: (x)
Body:
[0] LD (0 . 0)
[1] LD (1 . 0)
[2] LDG +
[3] TAPP 2
[4] RTN
Environment: 1 frame(s)
===================
scheme13> (add5 10)
15
```

`LD (0 . 0)` が `x`（自分のフレーム）、`LD (1 . 0)` が `n`（1つ外の
フレーム＝捕まえた環境）。`Environment: 1 frame(s)` がその捕捉を示している。

---

## 付録B. 継続の動作例

### B.1 基本的な脱出

```scheme
(+ 1 (call/cc (lambda (k) (k 10) 999)))   ; => 11
```

`(k 10)` で継続が起動し、`999` は評価されない。

### B.2 脱出しない場合

```scheme
(+ 1 (call/cc (lambda (k) 10)))   ; => 11
```

継続を使わなければ、手続きの値がそのまま `call/cc` の値になる。

### B.3 トップレベルのフォームを跨ぐ継続

**挙動が直観に反するので注意。** 実機の出力:

```scheme
(define saved #f)
(define n 0)
(set! n (+ 1 (call/cc (lambda (c) (set! saved c) 1))))
(if (< n 5) (saved n) n)
; => 3
```

素朴に読むと `n` が 5 になるまでループしそうだが、**3 で止まる。**

理由は §2.7 の凍結仕様にある。**トップレベルのフォームは個別に評価される。**
捕捉された継続は3番目のフォームの途中を指しているので、`(saved n)` で
そこへ跳ぶと、そのフォーム（`(set! n ...)`）が完了して**次のフォームへ
進む**。4番目のフォームの残りは実行されない。

- 1周目: `n = 1 + 1 = 2`。`(if (< 2 5) (saved 2) 2)` -> 継続へ跳ぶ
- 2周目: `n = 1 + 2 = 3`。3番目のフォームが終わり、4番目へ進む。
  `(if (< 3 5) (saved 3) 3)` -> 継続へ跳ぶ
- 3周目: `n = 1 + 3 = 4`... **ではなく**、フォームの評価が完了して 3 が残る

この値（3）は scheme12 でも実測して同じであることを確認してあり、
`--selftest` の `"call/cc across top-level forms"` で固定してある。

### B.4 dynamic-wind を跨いだ脱出

継続で外へ跳ぶと、**内側の `after` から順に**走る（第8.3節）。実機の出力:

```scheme
(define path '())
(define (add s) (set! path (cons s path)))

(display
 (call/cc (lambda (esc)
   (dynamic-wind (lambda () (add 'a-in))
     (lambda () (dynamic-wind (lambda () (add 'b-in))
                              (lambda () (esc 'escaped))
                              (lambda () (add 'b-out))))
     (lambda () (add 'a-out))))))
(newline)
(display (reverse path))
;  escaped
;  (a-in b-in b-out a-out)
```

### B.5 R5RS 6.4 の例（再入つき）

**脱出だけでなく再入も動く。** R5RS の原文にある例を、そのまま:

```scheme
(let ((path '()) (c #f))
  (let ((add (lambda (s) (set! path (cons s path)))))
    (dynamic-wind
      (lambda () (add 'connect))
      (lambda ()
        (add (call-with-current-continuation
              (lambda (c0) (set! c c0) 'talk1))))
      (lambda () (add 'disconnect)))
    (if (< (length path) 4)
        (c 'talk2)
        (reverse path))))
;  (connect talk1 disconnect connect talk2 disconnect)
```

`(c 'talk2)` が `dynamic-wind` の**中へ**跳び戻るので、`connect` が
もう一度走ってから `talk2` が積まれ、最後に `disconnect` で抜ける。

**継続を使う例は1つのトップレベルのフォームに閉じて書くこと。**
フォームを跨ぐと B.3 の癖が効いてしまう。この例が `let` で全体を包んで
いるのはそのためで、R5RS の原文もそう書かれている。
`tests/lib13_test.scm` に同じものが入っている。

---

## 付録C. エラーメッセージ一覧

すべて実機の出力。形の規則は第3.2節。

### C.1 型が違う

```
Fatal error: t.scm:1:1: car: wrong type of argument
  expected: a pair
  given: 5
    (car 5)
    ^

Fatal error: t.scm:1:1: length: wrong type of argument
  expected: a proper list
  given: (1 . 2)
    (length (cons 1 2))
    ^

Fatal error: t.scm:1:1: read-char: wrong type of argument
  expected: an open input port
  given: #<output-port>
    (read-char (current-output-port))
    ^
```

ポートは「ポートですらない」と「向きが違う（あるいは閉じている）」を
言い分ける。前者は `expected: a port`、後者は `expected: an open input port`
（第10.9節）。

### C.2 引数の数が違う

```
Fatal error: t.scm:1:26: f: wrong number of arguments
  expected: 2 arguments
  given: 1
    (define (f a b) (+ a b)) (f 1)
                             ^

Fatal error: t.scm:1:1: #<closure:(a b)>: wrong number of arguments
  expected: 2 arguments
  given: 1
    ((lambda (a b) a) 1)
    ^
```

名前が付いていれば名前、無名なら表示形。

### C.3 範囲外

```
Fatal error: t.scm:1:1: vector-ref: index out of range
  expected: an element index from 0 to 2
  given: 7
    (vector-ref (vector 1 2 3) 7)
    ^

Fatal error: t.scm:1:1: vector-ref: index out of range
  expected: an element index, but the vector is empty
  given: 0
    (vector-ref (vector) 0)
    ^

Fatal error: t.scm:1:1: integer->char: argument out of range
  expected: an ASCII code from 0 to 127
  given: 999
    (integer->char 999)
    ^
```

空の入れ物に「0 から -1 まで」と言わせない。値そのものの範囲は
`argument out of range` で、添字の `index out of range` と見出しを分ける。

### C.4 構文

```
Fatal error: t.scm:1:1: bad syntax in let
  expected: each binding to be (variable expression)
  given: (x)
    (let ((x)) x)
    ^

Fatal error: t.scm:1:1: bad syntax in set!
  expected: the assignment target to be a symbol
  given: 5
    (set! 5 1)
    ^

Fatal error: t.scm:1:1: bad syntax in define
  variable definition needs a value expression
    (define x)
    ^
```

`given:` には**悪い部分そのもの**が出る。散文の詳細も許すが、値が手元に
あるなら `expected:` / `given:` にする。

### C.5 名前と呼び出し

```
Fatal error: t.scm:1:1: unbound variable: nosuch
  note: it is referenced here but never defined by define or set!
    (nosuch 1)
    ^

Fatal error: t.scm:1:1: attempt to call a non-procedure
  expected: a procedure
  given: 5
    (5 6)
    ^
```

### C.6 ライブラリから

```
Fatal error: t.scm:1:1: sqrt: argument out of range
  given: -4
    (sqrt -4)
    ^
```

**`lib13.scm` の中を指していない**ことに注目（第3.4節）。

### C.7 内部エラー

```
internal error: as_pair on a non-pair
  note: this is a bug in scheme13 itself, not in the program being run
```

これが出たら scheme13 の不具合である。利用者のプログラムの誤りではない。

---

## 付録D. ビルドと起動

### D.1 依存

| 依存 | 入手 |
| --- | --- |
| C++17 コンパイラ | `clang++` または `g++` |
| Boehm GC | `libgc-dev`（`gc.h` / `gc_cpp.h` / `gc_allocator.h`） |
| Boost.Multiprecision | `libboost-dev`（ヘッダのみ） |

このリポジトリの `.devcontainer/` にはすべて入っている。

### D.2 ビルド

```sh
make -C scheme13
```

`scheme13/Makefile` は**リポジトリのルートからでも `scheme13/` からでも**
叩ける。

```sh
make -f scheme13/Makefile
make -C scheme13
```

実際に走るコマンド:

```sh
clang++ -std=c++17 -Wall -Wextra -O2 -Wno-unused-function \
        -I/usr/local/include -I/usr/include \
        -o scheme13/scheme13 scheme13/scheme13.cpp \
        -L/usr/local/lib -lgc -lgccpp
```

### D.3 Makefile のターゲット

| ターゲット | 内容 |
| --- | --- |
| `all` | ビルド |
| `selftest` | 凍結仕様との突き合わせ（183項目） |
| `compare` | 構文展開が scheme12 と等価か（15件） |
| `test` | 既存 `.scm` 資産との互換性回帰（17件）← **受け入れ基準** |
| `bench` | 呼び出し性能 |
| `clean` | 生成物を削除 |
| `help` | ターゲット一覧 |

### D.4 起動

```sh
scheme13/scheme13                        # 対話 REPL
scheme13/scheme13 --load test-case6.scm  # ファイルを実行して終了
scheme13/scheme13 --help
```

**どのディレクトリから起動してもよい**（第10.7節）。ライブラリの場所を
明示したいときは環境変数を使う。

```sh
SCHEME13_LIB=/path/to/system_lib.scm SCHEME13_LIB13=/path/to/lib13.scm scheme13/scheme13
```

### D.5 ファイルの配置

```
リポジトリのルート/
├── system_lib.scm              共有ライブラリ（scheme12 と共有。触らない）
├── rbtree_lib_improved.scm     赤黒木（共有資産）
├── hashtable_lib.scm           ハッシュテーブル（共有資産）
├── test-case6.scm              原典の 145 項目テストスイート
└── scheme13/
    ├── scheme13.cpp            処理系（単一ファイル）
    ├── scheme13                実行ファイル
    ├── lib13.scm               R5RS の不足 35 個
    ├── Makefile
    ├── dev_memo.md             設計憲章・凍結仕様・決定ログ
    ├── micro_scheme8_notes.md  原典の読解メモ
    ├── scheme13解説.md         この文書
    └── tests/
        ├── run_golden.sh       ゴールデン比較
        ├── compare_expand.sh   展開の等価性
        ├── lib13_test.scm      lib13.scm の 102 項目テスト
        ├── port_test.scm       ポートの 40 項目テスト
        └── golden/             期待される出力
```

---

## まとめ

scheme13 は scheme12 と**同じ振る舞いを、選び直した設計で**実現した
Scheme 処理系である。

- 既存 `.scm` 資産はゴールデンで**バイト単位で一致**する（受け入れ基準）
- 大域名は scheme12 の 156 個をすべて含み、**50 個多い上位互換**（206 個）
- **R5RS の不足はゼロ。** 8日目に数え上げた 40 件を、`lib13.scm`（8日目）、
  ポート（10日目）、多値と `dynamic-wind`（13日目）で埋めた
- 呼び出し性能は**約 27 倍**。実ワークロード（赤黒木）は 12日目に
  さらに **-23%**（`let` がクロージャを確保しなくなった）
- エラーは位置・見出し・`expected:`/`given:` の一つの形に揃っている。
  **マクロ展開の中で落ちても、利用者が書いた行を指す**
- 逆アセンブル・トレース・マクロ展開の観察が一級市民として揃っている

数字はすべて実機から採ってある。確かめ方は第10.1節（名前と個数）、
第8.4節（性能と命令の実行回数）、第12章（テスト）にコマンドで書いた。

**手を入れるときは `dev_memo.md` の §1 設計憲章と §2 凍結仕様を先に読み、
§6 決定ログに理由を残すこと。** そして `selftest` / `compare` / `test` の
3つを通すこと。
