;;;
;;; rbtree_key_test.scm : string keys, mixed number/string keys, and the
;;; numeric handle. The node API's numeric behaviour stays in
;;; rbtree_robustness_test.scm. A foreign key aborts the process, so those
;;; cases live in rbtree_key_reject_*.scm rather than here.
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

(display "===========================================")
(newline)
(display "  rbtree key tests (string / mixed)")
(newline)
(display "===========================================")
(newline)
(newline)

;;; ---------------------------------------------------------------------------
;;; Section 1: the comparators themselves. 123 and "123" are not equal.
;;; ---------------------------------------------------------------------------

(display "--- Section 1: comparators ---")
(newline)

(test-result "1a. number: 2 before 10" (rb-cmp-number 2 10) -1)
(test-result "1b. number: equals" (rb-cmp-number 123 123) 0)
(test-result "1c. string: \"10\" before \"2\"" (rb-cmp-string "10" "2") -1)
(test-result "1d. string: equals" (rb-cmp-string "123" "123") 0)
(test-result "1e. mixed: 123 before \"123\"" (rb-cmp-mixed 123 "123") -1)
(test-result "1f. mixed: \"123\" after 123" (rb-cmp-mixed "123" 123) 1)
(test-result "1g. mixed: number equals" (rb-cmp-mixed 123 123) 0)
(test-result "1h. mixed: string equals" (rb-cmp-mixed "123" "123") 0)
(test-result "1i. mixed: 0 before \"\"" (rb-cmp-mixed 0 "") -1)

(newline)

;;; ---------------------------------------------------------------------------
;;; Section 2: string tree.
;;; ---------------------------------------------------------------------------

(display "--- Section 2: string tree ---")
(newline)

