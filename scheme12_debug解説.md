# scheme12_debug解説.md
SECD 仮想マシン方式 Scheme コンパイラ兼実行系「scheme12_debug」の設計と実装の解説

本書は、Common Lisp 実装の micro_Scheme8.lisp（SECD VM 方式）をベースに、C++17 で実装された「scheme12_debug」（ファイル: scheme12_bignum_boost_debug.cpp）の設計思想と内部構造をまとめた技術解説です。SECD の 4 レジスタモデル、命令セット、コンパイラと VM の対応、継続 call/cc の実装、マクロシステム、デバッグ機能など、実装を読み解くための視点を提供します。

目次
- 1. 全体像
- 2. データモデル（Value 系）
- 3. リーダ（Reader: S 式パーサ）
- 4. コンパイラ（Compiler）
- 5. 命令セット（Instruction Set）
- 6. VM（実行機構）と継続（call/cc）
- 7. マクロシステム（define-macro とコンパイル時展開）
- 8. プリミティブと標準ライブラリ（system_lib.scm）
- 9. REPL とデバッグ機能
- 10. micro_Scheme8 からの主な差異と互換性ノート
- 11. 実装上の注意・拡張ポイント
- 付録A. 例: コンパイル出力と逆アセンブル
- 付録B. 例: 継続（call/cc）の動き
- 付録C. ビルド・起動方法（要約）

────────────────────────────────────

1. 全体像
- アーキテクチャ
  - フロントエンド: S 式リーダ（Reader）で S 式を Value 表現へ
  - 中間表現: SECD 風のバイトコード（Instruction の列＝Code）
  - バックエンド: スタックマシン VM（S, E, C, D の 4 レジスタ + PC）
- 実装言語とメモリ管理
  - C++17 + Boehm GC（libgc, libgccpp）
  - 整数は Boost.Multiprecision（cpp_int）による任意精度整数（フォールバックで long long）
- 目標
  - micro_Scheme8 と同等の評価意味の再現
  - SECD による末尾呼出最適化（TCO）
  - call/cc による継続の導入
  - デバッガビリティ（トレース・逆アセンブルなど）

────────────────────────────────────

2. データモデル（Value 系）
- Value（共用体）
  - 実体は std::variant を用いた tagged union 的表現
  - 保持可能な型
    - NilTag（NIL 相当）, bool, BigIntPtr（任意精度整数）, std::string
    - Symbol, PairPtr（cons セル）, ClosurePtr, ContPtr（継続）
    - PrimitiveInfoPtr（ネイティブ関数）, FilePortPtr（ファイルポート）
    - VectorPtr（ベクタ）, MacroPtr（マクロラッパ）, SpecialFormPtr（特殊形式マーカー）
- シンボル
  - インターンテーブル（g_symbol_intern）で同名同一性を保証
- リストとペア
  - Pair(car, cdr) を Value 化、NIL は専用の Value（g_nil）
- クロージャ（Closure）
  - params（固定引数名列）と rest_param（ドット対による可変引数）
  - body（CodePtr）と captured_env（静的リンク＝キャプチャ環境）
- 継続（Continuation）
  - S, E, C, pc, D を丸ごとスナップショット
- マクロ（Macro）
  - 変換器（transformer）として Closure を保持
  - g_macros に名→クロージャを格納（グローバルにも #<macro> 表示用を格納）
- 表示
  - to_string による人間可読表示
  - Closure は PARAMS と BODY（命令列）要約を表示
  - 継続は #<continuation> と省略表示

メモ
- すべて GC 管理オブジェクト（gc 継承）で管理。C++ 側の new は GC を通す。
- 等価性
  - eq?/eqv? はポインタ等価＋整数の数値等価
  - equal? は再帰的構造比較（循環検出は list? 判定にのみ実装、equal? には未導入）

────────────────────────────────────

