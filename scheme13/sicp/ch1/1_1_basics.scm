; SICP 1.1「プログラムの要素」を scheme13 で確認する。
;   1.1.1 式 / 1.1.2 名前と環境 / 1.1.3 組み合わせの評価
;   1.1.4 合成手続き / 1.1.6 条件式と述語
;   1.1.7 例: ニュートン法による平方根 / 1.1.8 ブラックボックスとしての抽象
;
; 書籍のコードをそのまま写すのではなく、同じ主題を自分で書いた検証コード。
; ただし 1.1.7 の平方根だけは、書籍が本文に印字している値と桁まで一致するかを
; 見たいので、書籍と同じ手順・同じ初期値 1.0・同じ許容誤差 0.001 で書いてある。

(define ng-count 0)
(define total-count 0)
(define (check label expr expected)
  (set! total-count (+ total-count 1))
  (if (equal? expr expected)
      (begin (display "ok   ") (display label) (newline))
      (begin (set! ng-count (+ ng-count 1))
             (display "NG   ") (display label)
             (display "  got=") (write expr)
             (display " want=") (write expected) (newline))))
(define (summary name)
  (display "=== ") (display name)
  (display "  total: ") (display total-count)
  (display "  NG: ") (display ng-count) (display " ===") (newline))

; --- 1.1.1 式: 素の数と組み合わせ ---
(check "486"            486                     486)
(check "(+ 137 349)"    (+ 137 349)             486)
(check "(- 1000 334)"   (- 1000 334)            666)
(check "(* 5 99)"       (* 5 99)                495)
(check "(/ 10 5)"       (/ 10 5)                2)
(check "(+ 2.7 10)"     (+ 2.7 10)              12.7)   ; 整数と実数の混合 → 実数
(check "可変長の +"     (+ 21 35 12 7)          75)
(check "可変長の *"     (* 25 4 12)             1200)
(check "入れ子の組み合わせ" (+ (* 3 5) (- 10 6)) 19)
(check "深い入れ子"     (+ (* 3 (+ (* 2 4) (+ 3 5))) (+ (- 10 7) 6)) 57)

; --- 1.1.2 名前と環境 ---
(define size 2)
(check "define した名前" size 2)
(check "名前を使う式"   (* 5 size) 10)
(define pi 3.14159)
(define radius 10)
(check "円の面積"       (* pi (* radius radius)) 314.159)
(define circumference (* 2 pi radius))
(check "円周"           circumference 62.8318)

; --- 1.1.4 合成手続き ---
(define (square x) (* x x))
(define (sum-of-squares x y) (+ (square x) (square y)))
(define (f a) (sum-of-squares (+ a 1) (* a 2)))

(check "square 21"        (square 21)          441)
(check "square の合成"    (square (+ 2 5))     49)
(check "square (square 3)" (square (square 3)) 81)
(check "sum-of-squares"   (sum-of-squares 3 4) 25)
(check "f 5"              (f 5)                136)

; --- 1.1.6 条件式と述語 ---
(define (abs-cond x)
  (cond ((> x 0) x)
        ((= x 0) 0)
        ((< x 0) (- x))))
(define (abs-else x)
  (cond ((< x 0) (- x))
        (else x)))
(define (abs-if x)
  (if (< x 0) (- x) x))

(check "abs-cond -5"  (abs-cond -5) 5)
(check "abs-cond 0"   (abs-cond 0)  0)
(check "abs-cond 5"   (abs-cond 5)  5)
(check "abs-else -5"  (abs-else -5) 5)
(check "abs-if -5"    (abs-if -5)   5)
(check "abs-if 実数"  (abs-if -2.5) 2.5)
(check "組み込みの abs" (abs -7) 7)

; and / or / not と、それらで作る >=
(define (>=-or  x y) (or (> x y) (= x y)))
(define (>=-not x y) (not (< x y)))
(define (between? x lo hi) (and (> x lo) (< x hi)))

(check ">=-or  等しいとき"  (>=-or 5 5)  #t)
(check ">=-not 小さいとき"  (>=-not 4 5) #f)
(check "between? 中"        (between? 5 1 10) #t)
(check "between? 外"        (between? 15 1 10) #f)
(check "or は最初の真値を返す" (or #f #f 3) 3)
(check "and は最後の値を返す"  (and 1 2 3) 3)
(check "and は偽で止まる"      (and 1 #f (car '())) #f)  ; 短絡しなければエラーになる
(check "not"                   (not (= 1 2)) #t)

; --- 1.1.7 ニュートン法による平方根 ---
; 書籍と同じ定義。scheme13 は 22日目に実数を持ったので、書き写したまま動く。
(define (average x y) (/ (+ x y) 2))
(define (improve guess x) (average guess (/ x guess)))
(define (good-enough? guess x) (< (abs (- (square guess) x)) 0.001))
(define (sqrt-iter guess x)
  (if (good-enough? guess x)
      guess
      (sqrt-iter (improve guess x) x)))
(define (my-sqrt x) (sqrt-iter 1.0 x))

; 期待値は書籍が本文に印字している数そのもの。倍精度の桁まで一致する。
(check "my-sqrt 9"              (my-sqrt 9)                 3.00009155413138)
(check "my-sqrt (+ 100 37)"     (my-sqrt (+ 100 37))        11.704699917758145)
(check "my-sqrt の入れ子"       (my-sqrt (+ (my-sqrt 2) (my-sqrt 3))) 1.7739279023207892)
(check "square (my-sqrt 1000)"  (square (my-sqrt 1000))     1000.000369924366)

; 整数を渡しても実数が返る（初期値 1.0 が実数なので、正確さが伝播する）
(check "my-sqrt 9 は非正確"     (inexact? (my-sqrt 9))      #t)
(check "組み込みの sqrt は正確を保つ" (sqrt 16)             4)
(check "組み込みの sqrt 2"      (sqrt 2)                    1.4142135623730951)

; --- 1.1.8 ブラックボックス抽象: 内部定義とレキシカルスコープ ---
; x を内側の手続きの引数で渡さず、囲みの束縛を捕まえる版（書籍の「ブロック構造」）。
(define (sqrt2 x)
  (define (good-enough? guess) (< (abs (- (square guess) x)) 0.001))
  (define (improve guess) (average guess (/ x guess)))
  (define (iter guess)
    (if (good-enough? guess) guess (iter (improve guess))))
  (iter 1.0))

(check "ブロック構造版が同じ値" (sqrt2 9) (my-sqrt 9))
(check "ブロック構造版 137"     (sqrt2 137) (my-sqrt 137))

; 内部定義は外に漏れない（good-enough? / improve は 2引数の大域版のまま）
(check "内部定義は大域を覆わない" (good-enough? 3.00009155413138 9) #t)
(check "大域の improve は2引数"   (improve 1.0 4) 2.5)

; 引数名の遮蔽（レキシカルスコープ）
(define (outer x) (define (inner x) (* x 10)) (+ x (inner 3)))
(check "内側の x は外側を隠す" (outer 1) 31)

(summary "SICP 1.1")
