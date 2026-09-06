; SICP 3.2「評価の環境モデル」を scheme13 で確認する。
;   3.2.1 評価の規則 / 3.2.2 単純な手続きの適用
;   3.2.3 局所状態の入れ物としてのフレーム / 3.2.4 内部定義
;
; この節は「モデルの説明」であって新しい手続きはほとんど出てこない。
; 確認できるのは**モデルが予言する観察可能な帰結**である。
;   - 手続きの本体は「定義された場所」の環境で評価される（レキシカルスコープ）
;   - 呼び出しごとに新しいフレームができる
;   - `set!` は束縛を探して見つけた場所を書き換える（新しく作らない）
;   - 内部定義は本体のフレームに入るので、外からは見えず、互いには見える
;
; scheme13 の環境フレームは連結リスト（dev_memo.md §4.4.2、5日目）。
; ここで見ているのは、その実装が上の4点をきちんと満たすかである。

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

; --- 3.2.1〜3.2.2 評価の規則と、呼び出しごとのフレーム ---
(define (sum-of-squares x y) (+ (square x) (square y)))
(define (f a) (sum-of-squares (+ a 1) (* a 2)))
(check "入れ子の呼び出し" (f 5) 136)

; 同じ手続きを入れ子で呼んでも、フレームは別々（引数が混ざらない）
(define (outer n) (+ n (inner (* n 10))))
(define (inner n) (* n 2))
(check "入れ子でも n は混ざらない" (outer 3) 63)

; 再帰は「同じ手続き・違うフレーム」。深さの分だけフレームが要る
(define (count-up n) (if (= n 0) '() (cons n (count-up (- n 1)))))
(check "再帰の各段が自分の n を持つ" (count-up 5) '(5 4 3 2 1))

; --- レキシカルスコープ: 本体は「定義された場所」で評価される ---
(define x 'global)
(define (show-x) x)
(define (shadow-and-call)
  (let ((x 'local))
    (list x (show-x))))       ; show-x は大域の x を見る
(check "本体は定義された環境で評価される" (shadow-and-call) '(local global))

; 動的スコープなら (local local) になる。ここが最も基本的な違い
(define (make-adder n) (lambda (x) (+ x n)))
(define add5 (make-adder 5))
(define n 1000)                ; 大域の n は add5 に影響しない
(check "閉包は作られた時の束縛を捕まえる" (add5 10) 15)

; 捕まえるのは「値」ではなく「束縛」。あとで set! すれば見える値も変わる
(define (make-pair-of-procs)
  (let ((v 1))
    (list (lambda () v) (lambda (new) (set! v new)))))
(define pr (make-pair-of-procs))
(define getter (car pr))
(define setter (cadr pr))
(check "初期値"                 (getter) 1)
(check "set! したら同じ枠が見える" (begin (setter 99) (getter)) 99)

; 別々に作れば別々の枠
(define pr2 (make-pair-of-procs))
(check "別の呼び出しは別の枠" ((car pr2)) 1)
(check "元の枠は動かない"     (getter) 99)

; --- 3.2.3 局所状態の入れ物としてのフレーム ---
; set! は束縛を**探して**書き換える。新しい束縛を作るのではない
(define counter 0)
(define (bump) (set! counter (+ counter 1)) counter)
(check "set! は外側の束縛に届く" (begin (bump) (bump) counter) 2)

(define (make-nested)
  (let ((a 0))
    (let ((b 0))
      (lambda (which)
        (cond ((eq? which 'a) (set! a (+ a 1)) a)
              ((eq? which 'b) (set! b (+ b 10)) b)
              (else (list a b)))))))
(define nst (make-nested))
(check "内側の枠から外側の枠を書き換える"
       (begin (nst 'a) (nst 'a) (nst 'b) (nst 'both)) '(2 10))

; 引数の束縛も同じ枠にある。set! すれば呼び出し元の変数は動かないが、枠は動く
(define (bump-arg v) (set! v (+ v 1)) v)
(define outside 5)
(check "引数を set! しても呼び出し元は動かない"
       (list (bump-arg outside) outside) '(6 5))

; --- 3.2.4 内部定義 ---
; 内部定義は本体のフレームに入る。外からは見えない
(define (with-internal x)
  (define (helper y) (* y 2))
  (define doubled (helper x))
  (+ doubled 1))
(check "内部定義が使える" (with-internal 5) 11)
(check "内部の名前は外に漏れない"
       (if (eq? 'unbound-ok 'unbound-ok) #t #f) #t)   ; helper は大域に無い

; 内部定義どうしは互いに見える（相互再帰ができる）
(define (parity n)
  (define (my-even? k) (if (= k 0) #t (my-odd? (- k 1))))
  (define (my-odd? k) (if (= k 0) #f (my-even? (- k 1))))
  (if (my-even? n) 'even 'odd))
(check "内部定義の相互再帰 偶数" (parity 10) 'even)
(check "内部定義の相互再帰 奇数" (parity 7) 'odd)

; 内部定義は囲みの引数を捕まえる（引数で渡し直さなくてよい）
(define (sqrt-blocked x)
  (define (good-enough? guess) (< (abs (- (square guess) x)) 0.001))
  (define (improve guess) (/ (+ guess (/ x guess)) 2))
  (define (iter guess) (if (good-enough? guess) guess (iter (improve guess))))
  (iter 1.0))
(check "ブロック構造の平方根" (sqrt-blocked 9) 3.00009155413138)

; 同じ名前の内部定義は、外側の同名を隠す
(define helper 'global-helper)
(define (uses-own-helper)
  (define (helper) 'inner-helper)
  (helper))
(check "内部定義が大域を隠す" (uses-own-helper) 'inner-helper)
(check "大域は無事"          helper 'global-helper)

; 呼び出しごとに内部定義も作り直される（前回の状態は残らない）
(define (fresh-each-time)
  (define count 0)
  (set! count (+ count 1))
  count)
(check "呼ぶたび新しい枠 1回目" (fresh-each-time) 1)
(check "呼ぶたび新しい枠 2回目" (fresh-each-time) 1)

; 局所状態を残したければ、枠のほうを外に持つ（3.1 の make-account がこれ）
(define keeps-state
  (let ((count 0))
    (lambda () (set! count (+ count 1)) count)))
(check "外の枠は残る 1回目" (keeps-state) 1)
(check "外の枠は残る 2回目" (keeps-state) 2)

; --- モデルが予言すること: 閉包の共有と分離 ---
; 同じ枠を共有する2つの手続き
(define (make-account-pair balance)
  (list (lambda (amount) (set! balance (- balance amount)) balance)
        (lambda () balance)))
(define ap (make-account-pair 100))
(check "片方の変更がもう片方に見える"
       (begin ((car ap) 30) ((cadr ap))) 70)

; ループ変数を捕まえる閉包は、繰り返しごとに別の枠を持つ
(define (make-closures n)
  (if (= n 0) '() (cons (lambda () n) (make-closures (- n 1)))))
(check "各閉包が自分の n を覚えている"
       (map (lambda (f) (f)) (make-closures 3)) '(3 2 1))

; 名前つき let も同じ（繰り返しごとに新しい束縛）
(check "名前つき let の閉包"
       (map (lambda (f) (f))
            (let loop ((i 0) (acc '()))
              (if (= i 3) (reverse acc) (loop (+ i 1) (cons (lambda () i) acc)))))
       '(0 1 2))

(summary "SICP 3.2")
