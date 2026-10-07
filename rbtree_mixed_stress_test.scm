;;;
;;; rbtree_mixed_stress_test.scm
;;;
;;; Stress the mixed number/string tree. Numbers sort before strings, and
;;; 123 is a different key from "123". The numeric stress test does not
;;; exercise that order.
;;;
;;; The generator is a fixed linear congruential sequence, so a failure
;;; repeats. Heap sizes are not printed: they move from run to run, and
;;; this file only reports whether the tree still matches its reference.
;;;

(load "rbtree_lib_improved.scm")

(define test-count 0)
(define pass-count 0)
(define fail-count 0)

(define test-result
  (lambda (name result expected)
    (set! test-count (+ test-count 1))
    (if (equal? result expected)
        (begin
          (set! pass-count (+ pass-count 1))
          (display "[PASS] ")
          (display name)
          (newline))
        (begin
          (set! fail-count (+ fail-count 1))
          (display "[FAIL] ")
          (display name)
          (newline)
          (display "  Expected: ")
          (display expected)
          (newline)
          (display "  Got:      ")
          (display result)
          (newline)))))

;;; Period 2^31-1. Seed is part of the test, not a hidden global of the
;;; interpreter, so scheme12 and scheme14 take the same steps.
(define rng-state 12345)

(define rnd
  (lambda (n)
    (set! rng-state (modulo (+ (* rng-state 1103515245) 12345) 2147483647))
    (modulo rng-state n)))

(define strictly-increasing?
  (lambda (ls cmp)
    (let loop ((ls ls))
      (or (null? ls)
          (null? (cdr ls))
          (and (< (cmp (car ls) (car (cdr ls))) 0)
               (loop (cdr ls)))))))

(define count-present
  (lambda (flags n)
    (let loop ((i 0) (c 0))
      (if (>= i n)
          c
          (loop (+ i 1)
                (if (vector-ref flags i) (+ c 1) c))))))

;;; Every live key matches the reference, and absent keys stay absent.
;;; A value of 0 must still count as present, so this uses contains?.
(define reference-matches?
  (lambda (db num-present num-value str-present str-value n)
    (let loop ((i 0))
      (if (>= i n)
          true
          (let ((s (number->string i)))
            (and (if (vector-ref num-present i)
                     (and (rb-db-contains? db i)
                          (equal? (rb-db-search db i) (vector-ref num-value i)))
                     (not (rb-db-contains? db i)))
                 (if (vector-ref str-present i)
                     (and (rb-db-contains? db s)
                          (equal? (rb-db-search db s) (vector-ref str-value i)))
                     (not (rb-db-contains? db s)))
                 (loop (+ i 1))))))))

(define list-index
  (lambda (ls key)
    (let loop ((ls ls) (i 0))
      (cond ((null? ls) -1)
            ((equal? (car ls) key) i)
            (else (loop (cdr ls) (+ i 1)))))))

(display "===========================================")
(newline)
(display "  rbtree mixed stress test")
(newline)
(display "===========================================")
(newline)
(newline)

;;; ---------------------------------------------------------------------------
;;; Section 1: random insert and delete. Two of every three operations
;;; insert. The key index and the type (number or its decimal string) are
;;; chosen separately, so 17 and "17" are both offered to the same tree.
;;; ---------------------------------------------------------------------------

(display "--- Section 1: random insert/delete ---")
(newline)

(define stress-span 200)
(define stress-ops 2500)

