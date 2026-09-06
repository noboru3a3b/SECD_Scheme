; lib13.scm（scheme13 が足す R5RS 手続き）の回帰テスト。
;
; 原典のテスト機構（6日目に復活させたもの）を使う。式の次の行が期待する
; write 表現で、大小文字は無視して照合される（決定30）。
;
;   scheme13/tests/run_golden.sh がこれを走らせ、出力全体をゴールデンと
;   バイト単位で比べる。--selftest では見られない（あちらはライブラリを
;   読む前に走る C++ 単体の回帰なので）。
;
; 末尾に多値と dynamic-wind の項目がある（13日目の決定58・59）。
; **継続を使う項目は1つのフォームの中に閉じて書くこと。** トップレベルの
; フォームを跨いで継続を起動すると、そのフォームの残りは実行されずに
; 次のフォームへ進む（凍結仕様 §2.7）ので、テスト機構の照合がずれる。

(test-start)
TRUE

;;; --- 数値の述語（正確な整数と不正確な実数の2階建て。18〜20日目）---

(integer? 3)
TRUE

(rational? 3)
TRUE

(real? 3)
TRUE

(complex? 3)
TRUE

(integer? "x")
FALSE

(exact? 3)
TRUE

(inexact? 3)
FALSE

(integer? 2.0)
TRUE

(integer? 2.5)
FALSE

(integer? +inf.0)
FALSE

(rational? +inf.0)
FALSE

(real? +nan.0)
TRUE

(exact? 3.0)
FALSE

(inexact? 3.0)
TRUE

(exact->inexact 1)
1.0

(inexact->exact 2.0)
2

(zero? 0)
TRUE

(zero? 1)
FALSE

(positive? 3)
TRUE

(positive? -3)
FALSE

(negative? -3)
TRUE

(even? 4)
TRUE

(even? 5)
FALSE

(odd? 5)
TRUE

(even? -4)
TRUE

(odd? -5)
TRUE

;;; --- abs / max / min ---

(abs -5)
5

(abs 5)
5

(abs 0)
0

(abs -99999999999999999999)
99999999999999999999

(max 1 7 3)
7

(min 1 7 3)
1

(max 5)
5

(min -1 -7)
-7

(max 2 1.0)
2.0

(min 1.0 7)
1.0

(abs -1.5)
1.5

;;; --- 除算。remainder の符号は被除数、modulo の符号は除数に一致する ---

(quotient 7 2)
3

(quotient -7 2)
-3

(remainder -7 2)
-1

(remainder 7 -2)
1

(modulo -7 2)
1

(modulo 7 -2)
-1

;;; --- gcd / lcm。引数0個も許す（R5RS）---

(gcd 12 18)
6

(gcd 12 18 8)
2

(gcd -12 18)
6

(gcd)
0

(gcd 7)
7

(lcm 4 6)
12

(lcm)
1

(lcm 4 0)
0

;;; --- expt。多倍長へ抜けても正しいこと ---

(expt 2 10)
1024

(expt 2 0)
1

(expt 0 0)
1

(expt 3 5)
243

(expt 99999999999 3)
999999999970000000000299999999999

(expt 2 100)
1267650600228229401496703205376

(expt 2 -3)
0.125

(expt 2.0 3)
8.0

;;; --- sqrt。正確な平方数なら正確な整数、そうでなければ不正確な実数（21日目）。
;;; sqrt は IEEE 754 が正しい丸めを義務づけているので、最後の桁まで固定してよい。

(sqrt 0)
0

(sqrt 1)
1

(sqrt 2)
1.4142135623730951

(sqrt 16)
4

(sqrt 17)
4.123105625617661

(sqrt 24)
4.898979485566356

(sqrt 25)
5

(sqrt 9999999999800000000001)
99999999999

(sqrt 2.0)
1.4142135623730951

(sqrt 2.25)
1.5

;;; --- 丸め。正確な整数では恒等、実数は実数のまま。round は偶数丸め（20日目）---

(floor 5)
5

(ceiling -5)
-5

(truncate 5)
5

(round -5)
-5

(floor 2.7)
2.0

(floor -2.5)
-3.0

(ceiling 2.1)
3.0

(truncate -2.7)
-2.0

(round 2.5)
2.0

(round 3.5)
4.0

;;; --- 算術の伝播規則（20日目）。一つでも不正確なら結果も不正確 ---

(+ 1 1.5)
2.5

(* 2 3.0)
6.0

(- 1 0.5)
0.5

(/ 7 2)
3

(/ 7 2.0)
3.5

(/ 1 3)
0

(/ 1.0 3)
0.3333333333333333

(/ 1.0 0.0)
+inf.0

(= 1 1.0)
TRUE

(eqv? 1 1.0)
FALSE

;;; --- NaN はどの比較も偽（20日目の決定87）。`>=` を `<` の否定で書くと落ちる ---

(= +nan.0 +nan.0)
FALSE

(< +nan.0 1)
FALSE

(> +nan.0 1)
FALSE

(<= 1 +nan.0)
FALSE

(>= +nan.0 1)
FALSE

