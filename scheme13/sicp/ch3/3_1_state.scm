; SICP 3.1「代入と局所状態」を scheme13 で確認する。
;   3.1.1 局所状態変数 / 3.1.2 代入を導入する利点 / 3.1.3 代入を導入する代償
;
; 処理系側で問われるのは
;   - `set!` がクロージャの捕まえた束縛を書き換えること（局所状態の土台）
;   - 同じ手続きから作った2つの物が、独立した状態を持つこと
;   - 代入によって「同じ値を返す式」が「呼ぶたび違う値を返す式」になること
;
; 期待値には書籍が本文に印字している値を使う。

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

; --- 3.1.1 局所状態変数 ---
; 大域変数を書き換える版
(define balance 100)
(define (withdraw amount)
  (if (>= balance amount)
      (begin (set! balance (- balance amount)) balance)
      "Insufficient funds"))

(check "withdraw 25"      (withdraw 25) 75)
(check "もう一度 25"      (withdraw 25) 50)
(check "残高不足"         (withdraw 60) "Insufficient funds")
(check "残高は減っていない" (withdraw 15) 35)

; 状態を手続きの中に閉じ込める版
(define new-withdraw
  (let ((balance 100))
    (lambda (amount)
      (if (>= balance amount)
          (begin (set! balance (- balance amount)) balance)
          "Insufficient funds"))))
(check "let に閉じた balance" (new-withdraw 25) 75)
(check "外の balance は無関係" balance 35)

; 作るたびに独立した状態を持つ
(define (make-withdraw balance)
  (lambda (amount)
    (if (>= balance amount)
        (begin (set! balance (- balance amount)) balance)
        "Insufficient funds")))
(define W1 (make-withdraw 100))
(define W2 (make-withdraw 100))
(check "W1 から 50"      (W1 50) 50)
(check "W2 は影響を受けない" (W2 70) 30)
(check "W2 の残高不足"   (W2 40) "Insufficient funds")
(check "W1 の残高は別"   (W1 40) 10)