(let ((db (rb-new-mixed))
      (num-present (make-vector stress-span false))
      (num-value (make-vector stress-span 0))
      (str-present (make-vector stress-span false))
      (str-value (make-vector stress-span 0)))
  (let loop ((i 0) (bad 0) (both 0))
    (if (< i stress-ops)
        (let ((k (rnd stress-span)))
          (let ((as-string (= (rnd 2) 0)))
            (let ((do-insert (< (rnd 3) 2)))
              (if (= (modulo i 500) 0) (gc-collect) false)
              (if do-insert
                  (begin
                    (if as-string
                        (begin
                          (vector-set! str-present k true)
                          (vector-set! str-value k i)
                          (rb-db-insert db (number->string k) i))
                        (begin
                          (vector-set! num-present k true)
                          (vector-set! num-value k i)
                          (rb-db-insert db k i))))
                  (begin
                    (if as-string
                        (vector-set! str-present k false)
                        (vector-set! num-present k false))
                    (rb-db-delete db (if as-string (number->string k) k))))
              (loop (+ i 1)
                    (+ bad (if (rb-db-valid? db) 0 1))
                    (+ both (if (and (vector-ref num-present k)
                                     (vector-ref str-present k))
                                1
                                0))))))
        (begin
          (test-result "1a. valid after every one of 2500 ops" bad 0)
          (test-result "1b. some index was stored as both number and string"
                       (> both 0) true)
          (test-result "1c. search matches the reference"
                       (reference-matches? db num-present num-value
                                           str-present str-value stress-span)
                       true)
          (let ((keys (rb-db-to-list db))
                (live (+ (count-present num-present stress-span)
                         (count-present str-present stress-span))))
            (test-result "1d. in-order length matches the live keys"
                         (length keys) live)
            (test-result "1e. in-order is strictly increasing under mixed cmp"
                         (strictly-increasing? keys rb-cmp-mixed) true)
            (let loop ((expect keys) (step 0) (ok true))
              (if (null? expect)
                  (begin
                    (test-result "1f. delete-min yields the in-order sequence"
                                 ok true)
                    (test-result "1g. empty after delete-min" (rb-db-count db) 0)
                    (test-result "1h. empty tree is valid" (rb-db-valid? db) true))
                  (begin
                    (rb-db-delete-min db)
                    (loop (cdr expect)
                          (+ step 1)
                          (and ok
                               (rb-db-valid? db)
                               (equal? (rb-db-to-list db) (cdr expect))))))))))))

(newline)

;;; ---------------------------------------------------------------------------
;;; Section 2: every index from 0 to 299 is inserted twice, once as a
;;; number and once as that number's decimal spelling. Deleting the
;;; numbers must leave the strings, in dictionary order. "10" stands
;;; before "2" there, which is the opposite of numeric order.
;;; ---------------------------------------------------------------------------

(display "--- Section 2: paired number and string keys ---")
(newline)

(define pair-span 300)

(let ((db (rb-new-mixed)))
  (let loop ((i 0))
    (if (< i pair-span)
        (begin
          (rb-db-insert db i i)
          (rb-db-insert db (number->string i) (string-append "s" (number->string i)))
          (loop (+ i 1)))))
  (test-result "2a. 600 keys, valid" (and (rb-db-valid? db) (= (rb-db-count db) 600)) true)
  (test-result "2b. 10 and \"10\" are different entries"
               (and (equal? (rb-db-search db 10) 10)
                    (equal? (rb-db-search db "10") "s10")
                    (equal? (rb-db-search db 2) 2)
                    (equal? (rb-db-search db "2") "s2"))
               true)
  (let loop ((i 0))
    (if (< i pair-span)
        (begin
          (rb-db-delete db i)
          (loop (+ i 1)))))
  (let ((keys (rb-db-to-list db)))
    (test-result "2c. only the 300 strings remain" (rb-db-count db) 300)
    (test-result "2d. valid after deleting every number" (rb-db-valid? db) true)
    (test-result "2e. 10 is gone and \"10\" remains"
                 (and (not (rb-db-contains? db 10))
                      (equal? (rb-db-search db "10") "s10"))
                 true)
    (test-result "2f. \"10\" stands before \"2\""
                 (and (>= (list-index keys "10") 0)
                      (>= (list-index keys "2") 0)
                      (< (list-index keys "10") (list-index keys "2")))
                 true)
    (test-result "2g. remaining keys are strictly dictionary-ordered"
                 (strictly-increasing? keys rb-cmp-string) true)
    (let loop ((expect keys) (ok true))
      (if (null? expect)
          (begin
            (test-result "2h. delete-min drains the strings in that order"
                         ok true)
            (test-result "2i. empty at the end" (rb-db-count db) 0))
          (begin
            (rb-db-delete-min db)
            (loop (cdr expect)
                  (and ok
                       (rb-db-valid? db)
                       (equal? (rb-db-to-list db) (cdr expect)))))))))

(newline)
(display "===========================================")
(newline)
(display "  Results: ")
(display pass-count)
(display "/")
(display test-count)
(display " passed")
(newline)
(if (= fail-count 0)
    (begin
      (display "*** ALL MIXED STRESS TESTS PASSED ***")
      (newline))
    (begin
      (display "*** ")
      (display fail-count)
      (display " TEST(S) FAILED ***")
      (newline)
      (exit 1)))
(display "===========================================")
(newline)
