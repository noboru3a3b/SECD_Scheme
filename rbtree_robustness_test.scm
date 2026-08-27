;;;
;;; rbtree_robustness_test.scm : Regression tests for the robustness fixes
;;; applied to rbtree_lib_improved.scm.
;;;
;;; Background: an audit against the Fncalc7 project's rbtree3.cal / rbtree4.cal
;;; (the library rbtree_lib_improved.scm was originally ported from) found that
;;; rbtree3.cal-style code had a class of bug the Fncalc7 author labeled RB-02:
;;; delete_min/delete_max, if exposed as a standalone public operation without
;;; painting the root red before descending and black after, can leave the
;;; root of the tree RED. rbtree4.cal fixed this with an explicit wrapper, and
;;; also strengthened its validator to catch two corruption classes its own
;;; predecessor's validator could not detect: right-leaning red links and
;;; BST order violations.
;;;
;;; This project's rbtree_lib_improved.scm had the same gaps:
;;;   - standalone rb-delete-min left the root red in 15/60 (25%) of calls
;;;     in a sequential 0..59 delete-min sweep
;;;   - rb-delete itself never painted the root red before descending either
;;;     (empirically harmless so far, but not guaranteed by construction)
;;;   - rb-validate/rb-check-property could not detect a right-leaning red
;;;     link or a BST order violation
;;;   - rb-search returning false for "not found" is indistinguishable from
;;;     a stored value of false (no separate membership predicate existed)
;;;
;;; This file verifies each fix.

(load "rbtree_lib_improved.scm")

(display "===========================================")
(newline)
(display "  rbtree robustness regression tests")
(newline)
(display "===========================================")
(newline)
(newline)

;;; Test result counters (same convention as test_improvements.scm)
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

;;; A silent validate: runs the same checks as rb-validate but without
;;; printing anything on success, so bulk loops stay readable. Prints on
;;; failure so a broken case is still diagnosable.
(define quiet-validate
  (lambda (node label)
    (cond
      ((rb-null? node) true)
      ((rb-is-red? node)
       (display "  VIOLATION (") (display label) (display "): root is red")
       (newline)
       false)
      (else
       (let ((height (rb-check-property node)))
         (set! rb-order-ok true)
         (set! rb-order-prev-set false)
         (rb-check-order node)
         (and (not (= height -1)) rb-order-ok))))))

;;; ===========================================================================
;;; Section 0: validator self-test - deliberately corrupted trees MUST be
;;; flagged. Mirrors rbtree4_test.cal section 0. Confirms the two checks
;;; added to rb-check-property/rb-validate (right-leaning red link, BST
;;; order) actually fire, and that the pre-existing checks still do too.
;;; ===========================================================================

(display "--- Section 0: validator self-test (each case MUST be rejected) ---")
(newline)

;; 0a. Right-leaning red link: black node with a RED right child and a
;; BLACK left child. This is exactly the shape the pre-fix validator could
;; not see, because it only ever asked "does a RED node have a red child",
;; never "does a BLACK node have a red RIGHT child".
(let ((bad (make-rb-node 10 "x")))
  (rb-set-color! bad BLACK)
  (rb-set-right! bad (make-rb-node 20 "y"))
  (rb-set-color! (rb-right bad) RED)
  (test-result "0a. detects right-leaning red link"
               (rb-validate bad)
               false))

;; 0b. BST order violation with colors/heights left untouched: swap two
;; children's keys so an in-order walk is no longer increasing, while
;; every node stays black (heights trivially match, no red-red anywhere).
(let ((bad (make-rb-node 10 "x")))
  (rb-set-color! bad BLACK)
  (rb-set-left! bad (make-rb-node 50 "left-but-bigger"))
  (rb-set-color! (rb-left bad) BLACK)
  (test-result "0b. detects BST order violation"
               (rb-validate bad)
               false))

;; 0c. Pre-existing check still works: red node with a red child.
(let ((bad (make-rb-node 10 "x")))
  (rb-set-color! bad BLACK)
  (rb-set-left! bad (make-rb-node 5 "y"))
  (rb-set-color! (rb-left bad) RED)
  (rb-set-left! (rb-left bad) (make-rb-node 3 "z"))
  (rb-set-color! (rb-left (rb-left bad)) RED)
  (test-result "0c. still detects red-red violation"
               (rb-validate bad)
               false))

;; 0d. Pre-existing check still works: red root.
(let ((bad (make-rb-node 10 "x")))
  (rb-set-color! bad RED)
  (test-result "0d. still detects red root"
               (rb-validate bad)
               false))

;; 0e. Sanity: a genuinely valid tree is still accepted (no false positives
;; from the new checks).
(let ((good RB-NIL))
  (set! good (rb-insert good 10 "a"))
  (set! good (rb-insert good 5 "b"))
  (set! good (rb-insert good 20 "c"))
  (set! good (rb-insert good 1 "d"))
  (set! good (rb-insert good 15 "e"))
  (test-result "0e. valid tree still accepted"
               (rb-validate good)
               true))

(newline)

