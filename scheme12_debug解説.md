# scheme12_debug 解説文書（最新版 v2.1）

SECD 仮想マシン方式 Scheme コンパイラ兼実行系「scheme12_debug」の設計と実装の解説

**最終更新**: 2026年9月（堅牢性・R5RS適合性の改善版）
（v2.0: 2026年8月、赤黒木ライブラリ堅牢性強化版）
（初版: 2024年1月、循環構造対応・安全性改善版）

---

## 目次

1. [全体像と設計思想](#1-全体像と設計思想)
2. [データモデル（Value系）](#2-データモデルvalue系)
3. [リーダ（Reader: S式パーサ）](#3-リーダreader-s式パーサ)
4. [コンパイラ（Compiler）](#4-コンパイラcompiler)
5. [命令セット（Instruction Set）](#5-命令セットinstruction-set)
6. [VM（実行機構）と継続（call/cc）](#6-vm実行機構と継続callcc)
7. [マクロシステム](#7-マクロシステム)
8. [プリミティブと標準ライブラリ](#8-プリミティブと標準ライブラリ)
9. [REPLとデバッグ機能](#9-replとデバッグ機能)
10. [データ構造ライブラリ](#10-データ構造ライブラリ)
11. [実用例とベストプラクティス](#11-実用例とベストプラクティス)
12. [互換性ノート](#12-互換性ノート)
13. [実装上の注意・拡張ポイント](#13-実装上の注意拡張ポイント)
14. [**最近の改善（v2.0）**](#14-最近の改善v20)
15. [**赤黒木ライブラリの堅牢性強化**](#15-赤黒木ライブラリの堅牢性強化)
16. [**最近の改善（v2.1）**](#16-最近の改善v21) ← **NEW!**

付録
- [A. コンパイル出力と逆アセンブル例](#付録a-コンパイル出力と逆アセンブル例)
- [B. 継続（call/cc）の動作例](#付録b-継続callccの動作例)
- [C. 赤黒木の詳細解説](#付録c-赤黒木の詳細解説)
- [D. ビルド・起動方法](#付録d-ビルド起動方法)

---

## 1. 全体像と設計思想

### 1.1 アーキテクチャ

**scheme12_debug**は、Common Lisp実装のmicro_Scheme8をベースに、C++17で実装されたSchemeコンパイラ兼実行系です。

```
┌─────────────────────────────────────────────┐
│           ユーザープログラム（.scm）          │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│         Reader (S式パーサ)                   │
│         S式 → Value表現への変換              │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│         Compiler (マクロ展開含む)            │
│         Value → Instruction列への変換        │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│         VM (SECD仮想マシン)                  │
│         S, E, C, D レジスタ + PC            │
└─────────────────────────────────────────────┘
                    ↓
              実行結果・出力
```

### 1.2 コア技術

#### SECD仮想マシン
- **S (Stack)**: 評価スタック
- **E (Environment)**: 環境（変数束縛）
- **C (Code)**: 実行コード
- **D (Dump)**: 継続保存領域

#### 実装言語とメモリ管理
- **言語**: C++17
- **GC**: Boehm GC（自動メモリ管理）
- **整数**: Boost.Multiprecision（任意精度整数）
  - フォールバック: long long（Boost未検出時）
  - **✨ v2.0**: 範囲オーバーフロー検出機能追加

### 1.3 主要機能

#### 基本機能
- ✅ **末尾呼出最適化（TCO）**: スタックを消費しない再帰
- ✅ **ファーストクラス継続**: call/ccによる制御フロー操作
- ✅ **マクロシステム**: define-macroによるコンパイル時展開
- ✅ **任意精度整数**: メモリが許す限りの大きな整数
- ✅ **ベクタ・文字列**: 実用的なデータ構造
- ✅ **ファイルI/O**: テキスト・バイナリ入出力

#### デバッグ機能
- ✅ **命令トレース**: VM実行のステップバイステップ表示
- ✅ **逆アセンブラ**: 関数内部のバイトコード詳細表示
- ✅ **コンパイラ出力確認**: 生成コードの検証
- ✅ **グローバル変数・マクロ一覧**: システム状態の可視化

#### v2.1 新機能 ✨ ← **NEW!**

- ✅ **循環構造対応の完成**: car方向の循環も検出。長いリストのequal?でスタックを溢れさせない
- ✅ **リーダの入力終端検出**: 閉じ括弧のないファイルで無限ループしない
- ✅ **ポートの自動回収**: 閉じ忘れてもディスクリプタが枯渇しない
- ✅ **内部define**: 本体先頭のdefineがレキシカル束縛になる（グローバルを汚さない）
- ✅ **準クオートの拡充**: ドット位置・ベクタ内の`unquote`に対応
- ✅ **call-with-current-continuation**: R5RSの正式名をサポート
- ✅ **特殊形式の構文検査**: フォーム名と該当式つきのエラーメッセージ

#### v2.0 新機能

- ✅ **循環構造対応**: equal?とto_stringで無限ループ回避
- ✅ **#t/#f サポート**: 標準Scheme構文の追加
- ✅ **BigInt変換の安全化**: オーバーフロー時の適切なエラー処理
- ✅ **改善されたエラーメッセージ**: より親切なユーザーフィードバック

#### ライブラリ
- ✅ **system_lib.scm**: 標準ライブラリ（map, filter, fold等）
- ✅ **rbtree_lib_improved.scm**: 赤黒木（自己平衡二分探索木）
- ✅ **hashtable_lib.scm**: ハッシュテーブル（赤黒木ベース）
- ✅ **rbtree_stress_test_safe.scm**: 大規模データのストレステスト

### 1.4 設計目標

1. **教育的価値**: SECD VMの動作を追跡可能に
2. **実用性**: 実際のプログラムが書ける機能セット
3. **デバッグ性**: 内部状態を詳細に観察可能
4. **パフォーマンス**: 末尾再帰最適化による効率的実行
5. **拡張性**: プリミティブ・ライブラリの追加が容易
6. **✨ 堅牢性（v2.0）**: 循環構造や範囲外データへの対応

---

## 2. データモデル（Value系）

### 2.1 Value構造

すべての値は`Value`構造体で表現され、`std::variant`による型安全なタグ付き共用体として実装されています。

```cpp
struct Value : public gc {
    using Data = std::variant<
        NilTag,              // NIL（空リスト）
        bool,                // ブール値
        BigIntPtr,           // 任意精度整数
        std::string,         // 文字列
        Symbol,              // シンボル
        PairPtr,             // ペア（cons セル）
        ClosurePtr,          // クロージャ（関数）
        ContPtr,             // 継続
        PrimitiveInfoPtr,    // プリミティブ関数
        FilePortPtr,         // ファイルポート
        VectorPtr,           // ベクタ
        MacroPtr,            // マクロ
        SpecialFormPtr       // 特殊形式
        EofTag               // EOF（v2.0で追加）
    >;
    Data data;
};
```

### 2.2 主要データ型

#### 2.2.1 基本型

**整数（BigInt）**
```scheme
scheme12> 12345678901234567890
12345678901234567890

scheme12> (+ 999999999999999999 1)
1000000000000000000
```

**⚠️ v2.0の改善**: BigInt → long long 変換時の範囲チェック

```scheme
scheme12> (make-string 99999999999999999999 "x")
Error: make-string: integer out of range for conversion
```

**文字列（std::string）****文字列（std::string）**

```scheme
scheme12> "Hello, World!"
"Hello, World!"

scheme12> (string-append "foo" "bar")
"foobar"
```

**シンボル（Symbol）**
```scheme
scheme12> 'apple
APPLE

scheme12> (eq? 'apple 'apple)
TRUE
```
- **インターン**: 同名シンボルは同一オブジェクト（`g_symbol_intern`で管理）

**ブール値・NIL**
```scheme
scheme12> true
TRUE

scheme12> false
FALSE

scheme12> #t    ; ← v2.0で追加
TRUE

scheme12> #f    ; ← v2.0で追加
FALSE

scheme12> nil
NIL
```
- 大文字・小文字どちらも使用可能（TRUE/True/true）
- **✨ v2.0**: 標準Scheme構文 `#t` / `#f` をサポート

#### 2.2.2 複合型

**ペア（Pair）とリスト**
```cpp
struct Pair : public gc {
    ValuePtr car;  // 先頭要素
    ValuePtr cdr;  // 残りのリスト
};
```

```scheme
scheme12> (cons 1 2)
(1 . 2)

scheme12> (list 1 2 3)
(1 2 3)

scheme12> (car (list 10 20 30))
10
```

**✨ v2.0: 循環リスト対応**

```scheme
scheme12> (define circular (cons 1 (cons 2 nil)))
circular

scheme12> (set-cdr! (cdr circular) circular)

scheme12> circular
(1 2 . #<circular>)  ; 無限ループせず表示

scheme12> (equal? circular circular)
TRUE  ; クラッシュしない
```

**ベクタ（Vector）**

```cpp
struct Vector : public gc {
    ValueVec elements;  // 要素の可変長配列
};
```

```scheme
scheme12> #(1 2 3 4 5)
#(1 2 3 4 5)

scheme12> (vector-ref #(a b c) 1)
B

scheme12> (make-vector 5 'x)
#(X X X X X)
```

**✨ v2.0: 自己参照ベクタ対応**

```scheme
scheme12> (define v (vector 1 2 3))
v

scheme12> (vector-set! v 1 v)

scheme12> v
#(1 #<circular-vector> 3)  ; 無限ループせず表示
```

#### 2.2.3 関数型

**クロージャ（Closure）**

```cpp
struct Closure : public gc {
    std::vector<std::string> params;          // 固定引数名
    std::optional<std::string> rest_param;    // 可変引数名
    CodePtr body;                             // 本体コード
    ValueVec captured_env;                    // 捕捉環境
};
```

```scheme
scheme12> (lambda (x) (* x x))
#<closure:(x)>

scheme12> (lambda (x y . rest) (list x y rest))
#<closure:(x y . rest)>
```

**継続（Continuation）**
```cpp
struct Continuation : public gc {
    ValueVec s;           // スタック
    ValueVec e;           // 環境
    CodePtr c;            // コード
    std::size_t pc;       // プログラムカウンタ
    DumpPtr d;            // ダンプ（永続リンクリストの先頭ノード）
};
```

```scheme
scheme12> (call/cc (lambda (k) k))
#<continuation>
```

### 2.3 表示形式

各データ型の`to_string`による表示：

| 型             | 表示例                      | 説明                         |
| -------------- | --------------------------- | ---------------------------- |
| 整数           | `123`, `999999999999999`    | 10進表記                     |
| 文字列         | `"hello"`                   | ダブルクォートで囲む         |
| シンボル       | `APPLE`, `+`                | 大文字で表示                 |
| ブール         | `TRUE`, `FALSE`             | 大文字表記                   |
| NIL            | `NIL`                       | 空リスト                     |
| ペア           | `(1 . 2)`                   | ドット対                     |
| リスト         | `(1 2 3)`                   | 括弧で囲む                   |
| **循環リスト** | `(1 2 . #<circular>)`       | **✨ v2.0**: 循環検出         |
| ベクタ         | `#(1 2 3)`                  | #で開始                      |
| **循環ベクタ** | `#(1 #<circular-vector> 3)` | **✨ v2.0**: 自己参照検出     |
| クロージャ     | `#<closure:(x y)>`          | パラメータのみ表示           |
| 継続           | `#<continuation>`           | 省略表示                     |
| プリミティブ   | `#<primitive:+>`            | 関数名表示                   |
| 特殊形式       | `#<special-form:if>`        | 形式名表示                   |
| **EOF**        | `#<eof>`                    | **✨ v2.0**: 専用オブジェクト |

### 2.4 循環構造の扱い（v2.1 で完成）✨

`visited` は「いま辿っている経路上にあるノード」の集合（ancestor set）です。
走査を終えたら自分が入れた分を取り除く（バックトラックする）ことで、
循環は検出しつつ、共有構造（DAG）を循環と誤判定しないようにしています。

#### equal? の循環検出

**アルゴリズム**: ノード対応マップによる追跡＋cdr 方向はループ

```cpp
using VisitedMap = std::unordered_map<void*, void*>;

// cdr 方向は再帰ではなくループで辿る。car だけ再帰する。
// スパン上のノードは path に貯め、比較を終えたらまとめて visited から外す。
static bool value_equal_with_visited(ValuePtr a, ValuePtr b, VisitedMap& visited) {
    if (both_pairs(a, b)) {
        std::vector<void*> path;
        bool result;
        for (;;) {
            auto it = visited.find(addr_a);
            if (it != visited.end()) { result = (it->second == addr_b); break; }
            visited[addr_a] = addr_b;
            path.push_back(addr_a);
            if (!value_equal_with_visited(car(a), car(b), visited)) { result = false; break; }
            a = cdr(a); b = cdr(b);          // ← 再帰せずループ
            ...
        }
        for (void* k : path) visited.erase(k);   // バックトラック
        return result;
    }
    ...
}
```

**cdr をループにしている理由**: v2.0 では cdr も再帰していたため、
20万要素程度のリスト同士を `equal?` で比較すると C スタックが溢れて
SIGSEGV していました。car の再帰だけならネストの深さに比例するので、
現実的な深さでは溢れません。

**動作例**:

```scheme
scheme12> (define a (cons 1 (cons 2 nil)))
scheme12> (set-cdr! (cdr a) a)
scheme12> (equal? a a)
TRUE  ; 無限ループせず正しく判定

scheme12> (define (range n acc) (if (= n 0) acc (range (- n 1) (cons n acc))))
scheme12> (equal? (range 200000 '()) (range 200000 '()))
TRUE  ; v2.1 以降はスタックを溢れさせない（v2.0 では SIGSEGV）
```

#### to_string の循環検出

**アルゴリズム**: 訪問済みセットによる追跡（car 方向も含む）

```cpp
std::unordered_set<void*> visited;

static std::string to_string_with_visited(ValuePtr v, std::unordered_set<void*>& visited) {
    if (visited.count(addr)) {
        return "#<circular>";  // または "#<circular-vector>"
    }
    visited.insert(addr);
    // ... 要素の文字列化。car へ降りるときも同じ visited を引き回す ...
    visited.erase(addr);  // バックトラック
}
```

**重要**: リストの cdr 鎖を辿るループから car を出力するときは、
`to_string()` ではなく `to_string_with_visited(car(ls), visited)` を呼ぶ
必要があります。v2.0 では前者を呼んでいたため visited が毎回作り直され、
car 方向の循環が検出できずスタックを溢れさせていました。

```scheme
scheme12> (define x (list 1 2))
scheme12> (set-car! x x)
scheme12> x
(( . #<circular>) 2)   ; v2.1 以降。v2.0 では SIGSEGV
```

---

## 3. リーダ（Reader: S式パーサ）

### 3.1 構文要素

Readerは入力文字列をS式（Value表現）に変換します。

#### 3.1.1 サポート構文

**数値**
```scheme
123          ; 整数
-456         ; 負の整数
+789         ; 明示的な正の整数
```
- ⚠️ 浮動小数点・有理数・複素数は未対応

**文字列**
```scheme
"hello"           ; 基本文字列
"line1\nline2"    ; エスケープシーケンス
"quote: \"text\"" ; クォートのエスケープ
```

**シンボル**

```scheme
apple            ; 通常のシンボル
+                ; 演算子もシンボル
foo-bar-baz      ; ハイフン使用可能
```

**真偽値（v2.0拡張）** ✨

```scheme
true             ; 従来の構文
false            ; 従来の構文
#t               ; ← NEW! 標準Scheme構文
#f               ; ← NEW! 標準Scheme構文
#T               ; 大文字も可
#F               ; 大文字も可
```

**実装詳細**:

```cpp
ValuePtr read_expr() {
    // ...
    if (c == '#') {
        char next = peek();
        if (next == '(') {
            get();
            return read_vector();
        }
        // #t と #f を直接処理
        if (next == 't' || next == 'T') {
            get();
            return make_bool(true);
        }
        if (next == 'f' || next == 'F') {
            get();
            return make_bool(false);
        }
        return read_atom(c);
    }
    // ...
}
```

**リスト**

```scheme
(1 2 3)          ; 通常のリスト
()               ; 空リスト（NIL）
(a (b c) d)      ; ネストしたリスト
```

**ドット対**
```scheme
(1 . 2)          ; 基本ドット対
(1 2 . 3)        ; リストの末尾指定
```

**ベクタ**
```scheme
#(1 2 3)         ; 基本ベクタ
#()              ; 空ベクタ
#(a (b c) d)     ; ネストした要素
```

**クオート記法**
```scheme
'x               ; (quote x)
`x               ; (quasiquote x)
,x               ; (unquote x)
,@xs             ; (splice xs)
```

**コメント**
```scheme
; 行コメント（行末まで）
(+ 1 2)  ; 式の後ろにもコメント可能
```

**⚠️ 注意: 角括弧は未サポート**

```scheme
[1 2 3]          ; ✗ エラー（丸括弧を使用）
(1 2 3)          ; ✓ 正しい
```

### 3.2 読み込み処理

#### 複数式の読み込み
```cpp
static ValueVec read_all_exprs(const std::string& src) {
    Reader r(src);
    ValueVec out;
    while (!r.eof()) {
        ValuePtr x = r.read_expr();
        if (!x) break;
        out.push_back(x);
    }
    return out;
}
```

#### 複数行入力（REPL）
REPLでは括弧のバランスを見て自動的に複数行入力を受け付けます：

```scheme
scheme12> (define (fact n)
       ...>   (if (= n 0)
       ...>       1
       ...>       (* n (fact (- n 1)))))
fact
```

#### 入力終端の扱い（v2.1）✨

`read_expr()` は入力を使い切ると `nullptr` を返します。`read_list()` と
`read_vector()` はこれを検出して打ち切る必要があります。

```cpp
ValuePtr x = read_expr();
if (!x) vm_error("unexpected EOF in list");
items.push_back(x);
```

v2.0 ではこの検査がなく、閉じ括弧のないファイルを `--load` すると
`nullptr` を積み続けて無限ループし、メモリを食い潰して `std::bad_alloc`
で落ちていました。REPL は `is_balanced()` が守っていたため、
`--load` と `read-expr` でのみ表面化する問題でした。

```
$ ./scheme12_debug --load unbalanced.scm
Fatal error: scheme12 VM error: unexpected EOF in list
```

---

## 4. コンパイラ（Compiler）

### 4.1 コンパイルプロセス

```
S式（Value）
    ↓
マクロ展開（macro_expand_1_expr）
    ↓
構文解析・環境分析
    ↓
命令列生成（Code）
    ↓
末尾位置の最適化
```

### 4.2 環境モデル

#### 静的スコープ
```cpp
using CompileEnv = std::vector<
    std::vector<std::string>  // 各フレームは変数名のリスト
>;
```

#### 変数の位置特定
```cpp
// (frame_index, slot_index) を返す
std::optional<std::pair<int, int>> location_of(
    const std::string& name, 
    const CompileEnv& env
);
```

例：
```scheme
(lambda (x y)          ; フレーム0: [x, y]
  (lambda (z)          ; フレーム1: [z]
    (+ x z)))          ; x は (1, 0), z は (0, 0)
```

### 4.3 特殊形式のコンパイル

#### 4.3.1 条件分岐（if）

```scheme
(if test then-expr else-expr)
```

**非末尾位置**（`SEL` + `JOIN`）:
```
[コンパイル test]
SEL then-code else-code
[続きのコード]

then-code:
  [コンパイル then-expr]
  JOIN

else-code:
  [コンパイル else-expr]
  JOIN
```

**末尾位置**（`SELR` + `RTN`）:
```
[コンパイル test]
SELR then-code else-code

then-code:
  [コンパイル then-expr]
  RTN            ; JOIN ではなく RTN

else-code:
  [コンパイル else-expr]
  RTN
```

末尾位置の `if` で `SEL` を使うと、分岐のたびにダンプへ退避してしまい、
分岐の中の末尾呼出が積み上がって末尾呼出最適化が効かなくなります。
`SELR` は退避せず、分岐は `RTN` で直接呼出し元へ戻ります。

#### 4.3.2 関数定義（lambda）

```scheme
(lambda (x y) body)
```

生成コード：
```
LDF lambda-code

lambda-code:
  [コンパイル body]
  RTN
```

#### 4.3.3 関数適用

**通常呼出**
```scheme
(f arg1 arg2)
```
```
[コンパイル arg1]
[コンパイル arg2]
ARGS 2
[コンパイル f]
APP
```

**末尾呼出（TCO）**
```scheme
(define (loop n)
  (if (> n 0)
      (loop (- n 1))  ; 末尾位置
      'done))
```
```
; 末尾位置では APP の代わりに TAPP
TAPP  ; Dにスタックフレームを積まない
```

#### 4.3.4 可変長引数

```scheme
(lambda (x y . rest) body)
```

- `rest`にリストとして残りの引数をすべて渡す
- フレーム構成: `[x, y, rest-list]`

#### 4.3.5 内部 define（v2.1）✨

本体の先頭に並ぶ `define` は、コンパイル前に `letrec` へ書き換えられます
（R5RS 5.2.2 の scan out defines）。

```scheme
(lambda (x)
  (define y (* x 2))
  (define (g k) (* y k))
  (g 3))
        ↓
(lambda (x)
  (letrec ((y (* x 2))
           (g (lambda (k) (* y k))))
    (g 3)))
```

`letrec` は `(let ((v :undef) ...) (set! v ...) ... body)` へ展開されるので、
逐次初期化（letrec* 相当）になり、内部 define の意味論と一致します。

**この変換が必要な理由**: 変換しないと `define` は `Op::DEF`（グローバルへの
代入）にコンパイルされ、内部の補助関数は `Op::LDG` でグローバルを引きます。
すると同名の補助関数を持つ別の関数を定義した時点で後勝ちで上書きされ、
先に作ったクロージャが壊れます。

```scheme
(define (make-f n) (define (helper x) (* x 2)) (lambda () (helper n)))
(define (make-g n) (define (helper x) (* x 3)) (lambda () (helper n)))
(define ff (make-f 5))
(define gg (make-g 5))
(list (ff) (gg) (ff))
;; v2.0: (15 15 15)   ← ff まで make-g の helper を見てしまう
;; v2.1: (10 15 10)   ← 正しい
```

**適用範囲**: 呼び出しは `comp()` の `lambda` の分岐のみです。`let` / `let*` /
名前付き `let` / `do` はすべて `lambda` へ展開されてから `comp` に戻るので
自動的にカバーされ、トップレベルや `begin` の `define` は従来どおり
グローバル定義のまま残ります。`letrec` は本物の `lambda` に展開されるので、
外側の引数参照の `Op::LD` の深さは `location_of` が再計算します。

**対象外**（従来どおりグローバルになります）:
- 式より後ろに書かれた `define`（R5RS でも未定義）
- マクロが生成した本体先頭の `define`（scan はマクロ展開の前に走るため）
- 本体先頭の `(begin (define ...) ...)` のスプライス

#### 4.3.6 構文検査（v2.1）✨

特殊形式の分解を素の `car`/`cdr` に任せると、構文エラーがほぼすべて
`expected pair` という同じ無情報なメッセージになります。v2.1 では
共通ヘルパーを設けて、フォーム名・期待する形・実際に書かれた式を
添えて報告します。

| ヘルパー | 役割 |
|---|---|
| `syntax_error()` | 引数リスト `rest` から `(form . rest)` を復元して表示する |
| `check_arity()` | 引数の個数を検査する（ドットリストも検出） |
| `check_bindings()` | `let`/`let*`/`letrec` の束縛が `(variable expression)` であることを検査する |

```
(define x)         → bad syntax in define: variable definition needs
                     a value expression -- in (define x)
(if a b c d)       → bad syntax in if: expects 2 to 3 argument(s),
                     got 4 -- in (if a b c d)
(let ((x)) x)      → bad syntax in let: each binding must be
                     (variable expression) -- in (let ((x)) x)
(do ((i)) (#t) 1)  → bad syntax in do: each spec must be
                     (variable init [step]) -- in (do ((i)) (TRUE) 1)
(lambda 5 1)       → bad syntax in lambda: parameter list must be symbols,
                     e.g. (x y) or (x . rest) -- in (lambda 5 1)
```

適用先は `quote` / `quasiquote` / `if` / `lambda` / `define` /
`define-macro` / `set!` / `call/cc` / `apply`（`comp` 内）と
`let` / `let*` / `letrec` / `cond` / `case` / `do`（`expand_*` 内）です。

なお `(if a b c d)` や `(define x 1 2)` は v2.0 では**黙って余分な引数を
無視していました**が、v2.1 ではエラーになります。

### 4.4 マクロ展開

#### コンパイル時展開
```scheme
(define-macro (when test . body)
  `(if ,test (begin ,@body) false))

(when (> x 0)
  (display "positive")
  (newline))
```

展開後：
```scheme
(if (> x 0)
    (begin
      (display "positive")
      (newline))
    false)
```

#### 組み込み構文展開

**let**
```scheme
(let ((x 1) (y 2)) (+ x y))
```
↓
```scheme
((lambda (x y) (+ x y)) 1 2)
```

**letrec**
```scheme
(letrec ((fact (lambda (n)
                 (if (= n 0) 1 (* n (fact (- n 1)))))))
  (fact 5))
```
↓
```scheme
(let ((fact :undef))
  (set! fact (lambda (n) ...))
  (fact 5))
```

**cond**
```scheme
(cond ((< x 0) 'neg)
      ((= x 0) 'zero)
      (else 'pos))
```
↓
```scheme
(if (< x 0)
    'neg
    (if (= x 0)
        'zero
        'pos))
```

---

## 5. 命令セット（Instruction Set）

### 5.1 SECD レジスタ

| レジスタ | 役割 | 型 |
|---------|------|-----|
| S | スタック | `ValueVec` |
| E | 環境 | `ValueVec`（フレームのリスト） |
| C | コード | `CodePtr` |
| D | ダンプ | `DumpFrameVec` |
| pc | プログラムカウンタ | `std::size_t` |

### 5.2 命令一覧

#### 5.2.1 値の読み込み

| 命令 | 引数 | 動作 | 例 |
|------|------|------|-----|
| **LDC** | const | 定数をスタックに積む | `LDC 42` |
| **LD** | (i, j) | E[i][j]をスタックに積む | `LD (0, 1)` |
| **LDG** | sym | グローバル変数をスタックに積む | `LDG +` |
| **LDF** | params, body | クロージャを作成してスタックに積む | `LDF (x y)` |

#### 5.2.2 関数適用

| 命令 | 引数 | 動作 | スタック変化 |
|------|------|------|-------------|
| **ARGS** | n | n個の値をリストにまとめる | `[v1 v2 ... vn]` → `[(v1 v2 ... vn)]` |
| **ARGS-AP** | n | apply用の引数結合 | `[v1 ... vn-1 list]` → `[(v1 ... vn-1 . list)]` |
| **APP** | - | 関数適用（Dに退避） | `[closure args]` → `[result]` |
| **TAPP** | - | 末尾呼出（Dに退避しない） | `[closure args]` → `[result]` |
| **RTN** | - | 関数からリターン | Dから復元 |

#### 5.2.3 制御フロー

| 命令 | 引数 | 動作 | 説明 |
|------|------|------|------|
| **SEL** | ct, cf | 条件分岐（Dに退避） | 非末尾位置の`if`。分岐は`JOIN`で終わる |
| **SELR** | ct, cf | 条件分岐（Dに退避しない） | 末尾位置の`if`。分岐は`RTN`で終わる |
| **JOIN** | - | 分岐から復帰 | Dから復元（`c`と`pc`のみ使う） |
| **STOP** | - | 実行終了 | 結果をスタックトップから取得 |

#### 5.2.4 変数操作

| 命令 | 引数 | 動作 | 説明 |
|------|------|------|------|
| **DEF** | sym | グローバル定義 | スタックトップを`g_globals[sym]`に設定 |
| **DEFM** | sym | マクロ定義 | `g_macros[sym]`に登録 |
| **LSET** | (i, j) | ローカル変数更新 | E[i][j]を破壊的更新 |
| **GSET** | sym | グローバル変数更新 | `g_globals[sym]`を更新 |

#### 5.2.5 継続

| 命令 | 引数 | 動作 | 説明 |
|------|------|------|------|
| **CALLCC** | - | call/cc実行（Dに退避） | 継続を引数として関数適用 |
| **TCALLCC** | - | 末尾位置のcall/cc（Dに退避しない） | 末尾位置でTCOを効かせる |
| **LDCT** | - | 継続を作成してスタックに積む | 現在の(S,E,C,pc,D)をスナップショット |

**注**: `LDCT` はコンパイラが生成しないデッドコードです（VM 側の実装のみ
残っています）。継続の捕捉は `CALLCC` / `TCALLCC` が行います。

#### 5.2.6 その他

| 命令 | 引数 | 動作 |
|------|------|------|
| **POP** | - | スタックトップを捨てる |

### 5.3 命令実行例

#### 例1: 簡単な計算
```scheme
(+ 1 2)
```

命令列：
```
[0] LDC 1      ; スタック: [1]
[1] LDC 2      ; スタック: [1, 2]
[2] ARGS 2     ; スタック: [(1 2)]
[3] LDG +      ; スタック: [(1 2), #<primitive:+>]
[4] APP        ; スタック: [3]
[5] STOP
```

#### 例2: 関数呼出
```scheme
((lambda (x) (* x x)) 5)
```

命令列：
```
[0] LDC 5           ; スタック: [5]
[1] ARGS 1          ; スタック: [(5)]
[2] LDF (x)         ; スタック: [(5), #<closure:(x)>]
     [0] LD (0, 0)      ; クロージャ内: x を取得
     [1] LD (0, 0)      ; x をもう一度
     [2] ARGS 2         ; [(x x)]
     [3] LDG *          ; [(x x), #<primitive:*>]
     [4] APP            ; [x*x]
     [5] RTN
[3] APP             ; 関数適用
[4] STOP
```

---

## 6. VM（実行機構）と継続（call/cc）

### 6.1 実行ループ

```cpp
struct VM {
    ValueVec s;          // スタック
    ValueVec e;          // 環境
    CodePtr c;           // コード
    std::size_t pc;      // プログラムカウンタ
    DumpFrameVec d;      // ダンプ
    
    ValuePtr run() {
        while (true) {
            const Instruction& ins = c->ins[pc++];
            
            if (g_trace_mode) {
                trace_state(ins);  // デバッグ出力
            }
            
            switch (ins.op) {
                case Op::LD: /* ... */ break;
                case Op::APP: /* ... */ break;
                // ... 各命令の処理
            }
        }
    }
};
```

### 6.2 環境の表現

#### フレーム構造
```scheme
(lambda (x y)
  (lambda (z)
    (+ x y z)))
```

環境の構造：
```
E = [
  Frame0: (z-value),           ; 内側のラムダの引数
  Frame1: (x-value y-value),   ; 外側のラムダの引数
  ...                          ; さらに外側のフレーム
]
```

#### 変数アクセス
- `LD (0, 0)` → Frame0の0番目 → `z-value`
- `LD (1, 0)` → Frame1の0番目 → `x-value`
- `LD (1, 1)` → Frame1の1番目 → `y-value`

### 6.3 関数適用の仕組み

#### 通常適用（APP）
```
1. スタックから関数とリストを取得
2. 現在の (S, E, C, pc) を D に退避
3. 新しい環境を構築:
   E' = [引数フレーム] + クロージャの捕捉環境
4. クロージャの本体に飛ぶ:
   C ← クロージャの body
   pc ← 0
```

#### 末尾適用（TAPP）
```
1. スタックから関数と引数リストを取得
2. D に退避しない（これがTCOの肝）
3. 新しい環境を構築（APPと同じ）
4. クロージャの本体に飛ぶ
```

**TCOの効果**：
```scheme
(define (loop n)
  (if (= n 0)
      'done
      (loop (- n 1))))  ; 末尾再帰 → TAPP

(loop 1000000)  ; スタックオーバーフローしない
```

### 6.4 継続（call/cc）

#### 継続の作成
```cpp
struct Continuation : public gc {
    ValueVec s;           // 現在のスタック
    ValueVec e;           // 現在の環境
    CodePtr c;            // 現在のコード
    std::size_t pc;       // 現在のPC
    DumpPtr d;            // 現在のダンプ（永続リンクリストの先頭）
};
```

ダンプは不変ノードの永続リンクリストです。push はノード1個の確保、pop は
ポインタの付け替えなので、継続の捕捉は「いまの先頭ポインタを持つ」だけの
O(1) で済みます。ノードが不変なので、捕捉後に VM 側が push/pop しても
捕捉済みの鎖は壊れません。

#### CALLCC / TCALLCC 命令の動作
```
1. スタックから関数を取得
2. 現在の (S, E, C, pc, D) を継続として作成
3. 継続を引数として関数に適用
   ※ 通常のAPP / TAPPと同じ流れ
   ※ CALLCC はDに退避し、TCALLCC は退避しない（末尾位置でTCOを効かせる）
```

引数に渡せるのはクロージャ、プリミティブ、そして**継続**です。R5RS では
継続も1引数の手続きなので `(call/cc k)` は有効で、「いまの継続を引数にして
`k` へ脱出する」ことを意味します（v2.1 で対応）。

#### 継続の適用
```
1. 継続が呼ばれると、保存された状態を復元
2. 引数の値をスタックに積む
3. 継続が作られた時点に戻る
   ※ 状態をまるごと差し替えるので、ダンプは積まない
```

#### 名前（v2.1）✨

R5RS の正式名 `call-with-current-continuation` も `call/cc` と同じに
扱われます。どちらで書いても同じコードが生成され、構文エラーの
メッセージには実際に書かれたほうの名前が出ます。

```scheme
scheme12> (call-with-current-continuation (lambda (k) (k 41)))
41
```

#### 実例
```scheme
scheme12> (define escape false)
escape

scheme12> (+ 1 (call/cc (lambda (k) 
                          (set! escape k) 
                          2)) 
             3)
6  ; (+ 1 2 3)

scheme12> (escape 100)
104  ; (+ 1 100 3)
```

**動作の流れ：**

1. `(+ 1 ... 3)`の評価中に`call/cc`が実行される
2. 継続`k`は「1を足して、さらに3を足す」という文脈を保持
3. `k`は変数`escape`に保存され、`2`が返される
4. 最初の式は`(+ 1 2 3) = 6`
5. 後で`(escape 100)`を呼ぶと、継続が復元され`100`が「1を足して3を足す」文脈に入る
6. 結果は`(+ 1 100 3) = 104`

#### 継続の実装ポイント

**メモリ管理**
- すべてのレジスタ（S,E,C,D）を完全にコピー
- Boehm GCにより自動管理
- 大量の継続生成も安全

**スコープ**
- 継続はファーストクラスオブジェクト
- 変数に代入可能
- 関数の引数・返り値として渡せる
- クロージャの中に捕捉可能
- `call/cc` の引数としても渡せる（v2.1）

**制約**
- `call/cc` 自身は特殊形式であって値ではありません。`(procedure? call/cc)`
  は `FALSE` で、高階関数に渡したり変数に束縛したりはできません
  （`apply` も同様）。
- トップレベルのフォームはそれぞれ別の VM で評価されるため、あるフォームで
  捕捉した継続を別のフォームから起動すると、そのフォームの残りは実行されず
  次のトップレベルフォームへ進みます。ジェネレータやコルーチンのように
  何度も再入する用途では、一連の処理を1つの `begin` にまとめてください。

**実用例：非局所脱出**
```scheme
(define (find-first pred lst)
  (call/cc
    (lambda (return)
      (for-each
        (lambda (x)
          (if (pred x)
              (return x)))  ; 見つかったら即座に返る
        lst)
      false)))  ; 見つからなかった場合

scheme12> (find-first (lambda (x) (> x 5)) '(1 3 7 2 9))
7
```

---

## 7. マクロシステム

### 7.1 define-macro

#### 基本構文
```scheme
(define-macro name transformer)
(define-macro (name . params) body ...)
```

#### マクロの動作

**定義時（DEFM命令）**
```
1. transformerをクロージャとして評価
2. g_macros[name]に登録
3. g_globals[name]に#<macro>として登録（表示用）
```

**展開時（コンパイル時）**
```
1. 式の先頭がマクロ名かチェック
2. マクロ変換器を引数に適用（VMで実行）
3. 展開結果の式を再帰的にコンパイル
```

### 7.2 マクロの例

#### 例1: when マクロ
```scheme
(define-macro (when test . body)
  `(if ,test
       (begin ,@body)
       false))

; 使用例
(when (> x 0)
  (display "positive")
  (newline))

; 展開結果
(if (> x 0)
    (begin
      (display "positive")
      (newline))
    false)
```

#### 例2: unless マクロ
```scheme
(define-macro (unless test . body)
  `(if ,test
       false
       (begin ,@body)))

(unless (null? lst)
  (display (car lst)))
```

#### 例3: 繰り返しマクロ
```scheme
(define-macro (repeat n . body)
  (let ((i (gensym "i")))
    `(let loop ((,i 0))
       (if (< ,i ,n)
           (begin
             ,@body
             (loop (+ ,i 1)))))))

(repeat 3
  (display "Hello")
  (newline))
```

### 7.3 準クオート（Quasiquote）

#### 構文
- **バッククオート** `` ` `` : テンプレート開始
- **カンマ** `,` : 評価して展開
- **カンマアット** `,@` : リストを展開して接合

#### 例
```scheme
scheme12> (define x 10)
scheme12> (define lst '(a b c))

scheme12> `(x is ,x and list is ,lst)
(X IS 10 AND LIST IS (A B C))

scheme12> `(x is ,x and elements are ,@lst)
(X IS 10 AND ELEMENTS ARE A B C)
```

#### 実装: qq_transfer
準クオートはコンパイル時に通常のリスト構築に展開されます：

```scheme
`(a ,b ,@c)
↓
(cons 'a (cons b (append c '())))
```

#### ドット位置の unquote（v2.1）✨

`` `(a . ,x) `` はリーダで `(a unquote x)` と読まれます。`qq_transfer` が
cdr へ降りた先で `ls` 自身が `(unquote x)` になるので、ここを拾って値に
置き換える必要があります。R5RS では `` `(unquote x) `` と `,x` は等価なので、
この置き換えは常に正しくなります。

```scheme
(define k 'name) (define v 42)

`(,k . ,v)     ; v2.0: (name unquote v)   → v2.1: (name . 42)
`(1 2 . ,v)    ; v2.0: (1 2 unquote v)    → v2.1: (1 2 . 42)
```

`` `(,key . ,val) `` は連想リストのエントリやドット対を組み立てるマクロの
定番イディオムです。v2.0 ではエラーにならず3要素のリストが黙って
下流へ流れていたため、発見が難しい種類の不具合でした。

なお R5RS で不正な `` `(a . ,@x) `` は、壊れた結果を返す代わりに
`unquote-splicing is not allowed in dotted tail position` を投げます。

#### ベクタ内の unquote（v2.1）✨

ベクタリテラルの中でも `,` / `,@` が働きます。要素をリストに直して
変換し、`list->vector` で戻す形で実装しています。

```scheme
(define x 7) (define b '(9 9))

`#(1 ,x)       ; v2.0: #(1 (unquote x))   → v2.1: #(1 7)
`#(,@b 3)      ;                          → v2.1: #(9 9 3)
```

#### 未対応

ネストした準クオート（`` `(a `(b ,,x)) ``）はクオート深度の追跡が必要で、
未対応です。

### 7.4 組み込み構文展開

以下の構文はマクロではなく、コンパイラが直接展開します：

#### let
```scheme
(let ((x 1) (y 2)) (+ x y))
↓
((lambda (x y) (+ x y)) 1 2)
```

#### let*（逐次束縛）
```scheme
(let* ((x 1) (y (+ x 1))) y)
↓
(let ((x 1))
  (let ((y (+ x 1)))
    y))
```

#### letrec（相互再帰）
```scheme
(letrec ((f (lambda (n) (if (= n 0) 1 (* n (f (- n 1)))))))
  (f 5))
↓
(let ((f :undef))
  (set! f (lambda (n) ...))
  (f 5))
```

#### and
```scheme
(and a b c)
↓
(if a (if b c false) false)
```

#### or
```scheme
(or a b c)
↓
(let ((t a))
  (if t t
      (let ((t b))
        (if t t c))))
```

#### cond
```scheme
(cond ((< x 0) 'neg)
      ((= x 0) 'zero)
      (else 'pos))
↓
(if (< x 0)
    'neg
    (if (= x 0)
        'zero
        'pos))
```

#### case
```scheme
(case key
  ((a b) 'first)
  ((c d) 'second)
  (else 'other))
↓
(let ((t key))
  (cond ((memv t '(a b)) 'first)
        ((memv t '(c d)) 'second)
        (else 'other)))
```

#### do
```scheme
(do ((i 0 (+ i 1))
     (sum 0 (+ sum i)))
    ((>= i 10) sum)
  (display i))
↓
(letrec ((loop (lambda (i sum)
                 (if (>= i 10)
                     sum
                     (begin
                       (display i)
                       (loop (+ i 1) (+ sum i)))))))
  (loop 0 0))
```

### 7.5 マクロの注意点

#### 非衛生マクロ
現在の実装は非衛生（unhygienic）です：

```scheme
(define-macro (swap x y)
  `(let ((tmp ,x))
     (set! ,x ,y)
     (set! ,y tmp)))

; 問題：tmpという変数名が衝突する可能性
```

**回避策：gensym の使用**
```scheme
(define-macro (swap x y)
  (let ((tmp (gensym "tmp")))
    `(let ((,tmp ,x))
       (set! ,x ,y)
       (set! ,y ,tmp))))
```

#### 複数回評価
マクロの引数が複数回評価される可能性：

```scheme
(define-macro (double x)
  `(+ ,x ,x))

(double (begin (display "eval") 1))
; "eval"が2回表示される
```

**回避策：let で束縛**
```scheme
(define-macro (double x)
  (let ((val (gensym "val")))
    `(let ((,val ,x))
       (+ ,val ,val))))
```

---

## 8. プリミティブと標準ライブラリ

### 8.1 プリミティブ関数（C++実装）

#### 8.1.1 算術演算

| 関数 | 引数 | 動作 | 例 |
|------|------|------|-----|
| `+` | 0個以上 | 加算（0個なら0） | `(+ 1 2 3)` → `6` |
| `-` | 1個以上 | 減算（1個なら符号反転） | `(- 10 3 2)` → `5` |
| `*` | 0個以上 | 乗算（0個なら1） | `(* 2 3 4)` → `24` |
| `/` | 1個以上 | 除算 | `(/ 20 4 2)` → `2` |
| `modulo` | 2個 | 剰余 | `(modulo 17 5)` → `2` |

**⚠️ v2.0の重要な制限**: 単一引数除算は未サポート

```scheme
scheme12> (/ 5)
Error: / requires at least 2 arguments (single-argument reciprocal is not supported; use (/ 1 x) instead)

; 回避策
scheme12> (/ 1 5)  ; 逆数を計算する場合
```

**✨ v2.0の改善**: より親切なエラーメッセージで回避策を提示

#### 8.1.2 比較演算

| 関数 | 引数 | 動作 | 例 |
|------|------|------|-----|
| `=` | 2個以上 | 数値等価 | `(= 1 1 1)` → `TRUE` |
| `<` | 2個以上 | 小なり（連鎖） | `(< 1 2 3)` → `TRUE` |
| `>` | 2個以上 | 大なり | `(> 5 3 1)` → `TRUE` |
| `<=` | 2個以上 | 以下 | `(<= 1 1 2)` → `TRUE` |
| `>=` | 2個以上 | 以上 | `(>= 3 3 2)` → `TRUE` |

#### 8.1.3 リスト操作

| 関数 | 引数 | 動作 | 例 |
|------|------|------|-----|
| `cons` | 2個 | ペア作成 | `(cons 1 2)` → `(1 . 2)` |
| `car` | 1個 | 先頭取得 | `(car '(1 2 3))` → `1` |
| `cdr` | 1個 | 残り取得 | `(cdr '(1 2 3))` → `(2 3)` |
| `list` | 0個以上 | リスト作成 | `(list 1 2 3)` → `(1 2 3)` |
| `append` | 0個以上 | リスト結合 | `(append '(1 2) '(3 4))` → `(1 2 3 4)` |
| `set-car!` | 2個 | 先頭破壊更新 | `(set-car! p 10)` |
| `set-cdr!` | 2個 | 残り破壊更新 | `(set-cdr! p '())` |

**car/cdr の組み合わせ**
```scheme
caar, cdar, cadr, cddr  ; 2段階
caddr, cdddr            ; 3段階
caaar, cdaar, ...       ; 4段階（system_lib.scm で定義）
```

#### 8.1.4 述語

| 関数              | 判定内容                            | 例                                 |
| ----------------- | ----------------------------------- | ---------------------------------- |
| `eq?`             | ポインタ同一性                      | `(eq? 'a 'a)` → `TRUE`             |
| `eqv?`            | eq?と同じ                           | `(eqv? 1 1)` → `TRUE`              |
| `equal?`          | **構造的等価性（✨v2.0: 循環対応）** | `(equal? '(1 2) '(1 2))` → `TRUE`  |
| `null?`           | NIL判定                             | `(null? '())` → `TRUE`             |
| `pair?`           | ペア判定                            | `(pair? '(1 . 2))` → `TRUE`        |
| `list?`           | 正常リスト判定                      | `(list? '(1 2 3))` → `TRUE`        |
| `atom?`           | アトム判定                          | `(atom? 1)` → `TRUE`               |
| `symbol?`         | シンボル判定                        | `(symbol? 'x)` → `TRUE`            |
| `number?`         | 数値判定                            | `(number? 42)` → `TRUE`            |
| `boolean?`        | ブール判定                          | `(boolean? true)` → `TRUE`         |
| `string?`         | 文字列判定                          | `(string? "hi")` → `TRUE`          |
| `vector?`         | ベクタ判定                          | `(vector? #(1 2))` → `TRUE`        |
| `procedure?`      | 手続き判定                          | `(procedure? car)` → `TRUE`        |
| **`eof-object?`** | **EOF判定（✨v2.0）**                | `(eof-object? obj)` → `TRUE/FALSE` |

**✨ v2.0: equal? の循環構造対応**

```scheme
scheme12> (define circ (cons 1 (cons 2 nil)))
scheme12> (set-cdr! (cdr circ) circ)
scheme12> (equal? circ circ)
TRUE  ; 無限ループせず正しく判定
```

#### 8.1.5 論理演算

| 関数 | 動作 | 例 |
|------|------|-----|
| `not` | 論理否定 | `(not false)` → `TRUE` |

#### 8.1.6 リスト検索

| 関数 | 動作 | 例 |
|------|------|-----|
| `memq` | ポインタ同一性で検索 | `(memq 'b '(a b c))` → `(B C)` |
| `memv` | eqv?で検索 | `(memv 2 '(1 2 3))` → `(2 3)` |
| `assq` | 連想リスト検索 | `(assq 'b '((a 1) (b 2)))` → `(B 2)` |
| `assv` | eqv?で連想リスト検索 | system_lib.scmで定義 |
| `length` | リスト長 | `(length '(a b c))` → `3` |

#### 8.1.7 文字列操作

| 関数 | 動作 | 例 |
|------|------|-----|
| `make-string` | 文字列作成 | `(make-string 5 "x")` → `"xxxxx"` |
| `string-length` | 長さ | `(string-length "abc")` → `3` |
| `string-ref` | 文字取得 | `(string-ref "abc" 1)` → `"b"` |
| `string-set!` | 文字更新 | `(string-set! s 0 "X")` |
| `substring` | 部分文字列 | `(substring "hello" 1 4)` → `"ell"` |
| `string-append` | 文字列結合 | `(string-append "a" "b")` → `"ab"` |
| `string->list` | リスト変換 | `(string->list "ab")` → `("a" "b")` |
| `list->string` | 文字列変換 | `(list->string '("a" "b"))` → `"ab"` |
| `string=?` | 等価性 | `(string=? "a" "a")` → `TRUE` |
| `string<?` | 辞書順比較 | `(string<? "a" "b")` → `TRUE` |
| `string>?` | 辞書順比較 | `(string>? "b" "a")` → `TRUE` |
| `string<=?` | 辞書順比較 | `(string<=? "a" "a")` → `TRUE` |
| `string>=?` | 辞書順比較 | `(string>=? "a" "a")` → `TRUE` |

#### 8.1.8 変換関数

| 関数 | 動作 | 例 |
|------|------|-----|
| `number->string` | 数値→文字列 | `(number->string 123)` → `"123"` |
| `string->number` | 文字列→数値 | `(string->number "123")` → `123` |
| `char->integer` | 文字→整数 | `(char->integer "A")` → `65` |
| `integer->char` | 整数→文字 | `(integer->char 65)` → `"A"` |
| `symbol->string` | シンボル→文字列 | `(symbol->string 'abc)` → `"abc"` |
| `string->symbol` | 文字列→シンボル | `(string->symbol "abc")` → `ABC` |

#### 8.1.9 ベクタ操作

| 関数 | 動作 | 例 |
|------|------|-----|
| `make-vector` | ベクタ作成 | `(make-vector 3 0)` → `#(0 0 0)` |
| `vector` | ベクタ作成 | `(vector 1 2 3)` → `#(1 2 3)` |
| `vector-length` | 長さ | `(vector-length #(a b))` → `2` |
| `vector-ref` | 要素取得 | `(vector-ref #(a b c) 1)` → `B` |
| `vector-set!` | 要素更新 | `(vector-set! v 0 10)` |
| `vector->list` | リスト変換 | `(vector->list #(1 2))` → `(1 2)` |
| `list->vector` | ベクタ変換 | `(list->vector '(1 2))` → `#(1 2)` |

**✨ v2.0の重要な改善**: 以下の関数でBigInt変換の安全性が向上

- `make-string`: 範囲外の長さを検出
- `string-ref`: インデックスの範囲チェック
- `substring`: 開始・終了位置の範囲チェック
- `make-vector`: 範囲外のサイズを検出
- `vector-ref`: インデックスの範囲チェック
- `vector-set!`: インデックスの範囲チェック

```scheme
; 安全な範囲チェック
scheme12> (make-string 99999999999999999999 "x")
Error: make-string: integer out of range for conversion

scheme12> (vector-ref #(a b c) 99999999999999)
Error: vector-ref: integer out of range for conversion
```

#### 8.1.10 入出力

| 関数 | 動作 | 例 |
|------|------|-----|
| `display` | 表示（1-2引数） | `(display "Hi")` |
| `write` | 書き込み（1-2引数） | `(write x port)` |
| `newline` | 改行（0-1引数） | `(newline)` |
| `read` | 標準入力から読込 | `(read)` |

**display vs write**
- `display`: 文字列を引用符なしで出力
- `write`: 文字列を引用符付きで出力（read可能な形式）

#### 8.1.11 ファイルI/O

| 関数 | 動作 | 例 |
|------|------|-----|
| `open-input-file` | 入力ポート開く | `(open-input-file "file.txt")` |
| `open-output-file` | 出力ポート開く | `(open-output-file "out.txt")` |
| `close-input-port` | 入力ポート閉じる | `(close-input-port port)` |
| `close-output-port` | 出力ポート閉じる | `(close-output-port port)` |
| `read-line` | 1行読込 | `(read-line port)` |
| `read-char` | 1文字読込 | `(read-char port)` |
| `read-expr` | S式読込 | `(read-expr port)` |
| `write-char` | 1文字書込 | `(write-char "A" port)` |
| `write_newline` | 改行書込（旧API） | `(write_newline port)` |
| `eof-object?` | EOF判定 | `(eof-object? obj)` |

**ファイル処理の例**
```scheme
(define (copy-file src dst)
  (let ((in (open-input-file src))
        (out (open-output-file dst)))
    (let loop ((c (read-char in)))
      (if (eof-object? c)
          (begin
            (close-input-port in)
            (close-output-port out))
          (begin
            (write-char c out)
            (loop (read-char in)))))))
```

**✨ v2.0: EOF専用オブジェクト**

```scheme
(define (read-all-lines port)
  (let loop ((lines '()))
    (let ((line (read-line port)))
      (if (eof-object? line)
          (reverse lines)
          (loop (cons line lines))))))

(define in (open-input-file "data.txt"))
(define lines (read-all-lines in))
(close-input-port in)
```

**✨ v2.1: ポートの自動回収**

`FilePort` は `gc` ではなく `gc_cleanup` を継承します。`gc` 継承だけでは
デストラクタが一度も呼ばれず、到達不能になったポートの `FILE*` が
閉じられないままディスクリプタを食い潰していました（`close` を忘れて
数百個開くと `EMFILE`）。`gc_cleanup` はファイナライザを登録し、
回収時に `~FilePort` を実行します。

ただしファイナライザは GC が走ったときにしか実行されないため、確保が
少ないループでは回収が間に合わないことがあります。そこで
`open-input-file` / `open-output-file` が使う `fopen` をラップし、
`EMFILE`/`ENFILE` で失敗したときだけ回収を促してから1回だけ再試行します。

```cpp
static std::FILE* fopen_with_gc_retry(const char* path, const char* mode) {
    errno = 0;
    std::FILE* fp = std::fopen(path, mode);
    if (fp) return fp;
    if (errno != EMFILE && errno != ENFILE) return nullptr;
    GC_gcollect();
    GC_invoke_finalizers();   // 回収するだけでは足りず、ここまで呼ぶ
    return std::fopen(path, mode);
}
```

`GC_gcollect()` はファイナライザをキューに積むだけなので、
`GC_invoke_finalizers()` まで呼んで実際に `fclose` させるのがポイントです。
`ENOENT` など他のエラーで GC を走らせても無駄なので即座に諦めます。

**とはいえ、ポートは明示的に閉じるのが基本です。** 上の仕組みは
閉じ忘れに対する保険であって、正しい作法の代わりにはなりません。

#### 8.1.12 乱数

| 関数 | 動作 | 例 |
|------|------|-----|
| `random` | 0以上n未満の整数 | `(random 100)` → 42 |
| `random-seed` | 乱数シード設定 | `(random-seed 12345)` |

**✨ v2.0の改善**: `random`の引数範囲チェック

```scheme
scheme12> (random 99999999999999999999)
Error: random: argument too large (must fit in long long range)
```

#### 8.1.13 GC制御

| 関数 | 動作 | 例 |
|------|------|-----|
| `gc-collect` | GC実行 | `(gc-collect)` |
| `gc-heap-size` | ヒープサイズ取得 | `(gc-heap-size)` → 1048576 |
| `gc-free-bytes` | 空きバイト数取得 | `(gc-free-bytes)` → 524288 |

#### 8.1.14 その他

| 関数 | 動作 | 例 |
|------|------|-----|
| `load` | ファイル読込・評価 | `(load "lib.scm")` |
| `gensym` | ユニークシンボル生成 | `(gensym "tmp")` → `TMP1` |

### 8.2 標準ライブラリ（system_lib.scm）

#### 8.2.1 高階関数

**map（Scheme実装版）**
```scheme
(define map
  (lambda (fn ls)
    (if (null? ls)
        '()
        (cons (fn (car ls)) (map fn (cdr ls))))))

(map (lambda (x) (* x x)) '(1 2 3 4 5))
; → (1 4 9 16 25)
```

**filter**
```scheme
(define filter
  (lambda (fn ls)
    (if (null? ls)
        '()
        (if (fn (car ls))
            (cons (car ls) (filter fn (cdr ls)))
            (filter fn (cdr ls))))))

(filter (lambda (x) (> x 0)) '(-1 2 -3 4))
; → (2 4)
```

**for-each**
```scheme
(define for-each
  (lambda (fn ls)
    (if (null? ls)
        '()
        (begin
          (fn (car ls))
          (for-each fn (cdr ls))))))

(for-each display '("a" "b" "c"))
; 出力: abc
```

**fold-left / fold-right**
```scheme
(define fold-left
  (lambda (fn a ls)
    (if (null? ls)
        a
        (fold-left fn (fn a (car ls)) (cdr ls)))))

(define fold-right
  (lambda (fn a ls)
    (if (null? ls)
        a
        (fn (car ls) (fold-right fn a (cdr ls))))))

(fold-left + 0 '(1 2 3 4 5))  ; → 15
(fold-right cons '() '(1 2 3))  ; → (1 2 3)
```

**reverse**
```scheme
(define reverse
  (lambda (ls)
    (letrec ((iter (lambda (ls a)
                     (if (null? ls)
                         a
                         (iter (cdr ls) (cons (car ls) a))))))
      (iter ls '()))))

(reverse '(1 2 3 4 5))  ; → (5 4 3 2 1)
```

#### 8.2.2 イテレータ

**make-iter（継続ベース）**
```scheme
(define make-iter
  (lambda (proc . args)
    (letrec ((iter
              (lambda (return)
                (apply
                  proc
                  (lambda (x)
                    (set! return
                      (call/cc
                        (lambda (cont)
                          (set! iter cont)
                          (return x)))))
                  args)
                (return false))))
      (lambda ()
        (call/cc
          (lambda (cont) (iter cont)))))))

; 使用例: リストのイテレータ
(define (list-iterator ls)
  (make-iter
    (lambda (yield)
      (for-each yield ls))))

(define iter (list-iterator '(1 2 3)))
(iter)  ; → 1
(iter)  ; → 2
(iter)  ; → 3
(iter)  ; → FALSE
```

#### 8.2.3 遅延評価

**delay / force**
```scheme
(define-macro delay
  (lambda (expr)
    `(make-promise (lambda () ,expr))))

(define make-promise
  (lambda (f)
    (let ((state (cons false false)))
      (lambda ()
        (if (not (car state))
            (begin
              (set-car! state true)
              (set-cdr! state (f))))
        (cdr state)))))

(define force
  (lambda (promise) (promise)))

; 使用例
(define x (delay (begin (display "eval") (newline) 42)))
(force x)  ; 出力: eval, 返り値: 42
(force x)  ; 出力なし, 返り値: 42（キャッシュ済み）
```

#### 8.2.4 アルゴリズム例

**階乗（末尾再帰）**
```scheme
(define fact
  (lambda (n a)
    (if (= n 0)
        a
        (fact (- n 1) (* a n)))))

(fact 10 1)  ; → 3628800
```

**竹内関数（tak）**
```scheme
(define tak
  (lambda (x y z)
    (if (<= x y)
        z
        (tak (tak (- x 1) y z)
             (tak (- y 1) z x)
             (tak (- z 1) x y)))))

(tak 14 7 0)  ; → 7
```

**遅延評価版竹内関数**
```scheme
(define tarai-delay
  (lambda (x y z)
    (if (<= x y)
        y
        (let ((zz (force z)))
          (tarai-delay
            (tarai-delay (- x 1) y (delay zz))
            (tarai-delay (- y 1) zz (delay x))
            (delay (tarai-delay (- zz 1) x (delay y))))))))

(tarai-delay 80 40 (delay 0))  ; → 41
```

---

## 9. REPLとデバッグ機能

### 9.1 REPL（Read-Eval-Print Loop）

#### 起動
```bash
$ ./scheme12_debug
scheme12 debug REPL. Type (help) for commands.
scheme12> 
```

#### 複数行入力
括弧のバランスが取れるまで自動的に入力を継続：

```scheme
scheme12> (define (factorial n)
       ...>   (if (= n 0)
       ...>       1
       ...>       (* n (factorial (- n 1)))))
factorial
```

#### 評価と表示
```scheme
scheme12> (+ 1 2 3)
6

scheme12> (list 'a 'b 'c)
(A B C)

scheme12> (lambda (x) (* x x))
#<closure:(x)>
```

### 9.2 デバッグコマンド

#### 9.2.1 (help) - ヘルプ表示

```scheme
scheme12> (help)

=== scheme12 Debug Commands ===

Basic evaluation:
  expr                    Evaluate expression

Inspection:
  (globals)              List all global variables
  (macros)               List all macros

Compilation:
  (compile expr)         Compile and show bytecode
  (disassemble closure)  Show closure internals

Tracing:
  (trace-on)            Enable VM step-by-step trace
  (trace-off)           Disable trace

...
```

#### 9.2.2 (globals) - グローバル変数一覧

```scheme
scheme12> (globals)

=== Global Variables ===
*SPECIAL-FORM
+PRIMITIVE
-PRIMITIVE
/PRIMITIVE
<PRIMITIVE
...
factorial : #<closure:(n)>
...
========================
:globals-listed
```

#### 9.2.3 (macros) - マクロ一覧

```scheme
scheme12> (macros)

=== Macros ===
delay
when
unless
==============
:macros-listed
```

#### 9.2.4 (compile expr) - コンパイル結果表示

```scheme
scheme12> (compile '(+ 1 2))

=== Compiled Code ===
[  0] LDC 1
[  1] LDC 2
[  2] ARGS 2
[  3] LDG +
[  4] APP
[  5] STOP
=====================
:compiled
```

**分岐を含む例：**
```scheme
scheme12> (compile '(if (< x 0) 'neg 'pos))

=== Compiled Code ===
[  0] LDG x
[  1] LDC 0
[  2] ARGS 2
[  3] LDG <
[  4] APP
[  5] SEL [THEN-BRANCH] [ELSE-BRANCH]
[  6] STOP
=====================
:compiled
```
- 注：分岐先の詳細は省略表示される

#### 9.2.5 (disassemble closure) - 逆アセンブル

関数の内部構造を完全に表示（分岐先・ラムダ本体も含む）：

```scheme
scheme12> (define (sign x)
            (cond ((< x 0) 'negative)
                  ((= x 0) 'zero)
                  (else 'positive)))
sign

scheme12> (disassemble sign)

=== Disassembly ===
Parameters: (x)
Body:
  [  0] LD (0 . 0)
  [  1] LDC 0
  [  2] ARGS 2
  [  3] LDG <
  [  4] APP
  [  5] SEL
    THEN:
      [  0] LDC NEGATIVE
      [  1] JOIN
    ELSE:
      [  0] LD (0 . 0)
      [  1] LDC 0
      [  2] ARGS 2
      [  3] LDG =
      [  4] APP
      [  5] SEL
        THEN:
          [  0] LDC ZERO
          [  1] JOIN
        ELSE:
          [  0] LDC POSITIVE
          [  1] JOIN
      [  6] JOIN
  [  6] RTN
Environment: 0 frame(s)
===================
:disassembled
```

**特徴：**
- ✅ 分岐先（THEN/ELSE）を完全展開
- ✅ ネストした条件も階層表示
- ✅ ラムダ式の本体も展開
- ✅ インデントで構造を可視化

#### 9.2.6 (trace-on) / (trace-off) - 実行トレース

**✨ v2.0の改善**: 環境表示が向上

```scheme
scheme12> (trace-on)
Trace mode ON

==== Step 0 ====
PC: 3
Instruction: STOP
Stack:
  [0] TRUE
Environment: (empty)
Dump: 0 frame(s)
TRUE
scheme12> (let ((x 10) (y 20)) (+ x y))

==== Step 0 ====
PC: 0
Instruction: LDC 10
Stack: (empty)
Environment: (empty)
Dump: 0 frame(s)

==== Step 1 ====
PC: 1
Instruction: LDC 20
Stack:
  [0] 10
Environment: (empty)
Dump: 0 frame(s)

==== Step 2 ====
PC: 2
Instruction: ARGS 2
Stack:
  [0] 20
  [1] 10
Environment: (empty)
Dump: 0 frame(s)

==== Step 3 ====
PC: 3
Instruction: LDF (x y)
Stack:
  [0] (10 20)
Environment: (empty)
Dump: 0 frame(s)

==== Step 4 ====
PC: 4
Instruction: APP
Stack:
  [0] #<closure:(x y)>
  [1] (10 20)
Environment: (empty)
Dump: 0 frame(s)

==== Step 5 ====
PC: 0
Instruction: LD (0 . 0)
Stack: (empty)
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 6 ====
PC: 1
Instruction: LD (0 . 1)
Stack:
  [0] 10
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 7 ====
PC: 2
Instruction: ARGS 2
Stack:
  [0] 20
  [1] 10
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 8 ====
PC: 3
Instruction: LDG +
Stack:
  [0] (10 20)
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 9 ====
PC: 4
Instruction: TAPP
Stack:
  [0] (PRIMITIVE +)
  [1] (10 20)
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 10 ====
PC: 5
Instruction: RTN
Stack:
  [0] 30
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 11 ====
PC: 5
Instruction: STOP
Stack:
  [0] 30
Environment: (empty)
Dump: 0 frame(s)
30
scheme12> (trace-off)

==== Step 0 ====
PC: 0
Instruction: ARGS 0
Stack: (empty)
Environment: (empty)
Dump: 0 frame(s)

==== Step 1 ====
PC: 1
Instruction: LDG trace-off
Stack:
  [0] NIL
Environment: (empty)
Dump: 0 frame(s)

==== Step 2 ====
PC: 2
Instruction: APP
Stack:
  [0] (PRIMITIVE trace-off)
  [1] NIL
Environment: (empty)
Dump: 0 frame(s)
Trace mode OFF
FALSE
scheme12>
```

**改善点**:

- 環境フレームがベクタかリストかを判別して表示
- 大きなスタック・環境は省略表示（最大5要素、3フレーム）
- より読みやすいフォーマット

### 9.3 デバッグワークフロー

#### パターン1: 関数の動作確認

```scheme
; 1. 関数を定義
scheme12> (define (mystery x)
            (if (= x 0)
                1
                (* x (mystery (- x 1)))))
mystery

; 2. 簡単な確認
scheme12> mystery
#<closure:(x)>

; 3. 逆アセンブルで詳細確認
scheme12> (disassemble mystery)
[... 詳細な命令列が表示される ...]

; 4. トレース実行で動作確認
scheme12> (trace-on)
scheme12> (mystery 3)
[... ステップバイステップの実行が表示される ...]
scheme12> (trace-off)

; 5. 結果: 階乗関数だと判明
```

#### パターン2: バグの追跡

```scheme
; 1. 意図しない動作を発見
scheme12> (my-function 5)
ERROR: ...

; 2. コンパイル結果を確認
scheme12> (compile '(my-function 5))
[... 生成コードを確認 ...]

; 3. 関数定義を逆アセンブル
scheme12> (disassemble my-function)
[... 内部構造を確認 ...]

; 4. トレースで実行を追跡
scheme12> (trace-on)
scheme12> (my-function 5)
[... どこでエラーが起きるか確認 ...]

; 5. 修正して再確認
```

#### パターン3: パフォーマンス分析

```scheme
; 1. 末尾再帰の確認
scheme12> (disassemble loop-function)
; TAPP命令が使われているか確認

; 2. 大量データでテスト
scheme12> (loop-function 1000000)
; スタックオーバーフローしなければTCOが効いている
```

### 9.4 デバッグの実践例

#### 例1: 継続の動作確認

```scheme
scheme12> (define escape false)
escape

scheme12> (trace-on)
Trace mode ON

scheme12> (+ 1 (call/cc (lambda (k) (set! escape k) 2)) 3)

==== Step 0 ====
PC: 0
Instruction: LDC 1
...

[... 多数のステップ ...]

==== Step N ====
PC: M
Instruction: CALLCC
Stack: 
  [0] #<closure:(k)>
Environment: ...
Dump: ...

[... 継続が作成される ...]

6

scheme12> (trace-off)
FALSE

scheme12> (escape 10)
13
```

#### 例2: マクロ展開の確認

```scheme
scheme12> (define-macro (when test . body)
            `(if ,test (begin ,@body) false))

scheme12> (compile '(when (> x 0) (display "pos") (newline)))

=== Compiled Code ===
; if に展開されたコードが表示される
[  0] LDG x
[  1] LDC 0
[  2] ARGS 2
[  3] LDG >
[  4] APP
[  5] SEL
    THEN:
      [  0] LDG display
      ...
```

#### 例3: 循環構造のデバッグ（v2.0）✨

```scheme
scheme12> (define circular (cons 1 (cons 2 nil)))
scheme12> (set-cdr! (cdr circular) circular)

; 循環構造を安全に表示
scheme12> circular
(1 2 . #<circular>)

; 循環構造の比較
scheme12> (equal? circular circular)
TRUE

; トレースでも問題なし
scheme12> (trace-on)
scheme12> (car circular)
[... 正常に動作 ...]
1
```

---

## 10. データ構造ライブラリ

scheme12は実用的なデータ構造ライブラリを提供します。

### 10.1 赤黒木ライブラリ（rbtree_lib_improved.scm）

#### 10.1.1 概要

**赤黒木（Red-Black Tree）**は自己平衡二分探索木の一種で、以下の性質を持ちます：

- ✅ 挿入・削除・検索が **O(log n)**
- ✅ 自動的にバランスを維持
- ✅ ソート順の走査が可能
- ✅ 大規模データでも効率的

**Improved版の特徴**:
- ✅ 改善された検証機能（`rb-validate`）— 左傾き不変条件（右傾き赤リンク禁止）とBST順序も検査 ← **NEW!**
- ✅ 簡略化されたツリー構造表示（`rb-print-tree`）
- ✅ より明確なエラーメッセージ
- ✅ 包括的なテストスイート
- ✅ `rb-delete-min` を単独で呼んでも安全（根の色を自動修復） ← **NEW!**
- ✅ 不在キーと偽値の混同を避ける `rb-contains?` ← **NEW!**

> 2026年8月、外部プロジェクト（Fncalc7の赤黒木ライブラリ）の監査で発見された潜在バグの是正版です。詳細は[15. 赤黒木ライブラリの堅牢性強化](#15-赤黒木ライブラリの堅牢性強化)を参照。

#### 10.1.2 基本操作

**ノード作成**
```scheme
(load "rbtree_lib_improved.scm")

; 新しいツリー（空）
(define tree RB-NIL)

; 挿入
(set! tree (rb-insert tree 10 "ten"))
(set! tree (rb-insert tree 5 "five"))
(set! tree (rb-insert tree 20 "twenty"))
```

**検索**
```scheme
(rb-search tree 10)  ; → "ten"
(rb-search tree 99)  ; → FALSE
```

**存在確認（`rb-contains?`）** ← **NEW!**
```scheme
; rb-search は「不在」も FALSE を返すため、
; 値そのものが false の場合と区別できない。
; rb-contains? は在・不在だけを厳密に判定する。
(set! tree (rb-insert tree 30 false))
(rb-search tree 30)     ; → FALSE（値が false なのか不在なのか分からない）
(rb-contains? tree 30)  ; → TRUE（キーは存在する、と明確に分かる）
(rb-contains? tree 99)  ; → FALSE（本当に存在しない）
```

**削除**
```scheme
(set! tree (rb-delete tree 10))
```

**走査**
```scheme
; ソート順のキーリストを取得
(rb-to-list tree)  ; → (5 20)

; 各要素に対して処理（キーを表示）
(rb-traverse tree)  ; キーを順に表示
```

#### 10.1.3 高度な操作

**検証（Improved版）**
```scheme
(rb-validate tree)
; 出力例:
; Tree is valid (black height: 2)
```

**改善点**:
- 空ツリーの適切な処理
- 根ノードの色チェック
- より詳細な黒高さ情報の表示
- 検証結果の真偽値返却
- 右傾き赤リンク（左傾き不変条件違反）の検出 ← **NEW!**
- 中順走査によるBST順序（キーの単調増加）の検証 ← **NEW!**

旧版は「赤ノードの子が赤でないか」と「黒高さが左右で一致するか」しか見ていなかったため、黒ノードが赤の右の子を持つ壊れ方（左傾き木としては不正だが上記2条件は素通りする）や、色・高さは正しいままキーの並びだけが壊れる壊れ方を検出できませんでした。Improved版はこの2点を追加で検査します（詳細は[15. 赤黒木ライブラリの堅牢性強化](#15-赤黒木ライブラリの堅牢性強化)）。

**ノード数カウント**
```scheme
(rb-count-nodes tree)  ; → 2
```

**ツリー構造の表示（簡略版）**
```scheme
(rb-print-tree tree)
; 出力例:
; Tree structure (key:color):
;     20:B
;   5:R
```

**特徴**:
- インデントによる階層表示
- キーと色（R/B）の簡潔な表示
- 右部分木 → ルート → 左部分木の順

#### 10.1.4 実装の特徴

**データ構造**
```scheme
; ノード: #(left right color key data)
(define node (vector RB-NIL RB-NIL RED 10 "data"))

; アクセス
(rb-left node)    ; → 左の子
(rb-right node)   ; → 右の子
(rb-color node)   ; → 色（RED=1 or BLACK=0）
(rb-key node)     ; → キー
(rb-data node)    ; → データ
```

**色の定義**
```scheme
(define BLACK 0)
(define RED 1)
(define RB-NIL ":nil")  ; 特殊なNIL値
```

**NILチェックの改善**

```scheme
(define rb-null?
  (lambda (node)
    (or (null? node)
        (eq? node RB-NIL)
        (equal? node RB-NIL))))
```

**平衡操作**
```scheme
; 右回転
(rb-rotate-right node)

; 左回転
(rb-rotate-left node)

; 色の反転（挿入用）
(rb-flip-colors node)

; 色の反転（削除用）
(rb-flip-colors-delete node)
```

**内部関数と公開関数の分離**（`rb-delete-min`）← **NEW!**

```scheme
; 内部専用: サブツリーに対してのみ使う（前提条件あり）
(rb-delete-min-impl node)

; 公開インターフェース: ツリーのルートに対して直接呼んでよい
(rb-delete-min node)
```

`rb-delete-min-impl` は「呼び出し側がすでに削除降下の不変条件（自身か左の子が赤）を整えた後」の使用を前提とする内部関数です。ツリーのルート（両方の子が黒であることが多い）に対してこれを直接呼ぶと、根が赤のまま返ってくることがありました。公開版の `rb-delete-min` は、降下前に「両方の子が黒なら根を赤にする」処理を行い、`rb-delete-min-impl` を呼んだ後に「結果の根を黒にする」処理で締めくくることで、単独呼び出しでも安全になっています。詳細は[15. 赤黒木ライブラリの堅牢性強化](#15-赤黒木ライブラリの堅牢性強化)を参照してください。

#### 10.1.5 テスト実行

**包括的テスト（rb-test）**
```scheme
scheme12> (load "rbtree_lib_improved.scm")
Red-Black Tree Library (Improved) loaded.
Commands:
  (rb-test)      - Run comprehensive tests
  (rb-example)   - Run simple example

scheme12> (rb-test)

=== Red-Black Tree Test ===

Inserting: 10, 5, 20, 15, 30, 25, 35, 3, 7, 40, 45, 11, 12

Keys in order: (3 5 7 10 11 12 15 20 25 30 35 40 45)

Tree is valid (black height: 3)

Searching for key 15: ddd

Deleting key 10
Keys in order: (3 5 7 11 12 15 20 25 30 35 40 45)
Tree is valid (black height: 3)

Deleting key 20
Keys in order: (3 5 7 11 12 15 25 30 35 40 45)
Tree is valid (black height: 3)

Tree structure:
Tree structure (key:color):
    45:B
  40:B
    35:B
      30:R
25:B
    15:B
      12:R
  11:B
      7:B
    5:R
      3:B

=== Stress Test ===
Inserting 0-49...

Node count: 50
Tree is valid (black height: 5)

Deleting even numbers...

Node count: 25
Remaining keys: (1 3 5 7 9 11 13 15 17 19 21 23 25 27 29 31 33 35 37 39 41 43 45 47 49)
Tree is valid (black height: 4)

=== Test Complete ===
```

**テストの内容**:
1. 13個のキーの挿入テスト
2. 検索機能の確認
3. 削除後の整合性確認
4. ツリー構造の可視化
5. ストレステスト（0-49の挿入、偶数の削除）

**簡単な使用例（rb-example）**
```scheme
scheme12> (rb-example)

=== Simple Example ===
Search 50: fifty
All keys: (25 50 75 100 150)
Tree is valid (black height: 2)

Tree structure (key:color):
    150:R
  100:B
    75:R
50:B
  25:B
```

#### 10.1.6 改善されたエラーハンドリング

```scheme
; NILノードへのアクセス時
(rb-key RB-NIL)
; 出力: Error: rb-key on nil node
; 返り値: 0

(rb-data RB-NIL)
; 出力: Error: rb-data on nil node
; 返り値: false
```

#### 10.1.7 堅牢性回帰テスト（rbtree_robustness_test.scm）← **NEW!**

`rb-test` が機能の一巡した動作確認であるのに対し、`rbtree_robustness_test.scm` は「壊れないこと」自体を検証する専用のテストです。

```scheme
scheme12> (load "rbtree_robustness_test.scm")
; ...
;   Results: 17/17 passed
; *** ALL ROBUSTNESS TESTS PASSED ***
```

検証内容は[15. 赤黒木ライブラリの堅牢性強化](#15-赤黒木ライブラリの堅牢性強化)にまとめています。

---

### 10.2 ハッシュテーブルライブラリ（hashtable_lib.scm）

#### 10.2.1 概要

**赤黒木ベースのハッシュテーブル実装**で、**適切な衝突処理（Proper Collision Handling）**を実装しています。

**主要な特徴**:
- ✅ **チェイニング方式**による衝突処理
- ✅ **O(log n)** の操作（赤黒木ベース）
- ✅ 様々なキー型をサポート（数値、文字列、シンボル、ブール）
- ✅ 型を考慮したキー比較
- ✅ 衝突統計情報の提供
- ✅ イテレータ・変換関数が充実

**衝突処理の仕組み**:
```
ハッシュテーブル構造:
  赤黒木 → バケット（リスト） → エントリ（key . value）

例: ハッシュ値が同じキーの格納
  hash(key1) = hash(key2) = 12345
  
  赤黒木[12345] → [(key1 . value1), (key2 . value2)]
                   ↑ バケット（リスト）
```

#### 10.2.2 データ構造

**ハッシュテーブル構造**
```scheme
; #(tree size metadata)
;   tree: 赤黒木（ハッシュ値 → バケット）
;   size: エントリ数
;   metadata: 将来の拡張用

(define HT-TREE-INDEX 0)
(define HT-SIZE-INDEX 1)
(define HT-META-INDEX 2)
```

**バケット構造（チェイニング）**
```scheme
; バケット: ((key1 . value1) (key2 . value2) ...)
; 同じハッシュ値を持つ複数のエントリを格納

; エントリの作成
(make-ht-entry key value)  ; → (key . value)

; エントリからの取得
(ht-entry-key entry)       ; → key
(ht-entry-value entry)     ; → value
```

**キー比較（型考慮）**
```scheme
(define ht-keys-equal?
  (lambda (k1 k2)
    (cond
      ((and (number? k1) (number? k2)) (= k1 k2))
      ((and (string? k1) (string? k2)) (string=? k1 k2))
      ((and (symbol? k1) (symbol? k2)) (eq? k1 k2))
      ((and (boolean? k1) (boolean? k2)) (eq? k1 k2))
      (else (equal? k1 k2)))))
```

#### 10.2.3 ハッシュ関数

**文字列ハッシュ（djb2アルゴリズム）**
```scheme
(define hash-string
  (lambda (str)
    (let loop ((chars (string->list str))
               (hash 5381))
      (if (null? chars)
          (modulo hash 2147483647)
          (let* ((c (char->integer (car chars)))
                 (new-hash (+ (* hash 33) c)))
            (loop (cdr chars) new-hash))))))
```

**型別ハッシュディスパッチ**
```scheme
(define hash-value
  (lambda (key)
    (cond
      ((number? key) (modulo key 2147483647))
      ((string? key) (hash-string key))
      ((symbol? key) (hash-string (symbol->string key)))
      ((boolean? key) (if key 1 0))
      (else (hash-string "unknown")))))
```

#### 10.2.4 バケット操作（衝突処理の核心）

**バケット内のエントリ検索**
```scheme
(define bucket-find
  (lambda (bucket key)
    (if (null? bucket)
        false
        (let ((entry (car bucket)))
          (if (ht-keys-equal? (ht-entry-key entry) key)
              entry
              (bucket-find (cdr bucket) key))))))
```

**バケットへの追加・更新**
```scheme
; 返り値: (new-bucket . added?)
; added? = true なら新規追加、false なら更新
(define bucket-set
  (lambda (bucket key value)
    (if (null? bucket)
        (cons (list (make-ht-entry key value)) true)
        (let ((entry (car bucket))
              (rest (cdr bucket)))
          (if (ht-keys-equal? (ht-entry-key entry) key)
              (begin
                (ht-set-entry-value! entry value)
                (cons bucket false))
              (let ((result (bucket-set rest key value)))
                (cons (cons entry (car result)) (cdr result))))))))
```

**バケットからの削除**
```scheme
; 返り値: (new-bucket . removed?)
(define bucket-remove
  (lambda (bucket key)
    (if (null? bucket)
        (cons '() false)
        (let ((entry (car bucket))
              (rest (cdr bucket)))
          (if (ht-keys-equal? (ht-entry-key entry) key)
              (cons rest true)
              (let ((result (bucket-remove rest key)))
                (cons (cons entry (car result)) (cdr result))))))))
```

#### 10.2.5 基本操作

**作成と挿入**
```scheme
(load "rbtree_lib_improved.scm")
(load "hashtable_lib.scm")

(define ht (make-hash-table))

; キーと値のペアを設定
(hash-table-set! ht "name" "Alice")
(hash-table-set! ht "age" 30)
(hash-table-set! ht 'status "Active")
(hash-table-set! ht 12345 "Number key")
(hash-table-set! ht true "Boolean key")
```

**内部動作**:
1. キーのハッシュ値を計算
2. 赤黒木でバケットを検索
3. バケット内で実際のキーを照合
4. 見つからなければ新規追加、見つかれば更新

**取得**
```scheme
(hash-table-get ht "name")     ; → "Alice"
(hash-table-get ht "unknown")  ; → FALSE

; デフォルト値指定
(hash-table-get ht "unknown" "N/A")  ; → "N/A"
```

**存在確認**
```scheme
(hash-table-has-key? ht "name")  ; → TRUE
(hash-table-has-key? ht "xyz")   ; → FALSE
```

**削除**
```scheme
(hash-table-delete! ht "age")  ; → TRUE（削除成功）
(hash-table-delete! ht "xyz")  ; → FALSE（存在しない）
```

**内部動作**:
1. バケットからエントリを削除
2. バケットが空になった場合は赤黒木からも削除
3. サイズカウンタを更新

**サイズとクリア**
```scheme
(hash-table-size ht)       ; → エントリ数
(hash-table-empty? ht)     ; → TRUE/FALSE
(hash-table-clear! ht)     ; すべて削除
```

#### 10.2.6 イテレーション

**キー・値の取得**
```scheme
(hash-table-keys ht)     ; → すべてのキーのリスト
(hash-table-values ht)   ; → すべての値のリスト
```

**連想リスト変換**
```scheme
; ハッシュテーブル → 連想リスト
(hash-table->alist ht)
; → ((key1 . value1) (key2 . value2) ...)

; 連想リスト → ハッシュテーブル
(define ht2 (alist->hash-table '(("a" . 1) ("b" . 2))))
```

**for-each**
```scheme
(hash-table-for-each ht
  (lambda (key value)
    (display key)
    (display " => ")
    (display value)
    (newline)))
```

**map**
```scheme
(hash-table-map ht
  (lambda (key value)
    (string-append (symbol->string key) ":" value)))
```

**filter**
```scheme
(define filtered 
  (hash-table-filter ht
    (lambda (key value)
      (string? value))))
```

**fold**
```scheme
(hash-table-fold ht
  (lambda (key value acc)
    (string-append acc (symbol->string key) " "))
  "Keys: ")
```

#### 10.2.7 ユーティリティ操作

**更新**
```scheme
; 値を更新（キーが存在しない場合は挿入）
(hash-table-update! ht "count"
  (lambda (v) (+ v 1))
  0)  ; デフォルト値
```

**マージとコピー**
```scheme
; コピー
(define ht-copy (hash-table-copy ht))

; マージ（ht2の値がht1を上書き）
(define merged (hash-table-merge ht1 ht2))
```

#### 10.2.8 ユーティリティマクロ

```scheme
; 簡潔な参照
(ht-ref ht "name")           ; = (hash-table-get ht "name")
(ht-ref ht "unknown" "N/A")  ; デフォルト値指定

; 簡潔な更新
(ht-set! ht "name" "Bob")    ; = (hash-table-set! ht "name" "Bob")

; 存在確認
(ht-has? ht "name")          ; = (hash-table-has-key? ht "name")
```

#### 10.2.9 デバッグ機能

**内容表示**
```scheme
(hash-table-display ht)
; 出力:
; Hash Table {
;   name => Alice
;   age => 30
;   status => Active
; }
; Size: 3
```

**検証**
```scheme
(hash-table-validate ht)
; 出力:
; Validating hash table...
;   Tree: PASS
;   Size: stored=3, actual=3 PASS
```

**統計情報（衝突分析付き）**
```scheme
(hash-table-stats ht)
; 出力:
; Hash Table Statistics:
;   Size: 100
;   Empty: FALSE
;   Tree nodes (buckets): 95
;   Buckets with collisions: 5 / 95
;   Collision rate: 5%
```

**改善点**:
- バケット数とエントリ数の区別
- 衝突が発生しているバケットの数を表示
- 衝突率の計算

#### 10.2.10 テスト関数

**衝突処理テスト（ht-test-collision）** - **NEW!**

```scheme
scheme12> (ht-test-collision)

=== Hash Collision Test ===
Testing collision handling...
Set keys with same hash modulo: 5, 2147483652, 4294967299

Retrieving values:
  key 5 => value-5
  key 2147483652 => value-2147483652
  key 4294967299 => value-4294967299

All keys preserved: (5 2147483652 4294967299)
Size: 3

Deleting middle key (2147483652)...
Remaining keys: (5 4294967299)
key 5 still accessible? value-5
key 4294967299 still accessible? value-4294967299

Hash Table Statistics:
  Size: 2
  Empty: FALSE
  Tree nodes (buckets): 1
  Buckets with collisions: 1 / 1
  Collision rate: 100%

Validating hash table...
  Tree: PASS
  Tree is valid (black height: 1)
  Size: stored=2, actual=2 PASS

Collision test completed!
```

**テストのポイント**:
- 同じハッシュ値を持つキーの正しい格納
- バケット内での個別キーの識別
- 衝突時の削除の正確性
- すべてのキーが独立してアクセス可能

**基本機能テスト（ht-test-basic）**

```scheme
scheme12> (ht-test-basic)

=== Hash Table Basic Test ===
Created empty hash table
Size: 0

Setting key-value pairs:
Keys: (name age city status 12345 TRUE)

Getting values:
  name => Alice
  age => 30
  status => Active
  12345 => Number key
  true => Boolean key
  unknown => DEFAULT

Updating 'age':
  age => 31

Hash Table {
  name => Alice
  age => 31
  city => Tokyo
  status => Active
  12345 => Number key
  TRUE => Boolean key
}
Size: 6

Hash Table Statistics:
  Size: 6
  Empty: FALSE
  Tree nodes (buckets): 6
  Buckets with collisions: 0 / 6
  Collision rate: 0%

Validating hash table...
  Tree: PASS
  Size: stored=6, actual=6 PASS
```

**ストレステスト（ht-test-stress）**

```scheme
scheme12> (ht-test-stress 1000)

=== Stress Test with Collision Tracking (1000 entries) ===
Inserting...
.......... .......... .......... ...（省略）

Hash Table Statistics:
  Size: 1000
  Empty: FALSE
  Tree nodes (buckets): 987
  Buckets with collisions: 13 / 987
  Collision rate: 1%

Validating hash table...
  Tree: PASS
  Size: stored=1000, actual=1000 PASS

Test completed!
```

**ストレステストの意義**:

- 大量データでの性能確認
- 衝突発生率の実測
- 赤黒木のバランス維持の確認
- メモリ使用量の確認

#### 10.2.11 実用例

**単語カウント**
```scheme
(define (count-words text)
  (let ((ht (make-hash-table)))
    (for-each
      (lambda (word)
        (hash-table-update! ht word
          (lambda (count) (+ count 1))
          0))
      (string-split text))
    ht))

(define wc (count-words "apple banana apple cherry banana apple"))
(hash-table-display wc)
; apple => 3
; banana => 2
; cherry => 1
```

**電話帳**
```scheme
(define phonebook (make-hash-table))

(ht-set! phonebook "Alice" "090-1234-5678")
(ht-set! phonebook "Bob" "080-9876-5432")
(ht-set! phonebook "Charlie" "070-1111-2222")

(display "Alice's phone: ")
(display (ht-ref phonebook "Alice"))
(newline)

; すべてのエントリを表示
(hash-table-for-each phonebook
  (lambda (name phone)
    (display name)
    (display ": ")
    (display phone)
    (newline)))
```

**グループ化**
```scheme
(define (group-by key-fn lst)
  (let ((ht (make-hash-table)))
    (for-each
      (lambda (item)
        (let ((key (key-fn item)))
          (hash-table-update! ht key
            (lambda (group) (cons item group))
            '())))
      lst)
    ht))

; 使用例: 長さでグループ化
(define words '("a" "bb" "c" "ddd" "ee" "f"))
(define grouped (group-by string-length words))
(hash-table-display grouped)
; 1 => (f c a)
; 2 => (ee bb)
; 3 => (ddd)
```

#### 10.2.12 パフォーマンス特性

| 操作 | 時間計算量 | 説明 |
|------|-----------|------|
| 挿入 | O(log n) | 赤黒木の挿入 + バケット内リスト操作 |
| 検索 | O(log n) | 赤黒木の検索 + バケット内線形探索 |
| 削除 | O(log n) | 赤黒木の削除 + バケット内リスト操作 |
| イテレーション | O(n) | すべてのエントリを走査 |

**衝突時の影響**:
- バケット内のエントリ数が k の場合、検索・挿入・削除は O(log n + k)
- 良いハッシュ関数では k は小さく、実質 O(log n)
- ストレステストでの衝突率は通常 1-5%

**メモリ使用量**:
- 赤黒木: O(バケット数) ≈ O(n)（衝突が少ない場合）
- バケット: O(n)（すべてのエントリ）
- 合計: O(n)

---

### 10.3 ライブラリ使用のベストプラクティス

#### 10.3.1 赤黒木の使い分け

**適している用途**:
- ソート順でのデータ走査が必要
- 範囲検索（最小・最大）
- 順序を保持したい場合

**例: 成績管理**
```scheme
(define scores RB-NIL)
(set! scores (rb-insert scores 95 "Alice"))
(set! scores (rb-insert scores 88 "Bob"))
(set! scores (rb-insert scores 92 "Charlie"))

; 成績順に表示
(rb-traverse scores)
; 88
; 92
; 95
```

#### 10.3.2 ハッシュテーブルの使い分け

**適している用途**:
- 高速な検索が必要
- キーの順序が不要
- 辞書・マップ的な使い方

**例: 設定管理**
```scheme
(define config (make-hash-table))
(ht-set! config 'debug-mode true)
(ht-set! config 'max-connections 100)
(ht-set! config 'timeout 30)

; 設定の取得
(if (ht-ref config 'debug-mode false)
    (display "Debug mode enabled"))
```

#### 10.3.3 大規模データの扱い

**定期的な検証**
```scheme
(define (process-large-data data)
  (let ((ht (make-hash-table)))
    (let loop ((remaining data) (count 0))
      (if (null? remaining)
          ht
          (begin
            (hash-table-set! ht (car remaining) count)
            ; 1000件ごとに検証
            (if (= (modulo count 1000) 0)
                (begin
                  (hash-table-validate ht)
                  (gc-collect)))
            (loop (cdr remaining) (+ count 1)))))))
```

**統計情報の監視**
```scheme
(define (monitor-hash-table ht)
  (hash-table-stats ht)
  (let ((size (hash-table-size ht)))
    (if (> size 10000)
        (display "Warning: Large hash table")
        (newline))))
```

#### 10.3.4 エラーハンドリング

**赤黒木での安全な操作**
```scheme
(define (safe-rb-search tree key default)
  (let ((result (rb-search tree key)))
    (if result
        result
        default)))

; 使用例
(define value (safe-rb-search tree 42 "Not found"))
```

**ハッシュテーブルでのデフォルト値**
```scheme
; デフォルト値を常に指定する習慣
(define count (hash-table-get ht "counter" 0))

; または update! を使用
(hash-table-update! ht "counter"
  (lambda (v) (+ v 1))
  0)  ; 初期値
```

#### 10.3.5 デバッグとトラブルシューティング

**赤黒木のデバッグ**
```scheme
(define (debug-rbtree tree)
  (display "=== RB-Tree Debug Info ===")
  (newline)
  (display "Node count: ")
  (display (rb-count-nodes tree))
  (newline)
  (display "Keys: ")
  (display (rb-to-list tree))
  (newline)
  (display "Validation: ")
  (rb-validate tree)
  (display "Structure:")
  (newline)
  (rb-print-tree tree))
```

**ハッシュテーブルのデバッグ**
```scheme
(define (debug-hashtable ht)
  (display "=== Hash Table Debug Info ===")
  (newline)
  (hash-table-stats ht)
  (hash-table-validate ht)
  (display "Sample entries (first 5):")
  (newline)
  (let ((entries (hash-table->alist ht)))
    (let loop ((es entries) (count 0))
      (if (or (null? es) (>= count 5))
          'done
          (begin
            (display "  ")
            (display (car (car es)))
            (display " => ")
            (display (cdr (car es)))
            (newline)
            (loop (cdr es) (+ count 1)))))))
```

**衝突の診断**
```scheme
(define (diagnose-collisions ht)
  (display "=== Collision Diagnosis ===")
  (newline)
  (hash-table-stats ht)
  (display "Checking hash distribution...")
  (newline)
  
  ; サンプルキーのハッシュ値を表示
  (hash-table-for-each ht
    (lambda (key value)
      (display "Key: ")
      (display key)
      (display " -> Hash: ")
      (display (hash-value key))
      (newline))))
```

---

## 11. 実用例とベストプラクティス

### 11.1 プログラムの構成

#### ファイル構成例
```
project/
├── main.scm              # メインプログラム
├── utils.scm             # ユーティリティ関数
├── data-structures.scm   # データ構造定義
├── tests.scm             # テストコード
└── lib/
    ├── rbtree_lib_improved.scm
    └── hashtable_lib.scm
```

#### main.scm
```scheme
; ライブラリの読み込み
(load "lib/rbtree_lib_improved.scm")
(load "lib/hashtable_lib.scm")
(load "utils.scm")
(load "data-structures.scm")

; メイン処理
(define (main)
  (display "Starting program...")
  (newline)
  ; ... 処理 ...
  )

; 実行
(main)
```

### 11.2 効率的なコーディング

#### 末尾再帰の活用

**悪い例（スタックを消費）**
```scheme
(define (sum-list lst)
  (if (null? lst)
      0
      (+ (car lst) (sum-list (cdr lst)))))

; 大きなリストでスタックオーバーフロー
```

**良い例（末尾再帰＋TCO）**
```scheme
(define (sum-list lst)
  (define (iter lst acc)
    (if (null? lst)
        acc
        (iter (cdr lst) (+ acc (car lst)))))
  (iter lst 0))

; スタックを消費しない
```

#### クロージャの活用

```scheme
(define (make-counter)
  (let ((count 0))
    (lambda ()
      (set! count (+ count 1))
      count)))

(define c1 (make-counter))
(c1)  ; → 1
(c1)  ; → 2

(define c2 (make-counter))
(c2)  ; → 1  ; 独立したカウンタ
```

### 11.3 データ処理パターン

#### パイプライン処理
```scheme
(define (process-data data)
  ; フィルタ → マップ → 集約
  (fold-left +
             0
             (map (lambda (x) (* x x))
                  (filter (lambda (x) (> x 0))
                          data))))

(process-data '(-2 -1 0 1 2 3 4 5))
; → 1 + 4 + 9 + 16 + 25 = 55
```

#### ハッシュテーブルによるグループ化
```scheme
(define (group-by key-fn lst)
  (let ((ht (make-hash-table)))
    (for-each
      (lambda (item)
        (let ((key (key-fn item)))
          (hash-table-update! ht key
            (lambda (group) (cons item group))
            '())))
      lst)
    ht))

; 使用例: 長さでグループ化
(define words '("a" "bb" "c" "ddd" "ee" "f"))
(define grouped (group-by string-length words))
(hash-table-display grouped)
; 1 => (f c a)
; 2 => (ee bb)
; 3 => (ddd)
```

#### 赤黒木による索引作成
```scheme
(define (build-index items key-fn)
  (let loop ((remaining items) (tree RB-NIL))
    (if (null? remaining)
        tree
        (let* ((item (car remaining))
               (key (key-fn item)))
          (loop (cdr remaining)
                (rb-insert tree key item))))))

; 使用例: ID による索引
(define students '((1 "Alice") (2 "Bob") (3 "Charlie")))
(define index (build-index students car))
(rb-search index 2)  ; → (2 "Bob")
```

### 11.4 エラー処理

#### 継続によるエラー処理
```scheme
(define (safe-divide a b)
  (call/cc
    (lambda (return)
      (if (= b 0)
          (return 'error-division-by-zero)
          (/ a b)))))

(safe-divide 10 2)  ; → 5
(safe-divide 10 0)  ; → error-division-by-zero
```

#### ガード節パターン
```scheme
(define (process-user user)
  (if (not (hash-table-has-key? user 'name))
      (begin
        (display "Error: name required")
        (newline)
        false)
      (if (not (hash-table-has-key? user 'age))
          (begin
            (display "Error: age required")
            (newline)
            false)
          ; 正常処理
          (begin
            (display "Processing user: ")
            (display (ht-ref user 'name))
            (newline)
            true))))
```

### 11.5 デバッグとテスト

#### アサーション
```scheme
(define (assert condition message)
  (if (not condition)
      (begin
        (display "ASSERTION FAILED: ")
        (display message)
        (newline)
        (call/cc (lambda (k) (k 'test-failed))))
      true))

(define (test-factorial)
  (assert (= (fact 0 1) 1) "fact(0) should be 1")
  (assert (= (fact 5 1) 120) "fact(5) should be 120")
  (display "All tests passed")
  (newline))
```

#### ユニットテストフレームワーク
```scheme
(define *test-results* '())

(define (test name proc)
  (display "Testing: ")
  (display name)
  (display "... ")
  (let ((result (call/cc
                  (lambda (escape)
                    (set! *test-results*
                      (cons (cons name (proc escape))
                            *test-results*))
                    'pass))))
    (if (eq? result 'pass)
        (display "PASS")
        (display "FAIL"))
    (newline)))

(define (run-tests)
  (test "addition"
    (lambda (fail)
      (if (not (= (+ 1 2) 3))
          (fail 'fail))))
  
  (test "hash-table operations"
    (lambda (fail)
      (let ((ht (make-hash-table)))
        (hash-table-set! ht "key" "value")
        (if (not (equal? (hash-table-get ht "key") "value"))
            (fail 'fail)))))
  
  (display "Test summary:")
  (newline)
  (for-each
    (lambda (result)
      (display (car result))
      (display ": ")
      (display (cdr result))
      (newline))
    (reverse *test-results*)))
```

### 11.6 実用的なアプリケーション例

#### 11.6.1 単語頻度分析器

```scheme
(load "lib/rbtree_lib_improved.scm")
(load "lib/hashtable_lib.scm")

(define (analyze-text filename)
  (let ((ht (make-hash-table))
        (port (open-input-file filename)))
    
    ; ファイルから単語を読み込んでカウント
    (let loop ()
      (let ((word (read port)))
        (if (eof-object? word)
            (begin
              (close-input-port port)
              ht)
            (begin
              (hash-table-update! ht word
                (lambda (count) (+ count 1))
                0)
              (loop)))))
    
    ; 結果を赤黒木に変換してソート
    (let ((sorted-tree RB-NIL))
      (hash-table-for-each ht
        (lambda (word count)
          (set! sorted-tree 
            (rb-insert sorted-tree count word))))
      
      ; 頻度順に表示
      (display "=== Word Frequency (sorted by count) ===")
      (newline)
      (rb-traverse sorted-tree))))

; 使用例
; (analyze-text "document.txt")
```

#### 11.6.2 キャッシュシステム

```scheme
(define (make-cache max-size)
  (let ((ht (make-hash-table))
        (access-order '()))
    
    ; キャッシュ取得（LRU）
    (define (get key)
      (let ((value (hash-table-get ht key false)))
        (if value
            (begin
              ; アクセス順を更新
              (set! access-order 
                (cons key (filter (lambda (k) (not (equal? k key))) 
                                 access-order)))
              value)
            false)))
    
    ; キャッシュ設定
    (define (put key value)
      ; サイズ制限チェック
      (if (and (>= (hash-table-size ht) max-size)
               (not (hash-table-has-key? ht key)))
          ; 最も古いエントリを削除
          (let ((oldest (car (reverse access-order))))
            (hash-table-delete! ht oldest)
            (set! access-order (cdr (reverse access-order)))))
      
      ; 新しいエントリを追加
      (hash-table-set! ht key value)
      (set! access-order (cons key access-order)))
    
    ; 統計情報
    (define (stats)
      (display "Cache size: ")
      (display (hash-table-size ht))
      (display " / ")
      (display max-size)
      (newline)
      (display "Access order: ")
      (display access-order)
      (newline))
    
    ; インターフェース
    (lambda (msg . args)
      (cond
        ((eq? msg 'get) (apply get args))
        ((eq? msg 'put) (apply put args))
        ((eq? msg 'stats) (stats))
        (else (display "Unknown message"))))))

; 使用例
(define cache (make-cache 3))
(cache 'put "key1" "value1")
(cache 'put "key2" "value2")
(cache 'put "key3" "value3")
(cache 'stats)
; Cache size: 3 / 3
; Access order: (key3 key2 key1)

(cache 'get "key1")  ; → "value1"
(cache 'stats)
; Access order: (key1 key3 key2)

(cache 'put "key4" "value4")  ; key2が削除される
(cache 'stats)
; Cache size: 3 / 3
; Access order: (key4 key1 key3)
```

#### 11.6.3 データベース風のクエリシステム

```scheme
(define (make-database)
  (let ((tables (make-hash-table)))
    
    ; テーブル作成
    (define (create-table name)
      (hash-table-set! tables name (make-hash-table)))
    
    ; レコード挿入
    (define (insert table-name id record)
      (let ((table (hash-table-get tables table-name)))
        (if table
            (hash-table-set! table id record)
            (display "Table not found"))))
    
    ; レコード検索
    (define (select table-name id)
      (let ((table (hash-table-get tables table-name)))
        (if table
            (hash-table-get table id)
            false)))
    
    ; 条件検索
    (define (where table-name predicate)
      (let ((table (hash-table-get tables table-name)))
        (if table
            (hash-table-filter table
              (lambda (id record) (predicate record)))
            (make-hash-table))))
    
    ; テーブル一覧
    (define (list-tables)
      (hash-table-keys tables))
    
    ; インターフェース
    (lambda (msg . args)
      (cond
        ((eq? msg 'create-table) (apply create-table args))
        ((eq? msg 'insert) (apply insert args))
        ((eq? msg 'select) (apply select args))
        ((eq? msg 'where) (apply where args))
        ((eq? msg 'list-tables) (list-tables))
        (else (display "Unknown command"))))))

; 使用例
(define db (make-database))
(db 'create-table 'users)
(db 'insert 'users 1 (make-hash-table))
(let ((user1 (db 'select 'users 1)))
  (ht-set! user1 'name "Alice")
  (ht-set! user1 'age 30)
  (ht-set! user1 'email "alice@example.com"))

(db 'insert 'users 2 (make-hash-table))
(let ((user2 (db 'select 'users 2)))
  (ht-set! user2 'name "Bob")
  (ht-set! user2 'age 25)
  (ht-set! user2 'email "bob@example.com"))

; 30歳以上のユーザーを検索
(define adults (db 'where 'users
                   (lambda (record)
                     (>= (ht-ref record 'age 0) 30))))

(hash-table-display adults)
```

---

## 12. 互換性ノート

### 12.1 micro_Scheme8との差異

#### 実装方針の違い
- **micro_Scheme8**: Common Lisp実装
- **scheme12**: C++実装（Boehm GC + Boost）

#### 型システム
| 機能 | micro_Scheme8 | scheme12 |
|------|---------------|----------|
| 整数 | 固定精度 | 任意精度（Boost） |
| 浮動小数 | ✅ | ❌ |
| 有理数 | ✅ | ❌ |
| 複素数 | ✅ | ❌ |
| 文字列 | ✅ | ✅ |
| ベクタ | ✅ | ✅ |

#### 命令セット
- **SELR**: scheme12では実装済みだが未使用（将来用）
- **CALLCC**: scheme12では専用命令、microではldct+app

#### マクロシステム
- 基本動作は同じ
- 展開タイミングや内部実装に差異

### 12.2 標準Schemeとの差異

scheme12は教育・実験用途のため、R5RS/R7RSとは一部異なります：

| 機能                     | R5RS/R7RS                | scheme12                          |
| ------------------------ | ------------------------ | --------------------------------- |
| 数値塔                   | 完全                     | 整数のみ                          |
| **真偽値表記**           | **`#t` / `#f`**          | **✅ v2.0でサポート**              |
| マクロ                   | syntax-rules             | define-macro                      |
| モジュール               | ✅ (R7RS)                 | ❌                                 |
| 例外処理                 | ✅                        | ❌（call/ccで代用）                |
| 遅延評価                 | delay/force              | ✅                                 |
| 継続                     | call/cc                  | ✅                                 |
| **継続の正式名**         | **call-with-current-continuation** | **✅ v2.1でサポート**    |
| **`(call/cc k)`**        | **有効**                 | **✅ v2.1でサポート**              |
| **call/cc・applyの値渡し** | **手続きなので可能**   | **❌ 特殊形式のため不可**          |
| **内部define**           | **本体内のレキシカル束縛** | **✅ v2.1でサポート（先頭のみ）** |
| **ドット位置のunquote**  | **`` `(a . ,x) ``**      | **✅ v2.1でサポート**              |
| **ベクタ内のunquote**    | **`` `#(1 ,x) ``**       | **✅ v2.1でサポート**              |
| **ネストした準クオート** | **`` `(a `(b ,,x)) ``**  | **❌ 未サポート**                  |
| **単一引数除算**         | **`(/ x)` = 逆数**       | **❌（v2.0で明示的にエラー）**     |
| **角括弧**               | **`[]` = `()`**          | **❌ 未サポート**                  |

**✨ v2.0での改善**:
- `#t` / `#f` 構文の追加でR5RS/R7RSとの互換性向上
- 未サポート機能で親切なエラーメッセージを提供

**✨ v2.1での改善**:
- `call-with-current-continuation` を追加（教科書のコードがそのまま動く）
- 内部 `define` がグローバルを汚さなくなった
- 準クオートのドット位置・ベクタ内の `unquote` に対応
- 特殊形式の構文エラーがフォーム名と該当式つきで報告される

### 12.3 移植時の注意点

#### Common Lispから移植する場合
```scheme
; Common Lisp
(defun fact (n)
  (if (zerop n)
      1
      (* n (fact (1- n)))))

; scheme12
(define (fact n)
  (if (= n 0)
      1
      (* n (fact (- n 1)))))
```

- `zerop` → `(= n 0)`
- `1-` → `(- n 1)`
- `defun` → `define`

#### 標準Schemeから移植する場合
```scheme
; R5RS (syntax-rules)
(define-syntax when
  (syntax-rules ()
    ((when test body ...)
     (if test (begin body ...)))))

; scheme12 (define-macro)
(define-macro (when test . body)
  `(if ,test (begin ,@body)))
```

#### v2.0での注意点 ✨

**1. 単一引数除算**
```scheme
; 標準Scheme
(/ 5)  ; → 1/5 または 0.2

; scheme12
(/ 5)  ; → Error: ... use (/ 1 x) instead
(/ 1 5)  ; 回避策
```

**2. 真偽値表記**
```scheme
; v2.0以降は両方サポート
#t       ; 標準構文（推奨）
true     ; scheme12独自（互換性のため残存）
```

**3. 循環構造**
```scheme
; v2.0では安全に扱える
(define circ (cons 1 nil))
(set-cdr! circ circ)
(equal? circ circ)  ; → TRUE（クラッシュしない）
```

#### v2.1での注意点 ✨

**1. 内部 define のスコープが変わった**
```scheme
(define (f x) (define y (* x 2)) (+ y 1))
(f 5)   ; → 11（変わらず）
y       ; v2.0: 10（グローバルに漏れていた）
        ; v2.1: unbound global: y（正しい）
```
v2.0 の挙動に依存して、関数の外から内部 `define` の名前を参照していた
コードは動かなくなります。その場合はトップレベルの `define` に移してください。

**2. 余分な引数がエラーになる**
```scheme
(if a b c d)     ; v2.0: d を黙って無視 → v2.1: エラー
(define x 1 2)   ; v2.0: 2 を黙って無視 → v2.1: エラー
```

**3. 継続は1つの begin にまとめる**
```scheme
; 何度も再入する用途（ジェネレータ等）は1フォームにまとめる
(begin
  (define k (call/cc (lambda (c) c)))
  ...)
```
トップレベルのフォームはそれぞれ別の VM で評価されるため、別フォームから
継続を起動するとそのフォームの残りは実行されません。

---

## 13. 実装上の注意・拡張ポイント

### 13.1 メモリ管理

#### Boehm GC
- すべてのオブジェクトは`gc`クラスを継承
- 明示的な`delete`不要
- GC設定の調整：

```cpp
GC_INIT();
GC_set_max_heap_size(1024 * 1024 * 1024);  // 1GB
GC_enable_incremental();
GC_set_free_space_divisor(4);  // より頻繁にGC
```

#### GC制御（Scheme側）
```scheme
(gc-collect)      ; 強制GC
(gc-heap-size)    ; ヒープサイズ確認
(gc-free-bytes)   ; 空きバイト数確認
```

### 13.2 パフォーマンスチューニング

#### 末尾再帰最適化の確認
```scheme
; TAPPが使われているか確認
(disassemble my-function)
; 末尾位置で TAPP が生成されていればOK
```

#### 大規模データの処理
```scheme
; 定期的にGCを実行
(define (process-large-data data)
  (let loop ((remaining data) (count 0))
    (if (null? remaining)
        'done
        (begin
          (if (= (modulo count 1000) 0)
              (gc-collect))  ; 1000件ごとにGC
          (process-item (car remaining))
          (loop (cdr remaining) (+ count 1))))))
```

### 13.3 プリミティブの追加

新しいプリミティブ関数を追加する手順：

```cpp
// 1. 関数実装
static ValuePtr prim_my_function(const ValueVec& args) {
    if (args.size() != 1) vm_error("my-function expects 1 arg");
    // ... 処理 ...
    return result;
}

// 2. init_globals()で登録
void init_globals() {
    // ...
    g_globals["my-function"] = make_prim("my-function", prim_my_function);
    // ...
}
```

### 13.4 拡張の方向性

#### 追加可能な機能
1. **数値型の拡張**
   - 浮動小数点（double）
   - 有理数（分数）
   - 複素数

2. **マクロの改善**
   - 衛生的マクロ（syntax-rules相当）
   - パターンマッチング

3. **モジュールシステム**
   - 名前空間管理
   - インポート/エクスポート

4. **例外処理**
   - try/catch相当の構文
   - エラーハンドリング強化

5. **並行処理**
   - スレッド
   - 非同期I/O

6. **データ構造ライブラリの拡張**
   - AVL木
   - B木
   - トライ木
   - グラフ構造

### 13.5 既知の制限事項

#### 循環構造（v2.1で完成）✨
```scheme
; cdr方向・car方向のどちらの循環も安全
(define a (cons 1 2))
(set-cdr! a a)
(equal? a a)  ; → TRUE（安全）
a             ; → (1 . #<circular>)

(define x (list 1 2))
(set-car! x x)
x             ; → (( . #<circular>) 2)   v2.1で対応

; 長いリストでもスタックを溢れさせない
(define (range n acc) (if (= n 0) acc (range (- n 1) (cons n acc))))
(equal? (range 200000 '()) (range 200000 '()))  ; → TRUE   v2.1で対応
```

**残る制限**:
- car 方向に極端に深くネストした構造は、C スタックの深さで制限される
- `equal?` は照合中のスパンの長さに比例した作業メモリ
  （`unordered_map`）を確保する。20万要素同士の比較で数秒かかる

#### 継続の制約
```scheme
; 継続はファーストクラスだが、
; C++側のフレームを跨ぐ復帰は未サポート
```
- `call/cc` と `apply` は特殊形式であって値ではない。
  `(procedure? call/cc)` は `FALSE` で、高階関数に渡せない。
  ファーストクラス化するには `Op::APP` に分岐を足す必要があり、
  呼出しのホットパスに手を入れることになる
- トップレベルのフォームは別々の VM で評価されるため、フォームを跨いで
  継続を起動するとそのフォームの残りは実行されない

#### 内部 define の制約（v2.1）
- 本体**先頭**の連続した `define` だけが `letrec` に変換される。
  式より後ろの `define`、マクロが生成した `define`、本体先頭の
  `(begin (define ...) ...)` のスプライスは従来どおりグローバルになる

#### マクロの制約
- マクロ展開はコンパイル時、`define-macro` の実行は実行時なので、
  同一コンパイル単位（同じ `begin` やライブラリ本体）の中で定義直後に
  使うことはできない。トップレベルで1フォームずつ評価する分には問題ない

#### メモリ
- 16文字以上の識別子名（`Symbol::name`、`Instruction::sym`、
  `Closure::params`）は `GC_MALLOC_UNCOLLECTABLE` から確保され、
  `gc` 継承クラスのデストラクタが呼ばれないため解放されない
- `make_gensym` はシンボルをインターンするため、`or`/`cond`/`case`/`do`
  をコンパイルするたびに `g_symbol_intern` が単調増加する

#### 性能
- 呼出し1回あたり `Op::ARGS` で引数をリスト化 → `vector_from_list` で
  ベクタに戻す → フレームをベクタ化、という三重変換をしている。
  単純なループで約30万呼出し/秒

#### ポータビリティ
- Boehm GCのヘッダ検出が環境依存
- Windowsでは追加設定が必要な場合あり

**Windows環境での日本語表示**:
```cmd
REM コンソールをUTF-8に設定
chcp 65001

REM その後scheme12を起動
scheme12_debug.exe
```

---

## 14. 最近の改善（v2.0）✨

### 14.1 概要

v2.0では、安全性・互換性・使いやすさの3つの観点から大幅な改善を実施しました。

### 14.2 主要な改善項目

#### 1. **循環構造の完全対応**

**問題**: 従来版では循環リスト・自己参照ベクタで無限ループ

**解決策**:
- `equal?`: ノード対応マップ（`unordered_map<void*, void*>`）で追跡
- `to_string`: 訪問済みセット（`unordered_set<void*>`）で循環検出

**効果**:
```scheme
; 安全な動作例
(define circular (cons 1 (cons 2 nil)))
(set-cdr! (cdr circular) circular)
(equal? circular circular)  ; TRUE（無限ループなし）
circular                    ; (1 2 . #<circular>)
```

**実装詳細**:
```cpp
// equal? の循環検出
using VisitedMap = std::unordered_map<void*, void*>;

static bool value_equal_with_visited(ValuePtr a, ValuePtr b, VisitedMap& visited) {
    void* addr_a = static_cast<void*>(get_ptr(a));
    void* addr_b = static_cast<void*>(get_ptr(b));
    
    // 既訪問時の対応関係チェック
    auto it = visited.find(addr_a);
    if (it != visited.end()) {
        return it->second == addr_b;
    }
    
    // 訪問記録
    visited[addr_a] = addr_b;
    // ... 再帰比較 ...
}
```

#### 2. **BigInt → long long 変換の安全化**

**問題**: 範囲外の整数でオーバーフロー・未定義動作

**解決策**: `safe_bigint_to_ll()` 関数の導入

**適用箇所**（全11箇所）:
- `prim_random`
- `prim_make_string`
- `prim_string_ref`
- `prim_string_set`
- `prim_substring`（2箇所）
- `prim_integer_to_char`
- `prim_make_vector`
- `prim_vector_ref`
- `prim_vector_set`
- `prim_random_seed`

**効果**:
```scheme
scheme12> (make-string 99999999999999999999 "x")
Error: make-string: integer out of range for conversion
```

#### 3. **#t / #f サポートの追加**

**問題**: 標準Scheme構文 `#t` / `#f` が使えず

**解決策**: Readerで直接処理

**効果**:
```scheme
scheme12> #t
TRUE

scheme12> #f
FALSE

scheme12> (and #t (not #f))
TRUE
```

#### 4. **EOF専用オブジェクトの導入**

**問題**: EOFがシンボルやfalseで代用され、曖昧

**解決策**: `EofTag` 型の追加

**効果**:
```scheme
scheme12> (define in (open-input-file "test.txt"))
scheme12> (let loop ()
            (let ((line (read-line in)))
              (if (eof-object? line)
                  'done
                  (begin
                    (display line)
                    (newline)
                    (loop)))))
```

#### 5. **エラーメッセージの改善**

**単一引数除算**:
```scheme
; Before
scheme12> (/ 5)
Error: / expects at least 2 args

; After (v2.0)
scheme12> (/ 5)
Error: / requires at least 2 arguments (single-argument reciprocal is not supported; use (/ 1 x) instead)
```

**BigInt変換エラー**:
```scheme
; Before
scheme12> (make-string 999999999999999999999 "x")
Error: conversion error

; After (v2.0)
scheme12> (make-string 999999999999999999999 "x")
Error: make-string: integer out of range for conversion
```

### 14.3 ライブラリの改善

#### 赤黒木ライブラリ（rbtree_lib_improved.scm）

**Improved版の改善点**:
1. **検証機能の強化**
   - 空ツリーの適切な処理
   - 根ノードの色チェック
   - より詳細な黒高さ情報

2. **ツリー表示の簡略化**
   - `rb-print-tree`: シンプルな階層表示
   - インデントによる視覚的構造
   - キーと色（R/B）の簡潔な表示

3. **エラーハンドリングの改善**
   - NILノードへのアクセス時の明確なエラー
   - より親切なメッセージ

4. **テストスイートの充実**
   - 包括的な `rb-test`
   - シンプルな `rb-example`
   - ストレステスト（50件の挿入・削除）

#### ハッシュテーブルライブラリ（hashtable_lib.scm）

**Fixed版の改善点**:
1. **適切な衝突処理（Chaining）**
   - バケット（リスト）による衝突管理
   - 型を考慮したキー比較
   - 独立したエントリの保持

2. **統計情報の拡充**
   - 衝突率の計算
   - バケット数とエントリ数の区別
   - 詳細な衝突分析

3. **テスト機能の追加**
   - `ht-test-collision`: 衝突処理の検証
   - `ht-test-basic`: 基本機能のテスト
   - `ht-test-stress`: 大規模データテスト

4. **ユーティリティの強化**
   - マクロによる簡潔なAPI（`ht-ref`, `ht-set!`, `ht-has?`）
   - イテレータ関数の充実
   - デバッグ関数の改善

### 14.4 パフォーマンスへの影響

**循環検出のオーバーヘッド**:
- 通常の使用では無視できる（< 1%）
- 循環構造がない場合も安全性のため実行
- メモリ使用量の増加は最小限

**ハッシュテーブルの衝突処理**:
- チェイニングによるわずかなオーバーヘッド
- 良いハッシュ関数では衝突率1-5%程度
- バケット内の線形探索は実質O(1)

**ベンチマーク例**:
```scheme
; 大量のequal?呼び出し
(define (bench n)
  (let loop ((i 0))
    (if (< i n)
        (begin
          (equal? '(1 2 3 4 5) '(1 2 3 4 5))
          (loop (+ i 1))))))

; v1.0: 約5.2秒
; v2.0: 約5.3秒（約2%の増加）

; ハッシュテーブル操作
(define (bench-ht n)
  (let ((ht (make-hash-table)))
    (let loop ((i 0))
      (if (< i n)
          (begin
            (hash-table-set! ht i (* i i))
            (hash-table-get ht i)
            (loop (+ i 1)))))))

; 1000件: 約0.15秒
; 10000件: 約1.8秒
```

### 14.5 互換性への影響

**後方互換性**: ✅ 完全に保持

既存のコードは変更なしで動作：
- `true` / `false` はそのまま使用可能
- 既存のプリミティブの動作は変更なし
- マクロ・ライブラリも影響なし

**新機能の活用**:
```scheme
; v2.0の新機能を使う場合
#t #f  ; 推奨（標準構文）
true false  ; 互換性維持

; 循環構造も自由に使える
(define circular (cons 1 nil))
(set-cdr! circular circular)

; ハッシュテーブルの衝突も正しく処理
(define ht (make-hash-table))
(hash-table-set! ht 5 "value1")
(hash-table-set! ht 2147483652 "value2")  ; 同じハッシュ値
(hash-table-get ht 5)  ; → "value1" (正しく取得)
```

### 14.6 今後の展望

v2.0で基礎的な安全性と互換性が確立されました。今後の改善候補：

1. **衛生的マクロ**: syntax-rules相当の実装
2. **例外処理**: try/catch構文の追加
3. **モジュールシステム**: 名前空間管理
4. **浮動小数点**: double型のサポート
5. **並行処理**: 基本的なスレッド機能
6. **データ構造の拡充**:
   - AVL木の実装
   - B木（大規模データ用）
   - 永続データ構造
7. **パフォーマンス最適化**:
   - ハッシュテーブルのリサイズ機能
   - より高速なハッシュ関数
   - JITコンパイル（将来的に）

---

## 15. 赤黒木ライブラリの堅牢性強化

### 15.1 概要

2026年8月、姉妹プロジェクトである「Fncalc7」（[github.com/noboru3a3b/Fncalc7](https://github.com/noboru3a3b/Fncalc7)）の赤黒木ライブラリ `rbtree3.cal` が `rbtree4.cal` へと改善され、そこで過去の潜在バグが複数修正されたことを受け、本プロジェクトの `rbtree_lib_improved.scm`（`rbtree3.cal` を元にした移植版）についても同種の問題が無いかを監査しました。

監査の結果、実際に再現するバグが1件、および将来のバグを見逃しうる検証機能の弱さが確認されたため、これらを修正し、再発防止のための回帰テスト `rbtree_robustness_test.scm` を追加しました。本節はその内容の記録です。

### 15.2 発見された問題

#### 問題1（実証済みバグ）: `rb-delete-min` を単独で呼ぶと根が赤のまま残る

左傾き赤黒木の削除アルゴリズム（`move-red-left` / `move-red-right` を使う Sedgewick 方式）は、削除降下を始める前に「対象ノード自身が赤、または赤にできる」という不変条件が成立していることを前提とします。ツリーの根はこの前提を自動的には満たさないため、根に対して削除系の操作を行う公開関数は、降下前に「両方の子が黒なら根を赤にする」処理を挟む必要があります。

修正前の `rb-delete-min` にはこの処理が無く、内部の再帰処理をそのまま公開していました。実際に検証用スクリプトで、キー0〜59を挿入したツリーに対して `rb-delete-min` を単独で60回連続呼び出したところ、**15/60回（25%）で根が赤のまま返る**ことを確認しました。

```
Test 2: standalone rb-delete-min x60
  -> root left RED after rb-delete-min at step 17
  -> root left RED after rb-delete-min at step 18
  ...（以下、計15回）
Test 2 done. failures=15
```

なお、この関数はプロジェクト内では `rb-delete-impl` の内部処理（後継ノード探索のための削除）としてのみ使われており、外部から単独で呼ばれてはいなかったため、**このバグはこれまで発火していませんでした**。しかし `rb-delete-min` はトップレベルで公開された関数であり、将来誰かが「最小キーを削除する」目的で直接呼び出せば、木の不変条件（根は黒）が壊れます。

#### 問題2: `rb-delete` 自体も同じ定石を欠いていた

公開関数 `rb-delete` も、削除降下の前に根を赤にする処理を行っていませんでした。これは移植元の `rbtree3.cal` にも同じ形で存在していた欠落です。

大規模なランダム操作・決定的な削除パターン（連続最小値削除、交互最小最大値削除）でテストした限り、`rb-fix-up` の色反転処理（挿入用の `rb-flip-colors` は色を強制的にセットする実装のため）が復帰時にこの欠落を吸収し、実際に壊れたケースは確認されませんでした。しかし、これは**アルゴリズムとして保証された安全性ではなく、現在の `rb-fix-up` の実装がたまたま吸収しているだけ**であり、今後のコード変更で牙を剥く可能性が残っていました。

#### 問題3: `rb-validate` が検出できない壊れ方があった

修正前の `rb-check-property` は次の2点しか検査していませんでした。

- 赤ノードの子が赤でないか
- 左右の部分木で黒高さが一致するか

このため、次の2種類の壊れ方は「Tree is valid」と誤って報告される可能性がありました。

- **右傾き赤リンク**: 黒ノードが赤の右の子を持つ状態。左傾き赤黒木としては不正だが、上記2条件はどちらも素通りする。
- **BST順序違反**: 色・黒高さのつじつまは合っているのに、キーの並びが崩れている状態（例: 回転の配線間違い）。

つまり、もし何らかのバグが将来紛れ込んでも、ライブラリ自身の検証機能では検出できない可能性がありました。

#### 問題4: 不在キーと偽値の混同

`rb-search` は該当キーが無いとき `false` を返しますが、値として `false` を格納した場合と区別できませんでした。在・不在を明確に判定する述語がありませんでした。

### 15.3 修正内容

| # | 修正 | 対象関数 |
|---|------|----------|
| 1 | 内部再帰用 `rb-delete-min-impl` と、根の色管理を行う安全な公開版 `rb-delete-min` に分離 | `rb-delete-min` |
| 2 | 削除降下前に「両方の子が黒なら根を赤にする」処理を追加 | `rb-delete` |
| 3 | 右傾き赤リンクの検出を追加 | `rb-check-property` |
| 4 | BST順序（中順走査での単調増加）を検証する `rb-check-order` を新設し、`rb-validate` から呼ぶよう変更 | `rb-validate` |
| 5 | 不在と偽値を区別する述語を新設 | `rb-contains?`（新規） |

いずれも既存の公開APIのシグネチャ・返り値の型は変更していないため、既存コード（`rbtree_stress_test_safe.scm` を含む）は無修正で動作します。

### 15.4 テストによる確認（rbtree_robustness_test.scm）

修正のたびに「本当に直っているか」を確認するため、専用の回帰テストファイル `rbtree_robustness_test.scm` を追加しました。`rb-test` のような機能一巡確認ではなく、**壊れないことそのもの**を検証する構成です。

```scheme
scheme12> (load "rbtree_robustness_test.scm")
```

**構成（全17項目）**:

1. **検証器の自己テスト**（Section 0）— わざと壊した木を用意し、`rb-validate` が確実に「不正」と判定することを確認。右傾き赤リンク・BST順序違反という新しい検査項目に加え、赤赤違反・赤根という既存の検査項目も後退していないことを確認。正常な木を誤って「不正」と判定しないことも確認（偽陽性がないことの確認）。
2. **`rb-delete-min` 単独呼び出しの回帰テスト**（Section 1）— 0〜59を挿入した木に対し `rb-delete-min` を60回連続で呼び、根が赤になった回数・`rb-validate` が失敗した回数がいずれも0であることを確認（修正前は15/60で失敗）。
3. **`rb-delete` の降下不変条件テスト**（Section 2）— 60回の連続最小値削除、61鍵に対する交互最小最大値削除（rbtree4.cal のRB-02回帰テストと同じシナリオ）を行い、常に木が有効であること、交互削除の最後に中央値（30）だけが正しく残ることを確認。
4. **`rb-contains?` のテスト**（Section 3）— 値が `false` のキーについて、`rb-contains?` が真を返し、`rb-search` は従来通り `false` を返すことを確認。
5. **大規模ランダムファズテスト**（Section 4）— 1200回のランダムな挿入・削除を行い、**操作1回ごとに毎回** `rb-validate` 相当の検証を実施し、破損が一度も発生しないことを確認。

**実行結果**:
```
===========================================
  Results: 17/17 passed
*** ALL ROBUSTNESS TESTS PASSED ***
===========================================
```

### 15.5 互換性への影響

**後方互換性**: ✅ 完全に保持

- `rb-insert` / `rb-delete` / `rb-search` / `rb-validate` など既存関数の引数・返り値は変更なし
- `rb-delete-min` は今までと同じ引数・返り値のまま、内部の安全性のみ向上
- `rbtree_stress_test_safe.scm`（既存のGC込みストレステスト）は無修正のまま動作確認済み
- 新規追加は `rb-contains?`、`rb-delete-min-impl`（内部専用）、`rb-check-order`（内部専用、検証用のモジュールレベル変数 `rb-order-ok` / `rb-order-prev-set` / `rb-order-prev` を伴う）のみ

---

## 16. 最近の改善（v2.1）✨

### 16.1 概要

v2.1 では、**落ちる・止まる不具合**と**エラーも出さずに間違った結果を返す
不具合**の解消を最優先に、あわせて R5RS 適合性と診断メッセージを改善しました。

各項目は再現を確認したうえで修正し、修正後に既存ファイル12件
（`test_fixes` / `test_improvements` / `list_test1` / `test_vector_env` /
`rbtree_robustness_test` / `rbtree_stress_test_safe` / `performance_test` /
`hashtable_lib` / `mlib7` / `rbtree_lib_improved` / `test-case6` /
`system_lib`）の出力が修正前とバイト単位で一致することを確認しています。

### 16.2 落ちる・止まる不具合

| 症状 | 原因 | 対応 |
|---|---|---|
| 閉じ括弧のないファイルを `--load` すると OOM | `read_list`/`read_vector` が EOF の `nullptr` を検出せず無限ループ | 終端を検出して `unexpected EOF in list` を投げる（§3.2） |
| car 方向の循環リストの表示で SIGSEGV | `list_to_string_with_visited` が car を `to_string()` で出力し `visited` が毎回リセットされていた | `to_string_with_visited` へ引き回す。あわせて経路をバックトラック（§2.4） |
| 20万要素同士の `equal?` で SIGSEGV | cdr 方向も再帰していた | cdr の走査をループ化し、car のみ再帰（§2.4） |
| ポートを閉じ忘れるとディスクリプタ枯渇 | `gc` 継承ではデストラクタが呼ばれない | `gc_cleanup` 継承 ＋ `EMFILE` 時の GC リトライ（§8.1.11） |

```
; 修正前 → 修正後
閉じ括弧なし --load : std::bad_alloc     → unexpected EOF in list
(set-car! x x) の表示: SIGSEGV           → (( . #<circular>) 2)
20万要素の equal?     : SIGSEGV           → TRUE
ポート2000個オープン   : cannot open file → done
```

### 16.3 黙って間違う不具合

**準クオートのドット位置 unquote**（§7.3）

```scheme
(define k 'name) (define v 42)
`(,k . ,v)     ; v2.0: (name unquote v)  → v2.1: (name . 42)
`#(1 ,x)       ; v2.0: #(1 (unquote x))  → v2.1: #(1 7)
```

**内部 define のグローバル汚染**（§4.3.5）

```scheme
(define (make-f n) (define (helper x) (* x 2)) (lambda () (helper n)))
(define (make-g n) (define (helper x) (* x 3)) (lambda () (helper n)))
(define ff (make-f 5))
(define gg (make-g 5))
(list (ff) (gg) (ff))   ; v2.0: (15 15 15)  → v2.1: (10 15 10)
```

どちらもエラーにならず壊れた値が下流へ流れるため、発見が難しい種類の
不具合でした。

### 16.4 R5RS 適合性

- `call-with-current-continuation` を追加（`call/cc` の別名）。従来は
  未定義で、教科書や既存の R5RS コードを貼り付けると `unbound global`
  で即座に止まっていた（§6.4）
- `Op::CALLCC` / `Op::TCALLCC` が継続を受け取れるようになった。R5RS では
  継続も1引数の手続きなので `(call/cc k)` は有効（§6.4）
- 本体先頭の `define` がレキシカルな束縛になった（§4.3.5）
- 準クオートのドット位置・ベクタ内の `unquote` に対応（§7.3）

### 16.5 診断メッセージ

特殊形式の構文検査を追加し、構文エラーがフォーム名・期待する形・
実際に書かれた式つきで報告されるようになりました（§4.3.6）。

```
(define x)     v2.0: expected pair
               v2.1: bad syntax in define: variable definition needs
                     a value expression -- in (define x)
```

### 16.6 互換性への影響

**ほぼ後方互換** ですが、次の3点は挙動が変わります。

1. **内部 `define` がグローバルに漏れなくなった** — v2.0 の挙動に依存して
   関数の外から内部 `define` の名前を参照していたコードは動かなくなります
2. **余分な引数がエラーになった** — `(if a b c d)` や `(define x 1 2)` は
   v2.0 では黙って無視していました
3. **`(let ((x)) ...)` のような不正な束縛がエラーになった** — v2.0 では
   `expected pair` で落ちるか、書き方によっては通っていました

### 16.7 未着手の項目

| 項目 | 内容 |
|---|---|
| 性能 | `Op::ARGS` のリスト化を廃して呼出しコストを下げる（現状 約30万呼出し/秒） |
| マクロの診断 | 同一コンパイル単位内でマクロを使うと `APP target is not callable` になる |
| `LDCT` | コンパイラが生成しないデッドコード |
| 識別子名のリーク | 16文字以上の名前が `GC_MALLOC_UNCOLLECTABLE` から確保され解放されない |
| gensym | シンボルをインターンするため `g_symbol_intern` が単調増加する |
| first-class 化 | `call/cc` / `apply` を値として渡せるようにする |

詳細は §13.5「既知の制限事項」を参照してください。

---

## 付録A. コンパイル出力と逆アセンブル例

### A.1 単純な式

```scheme
scheme12> (compile '(+ 1 2 3))

=== Compiled Code ===
[  0] LDC 1
[  1] LDC 2
[  2] LDC 3
[  3] ARGS 3
[  4] LDG +
[  5] APP
[  6] STOP
=====================
```

### A.2 条件分岐

```scheme
scheme12> (define (abs x)
            (if (< x 0) (- x) x))

scheme12> (disassemble abs)

=== Disassembly ===
Parameters: (x)
Body:
  [  0] LD (0 . 0)
  [  1] LDC 0
  [  2] ARGS 2
  [  3] LDG <
  [  4] APP
  [  5] SEL
    THEN:
      [  0] LD (0 . 0)
      [  1] ARGS 1
      [  2] LDG -
      [  3] APP
      [  4] JOIN
    ELSE:
      [  0] LD (0 . 0)
      [  1] JOIN
  [  6] RTN
Environment: 0 frame(s)
===================
```

### A.3 再帰関数（末尾再帰）

```scheme
scheme12> (define (factorial n acc)
            (if (= n 0)
                acc
                (factorial (- n 1) (* acc n))))

scheme12> (disassemble factorial)

=== Disassembly ===
Parameters: (n acc)
Body:
  [  0] LD (0 . 0)
  [  1] LDC 0
  [  2] ARGS 2
  [  3] LDG =
  [  4] APP
  [  5] SEL
    THEN:
      [  0] LD (0 . 1)
      [  1] JOIN
    ELSE:
      [  0] LD (0 . 0)
      [  1] LDC 1
      [  2] ARGS 2
      [  3] LDG -
      [  4] APP
      [  5] LD (0 . 1)
      [  6] LD (0 . 0)
      [  7] ARGS 2
      [  8] LDG *
      [  9] APP
      [ 10] ARGS 2
      [ 11] LDG factorial
      [ 12] TAPP    ← 末尾呼出（TCO）
      [ 13] JOIN
  [  6] RTN
Environment: 0 frame(s)
===================
```

**ポイント**: 12番目の命令が`TAPP`（末尾呼出）になっており、スタックを消費しない。

### A.4 クロージャ

```scheme
scheme12> (define (make-multiplier n)
            (lambda (x) (* x n)))

scheme12> (disassemble make-multiplier)

=== Disassembly ===
Parameters: (n)
Body:
  [  0] LDF (x)
    Lambda body:
      [  0] LD (0 . 0)    ← 内側のx
      [  1] LD (1 . 0)    ← 外側のn（静的リンク）
      [  2] ARGS 2
      [  3] LDG *
      [  4] APP
      [  5] RTN
  [  1] RTN
Environment: 0 frame(s)
===================
```

**ポイント**: `LD (1 . 0)`で1つ外のフレーム（捕捉環境）を参照。

### A.5 複雑なネスト

```scheme
scheme12> (define (outer a)
            (lambda (b)
              (lambda (c)
                (+ a b c))))

scheme12> (disassemble outer)

=== Disassembly ===
Parameters: (a)
Body:
  [  0] LDF (b)
    Lambda body:
      [  0] LDF (c)
        Lambda body:
          [  0] LD (2 . 0)    ← a（2つ外）
          [  1] LD (1 . 0)    ← b（1つ外）
          [  2] LD (0 . 0)    ← c（現在）
          [  3] ARGS 3
          [  4] LDG +
          [  5] APP
          [  6] RTN
      [  1] RTN
  [  1] RTN
Environment: 0 frame(s)
===================
```

---

## 付録B. 継続（call/cc）の動作例

### B.1 基本的な脱出

```scheme
scheme12> (define result
            (* 10 (call/cc
                    (lambda (k)
                      (k 5)
                      (display "never printed")
                      100))))

scheme12> result
50
```

**解説**: `(k 5)`で即座に継続に5を渡して戻るため、その後の処理は実行されない。

### B.2 継続の保存と再利用

```scheme
scheme12> (define saved-k false)

scheme12> (+ 1 (call/cc
                 (lambda (k)
                   (set! saved-k k)
                   10))
             2)
13

scheme12> (saved-k 100)
103

scheme12> (saved-k 200)
203
```

**解説**: 継続`k`は「1を足して、さらに2を足す」という文脈。何度でも呼び出せる。

### B.3 非局所脱出

```scheme
scheme12> (define (find-positive lst)
            (call/cc
              (lambda (return)
                (for-each
                  (lambda (x)
                    (if (> x 0)
                        (return x)))
                  lst)
                false)))

scheme12> (find-positive '(-1 -2 3 -4 5))
3
```

**解説**: 最初の正の数が見つかった時点で`return`を呼び出し、即座に関数から脱出。

### B.4 ジェネレータ（簡略版）

```scheme
scheme12> (define (make-generator lst)
            (let ((remaining lst))
              (lambda ()
                (if (null? remaining)
                    'done
                    (call/cc
                      (lambda (return)
                        (let ((val (car remaining)))
                          (set! remaining (cdr remaining))
                          (return val))))))))

; 使用例
scheme12> (define gen (make-generator '(1 2 3)))
scheme12> (gen)
1
scheme12> (gen)
2
scheme12> (gen)
3
scheme12> (gen)
done
```

---

## 付録C. 赤黒木の詳細解説

### C.1 赤黒木の性質

赤黒木は以下の5つの性質を満たす二分探索木です：

1. **各ノードは赤または黒**
2. **根は黒**
3. **すべての葉（NIL）は黒**
4. **赤ノードの子は両方とも黒**（連続した赤ノードは存在しない）
5. **任意のノードから葉までのパスに含まれる黒ノードの数は同じ**（黒高さ）

これらの性質により、木の高さは最悪でも**O(log n)**に保たれます。

### C.2 ノード構造

```scheme
; ノード: #(left right color key data)
; 例: キー10, データ"ten", 色RED
(define node (vector RB-NIL RB-NIL RED 10 "ten"))

; アクセサ
(rb-left node)    ; → 左の子
(rb-right node)   ; → 右の子
(rb-color node)   ; → 色（RED=1 or BLACK=0）
(rb-key node)     ; → キー
(rb-data node)    ; → データ
```

### C.3 回転操作

#### 右回転（Right Rotation）

```
      y              x
     / \            / \
    x   C    →     A   y
   / \                / \
  A   B              B   C
```

```scheme
(define rb-rotate-right
  (lambda (node)
    (let ((left-child (rb-left node)))
      ; ... 左の子を新しい根に
      ; ... 元の根を右の子に
      left-child)))
```

#### 左回転（Left Rotation）

```
    x                  y
   / \                / \
  A   y      →       x   C
     / \            / \
    B   C          A   B
```

### C.4 挿入操作

**アルゴリズム**:
1. 通常の二分探索木として挿入（新ノードは赤）
2. 赤黒木の性質を修復（fix-up）
   - 右の子が赤で左の子が黒 → 左回転
   - 左の子とその左の子が両方赤 → 右回転
   - 両方の子が赤 → 色反転

```scheme
(define rb-insert-impl
  (lambda (node key data)
    (if (rb-null? node)
        (make-rb-node key data)  ; 新ノード（赤）
        (begin
          ; 再帰的に挿入
          (cond ((< key (rb-key node))
                 (rb-set-left! node (rb-insert-impl (rb-left node) key data)))
                ((> key (rb-key node))
                 (rb-set-right! node (rb-insert-impl (rb-right node) key data)))
                (else
                 (rb-set-data! node data)))  ; 更新
          ; 修復
          (rb-fix-up node)))))
```

### C.5 削除操作

削除は挿入より複雑：
1. 通常の二分探索木として削除
2. 削除するノードが黒の場合、黒高さのバランスを修復
3. 赤を左に移動させる操作を使用

```scheme
(define rb-delete-impl
  (lambda (node key)
    ; ... 複雑な分岐処理 ...
    ; move-red-left, move-red-right を使用
    ; 最終的に fix-up で修復
    ))
```

**降下前に根を赤にする定石**（Sedgewick標準）← **NEW!**

`move-red-left` / `move-red-right` による削除降下アルゴリズムは、「今見ているノード自身が赤、または赤にできる」という不変条件が保たれていることを前提にしています。木のルートは（両方の子が黒であれば）この前提を満たさないため、公開インターフェース `rb-delete` は、降下を始める前に一度だけ次の処理を行います。

```scheme
(define rb-delete
  (lambda (node key)
    (if (rb-null? node)
        RB-NIL
        (begin
          ; 降下前: 両方の子が黒なら根を赤にする
          (if (and (rb-is-black? (rb-left node))
                   (rb-is-black? (rb-right node)))
              (rb-set-color! node RED))
          (let ((result (rb-delete-impl node key)))
            ; 完了後: 結果の根を必ず黒に戻す
            (if (not (rb-null? result))
                (rb-set-color! result BLACK))
            result)))))
```

`rb-delete-min` にも同じ「降下前に赤、完了後に黒」の対を導入しています（`rb-delete-min-impl` が内部の純粋な再帰処理、`rb-delete-min` が根の色を管理する公開版）。この対がないまま `delete_min` 相当の関数を単独で呼ぶと、根が赤のまま返る不具合になり得ることが、外部プロジェクト（Fncalc7）の赤黒木ライブラリ監査で実際に確認されています。詳細は[15. 赤黒木ライブラリの堅牢性強化](#15-赤黒木ライブラリの堅牢性強化)を参照してください。

### C.6 検証（Improved版）

```scheme
(define rb-validate
  (lambda (node)
    (cond
      ((rb-null? node)
       (display "Tree is valid (empty)")
       (newline)
       true)
      ((rb-is-red? node)
       (display "ERROR: Root is not black!")
       (newline)
       false)
      (else
       (let ((height (rb-check-property node)))
         (set! rb-order-ok true)
         (set! rb-order-prev-set false)
         (rb-check-order node)
         (if (or (= height -1) (not rb-order-ok))
             (begin
               (display "Tree is INVALID")
               (newline)
               false)
             (begin
               (display "Tree is valid (black height: ")
               (display height)
               (display ")")
               (newline)
               true)))))))
```

**改善点**:
- 空ツリーの適切な処理
- 根の色チェック
- 黒高さの明示的な表示
- 真偽値の返却
- `rb-check-property` が右傾き赤リンク（黒ノードが赤の右の子を持つ）を検出 ← **NEW!**
- `rb-check-order` が中順走査でBST順序（厳密な単調増加）を検証 ← **NEW!**

`rb-check-property` は黒高さを再帰的に計算しつつ、各ノードで「自分の右の子が赤でないか」も見るように拡張されています。左傾き赤黒木では右向きの赤リンクは（回転の途中を除き）決して現れてはならないため、これが検出できれば `rb-fix-up` 系のロジックにバグが入り込んだことの強力な手がかりになります。`rb-check-order` はキーの並びだけを独立に検証するため、色や黒高さのつじつまは合っているのにキーの位置だけがおかしい、という壊れ方も見逃しません。

### C.7 パフォーマンス特性

| 操作 | 最悪時間 | 平均時間 | 説明 |
|------|----------|----------|------|
| 検索 | O(log n) | O(log n) | 高さがlog n に制限される |
| 挿入 | O(log n) | O(log n) | 挿入 + 最大O(log n)回の回転 |
| 削除 | O(log n) | O(log n) | 削除 + 修復操作 |
| 最小値 | O(log n) | O(log n) | 左端まで辿る |
| 走査 | O(n) | O(n) | すべてのノードを訪問 |

**メモリ使用量**: O(n)（各ノード5ワード = 40バイト程度）

**実測パフォーマンス**:
```scheme
; 10000件の挿入・検索
(define tree RB-NIL)
(let loop ((i 0))
  (if (< i 10000)
      (begin
        (set! tree (rb-insert tree i i))
        (loop (+ i 1)))))
; 約0.5秒

; 10000件の検索
(let loop ((i 0))
  (if (< i 10000)
      (begin
        (rb-search tree i)
        (loop (+ i 1)))))
; 約0.3秒
```

---

## 付録D. ビルド・起動方法

### D.1 依存ライブラリ

#### 必須
- **Boehm GC** (libgc, libgccpp)
  - 自動メモリ管理
  - Ubuntu: `sudo apt-get install libgc-dev`
  - macOS: `brew install bdw-gc`
  - Windows: MinGW経由またはビルド済みバイナリ

- **Boost.Multiprecision**
  - 任意精度整数
  - Ubuntu: `sudo apt-get install libboost-all-dev`
  - macOS: `brew install boost`
  - Windows: 公式サイトからダウンロード

#### オプション
- **C++17対応コンパイラ**
  - GCC 7.0以上
  - Clang 5.0以上
  - MSVC 2017以上

### D.2 ビルド手順

#### Linux/macOS

```bash
# リポジトリのクローン（仮想）
cd scheme12_debug

# ビルド
make

# 実行
./scheme12_debug
```

#### Windows (MinGW)

```bash
# Makefileの確認
# BOOST_INCLUDEとGC_INCLUDEのパスを環境に合わせる

# ビルド
mingw32-make

# 実行
scheme12_debug.exe
```

### D.3 Makefile例（Linux）

```makefile
CXX = g++
CXXFLAGS = -std=c++17 -O2 -Wall -Wextra
INCLUDES = -I/usr/include
LIBS = -lgc -lgccpp -lpthread

TARGET = scheme12_debug
SOURCES = scheme12_bignum_boost_debug.cpp

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -o $@ $^ $(LIBS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
```

### D.4 起動オプション

```bash
# 対話型REPL
./scheme12_debug

# ファイル実行
./scheme12_debug --load script.scm

# ヘルプ
./scheme12_debug --help
```

### D.5 ライブラリの配置

起動時に`system_lib.scm`を自動読込：

```
scheme12_debug          # 実行ファイル
system_lib.scm          # 同じディレクトリに配置
rbtree_lib_improved.scm # オプション
hashtable_lib.scm       # オプション
```

または、カレントディレクトリにライブラリを配置。

### D.6 トラブルシューティング

#### Boehm GCが見つからない

```bash
# Ubuntu
sudo apt-get install libgc-dev

# macOS
brew install bdw-gc

# 手動ビルド
wget https://github.com/ivmai/bdwgc/releases/download/v8.2.2/gc-8.2.2.tar.gz
tar xzf gc-8.2.2.tar.gz
cd gc-8.2.2
./configure --prefix=/usr/local
make
sudo make install
```

#### Boostが見つからない

```bash
# Ubuntu
sudo apt-get install libboost-all-dev

# macOS
brew install boost

# ヘッダオンリーなので、インクルードパスを指定すればOK
```

#### コンパイルエラー

```bash
# C++17のチェック
g++ --version  # 7.0以上

# インクルードパスの確認
g++ -E -x c++ - -v < /dev/null
```

### D.7 実行例

```bash
$ ./scheme12_debug
scheme12 debug REPL. Type (help) for commands.
scheme12> (+ 1 2 3)
6
scheme12> (define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
fact
scheme12> (fact 10)
3628800
scheme12> (load "rbtree_lib_improved.scm")
Red-Black Tree Library (Improved) loaded.
Commands:
  (rb-test)      - Run comprehensive tests
  (rb-example)   - Run simple example
...
scheme12> (rb-test)
=== Red-Black Tree Test ===
...
scheme12> (load "hashtable_lib.scm")
Hash Table Library (Fixed with Chaining) loaded.
...
scheme12> (ht-test-collision)
=== Hash Collision Test ===
...
scheme12> (quit)
Bye!
```

---

## まとめ

**scheme12_debug v2.1**は、SECDアーキテクチャに基づく教育的かつ実用的なScheme実装です。

### v2.1の主な改善 ✨ ← **NEW!**

**堅牢性**（[16章](#16-最近の改善v21)参照）:
- ✅ **リーダの入力終端検出**: 閉じ括弧のないファイルでの無限ループ／OOMを解消
- ✅ **car方向の循環検出**: `(set-car! x x)` の表示でのSIGSEGVを解消
- ✅ **equal?のループ化**: 長いリスト同士の比較でのスタック溢れを解消
- ✅ **ポートの自動回収**: `gc_cleanup`＋`EMFILE`時のGCリトライでディスクリプタ枯渇を解消

**正しさ**:
- ✅ **準クオートのドット位置unquote**: `` `(,k . ,v) `` が正しい対を作る
- ✅ **ベクタ内のunquote**: `` `#(1 ,x) `` に対応
- ✅ **内部defineのスコープ**: グローバルを汚さないレキシカル束縛に

**R5RS適合性と診断**:
- ✅ **call-with-current-continuation**: 正式名を追加
- ✅ **`(call/cc k)`**: 継続を`call/cc`に渡せるように
- ✅ **特殊形式の構文検査**: フォーム名と該当式つきのエラーメッセージ

### v2.0の主な改善

**コア機能**:
- ✅ **循環構造の完全対応**: equal?とto_stringで無限ループ回避
- ✅ **安全なBigInt変換**: 範囲外エラーの適切な処理
- ✅ **標準構文のサポート**: #t / #f の追加
- ✅ **親切なエラーメッセージ**: ユーザーフレンドリーな改善
- ✅ **EOF専用オブジェクト**: 明確なファイル終端処理

**ライブラリ**:
- ✅ **赤黒木の改善**: 検証・表示機能の強化
- ✅ **ハッシュテーブルの修正**: 適切な衝突処理（チェイニング）
- ✅ **統計情報の拡充**: 衝突率分析
- ✅ **テストスイートの充実**: 包括的な動作検証

**赤黒木の堅牢性強化（2026年8月）** ← **NEW!**:
- ✅ `rb-delete-min` 単独呼び出し時の根の色バグを修正（実証済みバグ、[15章](#15-赤黒木ライブラリの堅牢性強化)参照）
- ✅ `rb-delete` に削除降下前の根塗り定石を追加し、経験則ではなく設計上の安全性に
- ✅ `rb-validate` に右傾き赤リンク検査・BST順序検査を追加
- ✅ 不在キーと偽値を区別する `rb-contains?` を追加
- ✅ 専用回帰テスト `rbtree_robustness_test.scm`（17項目）で改善を実証

### 主な特徴

- ✅ **SECD仮想マシン**: 4レジスタモデルによる明快な実行機構
- ✅ **末尾呼出最適化**: 効率的な再帰処理
- ✅ **ファーストクラス継続**: 強力な制御フロー操作
- ✅ **任意精度整数**: 大きな数値の正確な計算
- ✅ **充実したライブラリ**: 赤黒木、ハッシュテーブル等
- ✅ **強力なデバッグ機能**: トレース、逆アセンブル、検査

### 用途

- プログラミング言語処理系の学習
- SECDマシンの理解
- 継続の実験
- アルゴリズムとデータ構造の実装
- Scheme言語の実践
- **安全なデータ構造の探求（v2.0で強化）**
- **衝突処理を含むハッシュテーブルの実装学習**

### さらに詳しく学ぶには

- `(help)` コマンドでデバッグ機能を試す
- `(trace-on)` で実行を観察
- `(disassemble function)` で内部構造を理解
- 循環構造の動作を実験
- 赤黒木やハッシュテーブルのコードを読む
- `(ht-test-collision)` で衝突処理を確認
- 独自のプリミティブやライブラリを追加

### クイックスタート

```scheme
; 基本操作
scheme12> (+ 1 2 3)
6

; 赤黒木
scheme12> (load "rbtree_lib_improved.scm")
scheme12> (rb-example)

; 赤黒木の堅牢性回帰テスト
scheme12> (load "rbtree_robustness_test.scm")

; ハッシュテーブル
scheme12> (load "hashtable_lib.scm")
scheme12> (ht-test-basic)

; 衝突処理のテスト
scheme12> (ht-test-collision)

; 大規模テスト
scheme12> (ht-test-stress 1000)
```

---

**本ドキュメントの終わり（v2.0 + 赤黒木堅牢性強化）**
