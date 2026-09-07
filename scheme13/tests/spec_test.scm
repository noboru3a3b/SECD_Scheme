; 凍結仕様（dev_memo.md §2）の後ろ盾。
;
; **この1本が §2 の各行を1行ずつ写している。** 左に §2 の項番と本文、
; 右にその行が主張する値を置く。ゴールデン（golden/spec_test.scm.out）が
; 出力全体をバイト単位で押さえているので、§2 のどれか1行が嘘になれば
; ここが必ず落ちる。
;
; **なぜ別に1本置くのか**（26日目の決定132）。それまで §2 の行を守っていたのは
; 受け入れ基準の12件・lib13_test.scm・--selftest に散らばった項目で、
; 「どの行を誰が守っているのか」を誰も持っていなかった。変異法で測ったら
; 後ろ盾がゼロの行が実際にあった（dev_memo.md §6 の決定133 に表がある）。
; §2 を次に改めるときは、**この表と同じ順序で**ここも直すこと。
;
; ここに書けないものが3種類ある。§2 の行としては生きているので、
; どこが見ているかを明記しておく:
;   - エラーの文面（(/ x) / (/ 1 0) / 整数を要求する場所）
;     → 途中で止まるのでゴールデンに書けない。--selftest の selftest_errors()
;   - 「無い」という主張（syntax-rules が無い・準クオートのネストが未対応）
;     → 肯定形のテストで固定できない。踏むとエラーになる
;   - test-start/test-end の照合機構は使わない。**あちらは大小文字を無視して
;     比べる**（決定30）ので、§2.1「シンボルは大小文字を保存する」を
;     守れない。ここは write の出力そのものをゴールデンで押さえる

(define (chk id text val)
  (display id) (display "  ") (display text) (display "  ") (write val) (newline))

;;; ======================================================================
;;; §2.1 表示（write による）
;;; ======================================================================