(let ((db (rb-new-string)))
  (rb-db-insert db "dog" "d")
  (rb-db-insert db "cat" "c")
  (rb-db-insert db "bird" "b")
  (rb-db-insert db "ant" "a")
  (rb-db-insert db "zebra" "z")
  (rb-db-insert db "" "empty")
  (test-result "2a. in-order, dictionary, empty string first"
               (rb-db-to-list db)
               '("" "ant" "bird" "cat" "dog" "zebra"))
  (test-result "2b. valid after those inserts" (rb-db-valid? db) true)
  (test-result "2c. search cat" (rb-db-search db "cat") "c")
  (rb-db-insert db "cat" "c2")
  (test-result "2d. replace keeps one cat" (rb-db-search db "cat") "c2")
  (test-result "2e. count unchanged by replace" (rb-db-count db) 6)
  (rb-db-insert db "false-key" false)
  (test-result "2f. contains a key whose value is false"
               (rb-db-contains? db "false-key") true)
  (test-result "2g. search still returns that false"
               (rb-db-search db "false-key") false)
  (test-result "2h. missing key is absent" (rb-db-contains? db "nope") false)
  (test-result "2i. missing search is false" (rb-db-search db "nope") false)
  (rb-db-delete db "dog")
  (test-result "2j. dog is gone" (rb-db-contains? db "dog") false)
  (test-result "2k. still valid after delete" (rb-db-valid? db) true)
  (rb-db-delete db "not-there")
  (test-result "2l. deleting a missing key leaves the tree valid"
               (rb-db-valid? db) true)
  (test-result "2m. delete-min drops the empty string"
               (begin (rb-db-delete-min db) (rb-db-to-list db))
               '("ant" "bird" "cat" "false-key" "zebra"))
  (test-result "2n. valid after delete-min" (rb-db-valid? db) true))

;;; Dictionary order, not numeric order, including a run of inserts.
(let ((db (rb-new-string)))
  (rb-db-insert db "100" 100)
  (rb-db-insert db "20" 20)
  (rb-db-insert db "3" 3)
  (rb-db-insert db "123" 123)
  (test-result "2o. \"100\" \"123\" \"20\" \"3\""
               (rb-db-to-list db)
               '("100" "123" "20" "3"))
  (test-result "2p. that tree is valid" (rb-db-valid? db) true))

;;; 0..19 as decimal strings. Order is checked by rb-db-valid?, which uses
;;; string comparison, so "10" stands before "2".
(let ((db (rb-new-string)))
  (let loop ((i 0))
    (if (< i 20)
        (begin
          (rb-db-insert db (number->string i) i)
          (loop (+ i 1)))))
  (test-result "2q. 20 string keys, tree is valid" (rb-db-valid? db) true)
  (test-result "2r. count is 20" (rb-db-count db) 20)
  (test-result "2s. \"10\" finds 10" (rb-db-search db "10") 10)
  (test-result "2t. \"2\" finds 2" (rb-db-search db "2") 2)
  (let loop ((i 0))
    (if (< i 10)
        (begin
          (rb-db-delete db (number->string i))
          (loop (+ i 1)))))
  (test-result "2u. deleted \"0\"..\"9\", 10 left" (rb-db-count db) 10)
  (test-result "2v. \"0\" is gone" (rb-db-contains? db "0") false)
  (test-result "2w. \"10\" remains" (rb-db-contains? db "10") true)
  (test-result "2x. valid after the deletes" (rb-db-valid? db) true)
  (let loop ((i 0) (ok true))
    (if (< i 10)
        (begin
          (rb-db-delete-min db)
          (loop (+ i 1) (and ok (rb-db-valid? db))))
        (test-result "2y. delete-min down to empty stays valid" ok true)))
  (test-result "2z. empty at the end" (rb-db-count db) 0))

(newline)

;;; ---------------------------------------------------------------------------
;;; Section 3: numbers and strings in one tree. Numbers come first.
;;; ---------------------------------------------------------------------------

(display "--- Section 3: mixed tree ---")
(newline)

(let ((db (rb-new-mixed)))
  (rb-db-insert db 20 "n20")
  (rb-db-insert db "100" "s100")
  (rb-db-insert db 3 "n3")
  (rb-db-insert db "20" "s20")
  (rb-db-insert db 100 "n100")
  (rb-db-insert db "3" "s3")
  (rb-db-insert db 123 "from-number")
  (rb-db-insert db "123" "from-string")
  (test-result "3a. numbers, then dictionary strings"
               (rb-db-to-list db)
               '(3 20 100 123 "100" "123" "20" "3"))
  (test-result "3b. valid" (rb-db-valid? db) true)
  (test-result "3c. 123 is the number's value"
               (rb-db-search db 123) "from-number")
  (test-result "3d. \"123\" is the string's value"
               (rb-db-search db "123") "from-string")
  (test-result "3e. both keys are present"
               (and (rb-db-contains? db 123) (rb-db-contains? db "123"))
               true)
  (rb-db-delete db 123)
  (test-result "3f. deleting 123 leaves \"123\""
               (rb-db-search db "123") "from-string")
  (test-result "3g. 123 itself is gone" (rb-db-contains? db 123) false)
  (test-result "3h. valid after deleting the number" (rb-db-valid? db) true)
  (rb-db-delete db "123")
  (test-result "3i. \"123\" is gone too" (rb-db-contains? db "123") false)
  (test-result "3j. valid after deleting the string" (rb-db-valid? db) true)
  (test-result "3k. six keys remain" (rb-db-count db) 6))

;;; The mirror image: a string placed to the left of a number is out of order,
;;; even though both children have a legal colour. Heights match (the left
;;; child is red), so only the order walk can reject it.
(let ((bad (make-rb-node 5 "num")))
  (rb-set-color! bad BLACK)
  (rb-set-left! bad (make-rb-node "a" "str"))
  (rb-set-color! (rb-left bad) RED)
  (let ((db (rb-new-mixed)))
    (vector-set! db 0 bad)
    (test-result "3l. string before number is rejected" (rb-db-valid? db) false)))

(let ((good (make-rb-node "m" "str")))
  (rb-set-color! good BLACK)
  (rb-set-left! good (make-rb-node 5 "num"))
  (rb-set-color! (rb-left good) RED)
  (let ((db (rb-new-mixed)))
    (vector-set! db 0 good)
    (test-result "3m. number before string is accepted" (rb-db-valid? db) true)))

(newline)

;;; ---------------------------------------------------------------------------
;;; Section 4: the numeric handle uses the same order as the node API.
;;; ---------------------------------------------------------------------------

(display "--- Section 4: number handle ---")
(newline)

(let ((db (rb-new-number))
      (node RB-NIL))
  (rb-db-insert db 4 "d")
  (rb-db-insert db 1 "a")
  (rb-db-insert db 3 "c")
  (rb-db-insert db 2 "b")
  (set! node (rb-insert node 4 "d"))
  (set! node (rb-insert node 1 "a"))
  (set! node (rb-insert node 3 "c"))
  (set! node (rb-insert node 2 "b"))
  (test-result "4a. handle order matches rb-insert"
               (rb-db-to-list db) (rb-to-list node))
  (test-result "4b. handle is valid" (rb-db-valid? db) true)
  (test-result "4c. search 3" (rb-db-search db 3) "c")
  (rb-db-insert db 2 "b2")
  (test-result "4d. replace" (rb-db-search db 2) "b2")
  (rb-db-delete db 1)
  (test-result "4e. deleted 1" (rb-db-contains? db 1) false)
  (test-result "4f. still valid" (rb-db-valid? db) true)
  (test-result "4g. three keys left" (rb-db-count db) 3)
  (test-result "4h. rb-db-validate agrees" (rb-db-validate db) true))

;;; A caller-supplied comparator is stored on the handle and actually used.
(let ((db (rb-new-with (lambda (a b) (rb-cmp-number b a)))))
  (rb-db-insert db 1 "a")
  (rb-db-insert db 2 "b")
  (rb-db-insert db 3 "c")
  (test-result "4i. custom cmp reverses numeric order"
               (rb-db-to-list db) '(3 2 1))
  (test-result "4j. custom tree is valid under its own cmp"
               (rb-db-valid? db) true))

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
      (display "*** ALL KEY TESTS PASSED ***")
      (newline))
    (begin
      (display "*** ")
      (display fail-count)
      (display " TEST(S) FAILED ***")
      (newline)
      (exit 1)))
(display "===========================================")
(newline)
