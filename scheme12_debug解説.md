# scheme12_debug 解説文書（最新版）

SECD 仮想マシン方式 Scheme コンパイラ兼実行系「scheme12_debug」の設計と実装の解説

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

**文字列（std::string）**
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

scheme12> nil
NIL
```
- 大文字・小文字どちらも使用可能（TRUE/True/true）

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
    DumpFrameVec d;       // ダンプ
};
```

```scheme
scheme12> (call/cc (lambda (k) k))
#<continuation>
```

### 2.3 表示形式

各データ型の`to_string`による表示：

| 型 | 表示例 | 説明 |
|---|---|---|
| 整数 | `123`, `999999999999999` | 10進表記 |
| 文字列 | `"hello"` | ダブルクォートで囲む |
| シンボル | `APPLE`, `+` | 大文字で表示 |
| ブール | `TRUE`, `FALSE` | 大文字表記 |
| NIL | `NIL` | 空リスト |
| ペア | `(1 . 2)` | ドット対 |
| リスト | `(1 2 3)` | 括弧で囲む |
| ベクタ | `#(1 2 3)` | #で開始 |
| クロージャ | `#<closure:(x y)>` | パラメータのみ表示 |
| 継続 | `#<continuation>` | 省略表示 |
| プリミティブ | `#<primitive:+>` | 関数名表示 |
| 特殊形式 | `#<special-form:if>` | 形式名表示 |

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

生成コード：
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
| **SEL** | ct, cf | 条件分岐（Dに退避） | 真ならct、偽ならcf |
| **SELR** | ct, cf | 条件分岐（退避なし） | 未使用（将来用） |
| **JOIN** | - | 分岐から復帰 | Dから復元 |
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
| **LDCT** | - | 継続を作成してスタックに積む | 現在の(S,E,C,pc,D)をスナップショット |
| **CALLCC** | - | call/cc実行 | 継続を引数として関数適用 |

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
    DumpFrameVec d;       // 現在のダンプ
};
```

#### CALLCC命令の動作
```
1. スタックから関数を取得
2. 現在の (S, E, C, pc, D) を継続として作成
3. 継続を引数として関数に適用
   ※ 通常のAPPと同じ流れ
```

#### 継続の適用
```
1. 継続が呼ばれると、保存された状態を復元
2. 引数の値をスタックに積む
3. 継続が作られた時点に戻る
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

| 関数 | 判定内容 | 例 |
|------|----------|-----|
| `eq?` | ポインタ同一性 | `(eq? 'a 'a)` → `TRUE` |
| `eqv?` | eq?と同じ | `(eqv? 1 1)` → `TRUE` |
| `equal?` | 構造的等価性 | `(equal? '(1 2) '(1 2))` → `TRUE` |
| `null?` | NIL判定 | `(null? '())` → `TRUE` |
| `pair?` | ペア判定 | `(pair? '(1 . 2))` → `TRUE` |
| `list?` | 正常リスト判定 | `(list? '(1 2 3))` → `TRUE` |
| `atom?` | アトム判定 | `(atom? 1)` → `TRUE` |
| `symbol?` | シンボル判定 | `(symbol? 'x)` → `TRUE` |
| `number?` | 数値判定 | `(number? 42)` → `TRUE` |
| `boolean?` | ブール判定 | `(boolean? true)` → `TRUE` |
| `string?` | 文字列判定 | `(string? "hi")` → `TRUE` |
| `vector?` | ベクタ判定 | `(vector? #(1 2))` → `TRUE` |
| `procedure?` | 手続き判定 | `(procedure? car)` → `TRUE` |

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

#### 8.1.12 乱数

| 関数 | 動作 | 例 |
|------|------|-----|
| `random` | 0以上n未満の整数 | `(random 100)` → 42 |
| `random-seed` | 乱数シード設定 | `(random-seed 12345)` |

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

VM実行のステップバイステップ表示：

