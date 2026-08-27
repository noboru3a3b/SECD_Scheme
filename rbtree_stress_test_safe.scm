;;;
;;; rbtree_stress_test_safe.scm : Safe version with GC management
;;;

(load "rbtree_lib_improved.scm")

;;; GC management helpers
(define gc-info
  (lambda ()
    (display "Heap size: ")
    (display (gc-heap-size))
    (display " bytes, Free: ")
    (display (gc-free-bytes))
    (display " bytes")
    (newline)))

(define maybe-gc
  (lambda (force)
    (if force
        (begin
          (display "[Forcing GC...] ")
          (gc-collect)
          (gc-info))
        false)))

;;; Generate random integer list
(define make-random-list
  (lambda (n max-val)
    (let loop ((i 0) (acc '()))
      (if (>= i n)
          acc
          (loop (+ i 1) (cons (random max-val) acc))))))

;;; Random insertion test with GC
(define rb-random-insert-test-safe
  (lambda (n max-val gc-interval)
    (newline)
    (display "=== Random Insertion Test (with GC) ===")
    (newline)
    (display "Inserting ")
    (display n)
    (display " random keys (range: 0-")
    (display (- max-val 1))
    (display ")")
    (newline)
    
    (let ((keys (make-random-list n max-val))
          (tree RB-NIL))
      (display "Generated keys (sample): ")
      (display (if (> n 20) 
                   (append (list-head keys 20) '(...))
                   keys))
      (newline)
      
      (gc-info)
      (newline)
      
      (let loop ((ks keys) (tr tree) (count 0))
        (if (null? ks)
            (begin
              (newline)
              (display "Final node count: ")
              (display (rb-count-nodes tr))
              (newline)
              (gc-info)
              (rb-validate tr)
              tr)
            (begin
              ;; Progress and GC
              (if (= (modulo count gc-interval) 0)
                  (begin
                    (if (> count 0)
                        (begin
                          (display "Progress: ")
                          (display count)
                          (display "/")
                          (display n)
                          (display " ")
                          (gc-info)))
                    (maybe-gc (= (modulo count (* gc-interval 10)) 0))))
              (loop (cdr ks) 
                    (rb-insert tr (car ks) (car ks))
                    (+ count 1))))))))

;;; Random deletion test with GC
(define rb-random-delete-test-safe
  (lambda (tree n gc-interval)
    (newline)
    (display "=== Random Deletion Test (with GC) ===")
    (newline)
    (display "Deleting ")
    (display n)
    (display " random keys")
    (newline)
    
    (let ((keys (rb-to-list tree))
          (tr tree))
      (if (< (length keys) n)
          (begin
            (display "Not enough keys in tree (")
            (display (length keys))
            (display " available)")
            (newline)
            tree)
          (begin
            (gc-info)
            (newline)
            (let loop ((i 0) (tr tr) (remaining-keys keys))
              (if (>= i n)
                  (begin
                    (newline)
                    (display "Final node count: ")
                    (display (rb-count-nodes tr))
                    (newline)
                    (gc-info)
                    (rb-validate tr)
                    tr)
                  (begin
                    ;; Progress and GC
                    (if (= (modulo i gc-interval) 0)
                        (begin
                          (if (> i 0)
                              (begin
                                (display "Progress: ")
                                (display i)
                                (display "/")
                                (display n)
                                (display " ")
                                (gc-info)))
                          (maybe-gc (= (modulo i (* gc-interval 10)) 0))))
                    (let* ((idx (random (length remaining-keys)))
                           (key (list-ref remaining-keys idx))
                           (new-remaining (filter (lambda (k) (not (= k key))) 
                                                 remaining-keys)))
                      (loop (+ i 1) 
                            (rb-delete tr key)
                            new-remaining))))))))))

;;; Mixed operations test
(define rb-random-mixed-test-safe
  (lambda (n-insert n-delete max-val)
    (newline)
    (display "=== Mixed Random Operations Test (Safe) ===")
    (newline)
    (display "Phase 1: Insert ")
    (display n-insert)
    (display " keys")
    (newline)
    
    (let ((tree (rb-random-insert-test-safe n-insert max-val 100)))
      (display "Phase 2: Delete ")
      (display n-delete)
      (display " keys")
      (newline)
      (rb-random-delete-test-safe tree n-delete 100))))

;;; Scaled tests
(define rb-small-scale-test
  (lambda ()
    (newline)
    (display "=== Small-Scale Test (500 ops) ===")
    (newline)
    (rb-random-mixed-test-safe 500 250 5000)))

(define rb-medium-scale-test
  (lambda ()
    (newline)
    (display "=== Medium-Scale Test (2000 ops) ===")
    (newline)
    (rb-random-mixed-test-safe 2000 1000 20000)))

(define rb-large-scale-test-safe
  (lambda ()
    (newline)
    (display "=== Large-Scale Stress Test (Safe) ===")
    (newline)
    
    (display "Test 1: 1000 insertions, 500 deletions")
    (rb-random-mixed-test-safe 1000 500 10000)
    
    (newline)
    (display "Test 2: 3000 insertions, 1500 deletions")
    (rb-random-mixed-test-safe 3000 1500 30000)
    
    (newline)
    (display "=== All tests completed ===")
    (newline)))

;;; Quick test without GC monitoring
(define rb-quick-test
  (lambda ()
    (newline)
    (display "=== Quick Test ===")
    (newline)
    (let ((tree RB-NIL))
      (display "Inserting 100 random keys...")
      (newline)
      (let loop ((i 0) (tr tree))
        (if (>= i 100)
            (begin
              (display "Node count: ")
              (display (rb-count-nodes tr))
              (newline)
              (rb-validate tr)
              (display "Keys (sample): ")
              (let ((keys (rb-to-list tr)))
                (display (if (> (length keys) 20)
                            (append (list-head keys 20) '(...))
                            keys)))
              (newline)
              tr)
            (loop (+ i 1) (rb-insert tr (random 1000) i)))))))

;;; Helper functions
(define list-head
  (lambda (ls n)
    (if (or (null? ls) (<= n 0))
        '()
        (cons (car ls) (list-head (cdr ls) (- n 1))))))

(define list-ref
  (lambda (ls n)
    (if (= n 0)
        (car ls)
        (list-ref (cdr ls) (- n 1)))))

(newline)
(display "Red-Black Tree Stress Test Library (Safe) loaded.")
(newline)
(display "Commands:")
(newline)
(display "  (rb-quick-test)             - Quick 100 insertions test")
(newline)
(display "  (rb-small-scale-test)       - 500 insertions, 250 deletions")
(newline)
(display "  (rb-medium-scale-test)      - 2000 insertions, 1000 deletions")
(newline)
(display "  (rb-large-scale-test-safe)  - Safe large-scale test")
(newline)
(display "  (gc-info)                   - Show GC information")
(newline)
(display "  (gc-collect)                - Force garbage collection")
(newline)
