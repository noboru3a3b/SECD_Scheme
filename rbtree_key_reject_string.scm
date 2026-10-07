;;; A string tree must refuse a number. "123" is already stored.
;;; guard catches the refusal and leaves that entry in place.

(load "rbtree_lib_improved.scm")

(define db (rb-new-string))
(rb-db-insert db "123" "from-string")
(define result
  (guard (e (else 'refused))
    (rb-db-insert db 123 "from-number")))
(display result)
(newline)
(display (rb-db-count db))
(newline)
(display (rb-db-search db "123"))
(newline)
(if (and (eq? result 'refused)
         (= (rb-db-count db) 1)
         (equal? (rb-db-search db "123") "from-string"))
    (exit 0)
    (exit 1))