```scheme
scheme12> (trace-on)
Trace mode ON
TRUE

scheme12> (+ 1 2)

==== Step 0 ====
PC: 0
Instruction: LDC 1
Stack: (empty)
Environment: (empty)
Dump: 0 frame(s)

==== Step 1 ====
PC: 1
Instruction: LDC 2
Stack: 
  [0] 1
Environment: (empty)
Dump: 0 frame(s)

==== Step 2 ====
PC: 2
Instruction: ARGS 2
Stack: 
  [0] 2
  [1] 1
Environment: (empty)
Dump: 0 frame(s)

==== Step 3 ====
PC: 3
Instruction: LDG +
Stack: 
  [0] (1 2)
Environment: (empty)
Dump: 0 frame(s)

==== Step 4 ====
PC: 4
Instruction: APP
Stack: 
  [0] #<primitive:+>
  [1] (1 2)
Environment: (empty)
Dump: 0 frame(s)

==== Step 5 ====
PC: 5
Instruction: STOP
Stack: 
  [0] 3
Environment: (empty)
Dump: 0 frame(s)
3

scheme12> (trace-off)
Trace mode OFF
FALSE
```

**表示内容：**
- ステップ番号
- プログラムカウンタ（PC）
- 実行中の命令
- スタック（最大5要素）
- 環境（最大3フレーム）
- ダンプ（フレーム数）

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

**削除**
```scheme
(set! tree (rb-delete tree 10))
```

**走査**
```scheme
; ソート順のキーリストを取得
(rb-to-list tree)  ; → (5 20)

; 各要素に対して処理
(rb-traverse tree)  ; キーを順に表示
```

#### 10.1.3 高度な操作

**検証**
```scheme
(rb-validate tree)
; 出力例:
; Tree is valid (black height: 2)
```

**ノード数カウント**
```scheme
(rb-count-nodes tree)  ; → 2
```

**ツリー構造の表示**
```scheme
(rb-print-tree tree)
; 出力例:
; Tree structure (key:color):
;     20:B
;   5:R
```

#### 10.1.4 実装の特徴

**データ構造**
```scheme
; ノード: #(left right color key data)
(define node (vector RB-NIL RB-NIL RED 10 "data"))
```

**色の定義**
```scheme
(define BLACK 0)
(define RED 1)
```

**平衡操作**
```scheme
; 右回転
(rb-rotate-right node)

; 左回転
(rb-rotate-left node)

; 色の反転
(rb-flip-colors node)
```

#### 10.1.5 テスト実行

```scheme
scheme12> (load "rbtree_lib_improved.scm")

scheme12> (rb-test)

=== Red-Black Tree Test ===

Inserting: 10, 5, 20, 15, 30, 25, 35, 3, 7, 40, 45, 11, 12

Keys in order: (3 5 7 10 11 12 15 20 25 30 35 40 45)

Tree is valid (black height: 3)

Searching for key 15: ddd

Deleting key 10
Keys in order: (3 5 7 11 12 15 20 25 30 35 40 45)
Tree is valid (black height: 3)

...

=== Test Complete ===
```

### 10.2 ハッシュテーブルライブラリ（hashtable_lib.scm）

#### 10.2.1 概要

赤黒木をベースにしたハッシュテーブル実装：

- ✅ **O(log n)** の操作（平均的なハッシュテーブルのO(1)より遅いが安定）
- ✅ 様々なキー型をサポート（数値、文字列、シンボル、ブール）
- ✅ 衝突処理が組み込み済み
- ✅ イテレータ・変換関数が充実

#### 10.2.2 基本操作

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
```

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
(hash-table-delete! ht "age")  ; → TRUE
```

**サイズとクリア**
```scheme
(hash-table-size ht)       ; → 3
(hash-table-empty? ht)     ; → FALSE
(hash-table-clear! ht)     ; すべて削除
```

#### 10.2.3 イテレーション

**キー・値の取得**
```scheme
(hash-table-keys ht)     ; → ("name" status 12345)
(hash-table-values ht)   ; → ("Alice" "Active" "Number key")
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
; 値が文字列のエントリのみ抽出
(define filtered 
  (hash-table-filter ht
    (lambda (key value)
      (string? value))))
```

