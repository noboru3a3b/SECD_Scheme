;;; リーダのエラーは、ハンドラがあっても止まる。
(display "before")
(newline)
(with-exception-handler
  (lambda (e) (display "caught") (newline) 0)
  (lambda () (load "scheme14/tests/exception_reader_bad.scm")))
(display "must-not-run")
(newline)
