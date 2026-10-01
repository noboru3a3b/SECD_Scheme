; SICP 1.3「高階手続きによる抽象」を scheme13 で確認する。
;   1.3.1 引数としての手続き / 1.3.2 lambda と let
;   1.3.3 一般的手法としての手続き / 1.3.4 返り値としての手続き
;
; この節は書籍の中でも実数への依存が最も強い（数値積分・区間二分法・不動点・
; 数値微分）。scheme13 は 18〜22日目に倍精度実数を持ったので、
; 書籍の手順をそのまま書ける。期待値には書籍が本文に印字している数を使い、
; 倍精度の桁まで一致するかを見る。

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
; 実数の近さを見る版。libm の実装差が最終桁に出る場合に使う。
(define (check~ label expr expected eps)
  (set! total-count (+ total-count 1))
  (if (< (abs (- expr expected)) eps)
      (begin (display "ok   ") (display label) (newline))
      (begin (set! ng-count (+ ng-count 1))
             (display "NG   ") (display label)
             (display "  got=") (write expr)
             (display " want=") (write expected) (newline))))
(define (summary name)
  (display "=== ") (display name)
  (display "  total: ") (display total-count)
  (display "  NG: ") (display ng-count) (display " ===") (newline))

(define (square x) (* x x))
(define (cube x) (* x x x))
(define (average x y) (/ (+ x y) 2))
(define (inc n) (+ n 1))
(define (identity x) x)

; --- 1.3.1 引数としての手続き ---
(define (sum term a next b)
  (if (> a b) 0 (+ (term a) (sum term (next a) next b))))

(define (sum-integers a b) (sum identity a inc b))
(define (sum-cubes a b) (sum cube a inc b))

(check "sum-integers 1..10" (sum-integers 1 10) 55)
(check "sum-cubes 1..10"    (sum-cubes 1 10) 3025)
(check "立方和 = 和の平方"  (sum-cubes 1 10) (square (sum-integers 1 10)))

; π/8 に収束する級数。書籍が本文に印字している値と一致するはず。
(define (pi-sum a b)
  (define (pi-term x) (/ 1.0 (* x (+ x 2))))
  (define (pi-next x) (+ x 4))
  (sum pi-term a pi-next b))
(check "(* 8 (pi-sum 1 1000))" (* 8 (pi-sum 1 1000)) 3.139592655589783)
(check~ "π に近い"            (* 8 (pi-sum 1 1000)) 3.141592653589793 0.01)

; 数値積分。dx を小さくすると 1/4 に近づく。
(define (integral f a b dx)
  (define (add-dx x) (+ x dx))
  (* (sum f (+ a (/ dx 2)) add-dx b) dx))
(check "(integral cube 0 1 0.01)"  (integral cube 0 1 0.01)  0.24998750000000042)
(check "(integral cube 0 1 0.001)" (integral cube 0 1 0.001) 0.249999875000001)
(check~ "積分値は 1/4 に近い"      (integral cube 0 1 0.001) 0.25 0.000001)

; 総和の双対としての総積（演習 1.31）
(define (product term a next b)
  (if (> a b) 1 (* (term a) (product term (next a) next b))))
(check "product で階乗"   (product identity 1 inc 6) 720)
; ウォリスの公式で π/4 に近づける
(define (wallis-pi n)
  (define (term k)
    (/ (* 2.0 k (* 2 k)) (* (- (* 2 k) 1) (+ (* 2 k) 1))))
  (* 2 (product term 1 inc n)))
(check~ "ウォリス積 1000項が π に近い" (wallis-pi 1000) 3.141592653589793 0.001)

; sum と product をさらに一般化した accumulate（演習 1.32）
(define (accumulate combiner null-value term a next b)
  (if (> a b)
      null-value
      (combiner (term a) (accumulate combiner null-value term (next a) next b))))
(check "accumulate で和"   (accumulate + 0 identity 1 inc 10) 55)
(check "accumulate で積"   (accumulate * 1 identity 1 inc 6)  720)
(check "accumulate は sum と一致" (accumulate + 0 cube 1 inc 10) (sum-cubes 1 10))

; --- 1.3.2 lambda と let ---
(check "lambda を直に適用" ((lambda (x y) (+ x y (square x))) 3 4) 16)
(check "sum に lambda を渡す"
       (sum (lambda (x) (* x x)) 1 (lambda (x) (+ x 1)) 5) 55)

(define (f-with-let x y)
  (let ((a (+ 1 (* x y)))
        (b (- 1 y)))
    (+ (* x (square a)) (* y b) (* a b))))
(check "let の版"    (f-with-let 3 4) 456)
(check "let は同時束縛"
       (let ((x 5)) (let ((x 3) (y x)) (+ x y))) 8)   ; y は外側の 5
(check "let* は逐次束縛"
       (let ((x 5)) (let* ((x 3) (y x)) (+ x y))) 6)  ; y は内側の 3
(check "名前つき let で反復"
       (let loop ((i 0) (acc 0)) (if (= i 5) acc (loop (+ i 1) (+ acc i)))) 10)

; --- 1.3.3 一般的手法としての手続き: 区間二分法 ---
(define (search f neg-point pos-point)
  (let ((midpoint (average neg-point pos-point)))
    (if (< (abs (- pos-point neg-point)) 0.001)
        midpoint
        (let ((test-value (f midpoint)))
          (cond ((> test-value 0) (search f neg-point midpoint))
                ((< test-value 0) (search f midpoint pos-point))
                (else midpoint))))))