**fold**
```scheme
; すべての値を結合
(hash-table-fold ht
  (lambda (key value acc)
    (string-append acc value " "))
  "")
```

#### 10.2.4 変換操作

**連想リストとの相互変換**
```scheme
; ハッシュテーブル → 連想リスト
(hash-table->alist ht)
; → (("name" . "Alice") (status . "Active") ...)

; 連想リスト → ハッシュテーブル
(define ht2 (alist->hash-table '(("a" . 1) ("b" . 2))))
```

**更新**
```scheme
; 値を更新（キーが存在しない場合は挿入）
(hash-table-update! ht "count"
  (lambda (v) (+ v 1))
  0)  ; デフォルト値
```

**コピーとマージ**
```scheme
; コピー
(define ht-copy (hash-table-copy ht))

; マージ（ht2の値がht1を上書き）
(define merged (hash-table-merge ht1 ht2))
```

#### 10.2.5 ユーティリティマクロ

```scheme
; 簡潔な参照
(ht-ref ht "name")           ; = (hash-table-get ht "name")
(ht-ref ht "unknown" "N/A")  ; デフォルト値指定

; 簡潔な更新
(ht-set! ht "name" "Bob")    ; = (hash-table-set! ht "name" "Bob")

; 存在確認
(ht-has? ht "name")          ; = (hash-table-has-key? ht "name")
```

#### 10.2.6 デバッグ機能

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
; 内部の赤黒木が正しいか確認
```

**統計情報**
```scheme
(hash-table-stats ht)
; 出力:
; Hash Table Statistics:
;   Size: 3
;   Empty: FALSE
;   Tree nodes: 3
```

#### 10.2.7 実用例

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

#### 10.2.8 テスト実行

```scheme
scheme12> (load "rbtree_lib_improved.scm")
scheme12> (load "hashtable_lib.scm")

scheme12> (ht-example)

=== Simple Example ===
Creating phonebook...
Entries:

Hash Table {
  Alice => 090-1234-5678
  Bob => 080-9876-5432
  Charlie => 070-1111-2222
}
Size: 3

Looking up Alice: 090-1234-5678

Updating Bob:
Bob => 080-0000-1111

Using macros:
  (ht-ref phonebook "Charlie") => 070-1111-2222
  (ht-has? phonebook "Alice") => TRUE

Test completed!
```

### 10.3 ストレステストライブラリ（rbtree_stress_test_safe.scm）

#### 10.3.1 概要

大規模データに対する赤黒木の動作を検証するテストスイート：

- ✅ GC管理を含む安全な大量データ処理
- ✅ ランダム挿入・削除のテスト
- ✅ パフォーマンスと正確性の検証

#### 10.3.2 テストコマンド

**クイックテスト**
```scheme
(load "rbtree_lib_improved.scm")
(load "rbtree_stress_test_safe.scm")

(rb-quick-test)
; 100個のランダムキー挿入
```

**小規模テスト**
```scheme
(rb-small-scale-test)
; 500挿入 + 250削除
```

**中規模テスト**
```scheme
(rb-medium-scale-test)
; 2000挿入 + 1000削除
```

**大規模テスト**
```scheme
(rb-large-scale-test-safe)
; 1000挿入・500削除を複数回
; GC情報も表示
```

#### 10.3.3 実行例

```scheme
scheme12> (rb-quick-test)

=== Quick Test ===
Inserting 100 random keys...
Node count: 87
Tree is valid (black height: 6)
Keys (sample): (12 15 23 45 67 89 101 123 ...)
```

```scheme
scheme12> (rb-medium-scale-test)

=== Medium-Scale Test (2000 ops) ===
Phase 1: Insert 2000 keys

=== Random Insertion Test (with GC) ===
Inserting 2000 random keys (range: 0-19999)
Generated keys (sample): (1234 5678 9012 ...)

Heap size: 1048576 bytes, Free: 524288 bytes

Progress: 100/2000 Heap size: 1048576 bytes, Free: 500000 bytes
Progress: 200/2000 Heap size: 1048576 bytes, Free: 480000 bytes
...

