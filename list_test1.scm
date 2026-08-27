;; test1-5
(display (append '(a b c) '(d e f)))
(newline)
;(A B C D E F)

(display (append '((a b) (c d)) '(e f g)))
(newline)
;((A B) (C D) E F G)

(display (reverse '(a b c d e)))
(newline)
;(E D C B A)

(display (reverse '((a b) c (d e))))
(newline)
;((D E) C (A B))

(display (memq 'a '(a b c d e)))
(newline)
;(A B C D E)

(display (memq 'c '(a b c d e)))
(newline)
;(C D E)

(display (memq 'f '(a b c d e)))
(newline)
;FALSE

(display (assq 'a '((a 1) (b 2) (c 3) (d 4) (e 5))))
(newline)
;(A 1)

(display (assq 'e '((a 1) (b 2) (c 3) (d 4) (e 5))))
(newline);(E 5)

(display (assq 'f '((a 1) (b 2) (c 3) (d 4) (e 5))))
(newline)
;FALSE

(display (map car '((a 1) (b 2) (c 3) (d 4) (e 5))))
(newline)
;(A B C D E)

(display (map cdr '((a 1) (b 2) (c 3) (d 4) (e 5))))
(newline)
;((1) (2) (3) (4) (5))

(display (map (lambda (x) (cons x x)) '(a b c d e)))
(newline)
;((A . A) (B . B) (C . C) (D . D) (E . E))

(display (filter (lambda (x) (not (eq? x 'a))) '(a b c a b c a b c)))
(newline)
;(B C B C B C)

(display (fold-left cons '() '(a b c d e)))
(newline)
;(((((NIL . A) . B) . C) . D) . E)

(display (fold-right cons '() '(a b c d e)))
(newline)
;(A B C D E)