3. リーダ（Reader: S 式パーサ）
- 入力文字列から Value へ構文解析
- 対応要素
  - 数字（10進の整数のみ。浮動小数・有理・複素は未対応）
  - シンボル、文字列、クオート（'x → (quote x)）
  - 準クオート（`x → (quasiquote x)）
    - カンマ（,x → (unquote x)）、カンマアット（,@x → (splice x)）
  - ベクタ（#(a b c) → Vector）
  - リスト（(a b c)）、ドット対（(a . b)）
  - コメント（;～改行）
- 注意
  - micro_Scheme8 の「backquote マクロ」は、C++ 実装ではコンパイラ段階で quasiquote を構文展開（qq_transfer）する実装とし、読込は quasiquote/unquote/splice に変換
  - 数字は整数のみ。互換のための number->string / string->number を補う

────────────────────────────────────

4. コンパイラ（Compiler）
- 役割
  - S 式（Value）→ Code（Instruction 列）へコンパイル
  - 末尾位置では TAPP（tail APP）を使って TCO を実現
- 環境モデル（CompileEnv）
  - 各フレームは引数名列（std::vector<std::string>）
  - location_of(name, env) で (frame index, slot index) を検索し LD/LSET に埋め込む
- コンパイル対象（主要）
  - quote, if, lambda, define, define-macro, set!, call/cc, apply, begin
  - マクロ（and/or/cond/case/do/let/let*/letrec/quasiquote）をコンパイラ側で構文展開
- 末尾最適化
  - 関数呼出の末尾位置で TAPP を発行
  - if 末尾については（Lisp 実装の selr + rtn に相当する）SELR/RTN ではなく、分岐両方の末尾に JOIN を置く実装（注: VM は SELR をサポートするが、現行コンパイラは常に SEL + JOIN を生成）
- マクロ展開
  - macro_expand_1_expr により 1 段展開
  - 定義済みマクロは g_macros を参照、CLOSURE として評価（apply_callable_raw）し式を置換
- 可変長引数
  - lambda パラメータのドット対を rest_param として保持
  - 呼出時の APP/TAPP では、固定部＋余りを list にして 1 フレームに詰める
- apply の特殊処理
  - (apply f arg1 ... argN last-list)
  - ARGS-AP n で最後のリストに先頭 (n-1) 個を前置きして 1 つの引数リストを構成

────────────────────────────────────

5. 命令セット（Instruction Set）
- レジスタ
  - S: スタック
  - E: 環境（静的リンクのリスト列。各フレームは引数値のリスト）
  - C: 実行コード（CodePtr）
  - D: ダンプ（レジスタ退避領域、call/branch 戻り先）
  - pc: 命令インデックス
- 主要命令（C++ 実装での意味）
  - LD (i . j): E[i][j] をスタックへ
  - LDC const: 即値をスタックへ
  - LDG sym: 大域変数 sym の値をスタックへ
  - LDF: クロージャ（params, rest, body, captured_env=e）を構成して積む
  - ARGS n: スタックから n 個を取り出し、順序を正して 1 リストにして積む
  - ARGS-AP n: スタックからリスト1個＋(n-1)個を取り出し、結合した 1 リストを積む
  - APP: 関数適用。D へ (S,E,C,pc) 退避
  - TAPP: 末尾適用。D へ退避しない（TCO）
  - RTN: D から (S,E,C,pc) を復元。ダンプ空なら最終結果を返す
  - SEL ct cf: 条件分岐。条件値により ct/cf の Code へ飛ぶ（D に続きの (S,E,C,pc) を push）
  - SELR ct cf: 条件分岐（D に続き保存なし）
  - JOIN: 分岐から戻る（D から (S,E,C,pc) を復元）
  - POP: スタックトップを捨てる
  - DEF sym: スタックトップを g_globals[sym] に設定し、スタックトップを symbol で置換
  - DEFM sym: スタックトップ（クロージャ）をマクロ登録。g_macros と g_globals に格納
  - LSET (i . j): スタックトップの値で E[i][j] を破壊的書換（リストを辿って set）
  - GSET sym: g_globals[sym] をスタックトップで書換
  - LDCT: 現在の継続（S,E,C,pc,D）を Value にして積む
  - CALLCC: スタックトップの手続きに「現在の継続」を 1 引数として適用
  - STOP: 実行停止（結果はスタックトップ、なければ NIL）

補足
- 現行コンパイラは if を SEL+JOIN で生成（SELR は未使用）
- APP/TAPP 分岐の実装で、TAPP は D に退避しない点が TCO の肝

────────────────────────────────────

6. VM（実行機構）と継続（call/cc）
- 実行ループ
  - c->ins[pc++] を取り出し、命令ごとの処理を行う
  - g_trace_mode が ON の場合、各ステップで
    - 現在の PC・命令表示
    - スタック/環境/ダンプのサマリを出力
- 環境の表現
  - 1 フレームは「引数列のリスト」（list_from_vector(frame)）
  - LSET はリストを cdr で辿って位置（j）を探し car を破壊更新
  - 関数適用時
    - 新しい E は先頭に 1 フレーム（apply 時の引数値列）を cons
    - その後ろにクロージャの captured_env を連結
- 末尾呼出最適化（TCO）
  - TAPP の場合、現在の (S,E,C,pc) を D に退避しない
  - 新しいフレーム/環境に切替えて、そのまま callee の本体へジャンプ
- 継続（call/cc）
  - CALLCC の振る舞い
    1) 現在の継続 k = (S,E,C,pc,D) を丸ごと Value 化
    2) 手続きに 1 引数で渡し適用（通常の関数適用）
    3) 継続値が適用ターゲットの場合（k が callee）、引数の先頭要素を「継続の返り値」として復帰
       - つまり、S, E, C, pc, D を継続のスナップショットで置き換え、S に値を push して再開
  - LDCT は裸の継続を積むだけ（call/cc は関数に直接適用まで行う）
- arity チェック
  - rest_param の有無に応じて引数数を検査
  - 可変長時は余剰分を 1 本のリストにしてフレーム末尾に配置

────────────────────────────────────

7. マクロシステム（define-macro とコンパイル時展開）
- 仕組み
  - (define-macro name transformer) で登録
    - DEFM 命令により、g_macros[name] に transformer（Closure）を保存
    - g_globals[name] には（表示用に）(MACRO <closure>) を格納
  - コンパイル時、式の先頭シンボルが g_macros にあれば 1 段展開（macro_expand_1_expr）
    - macro 本体の評価は VM（apply_callable_raw）を使ってクロージャ実行
    - 展開結果の S 式を元の式と置換して再帰コンパイル
- 特記事項
  - and/or/cond/case/do/let/let*/letrec/quasiquote はコンパイラ側で直接構文展開（マクロ不要）
  - micro_Scheme8 の「backquote マクロ」は、C++ 実装では「quasiquote 特殊形式＋コンパイル展開」として実現
- 非衛生マクロ
  - gensym は提供（(gensym "prefix")）するが、マクロ衛生は未実装（micro_Scheme8 と同様の方針）

────────────────────────────────────

8. プリミティブと標準ライブラリ（system_lib.scm）
- プリミティブ（C++ 実装）
  - 整数演算 +, -, *, /, modulo, 比較（=, <, >, <=, >=）
  - ペア/リスト: cons, car, cdr, set-car!, set-cdr!, list, append, 各種 cadr 系
  - 述語: eq?, eqv?, equal?, not, symbol?, number?, boolean?, procedure?
  - リスト関連: length, list?, atom?, memq, memv, assq, null?, pair?
  - I/O: display, newline, read（標準入力から 1 行→式），load（ファイル読込）
  - ファイル I/O: open-input-file, open-output-file, close-*, read-line, write, write_newline, eof-object?, read-char, write-char, read-expr
  - 文字列: string?, make-string, string-length, string-ref, string-set!, substring, string-append, string->list, list->string, string=?/</>/<=/>=
  - 文字変換: number->string, string->number, char->integer, integer->char
  - ベクタ: vector?, make-vector, vector, vector-length, vector-ref, vector-set!, vector->list, list->vector
  - ユーティリティ: gensym
  - デバッグ: compile, disassemble, trace-on, trace-off, globals, macros, help
- ライブラリ（system_lib.scm）
  - micro_Scheme8 の mlib7 系をベースに、C++ 実装に合わせ厳選
  - map, filter, fold-left/right, for-each は Scheme 実装で上書き
    - 目的: call/cc による「途中脱出」（早期リターン）をループの枠組みで自然に通すため
    - C++ 実装ループ内だと C++ 側のフレームで継続が捕捉されてしまうのを回避
  - delay/force は Scheme 実装（make-promise）
  - primes や queue などの例題も整備

────────────────────────────────────

9. REPL とデバッグ機能
- REPL
  - 複数行入力に対応（括弧対応チェック）
  - 入力はすべて S 式として read_all_exprs で読み込み評価
  - 出力は to_string による 1 行表示
    - クロージャは `#<closure:(params)>` のように簡潔に表示
    - プリミティブは `#<primitive:name>` 形式
    - 特殊形式は `#<special-form:name>` 形式
    - TRUE/FALSE/NIL の大文字表記も利用可能

