; SICP 2.1「データ抽象入門」を scheme13 で確認する。
;   2.1.1 例: 有理数の算術演算 / 2.1.2 抽象の壁
;   2.1.3 データとは何か（手続きによる対の実装）
;   2.1.4 拡張演習: 区間算術
;
; 処理系側で問われるのは
;   - cons/car/cdr と、そこから積み上げた抽象が素直に書けるか
;   - 手続きだけで対を作れるか（クロージャと高階手続き）
;   - 区間算術の実数演算（min/max と負の幅の扱い）
; の3点。

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

; --- 2.1.1 有理数の算術演算 ---
; scheme13 は有理数型を持たない（§2.3 で凍結）。書籍と同じく、対から自分で作る。
(define (make-rat n d)
  (let ((g (gcd n d)))
    (cons (quotient n g) (quotient d g))))
(define (numer x) (car x))
(define (denom x) (cdr x))

(define (add-rat x y)
  (make-rat (+ (* (numer x) (denom y)) (* (numer y) (denom x)))
            (* (denom x) (denom y))))
(define (sub-rat x y)
  (make-rat (- (* (numer x) (denom y)) (* (numer y) (denom x)))
            (* (denom x) (denom y))))
(define (mul-rat x y)
  (make-rat (* (numer x) (numer y)) (* (denom x) (denom y))))
(define (div-rat x y)
  (make-rat (* (numer x) (denom y)) (* (denom x) (numer y))))
(define (equal-rat? x y)
  (= (* (numer x) (denom y)) (* (numer y) (denom x))))

; print-rat は表示だけなので、比べられるように文字列を作る版で見る
(define (rat->string x)
  (string-append (number->string (numer x)) "/" (number->string (denom x))))

(define one-half (make-rat 1 2))
(define one-third (make-rat 1 3))

