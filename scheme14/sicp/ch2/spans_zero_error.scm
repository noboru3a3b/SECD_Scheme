; 2.1.4 演習 2.10 の「0 を跨ぐ区間で割る」がエラーになることの確認。
;
; scheme13 に Scheme レベルの例外捕捉は無い（dev_memo §1.4-3）ので、
; エラーは処理系ごと止まる。**したがってこの確認だけは別ファイルにして、
; 終了状態と標準エラーの文面をシェル側で見る。**
; 期待: 終了状態 1 と、下の expect-error 行の文面。
; expect-error: Division by an interval that spans zero
(define (make-interval a b) (cons a b))
(define (lower-bound i) (car i))
(define (upper-bound i) (cdr i))
(define (div-interval x y)
  (if (and (<= (lower-bound y) 0) (>= (upper-bound y) 0))
      (error "Division by an interval that spans zero" y)
      (cons (/ (lower-bound x) (upper-bound y)) (/ (upper-bound x) (lower-bound y)))))
(display "before") (newline)
(div-interval (make-interval 1.0 2.0) (make-interval -2.0 1.0))
(display "unreachable") (newline)