- デバッグ機能（REPL コマンド）
  
  1. (help)
     - デバッグコマンドの一覧とヘルプを表示
  
  2. (compile expr)
     - 式 expr をコンパイルし、生成バイトコード（Code）をダンプ
     - 用途: コンパイラの出力を確認、最適化の検証
     - 注意: 分岐先のコードは `[THEN-BRANCH]` `[ELSE-BRANCH]` と省略表示される
  
  3. (disassemble closure-or-macro)
     - クロージャ（またはマクロの変換器クロージャ）の内部を詳細に表示
     - 表示内容:
       - パラメータ（固定引数と可変引数）
       - 本体の命令列（完全な逆アセンブル）
       - 捕捉環境のフレーム数
     - 特徴: 
       - **分岐先（THEN/ELSE）のコードも完全に表示**
       - **ラムダ式のボディも展開表示**
       - 階層構造をインデントで可視化（最大10階層まで）
     - 用途: 関数の内部構造の理解、バグ追跡
  
  4. (trace-on) / (trace-off)
     - VM の命令ごとのステップ実行の詳細を標準出力に表示/非表示
     - 表示内容:
       - ステップ番号と PC（プログラムカウンタ）
       - 実行中の命令
       - スタック（S）の内容（最大5要素まで表示）
       - 環境（E）のフレーム数と内容（最大3フレームまで表示）
       - ダンプ（D）のフレーム数
     - 用途: 実行フローの追跡、継続の動作確認
  
  5. (globals)
     - 現在のグローバル変数一覧を表示
     - プリミティブ・特殊形式・クロージャは短縮表記で表示
  
  6. (macros)
     - 登録済みマクロの名前一覧を表示