; メッセージで操作を選ぶ口座
(define (make-account balance)
  (define (withdraw amount)
    (if (>= balance amount)
        (begin (set! balance (- balance amount)) balance)
        "Insufficient funds"))
  (define (deposit amount)
    (set! balance (+ balance amount))
    balance)
  (define (dispatch m)
    (cond ((eq? m 'withdraw) withdraw)
          ((eq? m 'deposit) deposit)
          (else (error "Unknown request -- MAKE-ACCOUNT" m))))
  dispatch)

(define acc (make-account 100))
(check "口座から引き出す"  ((acc 'withdraw) 50) 50)
(check "残高不足"          ((acc 'withdraw) 60) "Insufficient funds")
(check "預け入れ"          ((acc 'deposit) 40) 90)
(check "また引き出す"      ((acc 'withdraw) 60) 30)
(define acc2 (make-account 100))
(check "別の口座は独立"    ((acc2 'withdraw) 10) 90)
(check "元の口座は動かない" ((acc 'deposit) 0) 30)

; 演習 3.1〜3.3
(define (make-accumulator total)
  (lambda (amount) (set! total (+ total amount)) total))
(define A (make-accumulator 5))
(check "累算器 1回目" (A 10) 15)
(check "累算器 2回目" (A 10) 25)

(define (make-monitored f)
  (let ((count 0))
    (lambda (arg)
      (cond ((eq? arg 'how-many-calls?) count)
            ((eq? arg 'reset-count) (set! count 0) count)
            (else (set! count (+ count 1)) (f arg))))))
(define s (make-monitored sqrt))
(check "監視つき sqrt"       (s 100) 10)
(check "呼ばれた回数"        (s 'how-many-calls?) 1)
(check "数えるのは本体だけ"  (begin (s 16) (s 'how-many-calls?)) 2)
(check "数え直せる"          (begin (s 'reset-count) (s 'how-many-calls?)) 0)

(define (make-pw-account balance password)
  (define (withdraw amount)
    (if (>= balance amount)
        (begin (set! balance (- balance amount)) balance)
        "Insufficient funds"))
  (define (deposit amount) (set! balance (+ balance amount)) balance)
  (lambda (pw m)
    (cond ((not (eq? pw password)) (lambda (x) "Incorrect password"))
          ((eq? m 'withdraw) withdraw)
          ((eq? m 'deposit) deposit)
          (else (error "Unknown request" m)))))
(define pacc (make-pw-account 100 'secret-password))
(check "合言葉が合えば引き出せる" ((pacc 'secret-password 'withdraw) 40) 60)
(check "合わなければ断られる"     ((pacc 'some-other-password 'deposit) 50)
                                  "Incorrect password")
(check "断られた分は残高に響かない" ((pacc 'secret-password 'deposit) 0) 60)

; --- 3.1.2 代入を導入する利点: 乱数と Monte Carlo ---
; 書籍の rand は「呼ぶたび次の数を返す」形。scheme13 の random は引数を取るので、
; 線形合同法を自分で書いて、状態を持つことのほうを見る。
(define (make-rand seed)
  (let ((x seed))
    (lambda ()
      (set! x (modulo (+ (* 1103515245 x) 12345) 2147483648))
      x)))
(define r1 (make-rand 1))
(define r2 (make-rand 1))
(define first-value (r1))
(check "同じ種なら同じ列"   first-value (r2))
(check "呼ぶたびに変わる"   (= first-value (r1)) #f)
(check "種が違えば列も違う" (= ((make-rand 7)) ((make-rand 9))) #f)

(define (monte-carlo trials experiment)
  (define (iter trials-remaining trials-passed)
    (cond ((= trials-remaining 0) (/ (exact->inexact trials-passed) trials))
          ((experiment) (iter (- trials-remaining 1) (+ trials-passed 1)))
          (else (iter (- trials-remaining 1) trials-passed))))
  (iter trials 0))
; 決まった答えの出る実験で、monte-carlo 自体の勘定を確かめる
(check "全部成功なら 1.0" (monte-carlo 100 (lambda () #t)) 1.0)
(check "全部失敗なら 0.0" (monte-carlo 100 (lambda () #f)) 0.0)
(define alt (let ((n 0)) (lambda () (set! n (+ n 1)) (even? n))))
(check "半分成功なら 0.5" (monte-carlo 100 alt) 0.5)

; 互いに素である確率は 6/π^2。π を逆算する（書籍の estimate-pi）。
;
; **下位ビットを捨てること。** 2の冪を法とする線形合同法は下位ビットの周期が
; 極端に短く（最下位ビットは 0,1,0,1 …）、連続する2数が互いに素になる割合が
; 0.82 まで偏って π が 2.7 になる。上位ビットだけを使えば 0.604 になり、
; 理論値 6/π^2 = 0.6079 と合う。**処理系ではなく乱数の作り方の問題。**
(define (cesaro-test rand)
  (= (gcd (rand) (rand)) 1))
(define (estimate-pi trials)
  (let* ((g (make-rand 12345))
         (rand (lambda () (quotient (g) 2048))))
    (let ((p (monte-carlo trials (lambda () (cesaro-test rand)))))
      (if (= p 0.0) 0.0 (sqrt (/ 6.0 p))))))
(define pi-est (estimate-pi 3000))
(check "π の推定は 3 前後" (and (> pi-est 2.9) (< pi-est 3.4)) #t)
(check "推定値は実数"      (inexact? pi-est) #t)

; --- 3.1.3 代入を導入する代償 ---
; 代入が無ければ、同じ引数の呼び出しは常に同じ値を返す（参照透過）
(define (make-decrementer balance)
  (lambda (amount) (- balance amount)))
(define D (make-decrementer 25))
(check "減算器 1回目" (D 20) 5)
(check "減算器 2回目、同じ引数なら同じ値" (D 20) 5)
(check "減算器は状態を持たない" (D 10) 15)

; 代入があると、同じ式が呼ぶたび違う値になる（残高不足も見ない簡易版）
(define (make-simplified-withdraw balance)
  (lambda (amount) (set! balance (- balance amount)) balance))
(define W (make-simplified-withdraw 25))
(check "簡易引き出し 1回目" (W 20) 5)
(check "同じ式が違う値を返す" (W 10) -5)

; 「同じか」が言えなくなる（sameness and change）
(define peter-acc (make-account 100))
(define paul-acc (make-account 100))
(define both-acc peter-acc)          ; 同じ口座への別名
(check "別々の口座は独立"
       (begin ((peter-acc 'withdraw) 10) ((paul-acc 'deposit) 0)) 100)
(check "別名は同じ口座を指す"
       ((both-acc 'deposit) 0) 90)
(check "手続きどうしは eq? で見分けられる" (eq? peter-acc both-acc) #t)
(check "中身が同じでも別の物は別"          (eq? peter-acc paul-acc) #f)

(summary "SICP 3.1")
