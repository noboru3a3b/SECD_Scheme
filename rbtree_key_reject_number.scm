;;; A number tree must refuse a string, including one that looks like a
;;; number. guard catches the refusal. The tree already holds 123; the
;;; string "123" is a different key and must not be inserted.

(load "rbtree_lib_improved.scm")

(define db (rb-new-number))
(rb-db-insert db 123 "from-number")
(define result
  (guard (e (else 'refused))
    (rb-db-insert db "123" "from-string")))
(display result)
(newline)
(display (rb-db-count db))
(newline)
(display (rb-db-search db 123))
(newline)
(if (and (eq? result 'refused)
         (= (rb-db-count db) 1)
         (equal? (rb-db-search db 123) "from-number"))
    (exit 0)
    (exit 1))