- デバッグワークフロー例
  
  基本的な関数の検証:
  1. 関数を定義
  2. シンボル表示で簡潔な情報確認（`#<closure:(params)>`）
  3. (disassemble func) で詳細な内部構造を確認
  4. 必要に応じて (trace-on) で実際の実行を追跡
  5. (trace-off) でトレースを終了
  
  コンパイラ出力の検証:
  1. (compile expr) でコンパイル結果の概要を確認
  2. 関数に定義してから (disassemble) で詳細確認

────────────────────────────────────

10. micro_Scheme8 からの主な差異と互換性ノート
- 命令とコンパイル
  - Lisp 実装は if の末尾で selr と rtn を使い分けるが、本実装は if で一律 SEL + JOIN を生成（SELR は命令としては存在するが未使用）
  - call/cc は専用オペコード CALLCC を用意（micro では ldct+args+app の合成で表現）
- 型と表示
  - 整数は任意精度（Boost cpp_int）。フォールバックで long long
  - 文字列・ベクタ型を実装（micro_Scheme8 の Common Lisp 互換よりは S-式言語として素朴寄り）
  - TRUE/FALSE/NIL など大文字の別名も用意（利便目的）
- リーダ
  - 数の扱いは整数のみ（浮動小数/有理/複素は未対応）
  - backquote は quasiquote+コンパイラ展開（micro の backquote マクロと同等の振る舞い）