;;; --- 超越関数（21日目）。
;;; **libm の最後の桁に依存する値をゴールデンに置かない。** 移植先で libm が
;;; 変われば落ちる。正確に表せる値と、誤差の範囲で見る形だけを固定する。

(exp 0)
1.0

(log 1)
0.0

(log 0)
-inf.0

(log -1)
+nan.0

(sin 0)
0.0

(cos 0)
1.0

(atan 0)
0.0

(asin 2)
+nan.0

(< (abs (- (* 4 (atan 1)) 3.141592653589793)) 1e-15)
TRUE

(< (abs (- (exp 1) 2.718281828459045)) 1e-15)
TRUE

(< (abs (- (log (exp 1)) 1)) 1e-15)
TRUE

(< (abs (- (+ (* (sin 1) (sin 1)) (* (cos 1) (cos 1))) 1)) 1e-15)
TRUE

(< (abs (- (atan 1 1) (atan 1))) 1e-15)
TRUE

;;; --- list-tail / list-ref ---

(list-tail '(a b c) 0)
(A B C)

(list-tail '(a b c) 1)
(B C)

(list-tail '(a b c) 3)
NIL

(list-ref '(a b c) 0)
A

(list-ref '(a b c) 2)
C

;;; --- member / assoc は equal? で比べる（memq/assq は eq?）---

(member 2 '(1 2 3))
(2 3)

(member 9 '(1 2 3))
FALSE

(member '(a) '((x) (a) (b)))
((A) (B))

(assoc 2 '((1 a) (2 b)))
(2 B)

(assoc 9 '((1 a)))
FALSE

(assoc '(k) '(((k) 1)))
((K) 1)

;;; --- 文字は長さ1の文字列（§2.2）---

(string "a" "b" "c")
"abc"

(string)
""

(string-copy "hello")
"hello"

(string-fill! (make-string 3 "x") "z")
:undef

(let ((s (make-string 3 "x"))) (string-fill! s "z") s)
"zzz"

;;; --- ベクタ ---

(vector-fill! (make-vector 3 0) 7)
:undef

(let ((v (make-vector 3 0))) (vector-fill! v 7) v)
#(7 7 7)

;;; --- 多値（13日目の決定58）---
;;; 1個のときは箱に入れない。#<values ...> は読み戻せないので、
;;; 箱そのものは %values->list を通して確かめる（表示は --selftest が押さえる）。

(values 5)
5

(%values->list (values 1 2))
(1 2)

(%values->list 7)
(7)

(%values->list (values))
NIL

(call-with-values (lambda () (values 4 5)) (lambda (a b) b))
5

(call-with-values (lambda () (values 1 2 3)) list)
(1 2 3)

(call-with-values (lambda () 7) list)
(7)

(call-with-values (lambda () (values)) list)
NIL

; R5RS 6.4 の例。(*) は 1 なので (- 1) で -1
(call-with-values * -)
-1

;;; --- dynamic-wind（13日目の決定59）---

(define wind-log '())
wind-log

(define wind-note (lambda (x) (set! wind-log (cons x wind-log))))
wind-note

(define wind-reset (lambda () (set! wind-log '())))
wind-reset

;;; 普通に通れば before → thunk → after の順

(dynamic-wind (lambda () (wind-note 'in))
              (lambda () 42)
              (lambda () (wind-note 'out)))
42

(reverse wind-log)
(in out)

;;; 脱出しても after は走る

(wind-reset)
NIL

(call/cc (lambda (esc)
  (dynamic-wind (lambda () (wind-note 'in))
                (lambda () (esc 'escaped) (wind-note 'NEVER))
                (lambda () (wind-note 'out)))))
escaped

(reverse wind-log)
(in out)

;;; 入れ子の脱出は内側の after から

(wind-reset)
NIL

(call/cc (lambda (esc)
  (dynamic-wind (lambda () (wind-note 'a-in))
    (lambda () (dynamic-wind (lambda () (wind-note 'b-in))
                             (lambda () (esc 'deep))
                             (lambda () (wind-note 'b-out))))
    (lambda () (wind-note 'a-out)))))
deep

(reverse wind-log)
(a-in b-in b-out a-out)

;;; before の中で脱出したら after は走らない（枠を積む前だから）

(wind-reset)
NIL

(call/cc (lambda (esc)
  (dynamic-wind (lambda () (wind-note 'b) (esc 'from-before))
                (lambda () (wind-note 'THUNK))
                (lambda () (wind-note 'AFTER)))))
from-before

(reverse wind-log)
(b)

;;; 再入すると before がもう一度走る

(wind-reset)
NIL

(let ((k #f) (n 0))
  (dynamic-wind (lambda () (wind-note 'before))
                (lambda () (call/cc (lambda (c) (set! k c))) (set! n (+ n 1)))
                (lambda () (wind-note 'after)))
  (if (< n 2) (k #f))
  n)
2

(reverse wind-log)
(before after before after)

;;; R5RS 6.4 の例そのもの

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
(connect talk1 disconnect connect talk2 disconnect)

(test-end)
