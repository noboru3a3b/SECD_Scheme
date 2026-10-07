;;; with-exception-handler / guard / raise-continuable。
;;; ハンドラが戻って止まる筋と、リーダのエラーは別ファイル。

(define failures 0)

(define expect
  (lambda (name got want)
    (display name)
    (if (equal? got want)
        (display " PASS")
        (begin
          (set! failures (+ failures 1))
          (display " FAIL")
          (newline)
          (display "  got: ")
          (display got)
          (newline)
          (display "  want: ")
          (display want)))
    (newline)))

(expect "car"
        (guard (e (else (error-object-message e))) (car '()))
        "car: wrong type of argument\n  expected: a pair\n  given: NIL")

(expect "div"
        (guard (e (else (error-object-message e))) (/ 1 0))
        "/: division by zero\n  given: 0")

(expect "error"
        (guard (e (else (error-object-message e))) (error "boom" 1))
        "boom\n  given: 1")

(expect "continuable"
        (with-exception-handler (lambda (e) 42)
          (lambda () (raise-continuable 'x)))
        42)

(expect "nested"
        (guard (e (else 'outer))
          (guard (e ((error-object? e) 'inner))
            (raise 5)))
        'outer)

(define notes '())
(expect "wind-result"
        (guard (e (else 'refused))
          (dynamic-wind
            (lambda () (set! notes (append notes '(in))))
            (lambda () (car '()))
            (lambda () (set! notes (append notes '(out))))))
        'refused)
(expect "wind-notes" notes '(in out))

(expect "eval-syntax"
        (guard (e (else 'bad-syntax))
          (eval '(let) (interaction-environment)))
        'bad-syntax)

(display failures)
(display " failed")
(newline)
(if (= failures 0) (exit 0) (exit 1))
