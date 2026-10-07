;;; A mixed tree holds both 123 and "123". A symbol is in neither domain.
;;; guard catches the refusal. Both stored keys stay.

(load "rbtree_lib_improved.scm")

(define db (rb-new-mixed))
(rb-db-insert db 123 "from-number")
(rb-db-insert db "123" "from-string")
(define result
  (guard (e (else 'refused))
    (rb-db-insert db (quote sym) "no")))
(display result)
(newline)
(display (rb-db-count db))
(newline)
(display (rb-db-search db 123))
(newline)
(display (rb-db-search db "123"))
(newline)
(if (and (eq? result 'refused)
         (= (rb-db-count db) 2)
         (equal? (rb-db-search db 123) "from-number")
         (equal? (rb-db-search db "123") "from-string"))
    (exit 0)
    (exit 1))