Final node count: 1987
Tree is valid (black height: 11)

Phase 2: Delete 1000 keys
...
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
└── tests.scm             # テストコード
```

#### main.scm
```scheme
; ライブラリの読み込み
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
  
  (test "list operations"
    (lambda (fail)
      (if (not (equal? (append '(1 2) '(3 4)) '(1 2 3 4)))
          (fail 'fail))))
  
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

| 機能 | R5RS/R7RS | scheme12 |
|------|-----------|----------|
| 数値塔 | 完全 | 整数のみ |
| マクロ | syntax-rules | define-macro |
| モジュール | ✅ (R7RS) | ❌ |
| 例外処理 | ✅ | ❌（call/ccで代用） |
| 遅延評価 | delay/force | ✅ |
| 継続 | call/cc | ✅ |

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

### 13.5 既知の制限事項

#### 循環構造
```scheme
; 循環リストの作成は可能だが...
(define a (cons 1 2))
(set-cdr! a a)

; equal?は無限ループに陥る可能性
; (equal? a a)  ; 危険
```

#### 継続の制約
```scheme
; 継続はファーストクラスだが、
; C++側のフレームを跨ぐ復帰は未サポート
```

#### ポータビリティ
- Boehm GCのヘッダ検出が環境依存
- Windowsでは追加設定が必要な場合あり

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

### B.4 ジェネレータ

```scheme
scheme12> (define (make-generator lst)
            (lambda ()
              (call/cc
                (lambda (return)
                  (for-each
                    (lambda (x)
                      (call/cc
                        (lambda (resume)
                          (set! return
                            (call/cc
                              (lambda (next)
                                (set! make-generator
                                  (lambda () (resume next)))
                                (return x)))))))
                    lst)
                  'done))))

; 使用例（簡略版）
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
(rb-color node)   ; → 色（RED or BLACK）
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
      ; ... 省略 ...
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

### C.6 検証

```scheme
(define rb-check-property
  (lambda (node)
    (if (rb-null? node)
        1  ; NILの黒高さは1
        (begin
          ; 性質4: 赤ノードの子は黒
          (if (rb-is-red? node)
              (if (or (rb-is-red? (rb-left node))
                      (rb-is-red? (rb-right node)))
                  -1  ; エラー
                  ...))
          ; 性質5: 左右の黒高さが同じ
          (let ((left-height (rb-check-property (rb-left node)))
                (right-height (rb-check-property (rb-right node))))
            (if (not (= left-height right-height))
                -1  ; エラー
                (+ left-height (if (rb-is-black? node) 1 0))))))))
```

### C.7 パフォーマンス特性

| 操作 | 最悪時間 | 平均時間 |
|------|----------|----------|
| 検索 | O(log n) | O(log n) |
| 挿入 | O(log n) | O(log n) |
| 削除 | O(log n) | O(log n) |
| 最小値 | O(log n) | O(log n) |
| 走査 | O(n) | O(n) |

**メモリ使用量**: O(n)（各ノード5ワード）

---

## 付録D. ビルド・起動方法

### D.1 依存ライブラリ

#### 必須
- **Boehm GC** (libgc, libgccpp)
  - 自動メモリ管理
  - Ubuntu: `sudo apt-get install libgc-dev`
  - macOS: `brew install bdw-gc`

- **Boost.Multiprecision**
  - 任意精度整数
  - Ubuntu: `sudo apt-get install libboost-all-dev`
  - macOS: `brew install boost`

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
...
scheme12> (rb-test)
=== Red-Black Tree Test ===
...
scheme12> (quit)
Bye!
```

---

## まとめ

**scheme12_debug**は、SECDアーキテクチャに基づく教育的かつ実用的なScheme実装です。

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

### さらに詳しく学ぶには
- `(help)` コマンドでデバッグ機能を試す
- `(trace-on)` で実行を観察
- `(disassemble function)` で内部構造を理解
- 赤黒木やハッシュテーブルのコードを読む
- 独自のプリミティブやライブラリを追加

---

**本ドキュメントの終わり**