- ライブラリ
  - map/filter/fold などは Scheme 実装で上書き（call/cc の振る舞いの一貫性確保）
- 等価性
  - equal? は循環構造の完全対応は未実装（list? 判定の循環検出はあり）
- テスト用の特殊フォーム
  - micro の test-start/test-end/trace-print/macro-print/compile-print は「LDC true を返すだけ」に簡略化（REPL のデバッグコマンドで代替）

────────────────────────────────────

11. 実装上の注意・拡張ポイント
- 継続（Continuation）
  - 直感的に「コールスタックを丸ごと Value 化」しているため、デバッグ時に VM の状態遷移が理解しやすい
  - 一方で S/E/C/D をすべてコピーするため、継続の大量生成は注意（Boehm GC の上で普通は大丈夫）
- 末尾最適化
  - TAPP による TCO は関数呼び出しの末尾に限定。if 末尾の最適化は SEL/SELR の使い分けで強化の余地がある
- 等価性と循環
  - equal? は循環を考慮しないため、循環構造で無限再帰の可能性あり（用途に応じて拡張を検討）
- 追加プリミティブ
  - g_globals に (name → make_prim(name, fn)) を追加
  - to_string と表示整合性、引数数チェック、エラー文言の一貫性に注意
- マクロ衛生
  - 現状は非衛生（micro と同様）。必要に応じ hygienic macro 系の導入も可能
- ポータビリティ
  - Boehm GC の検出分岐（<gc/gc.h> など）を持つ。Windows/Unix でインクルードパスの調整が必要
- ビルド
  - Windows 用 Makefile と Linux/FreeBSD 用 Makefile を同梱
  - Boost と Boehm GC のインクルード/リンク設定を環境に合わせる

────────────────────────────────────

付録A. 例: コンパイル出力と逆アセンブル

■ 例1: 簡単な式のコンパイル

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

解説:
- LDC で定数 1, 2 をスタックに積む
- ARGS 2 で2つの引数をリストにまとめる
- LDG + でグローバル関数 + を取得
- APP で適用
- STOP で終了

────────────────────────────────────

■ 例2: 条件分岐を含む関数（disassemble の威力）

```scheme
scheme12> (define (fact n a)
            (if (= n 0)
                a
                (fact (- n 1) (* a n))))
fact

scheme12> fact
#<closure:(n a)>

scheme12> (disassemble fact)

=== Disassembly ===
Parameters: (n a)
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
      [  1] LD (0 . 0)
      [  2] LDC 1
      [  3] ARGS 2
      [  4] LDG -
      [  5] APP
      [  6] LD (0 . 1)
      [  7] LD (0 . 0)
      [  8] ARGS 2
      [  9] LDG *
      [ 10] APP
      [ 11] ARGS 2
      [ 12] LDG fact
      [ 13] TAPP
      [ 14] JOIN
  [  6] RTN
Environment: 0 frame(s)
===================
:disassembled
```

解説:
- SEL 命令の分岐先（THEN/ELSE）が完全に表示される
- THEN ブランチ: 単に a を返す（LD (0.1) = 第0フレームの第1スロット）
- ELSE ブランチ: 
  - (- n 1) と (* a n) を計算
  - TAPP で末尾再帰呼び出し（TCO が効く）
- インデントで階層構造が一目瞭然

────────────────────────────────────

■ 例3: ネストした条件分岐

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

解説:
- cond が複数の if にネストして展開される様子が見える
- ELSE ブランチの中にさらに SEL があり、2段階の条件分岐
- インデントの深さで入れ子構造が明確

────────────────────────────────────

■ 例4: ラムダ式を含む関数