(chk "2.1-01" "'() および nil は NIL      " (list (quote ()) nil))
(chk "2.1-02" "#t / true は TRUE          " (list #t true))
(chk "2.1-03" "#f / false は FALSE        " (list #f false))
(chk "2.1-04" "シンボルは大小文字を保存する" (quote AbC))
(chk "2.1-05" "'(a B c)                   " (quote (a B c)))
(chk "2.1-06" "'(a . b) はドット対        " (quote (a . b)))
(chk "2.1-07" "'#(1 a \"s\")                " (vector 1 (quote a) "s"))
(chk "2.1-08" "write は改行をエスケープしない" "hi
there")
(chk "2.1-09" "閉包は #<closure:(x y)>    " (lambda (x y) x))
(chk "2.1-10" "可変長の閉包は (x . r)     " (lambda (x . r) x))
(chk "2.1-11" "プリミティブは (PRIMITIVE) " car)
(chk "2.1-12" "特殊形式は (SPECIAL-FORM)  " if)
(chk "2.1-13" "継続は #<continuation>     " (call/cc (lambda (k) k)))
(chk "2.1-14" "循環リスト（cdr方向）      " (let ((c (list 1 2))) (set-cdr! c c) c))
(chk "2.1-15" "循環リスト（car方向）      " (let ((d (list 1 2))) (set-car! d d) d))
(chk "2.1-16" "循環ベクタ                 " (let ((v (vector 0 0))) (vector-set! v 0 v) v))

; ポートと eof は実ファイルが要る。run_golden.sh が最後に消す。
(define spec-tmp "test-spec-temp.txt")
(define out-port (open-output-file spec-tmp))
(close-output-port out-port)
(chk "2.1-17" "閉じたポートは #<closed-port>" out-port)
(define in-port (open-input-file spec-tmp))
(chk "2.1-18" "eof は #<eof>              " (let ((c (read-char in-port))) (close-input-port in-port) c))

; 実数（18日目の決定90）
(chk "2.1-19" "1.5 は 1.5                 " 1.5)
(chk "2.1-20" "実数は必ず . か e を含む   " (list 1.0 (* 2.0 3.0)))
(chk "2.1-21" "読み戻せる最短の形         " (/ 1.0 3))
(chk "2.1-22" "丸めて隠さない             " (+ 0.1 0.2))
(chk "2.1-23" "指数の + は付けない        " 1e21)
(chk "2.1-24" "指数を 0 で詰めない        " 1e-7)
(chk "2.1-25" "-0.0 は -0.0               " -0.0)
(chk "2.1-26" "無限大は +inf.0 / -inf.0   " (list (/ 1.0 0.0) (/ -1.0 0.0)))
(chk "2.1-27" "非数は +nan.0              " (* 0.0 (/ 1.0 0.0)))

; display と write の違いは**最外の文字列を引用符で囲むかどうかだけ**。
; リストの要素にある文字列は display でも引用符つきで出る。
(display "2.1-28  display と write の違い  ")
(display "x") (display " / ") (write "x")
(display " / ") (display (list "x" (quote y))) (display " / ") (write (list "x" (quote y)))
(newline)

;;; ======================================================================
;;; §2.2 型と述語
;;; ======================================================================

(chk "2.2-01" "文字型は無い（長さ1の文字列）" (list (string-ref "abc" 1) (integer->char 65)))
(chk "2.2-02" "eq? は数値を値で比べる     " (eq? 100000000000 100000000000))
(chk "2.2-03" "シンボルは名前比較         " (eq? (string->symbol "ab") (quote ab)))
(chk "2.2-04" "文字列はポインタ比較       " (eq? "a" "a"))
(chk "2.2-05" "正確な整数と不正確な実数の2種" (list (exact? 1) (exact? 1.0) (inexact? 1.0)))
(chk "2.2-06" "有理数は無い（(/ 7 2)）    " (/ 7 2))
(chk "2.2-07" "eqv? は正確さが一致して初めて真" (list (= 1 1.0) (eqv? 1 1.0)))
(chk "2.2-08" "実数の eqv? はビット列で比べる" (list (eqv? 0.0 -0.0) (eqv? +nan.0 +nan.0)))
(chk "2.2-09" "= のほうは逆              " (list (= 0.0 -0.0) (= +nan.0 +nan.0)))
(chk "2.2-10" "実数の結果を整数に落とさない" (* 2.0 3.0))

;;; ======================================================================
;;; §2.3 算術
;;; ======================================================================

(chk "2.3-01" "(/ -7 2) は -3（0方向切り捨て）" (/ -7 2))
(chk "2.3-02" "(/ 1 3) は 0（仕様であって不具合ではない）" (/ 1 3))
(chk "2.3-03" "modulo の符号は除数に一致  " (list (modulo -7 2) (modulo 7 -2)))
(chk "2.3-04" "remainder の符号は被除数に一致" (list (remainder -7 2) (remainder 7 -2)))
(chk "2.3-05" "多倍長整数                 " (* 99999999999 99999999999))
(chk "2.3-06" "不正確が1つでもあれば結果も不正確" (list (+ 1 1.5) (/ 7 2.0) (* 2 3.0)))
(chk "2.3-07" "NaN が混ざったらどの比較も偽" (list (< +nan.0 1) (> +nan.0 1) (<= +nan.0 1) (>= +nan.0 1) (= +nan.0 1)))
(chk "2.3-08" "整数と実数の比較は倍精度に寄せる" (= 9007199254740993 9007199254740992.0))
(chk "2.3-09" "(/ 1.0 0.0) は +inf.0      " (/ 1.0 0.0))

;;; ======================================================================
;;; §2.4 返り値
;;; ======================================================================

(chk "2.4-01" "(define zz 1) はシンボル zz" (define zz 1))
(chk "2.4-02" "(set! v 2) は代入した値    " (let ((v 1)) (set! v 2)))
(chk "2.4-03" "(vector-set! ...) は :undef" (vector-set! (vector 1) 0 9))
(chk "2.4-04" "(string-set! ...) は :undef" (string-set! (string-copy "ab") 0 "b"))
(chk "2.4-05" "(display x) は x そのもの  " (display ""))
; (newline) は**改行を出しつつ** NIL を返す。その改行は chk が名札を出す前に
; 流れるので、次の行の手前が1行空く。空行もゴールデンの一部である。
(chk "2.4-06" "(newline) は NIL           " (let ((v (newline))) v))

;;; ======================================================================
;;; §2.5 構文
;;; ======================================================================

(chk "2.5-01" "角括弧は区切り文字ではない " (quote ([1 2])))
(chk "2.5-02" "true / false / nil のリテラル" (list (quote nil) (quote true) (quote false)))
(chk "2.5-03" ",@ は splice に読まれる    " (quote (a ,@b)))
(chk "2.5-04" "実数のリテラル             " (list .5 1. 1e10 1.5e-3 +2.5E7 -0.75))
(chk "2.5-05" "inf / nan のリテラル       " (list +inf.0 -inf.0 +nan.0 -nan.0))
(chk "2.5-06" "1/2 1.2.3 1e はシンボル    " (list (symbol? (quote 1/2)) (symbol? (quote 1.2.3)) (symbol? (quote 1e))))
(chk "2.5-07" "(a .5) は2要素             " (quote (a .5)))
(chk "2.5-08" "(a . 5) はドット対         " (quote (a . 5)))

;;; ======================================================================
;;; §2.6 内部 define
;;; ======================================================================
;;; letrec になるのは**本体先頭の連続した define だけ**。それ以外は大域定義。

(define (spec-head) (define a 1) (define b 2) (+ a b))
(chk "2.6-01" "本体先頭の define は letrec" (spec-head))

(define (spec-after) (display "") (define g-after 99) g-after)
(chk "2.6-02" "式より後ろの define の値   " (spec-after))
(chk "2.6-03" "  → 大域定義になっている   " g-after)

(define-macro (spec-mk) (list (quote define) (quote g-macro) 88))
(define (spec-viamac) (spec-mk) 1)
(chk "2.6-04" "マクロが生成した define    " (spec-viamac))
(chk "2.6-05" "  → 大域定義になっている   " g-macro)

(define (spec-splice) (begin (define g-begin 77)) 1)
(chk "2.6-06" "先頭の (begin (define ...))" (spec-splice))
(chk "2.6-07" "  → 大域定義になっている   " g-begin)

;;; ======================================================================
;;; §2.7 継続
;;; ======================================================================

(chk "2.7-01" "call/cc                    " (call/cc (lambda (k) (k 5))))
(chk "2.7-02" "call-with-current-continuation" (call-with-current-continuation (lambda (k) (k 5))))
(chk "2.7-03" "call/cc は値ではない       " (procedure? call/cc))
(chk "2.7-04" "apply は値ではない         " (procedure? apply))

; トップレベルのフォームは個別に評価される。フォームを跨いで継続を起動すると
; **そのフォームの残りは実行されず、次のフォームへ進む**。
(define spec-k #f)
(define spec-n 0)
(begin
  (display "2.7-05  フォームを跨ぐ継続      ")
  (write (call/cc (lambda (c) (set! spec-k c) 1)))
  (display "  ← 2周目はこのフォームの途中から再開する")
  (newline))
(set! spec-n (+ spec-n 1))
(if (= spec-n 1) (spec-k 2))       ; ここから上のフォームへ跳ぶ
(begin
  (display "2.7-06  跳んだ後は次のフォームへ  ")
  (write spec-n)
  (display "  ← if の残りは実行されない")
  (newline))