(define (half-interval-method f a b)
  (let ((a-value (f a))
        (b-value (f b)))
    (cond ((and (< a-value 0) (> b-value 0)) (search f a b))
          ((and (< b-value 0) (> a-value 0)) (search f b a))
          (else (error "Values are not of opposite sign" a b)))))

(check "sin の零点を 2〜4 で挟む" (half-interval-method sin 2.0 4.0) 3.14111328125)
(check "x^3-2x-3 の根を 1〜2 で挟む"
       (half-interval-method (lambda (x) (- (* x x x) (* 2 x) 3)) 1.0 2.0)
       1.89306640625)
(check~ "sin の零点は π に近い" (half-interval-method sin 2.0 4.0) 3.141592653589793 0.001)

; --- 1.3.3 不動点 ---
(define tolerance 0.00001)
(define (fixed-point f first-guess)
  (define (close-enough? v1 v2) (< (abs (- v1 v2)) tolerance))
  (define (try guess)
    (let ((next (f guess)))
      (if (close-enough? guess next) next (try next))))
  (try first-guess))

; 書籍の値は 0.7390822985224023、この環境（glibc の cos）では …24。
; 1 ULP の差で、原因は libm 側。値そのものではなく近さで見る。
(check~ "cos の不動点" (fixed-point cos 1.0) 0.7390822985224023 1e-15)
(check "sin+cos の不動点"
       (fixed-point (lambda (y) (+ (sin y) (cos y))) 1.0) 1.2587315962971173)
; 不動点の判定は「連続する2つの推測が tolerance 以内」なので、f(x) と x の差も
; その程度までしか縮まない。1e-10 で比べるのは主張のほうが間違い。
(check~ "不動点は f(x)=x をほぼ満たす"
       (cos (fixed-point cos 1.0)) (fixed-point cos 1.0) tolerance)

; 平均減衰つきの不動点としての平方根
(define (average-damp f) (lambda (x) (average x (f x))))
(check "((average-damp square) 10)" ((average-damp square) 10) 55)
(define (sqrt-fp x) (fixed-point (average-damp (lambda (y) (/ x y))) 1.0))
(define (cube-root x) (fixed-point (average-damp (lambda (y) (/ x (square y)))) 1.0))
(check~ "不動点版 sqrt 2"   (sqrt-fp 2)   (sqrt 2)   0.0001)
(check~ "不動点版 sqrt 137" (sqrt-fp 137) (sqrt 137) 0.0001)
(check~ "cube-root 27"      (cube-root 27) 3.0       0.0001)
(check~ "cube-root 2"       (cube-root 2) 1.2599210498948732 0.0001)

; 減衰なしでは振動して収束しない（書籍が減衰を導入する理由）。
; 100 回で止めて、振動していることを確かめる。
(define (oscillates? x)
  (define (loop g n prev)
    (cond ((= n 0) #t)
          ((< (abs (- g prev)) tolerance) #f)
          (else (loop (/ x g) (- n 1) g))))
  (loop 1.0 100 0.0))
(check "減衰なしの y↦x/y は収束しない" (oscillates? 2.0) #t)

; --- 1.3.4 返り値としての手続き: ニュートン法 ---
(define dx 0.00001)
(define (deriv g) (lambda (x) (/ (- (g (+ x dx)) (g x)) dx)))
(check "((deriv cube) 5)" ((deriv cube) 5) 75.00014999664018)
(check~ "cube の微分は 3x^2" ((deriv cube) 5) 75.0 0.001)

(define (newton-transform g) (lambda (x) (- x (/ (g x) ((deriv g) x)))))
(define (newtons-method g guess) (fixed-point (newton-transform g) guess))
(define (sqrt-newton x) (newtons-method (lambda (y) (- (square y) x)) 1.0))
(check~ "ニュートン法の sqrt 2"   (sqrt-newton 2)   (sqrt 2)   0.0001)
(check~ "ニュートン法の sqrt 137" (sqrt-newton 137) (sqrt 137) 0.0001)

; 抽象を一段上げる: 変換した関数の不動点を求める、という枠組み
(define (fixed-point-of-transform g transform guess)
  (fixed-point (transform g) guess))
(define (sqrt-t1 x) (fixed-point-of-transform (lambda (y) (/ x y)) average-damp 1.0))
(define (sqrt-t2 x) (fixed-point-of-transform (lambda (y) (- (square y) x))
                                              newton-transform 1.0))
(check "枠組み版1 は不動点版と同じ" (sqrt-t1 2) (sqrt-fp 2))
(check "枠組み版2 はニュートン版と同じ" (sqrt-t2 2) (sqrt-newton 2))

; 手続きを返す手続きの基本形（演習 1.42〜1.44）
(define (compose f g) (lambda (x) (f (g x))))
(check "((compose square inc) 6)" ((compose square inc) 6) 49)

(define (repeated f n)
  (if (= n 1) f (compose f (repeated f (- n 1)))))
(check "((repeated square 2) 5)" ((repeated square 2) 5) 625)
(check "((repeated inc 10) 0)"   ((repeated inc 10) 0) 10)

(define (double f) (lambda (x) (f (f x))))
(check "double inc"                ((double inc) 5) 7)
(check "double double inc"         (((double double) inc) 5) 9)
(check "double (double double) inc" (((double (double double)) inc) 5) 21)

(define (smooth f)
  (lambda (x) (/ (+ (f (- x dx)) (f x) (f (+ x dx))) 3)))
(check~ "平滑化しても square はほぼ同じ" ((smooth square) 3.0) 9.0 0.0001)
(check~ "n重平滑化"                      (((repeated smooth 3) square) 3.0) 9.0 0.0001)

(summary "SICP 1.3")