```scheme
scheme12> (define (make-adder n)
            (lambda (x) (+ x n)))
make-adder

scheme12> (disassemble make-adder)

=== Disassembly ===
Parameters: (n)
Body:
  [  0] LDF (x)
    Lambda body:
      [  0] LD (0 . 0)
      [  1] LD (1 . 0)
      [  2] ARGS 2
      [  3] LDG +
      [  4] APP
      [  5] RTN
  [  1] RTN
Environment: 0 frame(s)
===================
:disassembled
```

解説:
- LDF 命令の中にラムダのボディが展開表示される
- 内側のラムダは外側の n を参照（LD (1.0) = 1つ外のフレーム）
- クロージャの静的スコープの仕組みが可視化される

────────────────────────────────────

■ 例5: トレース実行で継続の動きを観察

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

解説:
- 各ステップでスタック・環境・ダンプの状態を確認
- LDC → ARGS → APP の流れを追跡
- プリミティブ関数の呼び出しも観察可能

────────────────────────────────────

■ 例6: compile と disassemble の使い分け

**compile の用途**: 
- 式の即座のコンパイル結果確認
- 分岐の概要把握（詳細は省略される）

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

**disassemble の用途**:
- 定義済み関数の詳細分析
- 分岐先の完全な命令列確認
- ラムダ式の内部構造確認

```scheme
scheme12> (define (test x) (if (< x 0) 'neg 'pos))
scheme12> (disassemble test)

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
      [  0] LDC NEG
      [  1] JOIN
    ELSE:
      [  0] LDC POS
      [  1] JOIN
  [  6] RTN
Environment: 0 frame(s)
===================
:disassembled
```

**使い分けのポイント**:
- compile: 概要把握、コンパイラの動作確認
- disassemble: 詳細分析、デバッグ、学習

────────────────────────────────────

■ 例7: call/cc のトレース（高度な例）

```scheme
scheme12> (define escape false)
scheme12> (trace-on)
scheme12> (+ 1 (call/cc (lambda (k) (set! escape k) 2)) 3)

... 多数のステップ表示（省略）...
... CALLCC 命令で継続が作成される様子
... 継続が変数に代入される様子
... 最終的に (+ 1 2 3) = 6 が返る

6
scheme12> (trace-off)
scheme12> (escape 10)
13
```

解説:
- トレースモードで call/cc の内部動作を観察
- 継続が捕捉され、後で呼び出される様子を追跡
- CALLCC 命令がどのように S,E,C,D をスナップショットするか確認可能

────────────────────────────────────

付録B. 例: 継続（call/cc）の動き
- 代表例
  ```
  scheme12> (define a false)
  scheme12> (list 'a 'b (call/cc (lambda (k) (set! a k) 'c)) 'd)
  (A B C D)
  scheme12> (a 'e)
  (A B E D)
  ```
- 解説
  - (call/cc (lambda (k) ...)) で現在の継続を k に束縛
  - k は任意の時点で呼べる関数で、引数を「直ちにその時点へ戻り値として返す」
  - 本実装では ContPtr が S,E,C,pc,D を保持し、適用時に VM 状態を復元して値を積む

────────────────────────────────────

付録C. ビルド・起動方法（要約）
- 依存
  - Boehm GC（libgc, libgccpp）
  - Boost.Multiprecision（任意精度整数）
- ビルド（例: Windows/MinGW の Makefile）
  ```
  make
  ```
- 起動
  ```
  ./scheme12_debug
  scheme12 debug REPL. Type (help) for commands.
  ```
- ライブラリ読み込み
  - 起動時に system_lib.scm をロード（実行ファイル隣接またはカレント）
  - (load "path/to/file.scm") で追加入力

────────────────────────────────────


以上

本ドキュメントは、micro_Scheme8 の設計思想を尊重しつつ、C++ 実装（scheme12_debug）におけるオブジェクト表現・命令実装・デバッグ機能の追加点を中心にまとめました。特に継続（call/cc）と TCO（TAPP）の実装は、SECD VM の肝であり、本実装でも可読性と追跡容易性を意識して構成されています。さらに詳細な追跡が必要な場合は、(trace-on) で VM の 1 命令ごとの状態変化を観察してください。
