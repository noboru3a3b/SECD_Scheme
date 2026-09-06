; SICP 1.2「手続きとそれが生成するプロセス」を scheme13 で確認する。
;   1.2.1 線形再帰と反復 / 1.2.2 木構造再帰 / 1.2.3 増加の程度
;   1.2.4 べき乗 / 1.2.5 最大公約数 / 1.2.6 例: 素数性の判定
;
; この節の主題は「同じ関数を、再帰的プロセスと反復的プロセスの両方で書き、
; 結果が一致すること」。処理系側で問われるのは
;   - 末尾呼び出しが本当にスタックを伸ばさないか（反復版が深さで落ちないか）
;   - fixnum から bignum への昇格が値をずらさないか
; の2点なので、そこを明示的に見る。

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

(define (square x) (* x x))

; --- 1.2.1 線形再帰と線形反復 ---
(define (fact-rec n)
  (if (= n 1) 1 (* n (fact-rec (- n 1)))))

(define (fact-iter n)
  (define (iter product counter)
    (if (> counter n) product (iter (* counter product) (+ counter 1))))
  (iter 1 1))

(check "fact-rec 10"   (fact-rec 10)  3628800)
(check "fact-iter 10"  (fact-iter 10) 3628800)
(check "両者が一致 25" (fact-rec 25)  (fact-iter 25))
(check "20! は fixnum の縁"  (fact-iter 20) 2432902008176640000)
(check "21! は bignum へ昇格" (fact-iter 21) 51090942171709440000)
(check "昇格しても整数のまま" (integer? (fact-iter 21)) #t)
(check "100! の桁数"
       (string-length (number->string (fact-iter 100))) 158)

; 反復的プロセスは定数空間で走る。10万段でも落ちないことが末尾呼び出しの証拠。
(define (count-down n acc) (if (= n 0) acc (count-down (- n 1) (+ acc 1))))
(check "末尾呼び出し 10万段" (count-down 100000 0) 100000)

; --- 1.2.2 木構造再帰: フィボナッチ ---
(define (fib-rec n)
  (cond ((= n 0) 0)
        ((= n 1) 1)
        (else (+ (fib-rec (- n 1)) (fib-rec (- n 2))))))

(define (fib-iter n)
  (define (iter a b count)
    (if (= count 0) b (iter (+ a b) a (- count 1))))
  (iter 1 0 n))

(check "fib-rec 10"    (fib-rec 10)  55)
(check "fib-iter 10"   (fib-iter 10) 55)
(check "両者が一致 20" (fib-rec 20)  (fib-iter 20))
(check "fib-iter 100 は bignum" (fib-iter 100) 354224848179261915075)

; 硬貨の両替（木構造再帰の例）。書籍が本文で示す 292 になる。
(define (first-denomination kinds-of-coins)
  (cond ((= kinds-of-coins 1) 1)
        ((= kinds-of-coins 2) 5)
        ((= kinds-of-coins 3) 10)
        ((= kinds-of-coins 4) 25)
        ((= kinds-of-coins 5) 50)))
(define (cc amount kinds-of-coins)
  (cond ((= amount 0) 1)
        ((or (< amount 0) (= kinds-of-coins 0)) 0)
        (else (+ (cc amount (- kinds-of-coins 1))
                 (cc (- amount (first-denomination kinds-of-coins))
                     kinds-of-coins)))))
(define (count-change amount) (cc amount 5))

(check "count-change 100" (count-change 100) 292)
(check "count-change 11"  (count-change 11)  4)

; 演習 1.10 のアッカーマン関数（木構造再帰の増加の程度）
(define (A x y)
  (cond ((= y 0) 0)
        ((= x 0) (* 2 y))
        ((= y 1) 2)
        (else (A (- x 1) (A x (- y 1))))))
(check "(A 1 10)" (A 1 10) 1024)
(check "(A 2 4)"  (A 2 4)  65536)
(check "(A 3 3)"  (A 3 3)  65536)

; --- 1.2.4 べき乗 ---
(define (expt-rec b n)
  (if (= n 0) 1 (* b (expt-rec b (- n 1)))))
(define (expt-iter b n)
  (define (iter counter product)
    (if (= counter 0) product (iter (- counter 1) (* b product))))
  (iter n 1))
(define (fast-expt b n)
  (cond ((= n 0) 1)
        ((even? n) (square (fast-expt b (quotient n 2))))
        (else (* b (fast-expt b (- n 1))))))

(check "expt-rec 2^10"    (expt-rec 2 10)  1024)
(check "expt-iter 2^10"   (expt-iter 2 10) 1024)
(check "fast-expt 2^10"   (fast-expt 2 10) 1024)
(check "fast-expt 3^0"    (fast-expt 3 0)  1)
(check "2^100 が3通りで一致" (fast-expt 2 100) (expt-iter 2 100))
(check "組み込み expt と一致" (fast-expt 2 100) (expt 2 100))
(check "実数の底"          (fast-expt 1.5 4) 5.0625)
(check "組み込み expt 実数" (expt 2 0.5) 1.4142135623730951)

; --- 1.2.5 最大公約数（ユークリッドの互除法）---
(define (my-gcd a b) (if (= b 0) a (my-gcd b (remainder a b))))
(check "gcd 206 40"       (my-gcd 206 40) 2)
(check "組み込みと一致"   (my-gcd 1071 462) (gcd 1071 462))
(check "互いに素"         (my-gcd 17 13) 1)
(check "bignum の gcd"    (my-gcd (fast-expt 2 64) (fast-expt 2 40)) (fast-expt 2 40))

; --- 1.2.6 素数性の判定 ---
(define (divides? a b) (= (remainder b a) 0))
(define (find-divisor n test-divisor)
  (cond ((> (square test-divisor) n) n)
        ((divides? test-divisor n) test-divisor)
        (else (find-divisor n (+ test-divisor 1)))))
(define (smallest-divisor n) (find-divisor n 2))
(define (prime? n) (= n (smallest-divisor n)))

(check "smallest-divisor 199"   (smallest-divisor 199)   199)
(check "smallest-divisor 1999"  (smallest-divisor 1999)  1999)
(check "smallest-divisor 19999" (smallest-divisor 19999) 7)
(check "prime? 97"  (prime? 97) #t)
(check "prime? 91"  (prime? 91) #f)   ; 91 = 7*13
(check "prime? 2"   (prime? 2)  #t)

; フェルマーテスト
(define (expmod base exp m)
  (cond ((= exp 0) 1)
        ((even? exp) (remainder (square (expmod base (quotient exp 2) m)) m))
        (else (remainder (* base (expmod base (- exp 1) m)) m))))
(define (fermat-test n)
  (define (try-it a) (= (expmod a n n) a))
  (try-it (+ 1 (random (- n 1)))))
(define (fast-prime? n times)
  (cond ((= times 0) #t)
        ((fermat-test n) (fast-prime? n (- times 1)))
        (else #f)))

(check "expmod 2^10 mod 1000"   (expmod 2 10 1000) 24)
(check "expmod = 素朴な計算"    (expmod 3 7 5) (remainder (fast-expt 3 7) 5))
(check "expmod 大きな法"        (expmod 7 1000000 1000000007)
                                (remainder (fast-expt 7 1000000) 1000000007))
; 乱数を使うので結果そのものは主張にしにくいが、素数なら必ず真になる
(check "fast-prime? 97"    (fast-prime? 97 10) #t)
(check "fast-prime? 1009"  (fast-prime? 1009 10) #t)
; 561（カーマイケル数）はフェルマーテストをすり抜ける。書籍の演習 1.27 の主題。
(check "561 は合成数だがフェルマーテストを通る"
       (and (not (prime? 561)) (fast-prime? 561 10)) #t)

; 素数の列を作って、2つの判定が一致することを見る
(define (primes-upto n)
  (define (loop i acc) (if (> i n) (reverse acc)
                           (loop (+ i 1) (if (prime? i) (cons i acc) acc))))
  (loop 2 '()))
(check "100 以下の素数は25個" (length (primes-upto 100)) 25)
(check "100 以下の素数の先頭" (car (primes-upto 100)) 2)
(check "試し割りとフェルマーが一致"
       (map (lambda (p) (fast-prime? p 5)) (primes-upto 50))
       (map (lambda (p) #t) (primes-upto 50)))

(summary "SICP 1.2")
