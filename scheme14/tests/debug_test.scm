;;; debug_test.scm — 看板のデバッグ機能の回帰（30日目の決定145〜147）
;;;
;;; §1.5 は `trace-on` / `trace-off` / `compile` / `disassemble` / `globals` /
;;; `macros` / `help` を「この処理系の看板」とし、とくに
;;; **「逆アセンブル表示は、命令セットを変えるたびに追随させること」**と
;;; 定めている。ところが30日目に測ったところ、**7つのうち出力に後ろ盾が
;;; あったのは `help` と `macro-print` の2つだけ**だった。
;;; `compile` / `disassemble` / `globals` / `macros` は `(help)` の文面に
;;; 名前が載っているだけで、`trace-on` に至っては
;;; `test_improvements.scm` が**名前を含む文字列を印字していただけ**である。
;;; このファイルはその穴を埋める。
;;;
;;; **`globals` はここに入れない**（26日目の決定136）。大域名が増えるたびに
;;; 動くので、採り直しが「何かを壊した合図」にならない。実際に直近2日で
;;; 249 → 275 と動いた。**`macros` は入れる** — 一覧が2件で、
;;; 増えるのはマクロを足したときだけだからである。
;;;
;;; 第1節（compile）の並びには意図がある。**21個の命令をすべて出す**ように
;;; 選んであり、命令セットに手が入れば必ずどこかが動く。これが §1.5 の
;;; 「追随させること」を人の目から機械に移す仕掛けである。
;;; 覆いを確かめるコマンドは tests/golden/README.md にある。
;;;
;;; **足すときは第4節（トレース）の前に足すこと。** トレースは以降の
;;; すべての評価を実況するので、後ろに置いたものは巻き込まれる。

;;; ============================================================ 1. compile
;;; `(compile expr)` は式をコンパイルして命令列を表示する。**評価はしない**
;;; ので、ここに書いた define や set! で環境は動かない。

;; LDC / LDG / APP / STOP
(compile '(+ 1 2))

;; SEL / JOIN — 末尾でない if は、二股を積んで JOIN で合流する
(compile '(if a b c))

;; LD / LDF / RTN / SELR / TAPP — 末尾の if は SELR で、合流せずそのまま返す
(compile '(lambda (n) (if (= n 0) 1 (f n))))

;; DEF
(compile '(define x 1))

;; DEFM
(compile '(define-macro m (lambda (x) x)))

;; LSET — 引数への set! は局所の代入
(compile '(lambda (a) (set! a 1)))

;; GSET — 大域への set!
(compile '(set! x 1))

;; POP — begin の途中の値は捨てる
(compile '(begin 1 2))

;; CALLCC / TCALLCC — 末尾かどうかで分かれる
(compile '(call/cc (lambda (k) k)))
(compile '(lambda () (call/cc (lambda (k) k))))

;; ARGS-AP / APPLY / TAPPLY — apply も末尾かどうかで分かれる
(compile '(apply + (list 1 2)))
(compile '(lambda () (apply + (list 1 2))))

;;; ======================================================== 2. disassemble
;;; `(disassemble closure)` は閉包の中身を出す。compile と違い
;;; **引数と、閉じ込めた環境の段数**も出る。

(define (mul a b) (* a b))
(disassemble mul)

;; 環境を1段閉じ込めた閉包。`Environment:` の段数が 0 でなくなる
(define adder ((lambda (n) (lambda (x) (+ x n))) 10))
(disassemble adder)

;;; ============================================================= 3. macros
;;; `(macros)` は define-macro で定義された名前を並べる。
;;; **一覧が実際を追っていることを見たいので、足す前と後の両方を見る。**
;;; 足す前に出るのは `delay` ただ1つで、これは system_lib.scm のもの。

(macros)

(define-macro unless (lambda (c e) (list 'if c ':undef e)))

(macros)

;;; ============================================================== 4. trace
;;; `(trace-on)` は1命令ごとに PC・命令・スタック・環境・Dump を出す。
;;; **ここは意図して最小にしてある。** `(fact 3)` を実況させると608行に
;;; なり、ゴールデンとしては「何が変わったか」が読めなくなる。
;;; 見たいのは「出ること・止まること・5つの欄が揃っていること」の3点で、
;;; それには `(+ 1 2)` の5命令で足りる。
;;;
;;; `(trace-on)` 自身の STOP が1つ実況されるのは、切り替えが
;;; **その式の評価の途中で**効くためである（仕様であって不具合ではない）。

(trace-on)
(+ 1 2)
(trace-off)