(check "1/2"                  (rat->string one-half) "1/2")
(check "1/2 + 1/3 = 5/6"      (rat->string (add-rat one-half one-third)) "5/6")
(check "1/2 * 1/3 = 1/6"      (rat->string (mul-rat one-half one-third)) "1/6")
(check "1/3 + 1/3 = 2/3"      (rat->string (add-rat one-third one-third)) "2/3")
(check "1/2 - 1/3 = 1/6"      (rat->string (sub-rat one-half one-third)) "1/6")
(check "(1/2)/(1/3) = 3/2"    (rat->string (div-rat one-half one-third)) "3/2")
(check "equal-rat? 約分前後"  (equal-rat? (make-rat 2 4) one-half) #t)
(check "equal-rat? 違う数"    (equal-rat? one-half one-third) #f)
(check "gcd で約分済み"       (rat->string (make-rat 6 9)) "2/3")
; 負の有理数（演習 2.1）。scheme13 の gcd は負を受けるか、符号はどう出るか。
(check "gcd は負の引数でも正"  (gcd -6 9) 3)
(check "-6/9"                  (rat->string (make-rat -6 9)) "-2/3")
; gcd は常に正を返すので、約分しても符号は分母に残ったまま（演習 2.1 が直す点）
(check "6/-9 は符号が分母に残る" (rat->string (make-rat 6 -9)) "2/-3")
; 符号を正規化する版（演習 2.1 の答え）
(define (make-rat2 n d)
  (let* ((g (abs (gcd n d)))
         (s (if (< d 0) -1 1)))
    (cons (quotient (* s n) g) (quotient (* s d) g))))
(check "正規化版 6/-9"         (rat->string (make-rat2 6 -9)) "-2/3")
(check "正規化版 -6/-9"        (rat->string (make-rat2 -6 -9)) "2/3")

; --- 2.1.2 抽象の壁: 表現を変えても上の層は動く ---
; 約分を「作るとき」ではなく「取り出すとき」にやる表現に差し替える
(define (make-rat-lazy n d) (cons n d))
(define (numer-lazy x) (quotient (car x) (gcd (car x) (cdr x))))
(define (denom-lazy x) (quotient (cdr x) (gcd (car x) (cdr x))))
(check "遅い約分でも同じ値" (numer-lazy (make-rat-lazy 6 9)) 2)
(check "遅い約分でも同じ分母" (denom-lazy (make-rat-lazy 6 9)) 3)

; --- 2.1.3 データとは何か: 手続きだけで対を作る ---
; 対の「意味」は3つの公理だけ。実体は要らない。
(define (my-cons x y)
  (define (dispatch m)
    (cond ((= m 0) x)
          ((= m 1) y)
          (else (error "Argument not 0 or 1 -- CONS" m))))
  dispatch)
(define (my-car z) (z 0))
(define (my-cdr z) (z 1))

(check "手続きの対 car" (my-car (my-cons 1 2)) 1)
(check "手続きの対 cdr" (my-cdr (my-cons 1 2)) 2)
(check "入れ子にできる"
       (my-car (my-cdr (my-cons 1 (my-cons 3 4)))) 3)
(check "手続きの対は procedure?" (procedure? (my-cons 1 2)) #t)
; 上の有理数の層は、対の実装を知らないので、そのまま乗る
(define (make-rat-p n d)
  (let ((g (gcd n d))) (my-cons (quotient n g) (quotient d g))))
(check "手続きの対の上の有理数"
       (string-append (number->string (my-car (make-rat-p 6 9))) "/"
                      (number->string (my-cdr (make-rat-p 6 9))))
       "2/3")

; チャーチ数（演習 2.4〜2.6）。数すら手続きで表せる。
(define (church-zero f) (lambda (x) x))
(define (church-add-1 n) (lambda (f) (lambda (x) (f ((n f) x)))))
(define church-one (lambda (f) (lambda (x) (f x))))
(define church-two (lambda (f) (lambda (x) (f (f x)))))
(define (church->int n) ((n (lambda (k) (+ k 1))) 0))
(define (church-add m n) (lambda (f) (lambda (x) ((m f) ((n f) x)))))

(check "チャーチ 0"         (church->int church-zero) 0)
(check "チャーチ 1"         (church->int church-one) 1)
(check "add-1 で 1 になる"  (church->int (church-add-1 church-zero)) 1)
(check "add-1 を2回で 2"    (church->int (church-add-1 (church-add-1 church-zero))) 2)
(check "チャーチ加算 2+3"   (church->int (church-add church-two
                                                     (church-add-1 church-two))) 5)

; --- 2.1.4 区間算術 ---
(define (make-interval a b) (cons a b))
(define (lower-bound i) (car i))
(define (upper-bound i) (cdr i))

(define (add-interval x y)
  (make-interval (+ (lower-bound x) (lower-bound y))
                 (+ (upper-bound x) (upper-bound y))))
(define (mul-interval x y)
  (let ((p1 (* (lower-bound x) (lower-bound y)))
        (p2 (* (lower-bound x) (upper-bound y)))
        (p3 (* (upper-bound x) (lower-bound y)))
        (p4 (* (upper-bound x) (upper-bound y))))
    (make-interval (min p1 p2 p3 p4) (max p1 p2 p3 p4))))
(define (div-interval x y)
  (if (and (<= (lower-bound y) 0) (>= (upper-bound y) 0))
      (error "Division by an interval that spans zero" y)   ; 演習 2.10
      (mul-interval x (make-interval (/ 1.0 (upper-bound y))
                                     (/ 1.0 (lower-bound y))))))
(define (sub-interval x y)                                   ; 演習 2.8
  (make-interval (- (lower-bound x) (upper-bound y))
                 (- (upper-bound x) (lower-bound y))))

(define i1 (make-interval 1.0 2.0))
(define i2 (make-interval 3.0 5.0))
(check "区間の和の下限"   (lower-bound (add-interval i1 i2)) 4.0)
(check "区間の和の上限"   (upper-bound (add-interval i1 i2)) 7.0)
(check "区間の差の下限"   (lower-bound (sub-interval i2 i1)) 1.0)
(check "区間の差の上限"   (upper-bound (sub-interval i2 i1)) 4.0)
(check "区間の積の下限"   (lower-bound (mul-interval i1 i2)) 3.0)
(check "区間の積の上限"   (upper-bound (mul-interval i1 i2)) 10.0)
; 負を跨ぐ区間では、4通り全部を見ないと下限を取り違える
(define i3 (make-interval -2.0 1.0))
(check "負を跨ぐ積の下限" (lower-bound (mul-interval i3 i2)) -10.0)
(check "負を跨ぐ積の上限" (upper-bound (mul-interval i3 i2)) 5.0)
(check "min/max は3引数以上を取る" (min 3 1 2 5) 1)

(define (center i) (/ (+ (lower-bound i) (upper-bound i)) 2))
(define (width i) (/ (- (upper-bound i) (lower-bound i)) 2))
(define (make-center-width c w) (make-interval (- c w) (+ c w)))
(define (make-center-percent c p) (make-center-width c (* c (/ p 100.0))))
(define (percent i) (* 100.0 (/ (width i) (center i))))

(check "中心"           (center (make-interval 1.0 3.0)) 2.0)
(check "幅"             (width (make-interval 1.0 3.0)) 1.0)
(check~ "中心と誤差率から作って戻す" (percent (make-center-percent 100.0 5.0)) 5.0 1e-9)
(check~ "中心は保たれる"             (center (make-center-percent 100.0 5.0)) 100.0 1e-9)
; 演習 2.9: 和の幅は幅の和になるが、積ではそうならない
(check "和の幅 = 幅の和"
       (width (add-interval i1 i2)) (+ (width i1) (width i2)))
(check "積の幅は幅だけでは決まらない"
       (= (width (mul-interval i1 i2)) (* (width i1) (width i2))) #f)

; 演習 2.14: 代数的に等しい2つの式が、区間では違う答えを出す
(define (par1 r1 r2) (div-interval (mul-interval r1 r2) (add-interval r1 r2)))
(define (par2 r1 r2)
  (let ((one (make-interval 1.0 1.0)))
    (div-interval one (add-interval (div-interval one r1) (div-interval one r2)))))
(define ra (make-center-percent 100.0 1.0))
(define rb (make-center-percent 200.0 1.0))
(check "par1 と par2 は一致しない"
       (= (center (par1 ra rb)) (center (par2 ra rb))) #f)
(check "par2 のほうが誤差が小さい"
       (< (percent (par2 ra rb)) (percent (par1 ra rb))) #t)
(check~ "par2 の中心はほぼ 200/3" (center (par2 ra rb)) 66.6666666 0.01)

; 演習 2.10: 0 を跨ぐ区間で割るのは誤り。
; **scheme13 に Scheme レベルの例外捕捉は無い**（§1.4-3 の設計判断）ので、
; `(error ...)` が起きたことをテストの中から主張できない。判定そのものを
; 述語として取り出して見る。エラーが実際に出ることは、この節の外
; （`spans_zero_error.scm` を別に走らせて終了状態を見る）で確かめている。
(define (spans-zero? i) (and (<= (lower-bound i) 0) (>= (upper-bound i) 0)))
(check "0 を跨ぐ区間を見分ける"     (spans-zero? i3) #t)
(check "跨がない区間は見分けない"   (spans-zero? i2) #f)
(check "0 を跨がなければ割れる"
       (< (abs (- (upper-bound (div-interval i1 i2)) 0.6666666666666667)) 1e-12) #t)

(summary "SICP 2.1")
