; SICP 3.5「ストリーム」を scheme13 で確認する。
;   3.5.1 遅延リストとしてのストリーム / 3.5.2 無限ストリーム
;   3.5.3 ストリームパラダイムの利用 / 3.5.4 ストリームと遅延評価
;
; 処理系側で問われるのは
;   - `delay` / `force` が**値を覚える**こと（memo-proc）。覚えないと
;     無限ストリームの計算量が指数的に膨らみ、この節は成立しない
;   - `define-macro` で `cons-stream` のような特殊形式を作れること
;   - 相互に参照し合う大域定義（`integers` が自分自身を使う）が書けること
;
; scheme13 の `delay` は system_lib.scm にあり、`make-promise` を通して
; 値を1度だけ計算して覚える。**書籍が要求する memo-proc がすでに入っている。**
; （注: ここの `make-promise` は R7RS のもの（値を取る）ではなく、
;   `delay` 用の内部ヘルパ（thunk を取る）である。）

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

; --- 3.5.1 遅延リストとしてのストリーム ---
; cons-stream は特殊形式でなければならない（第2引数を評価してはいけない）
(define-macro (cons-stream a b) (list 'cons a (list 'delay b)))

(define the-empty-stream '())
(define (stream-null? s) (null? s))
(define (stream-car s) (car s))
(define (stream-cdr s) (force (cdr s)))

(define (stream-ref s n)
  (if (= n 0) (stream-car s) (stream-ref (stream-cdr s) (- n 1))))
(define (stream-map proc s)
  (if (stream-null? s)
      the-empty-stream
      (cons-stream (proc (stream-car s)) (stream-map proc (stream-cdr s)))))
(define (stream-filter pred s)
  (cond ((stream-null? s) the-empty-stream)
        ((pred (stream-car s))
         (cons-stream (stream-car s) (stream-filter pred (stream-cdr s))))
        (else (stream-filter pred (stream-cdr s)))))
(define (stream-for-each proc s)
  (if (stream-null? s)
      'done
      (begin (proc (stream-car s)) (stream-for-each proc (stream-cdr s)))))
(define (stream-enumerate-interval low high)
  (if (> low high)
      the-empty-stream
      (cons-stream low (stream-enumerate-interval (+ low 1) high))))
(define (stream-head s n)
  (if (= n 0) '() (cons (stream-car s) (stream-head (stream-cdr s) (- n 1)))))

; 遅延の証拠: cdr は要求されるまで作られない
(define built '())
(define (note x) (set! built (cons x built)) x)
(define lazy (cons-stream (note 1) (cons-stream (note 2) (cons-stream (note 3) '()))))
(check "先頭だけが作られている"   (reverse built) '(1))
(check "1つ進めると2番目が作られる"
       (begin (stream-car (stream-cdr lazy)) (reverse built)) '(1 2))
(check "3番目はまだ"              (memq 3 built) #f)

; 記憶化: 2度目の force で再計算しない（書籍の memo-proc）
(define eval-count 0)
(define memo-s (cons-stream 'head (begin (set! eval-count (+ eval-count 1)) 'tail)))
(check "1度目の force"  (stream-cdr memo-s) 'tail)
(check "2度目も同じ値"  (stream-cdr memo-s) 'tail)
(check "計算されたのは1度だけ" eval-count 1)

(define s1 (stream-enumerate-interval 1 5))
(check "stream-car"     (stream-car s1) 1)
(check "stream-ref 3"   (stream-ref s1 3) 4)
(check "有限ストリーム" (stream-head s1 5) '(1 2 3 4 5))
(check "stream-map"     (stream-head (stream-map square s1) 5) '(1 4 9 16 25))
(check "stream-filter"  (stream-head (stream-filter odd? s1) 3) '(1 3 5))
(check "空ストリーム"   (stream-null? the-empty-stream) #t)
(check "for-each は左から"
       (let ((acc '()))
         (stream-for-each (lambda (x) (set! acc (cons x acc))) s1)
         (reverse acc))
       '(1 2 3 4 5))

; 2.2.3 の「公認インターフェース」と同じ形が、ストリームでも書ける
(define (sum-primes-stream a b)
  (define (prime? n)
    (define (iter d) (cond ((> (square d) n) #t) ((= 0 (remainder n d)) #f)
                           (else (iter (+ d 1)))))
    (and (> n 1) (iter 2)))
  (let loop ((s (stream-filter prime? (stream-enumerate-interval a b))) (acc 0))
    (if (stream-null? s) acc (loop (stream-cdr s) (+ acc (stream-car s))))))
(check "10〜20 の素数の和" (sum-primes-stream 10 20) 60)   ; 11+13+17+19

; --- 3.5.2 無限ストリーム ---
(define (integers-starting-from n) (cons-stream n (integers-starting-from (+ n 1))))
(define integers (integers-starting-from 1))
(check "整数の 0番目"    (stream-ref integers 0) 1)
(check "整数の 100番目"  (stream-ref integers 100) 101)

(define (divisible? x y) (= (remainder x y) 0))
(define no-sevens (stream-filter (lambda (x) (not (divisible? x 7))) integers))
(check "7の倍数を除いた 100番目" (stream-ref no-sevens 100) 117)  ; 書籍の値

(define (fibgen a b) (cons-stream a (fibgen b (+ a b))))
(define fibs (fibgen 0 1))
(check "フィボナッチの先頭10個" (stream-head fibs 10) '(0 1 1 2 3 5 8 13 21 34))
(check "フィボナッチ 100番目"   (stream-ref fibs 100) 354224848179261915075)

; エラトステネスの篩
(define (sieve stream)
  (cons-stream (stream-car stream)
               (sieve (stream-filter
                       (lambda (x) (not (divisible? x (stream-car stream))))
                       (stream-cdr stream)))))
(define primes (sieve (integers-starting-from 2)))
(check "素数の先頭10個" (stream-head primes 10) '(2 3 5 7 11 13 17 19 23 29))
(check "素数の 50番目"  (stream-ref primes 50) 233)          ; 書籍の値

; 自分自身を使って定義するストリーム（暗黙の定義）
(define (add-streams s1 s2)
  (cond ((stream-null? s1) s2)
        ((stream-null? s2) s1)
        (else (cons-stream (+ (stream-car s1) (stream-car s2))
                           (add-streams (stream-cdr s1) (stream-cdr s2))))))
(define (scale-stream stream factor)
  (stream-map (lambda (x) (* x factor)) stream))
(define ones (cons-stream 1 ones))
(define integers2 (cons-stream 1 (add-streams ones integers2)))
(check "ones は無限に 1"       (stream-head ones 4) '(1 1 1 1))
(check "暗黙の定義の整数"      (stream-head integers2 5) '(1 2 3 4 5))
(check "2つの整数列は一致"     (stream-ref integers2 200) (stream-ref integers 200))

(define fibs2 (cons-stream 0 (cons-stream 1 (add-streams (stream-cdr fibs2) fibs2))))
(check "暗黙の定義のフィボナッチ" (stream-head fibs2 10) '(0 1 1 2 3 5 8 13 21 34))

(define double (cons-stream 1 (scale-stream double 2)))
(check "2の冪"                 (stream-head double 8) '(1 2 4 8 16 32 64 128))

; --- 3.5.3 ストリームパラダイムの利用 ---
(define (partial-sums s)
  (cons-stream (stream-car s) (add-streams (stream-cdr s) (partial-sums s))))
(check "部分和" (stream-head (partial-sums integers) 6) '(1 3 6 10 15 21))

; 平方根をストリームで（1.1.7 と同じ漸化式を、列として見る）
(define (average x y) (/ (+ x y) 2))
(define (sqrt-improve guess x) (average guess (/ x guess)))
(define (sqrt-stream x)
  (define guesses (cons-stream 1.0 (stream-map (lambda (guess) (sqrt-improve guess x))
                                               guesses)))
  guesses)
(check~ "平方根の列は収束する" (stream-ref (sqrt-stream 2) 5) 1.4142135623730951 1e-12)
(check "最初の項は 1.0"        (stream-ref (sqrt-stream 2) 0) 1.0)

; π の級数と、オイラー変換による加速
(define (pi-summands n)
  (cons-stream (/ 1.0 n) (stream-map - (pi-summands (+ n 2)))))
(define pi-stream (scale-stream (partial-sums (pi-summands 1)) 4))
(check "π の級数の先頭" (stream-ref pi-stream 0) 4.0)
(check~ "3項目"         (stream-ref pi-stream 2) 3.466666666666667 1e-12)
(check~ "遅い収束"      (stream-ref pi-stream 20) 3.141592653589793 0.05)

(define (euler-transform s)
  (let ((s0 (stream-ref s 0)) (s1 (stream-ref s 1)) (s2 (stream-ref s 2)))
    (cons-stream (- s2 (/ (square (- s2 s1)) (+ s0 (* -2 s1) s2)))
                 (euler-transform (stream-cdr s)))))
; 6項目での誤差は、元の級数が約 0.17、オイラー変換が約 7e-4。
; **「速い」は同じ項数での近さで言う。** 絶対値の許容誤差だけで書くと、
; どれくらい速いのかが主張に出ない。
(check~ "オイラー変換 6項目"
        (stream-ref (euler-transform pi-stream) 5) 3.141592653589793 1e-3)
(check "同じ項数で元の級数よりはるかに近い"
       (< (abs (- (stream-ref (euler-transform pi-stream) 5) 3.141592653589793))
          (/ (abs (- (stream-ref pi-stream 5) 3.141592653589793)) 100))
       #t)

(define (make-tableau transform s) (cons-stream s (make-tableau transform (transform s))))
(define (accelerated-sequence transform s)
  (stream-map stream-car (make-tableau transform s)))
(check~ "加速の加速は8項で倍精度の限界まで届く"
        (stream-ref (accelerated-sequence euler-transform pi-stream) 7)
        3.141592653589793 1e-13)

; 対の列（無限ストリームの組み合わせ）
(define (interleave s1 s2)
  (if (stream-null? s1)
      s2
      (cons-stream (stream-car s1) (interleave s2 (stream-cdr s1)))))
(define (stream-append s1 s2)
  (if (stream-null? s1)
      s2
      (cons-stream (stream-car s1) (stream-append (stream-cdr s1) s2))))
(check "交互に混ぜる"
       (stream-head (interleave integers (scale-stream integers 10)) 6)
       '(1 10 2 20 3 30))
(define (pairs s t)
  (cons-stream (list (stream-car s) (stream-car t))
               (interleave (stream-map (lambda (x) (list (stream-car s) x))
                                       (stream-cdr t))
                           (pairs (stream-cdr s) (stream-cdr t)))))
(check "対の列は最初の対から始まる"
       (stream-car (pairs integers integers)) '(1 1))
(check "対の列は無限に続く（10個取れる）"
       (length (stream-head (pairs integers integers) 10)) 10)
(check "取り出した対はすべて i<=j"
       (map (lambda (p) (<= (car p) (cadr p)))
            (stream-head (pairs integers integers) 10))
       '(#t #t #t #t #t #t #t #t #t #t))

; --- 3.5.4 遅延評価が要る場面 ---
; 積分器は「自分の出力を入力に使う」ので、入力を遅らせないと定義できない
(define (integral delayed-integrand initial-value dt)
  (define int
    (cons-stream initial-value
                 (let ((integrand (force delayed-integrand)))
                   (add-streams (scale-stream integrand dt) int))))
  int)
(define (solve f y0 dt)
  (define y (integral (delay dy) y0 dt))
  (define dy (stream-map f y))
  y)
; dy/dt = y、y(0)=1 の解は e^t。t=1 での値は e に近づく
(check~ "微分方程式を解いて e を得る"
        (stream-ref (solve (lambda (y) y) 1.0 0.001) 1000)
        2.718281828459045 0.005)
(check "解の先頭は初期値" (stream-ref (solve (lambda (y) y) 1.0 0.001) 0) 1.0)

(summary "SICP 3.5")
