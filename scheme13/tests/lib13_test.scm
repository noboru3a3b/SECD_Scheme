; lib13.scm（scheme13 が足す R5RS 手続き）の回帰テスト。
;
; 原典のテスト機構（6日目に復活させたもの）を使う。式の次の行が期待する
; write 表現で、大小文字は無視して照合される（決定30）。
;
;   scheme13/tests/run_golden.sh がこれを走らせ、出力全体をゴールデンと
;   バイト単位で比べる。--selftest では見られない（あちらはライブラリを
;   読む前に走る C++ 単体の回帰なので）。

(test-start)
TRUE

;;; --- 数値の述語（整数しか無いので数値塔はすべて「整数か」に潰れる）---

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

;;; --- sqrt は平方根の整数部（不正確な数が無いので）---

(sqrt 0)
0

(sqrt 1)
1

(sqrt 2)
1

(sqrt 16)
4

(sqrt 17)
4

(sqrt 24)
4

(sqrt 25)
5

(sqrt 9999999999800000000001)
99999999999

;;; --- 丸めは整数では恒等 ---

(floor 5)
5

(ceiling -5)
-5

(truncate 5)
5

(round -5)
-5

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

(test-end)
