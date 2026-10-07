;;; ハンドラが普通に戻ると、失敗した式の続きは走らない。
(display "before")
(newline)
(with-exception-handler
  (lambda (e) 'came-back)
  (lambda () (error "boom")))
(display "must-not-run")
(newline)