;;; ===========================================================================
;;; Section 1: RB-02 regression - standalone rb-delete-min must never leave
;;; the root red. This is the exact scenario that failed 15/60 times before
;;; the fix (insert 0..59, then repeatedly call rb-delete-min directly and
;;; check the returned root's color and full validity after every call).
;;; ===========================================================================

(display "--- Section 1: rb-delete-min standalone (RB-02 regression) ---")
(newline)

(let ((n 60))
  (let ((root RB-NIL))
    (let loop ((i 0))
      (if (< i n)
          (begin
            (set! root (rb-insert root i (* i 100)))
            (loop (+ i 1)))))
    (let loop ((i 0) (tr root) (root-was-red 0) (invalid 0))
      (if (< i n)
          (let ((new-tr (rb-delete-min tr)))
            (loop (+ i 1)
                  new-tr
                  (+ root-was-red (if (and (not (rb-null? new-tr)) (rb-is-red? new-tr)) 1 0))
                  (+ invalid (if (quiet-validate new-tr "delete-min step") 0 1))))
          (begin
            (test-result "1a. rb-delete-min never leaves root red (60 calls)"
                         root-was-red 0)
            (test-result "1b. tree stays fully valid after every rb-delete-min"
                         invalid 0)
            (test-result "1c. all 60 elements were removed"
                         (rb-count-nodes tr) 0))))))

(newline)

;;; ===========================================================================
;;; Section 2: rb-delete robustness under patterns that specifically stress
;;; the delete-descent invariant: sequential ascending delete (each step
;;; removes the current minimum), and alternating min/max delete.
;;; ===========================================================================

(display "--- Section 2: rb-delete descent invariant ---")
(newline)

(let ((n 60))
  (let ((root RB-NIL))
    (let loop ((i 0))
      (if (< i n)
          (begin
            (set! root (rb-insert root i (* i 100)))
            (loop (+ i 1)))))
    (let loop ((i 0) (tr root) (bad 0))
      (if (< i n)
          (let ((new-tr (rb-delete tr i)))
            (loop (+ i 1)
                  new-tr
                  (+ bad
                     (if (quiet-validate new-tr "sequential delete") 0 1)
                     (if (= (rb-count-nodes new-tr) (- n i 1)) 0 1))))
          (test-result "2a. sequential ascending delete via rb-delete (60 steps)"
                       bad 0)))))

;; n=61 (odd), 30 rounds of (delete-min, delete-max) removes 60 keys and
;; leaves exactly the middle key (30) untouched - mirrors rbtree4_test.cal
;; section 3's "alternating" case exactly (including its two extra checks:
;; one node left, and it is the middle key).
(let ((n 61) (rounds 30))
  (let ((root RB-NIL))
    (let loop ((i 0))
      (if (< i n)
          (begin
            (set! root (rb-insert root i i))
            (loop (+ i 1)))))
    (let loop ((round 0) (lo 0) (hi (- n 1)) (tr root) (bad 0))
      (if (< round rounds)
          (let* ((tr1 (rb-delete tr lo))
                 (bad1 (+ bad (if (quiet-validate tr1 "alt delete-min") 0 1)))
                 (tr2 (rb-delete tr1 hi))
                 (bad2 (+ bad1 (if (quiet-validate tr2 "alt delete-max") 0 1))))
            (loop (+ round 1) (+ lo 1) (- hi 1) tr2 bad2))
          (begin
            (test-result "2b. alternating min/max delete via rb-delete (61 keys)"
                         bad 0)
            (test-result "2c. exactly one node left"
                         (rb-count-nodes tr) 1)
            (test-result "2d. it is the middle key"
                         (rb-key (rb-search-min-node tr)) 30))))))

(newline)

;;; ===========================================================================
;;; Section 3: rb-contains? - membership must not be confused with the
;;; stored value, specifically when the stored value is false itself.
;;; ===========================================================================

(display "--- Section 3: rb-contains? / not-found vs. false-value ---")
(newline)

(let ((tr RB-NIL))
  (set! tr (rb-insert tr 5 false))
  (set! tr (rb-insert tr 10 "ten"))
  (test-result "3a. rb-contains? true for a key whose value is false"
               (rb-contains? tr 5)
               true)
  (test-result "3b. rb-search still returns false for that same key"
               (rb-search tr 5)
               false)
  (test-result "3c. rb-contains? false for a genuinely absent key"
               (rb-contains? tr 999)
               false)
  (test-result "3d. rb-contains? true for an ordinary present key"
               (rb-contains? tr 10)
               true))

(newline)

;;; ===========================================================================
;;; Section 4: large-scale random fuzz, validating after every single
;;; operation (not just at the end of a batch).
;;; ===========================================================================

(display "--- Section 4: random fuzz, validate after every op ---")
(newline)

(let ((ops 1200) (max-val 400))
  (let loop ((i 0) (tr RB-NIL) (bad 0))
    (if (< i ops)
        (let ((k (random max-val)))
          (if (< (modulo i 3) 2)
              (let ((new-tr (rb-insert tr k i)))
                (loop (+ i 1) new-tr (+ bad (if (quiet-validate new-tr "fuzz insert") 0 1))))
              (let ((new-tr (rb-delete tr k)))
                (loop (+ i 1) new-tr (+ bad (if (quiet-validate new-tr "fuzz delete") 0 1))))))
        (test-result "4a. 1200 random insert/delete ops, always valid"
                     bad 0))))

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
      (display "*** ALL ROBUSTNESS TESTS PASSED ***")
      (newline))
    (begin
      (display "*** ")
      (display fail-count)
      (display " TEST(S) FAILED ***")
      (newline)))
(display "===========================================")
(newline)
