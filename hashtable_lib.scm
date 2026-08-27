;;;
;;; hashtable_lib.scm : Hash Table Library with Proper Collision Handling
;;;
;;; Fixed version: Uses chaining to handle hash collisions correctly
;;;

;;; Load the red-black tree library (明示的に有効化)
(load "rbtree_lib_improved.scm")

;;;============================================================================
;;; Hash Function Implementation
;;;============================================================================

;;; Simple string hash function (djb2 algorithm)
(define hash-string
  (lambda (str)
    (let loop ((chars (string->list str))
               (hash 5381))
      (if (null? chars)
          (modulo hash 2147483647)  ; Keep positive
          (let* ((c (char->integer (car chars)))
                 (new-hash (+ (* hash 33) c)))
            (loop (cdr chars) new-hash))))))

;;; Hash function dispatcher for different types
(define hash-value
  (lambda (key)
    (cond
      ((number? key) 
       (modulo key 2147483647))
      ((string? key) 
       (hash-string key))
      ((symbol? key) 
       (hash-string (symbol->string key)))
      ((boolean? key) 
       (if key 1 0))
      (else 
       (hash-string "unknown")))))

;;;============================================================================
;;; Hash Table Structure
;;;============================================================================

;;; Hash table structure: #(tree size metadata)
;;;   tree: red-black tree storing hash-key -> bucket
;;;   bucket: list of (original-key . value) pairs (for collision handling)
;;;   size: number of entries
;;;   metadata: reserved for future use

(define HT-TREE-INDEX 0)
(define HT-SIZE-INDEX 1)
(define HT-META-INDEX 2)

;;; Create a new hash table
(define make-hash-table
  (lambda ()
    (vector RB-NIL 0 '())))

;;; Get the underlying tree
(define ht-tree
  (lambda (ht)
    (vector-ref ht HT-TREE-INDEX)))

;;; Set the underlying tree
(define ht-set-tree!
  (lambda (ht tree)
    (vector-set! ht HT-TREE-INDEX tree)))

;;; Get the size
(define ht-size
  (lambda (ht)
    (vector-ref ht HT-SIZE-INDEX)))

;;; Set the size
(define ht-set-size!
  (lambda (ht size)
    (vector-set! ht HT-SIZE-INDEX size)))

;;; Increment size
(define ht-inc-size!
  (lambda (ht)
    (ht-set-size! ht (+ (ht-size ht) 1))))

;;; Decrement size
(define ht-dec-size!
  (lambda (ht)
    (ht-set-size! ht (- (ht-size ht) 1))))

;;;============================================================================
;;; Bucket Operations (Chaining for Collision Handling)
;;;============================================================================

;;; Bucket: list of (key . value) pairs
;;; Example: ((key1 . val1) (key2 . val2) ...)

;;; Create an entry
(define make-ht-entry
  (lambda (key value)
    (cons key value)))

;;; Get key from entry
(define ht-entry-key car)

;;; Get value from entry
(define ht-entry-value cdr)

;;; Set value in entry
(define ht-set-entry-value!
  (lambda (entry value)
    (set-cdr! entry value)))

;;; Check if two keys are equal (type-aware)
(define ht-keys-equal?
  (lambda (k1 k2)
    (cond
      ((and (number? k1) (number? k2)) (= k1 k2))
      ((and (string? k1) (string? k2)) (string=? k1 k2))
      ((and (symbol? k1) (symbol? k2)) (eq? k1 k2))
      ((and (boolean? k1) (boolean? k2)) (eq? k1 k2))
      (else (equal? k1 k2)))))

;;; Find entry in bucket by key
(define bucket-find
  (lambda (bucket key)
    (if (null? bucket)
        false
        (let ((entry (car bucket)))
          (if (ht-keys-equal? (ht-entry-key entry) key)
              entry
              (bucket-find (cdr bucket) key))))))

;;; Add or update entry in bucket
;;; Returns: (new-bucket . added?)
;;; added? is true if new entry was added, false if updated
(define bucket-set
  (lambda (bucket key value)
    (if (null? bucket)
        ;; Empty bucket, add new entry
        (cons (list (make-ht-entry key value)) true)
        (let ((entry (car bucket))
              (rest (cdr bucket)))
          (if (ht-keys-equal? (ht-entry-key entry) key)
              ;; Found matching key, update value
              (begin
                (ht-set-entry-value! entry value)
                (cons bucket false))
              ;; Continue searching
              (let ((result (bucket-set rest key value)))
                (cons (cons entry (car result)) (cdr result))))))))

;;; Remove entry from bucket by key
;;; Returns: (new-bucket . removed?)
(define bucket-remove
  (lambda (bucket key)
    (if (null? bucket)
        (cons '() false)
        (let ((entry (car bucket))
              (rest (cdr bucket)))
          (if (ht-keys-equal? (ht-entry-key entry) key)
              ;; Found it, remove
              (cons rest true)
              ;; Continue searching
              (let ((result (bucket-remove rest key)))
                (cons (cons entry (car result)) (cdr result))))))))

;;; Get all entries from bucket
(define bucket-entries
  (lambda (bucket)
    bucket))

;;;============================================================================
;;; Core Hash Table Operations
;;;============================================================================

;;; Set a key-value pair
(define hash-table-set!
  (lambda (ht key value)
    (let* ((hash-key (hash-value key))
           (tree (ht-tree ht))
           (bucket (rb-search tree hash-key)))
      (if bucket
          ;; Bucket exists, add/update entry
          (let ((result (bucket-set bucket key value)))
            (let ((new-bucket (car result))
                  (added? (cdr result)))
              ;; Update bucket in tree
              (ht-set-tree! ht (rb-insert tree hash-key new-bucket))
              ;; Increment size if new entry was added
              (if added? (ht-inc-size! ht))))
          ;; No bucket, create new one
          (begin
            (ht-set-tree! ht (rb-insert tree hash-key 
                                       (list (make-ht-entry key value))))
            (ht-inc-size! ht)))
      value)))

;;; Get a value by key
(define hash-table-get
  (lambda (ht key . default)
    (let* ((hash-key (hash-value key))
           (tree (ht-tree ht))
           (bucket (rb-search tree hash-key)))
      (if bucket
          (let ((entry (bucket-find bucket key)))
            (if entry
                (ht-entry-value entry)
                (if (null? default) false (car default))))
          (if (null? default) false (car default))))))

;;; Check if key exists
(define hash-table-has-key?
  (lambda (ht key)
    (let* ((hash-key (hash-value key))
           (tree (ht-tree ht))
           (bucket (rb-search tree hash-key)))
      (if bucket
          (if (bucket-find bucket key) true false)
          false))))

;;; Delete a key
(define hash-table-delete!
  (lambda (ht key)
    (let* ((hash-key (hash-value key))
           (tree (ht-tree ht))
           (bucket (rb-search tree hash-key)))
      (if bucket
          (let ((result (bucket-remove bucket key)))
            (let ((new-bucket (car result))
                  (removed? (cdr result)))
              (if removed?
                  (begin
                    ;; If bucket is now empty, remove from tree
                    (if (null? new-bucket)
                        (ht-set-tree! ht (rb-delete tree hash-key))
                        (ht-set-tree! ht (rb-insert tree hash-key new-bucket)))
                    (ht-dec-size! ht)
                    true)
                  false)))
          false))))

;;; Get the number of entries
(define hash-table-size
  (lambda (ht)
    (ht-size ht)))

;;; Clear all entries
(define hash-table-clear!
  (lambda (ht)
    (ht-set-tree! ht RB-NIL)
    (ht-set-size! ht 0)
    ht))

;;; Check if hash table is empty
(define hash-table-empty?
  (lambda (ht)
    (= (ht-size ht) 0)))

;;;============================================================================
;;; Iteration and Collection Operations
;;;============================================================================

;;; Internal: Extract all entries from all buckets (in-order)
(define ht-tree-to-entries
  (lambda (node)
    (if (rb-null? node)
        '()
        (append (ht-tree-to-entries (rb-left node))
                (bucket-entries (rb-data node))
                (ht-tree-to-entries (rb-right node))))))

;;; Get all keys
(define hash-table-keys
  (lambda (ht)
    (let ((entries (ht-tree-to-entries (ht-tree ht))))
      (map ht-entry-key entries))))

;;; Get all values
(define hash-table-values
  (lambda (ht)
    (let ((entries (ht-tree-to-entries (ht-tree ht))))
      (map ht-entry-value entries))))

;;; Get all entries as association list ((key . value) ...)
(define hash-table->alist
  (lambda (ht)
    (ht-tree-to-entries (ht-tree ht))))

;;; Create hash table from association list
(define alist->hash-table
  (lambda (alist)
    (let ((ht (make-hash-table)))
      (for-each (lambda (pair)
                  (hash-table-set! ht (car pair) (cdr pair)))
                alist)
      ht)))

;;; For-each over hash table entries
(define hash-table-for-each
  (lambda (ht proc)
    (for-each (lambda (entry)
                (proc (ht-entry-key entry) (ht-entry-value entry)))
              (ht-tree-to-entries (ht-tree ht)))))

;;; Map over hash table entries
(define hash-table-map
  (lambda (ht proc)
    (map (lambda (entry)
           (proc (ht-entry-key entry) (ht-entry-value entry)))
         (ht-tree-to-entries (ht-tree ht)))))

;;; Filter hash table entries
(define hash-table-filter
  (lambda (ht pred)
    (let ((new-ht (make-hash-table)))
      (hash-table-for-each ht
        (lambda (key value)
          (if (pred key value)
              (hash-table-set! new-ht key value))))
      new-ht)))

;;; Fold over hash table entries
(define hash-table-fold
  (lambda (ht proc init)
    (let loop ((entries (ht-tree-to-entries (ht-tree ht)))
               (acc init))
      (if (null? entries)
          acc
          (loop (cdr entries)
                (proc (ht-entry-key (car entries))
                      (ht-entry-value (car entries))
                      acc))))))

;;;============================================================================
;;; Utility Operations
;;;============================================================================

;;; Update value if key exists, insert if not
(define hash-table-update!
  (lambda (ht key proc . default)
    (let ((current (apply hash-table-get ht key default)))
      (hash-table-set! ht key (proc current)))))

;;; Merge two hash tables (ht2 values override ht1)
(define hash-table-merge
  (lambda (ht1 ht2)
    (let ((result (make-hash-table)))
      (hash-table-for-each ht1
        (lambda (k v) (hash-table-set! result k v)))
      (hash-table-for-each ht2
        (lambda (k v) (hash-table-set! result k v)))
      result)))

;;; Copy a hash table
(define hash-table-copy
  (lambda (ht)
    (let ((result (make-hash-table)))
      (hash-table-for-each ht
        (lambda (k v) (hash-table-set! result k v)))
      result)))

;;;============================================================================
;;; Display and Debug Functions
;;;============================================================================

;;; Display hash table contents
(define hash-table-display
  (lambda (ht)
    (display "Hash Table {")
    (newline)
    (hash-table-for-each ht
      (lambda (key value)
        (display "  ")
        (display key)
        (display " => ")
        (display value)
        (newline)))
    (display "}")
    (newline)
    (display "Size: ")
    (display (hash-table-size ht))
    (newline)))

;;; Validate hash table structure
(define hash-table-validate
  (lambda (ht)
    (display "Validating hash table...")
    (newline)
    (let ((tree-valid (rb-validate (ht-tree ht)))
          (counted-size (length (ht-tree-to-entries (ht-tree ht))))
          (stored-size (ht-size ht)))
      (display "  Tree: ")
      (display (if tree-valid "PASS" "FAIL"))
      (newline)
      (display "  Size: stored=")
      (display stored-size)
      (display ", actual=")
      (display counted-size)
      (display " ")
      (display (if (= stored-size counted-size) "PASS" "FAIL"))
      (newline)
      (and tree-valid (= stored-size counted-size)))))

;;; Show hash statistics including collision info
(define hash-table-stats
  (lambda (ht)
    (display "Hash Table Statistics:")
    (newline)
    (display "  Size: ")
    (display (hash-table-size ht))
    (newline)
    (display "  Empty: ")
    (display (hash-table-empty? ht))
    (newline)
    (display "  Tree nodes (buckets): ")
    (display (rb-count-nodes (ht-tree ht)))
    (newline)
    
    ;; Collision analysis
    (let ((tree (ht-tree ht)))
      (if (not (rb-null? tree))
          (let ((buckets (ht-collect-buckets tree)))
            (let ((total-buckets (length buckets))
                  (collisions (ht-count-collisions buckets)))
              (display "  Buckets with collisions: ")
              (display collisions)
              (display " / ")
              (display total-buckets)
              (newline)
              (if (> collisions 0)
                  (begin
                    (display "  Collision rate: ")
                    (display (/ (* collisions 100) total-buckets))
                    (display "%")
                    (newline)))))))))

;;; Helper: collect all buckets from tree
(define ht-collect-buckets
  (lambda (node)
    (if (rb-null? node)
        '()
        (append (ht-collect-buckets (rb-left node))
                (list (rb-data node))
                (ht-collect-buckets (rb-right node))))))

;;; Helper: count buckets with multiple entries
(define ht-count-collisions
  (lambda (buckets)
    (let loop ((bs buckets) (count 0))
      (if (null? bs)
          count
          (loop (cdr bs)
                (if (> (length (car bs)) 1)
                    (+ count 1)
                    count))))))

;;;============================================================================
;;; Utility Macros
;;;============================================================================

;;; Convenient hash table reference
(define-macro ht-ref
  (lambda (ht key . default)
    (if (null? default)
        `(hash-table-get ,ht ,key)
        `(hash-table-get ,ht ,key ,(car default)))))

;;; Convenient hash table update
(define-macro ht-set!
  (lambda (ht key value)
    `(hash-table-set! ,ht ,key ,value)))

;;; Convenient existence check
(define-macro ht-has?
  (lambda (ht key)
    `(hash-table-has-key? ,ht ,key)))

;;;============================================================================
;;; Test Functions
;;;============================================================================

;;; COLLISION TEST: Keys with intentionally same hash value
(define ht-test-collision
  (lambda ()
    (newline)
    (display "=== Hash Collision Test ===")
    (newline)
    
    (let ((ht (make-hash-table)))
      ;; Create keys that will likely collide
      ;; Using modulo, some numbers will have same hash
      (display "Testing collision handling...")
      (newline)
      
      (hash-table-set! ht 5 "value-5")
      (hash-table-set! ht 2147483652 "value-2147483652")  ; 5 + 2147483647
      (hash-table-set! ht 4294967299 "value-4294967299")  ; 5 + 2*2147483647
      
      (display "Set keys with same hash modulo: 5, 2147483652, 4294967299")
      (newline)
      (newline)
      
      (display "Retrieving values:")
      (newline)
      (display "  key 5 => ")
      (display (hash-table-get ht 5))
      (newline)
      (display "  key 2147483652 => ")
      (display (hash-table-get ht 2147483652))
      (newline)
      (display "  key 4294967299 => ")
      (display (hash-table-get ht 4294967299))
      (newline)
      (newline)
      
      (display "All keys preserved: ")
      (display (hash-table-keys ht))
      (newline)
      (display "Size: ")
      (display (hash-table-size ht))
      (newline)
      (newline)
      
      (display "Deleting middle key (2147483652)...")
      (newline)
      (hash-table-delete! ht 2147483652)
      
      (display "Remaining keys: ")
      (display (hash-table-keys ht))
      (newline)
      (display "key 5 still accessible? ")
      (display (hash-table-get ht 5))
      (newline)
      (display "key 4294967299 still accessible? ")
      (display (hash-table-get ht 4294967299))
      (newline)
      (newline)
      
      (hash-table-stats ht)
      (hash-table-validate ht)
      (newline)
      (display "Collision test completed!")
      (newline)
      ht)))

;;; Basic functionality test
(define ht-test-basic
  (lambda ()
    (newline)
    (display "=== Hash Table Basic Test ===")
    (newline)
    
    (let ((ht (make-hash-table)))
      (display "Created empty hash table")
      (newline)
      (display "Size: ")
      (display (hash-table-size ht))
      (newline)
      (newline)
      
      (display "Setting key-value pairs:")
      (newline)
      (hash-table-set! ht "name" "Alice")
      (hash-table-set! ht "age" 30)
      (hash-table-set! ht "city" "Tokyo")
      (hash-table-set! ht 'status "Active")
      (hash-table-set! ht 12345 "Number key")
      (hash-table-set! ht true "Boolean key")
      
      (display "Keys: ")
      (display (hash-table-keys ht))
      (newline)
      (newline)
      
      (display "Getting values:")
      (newline)
      (display "  name => ")
      (display (hash-table-get ht "name"))
      (newline)
      (display "  age => ")
      (display (hash-table-get ht "age"))
      (newline)
      (display "  status => ")
      (display (hash-table-get ht 'status))
      (newline)
      (display "  12345 => ")
      (display (hash-table-get ht 12345))
      (newline)
      (display "  true => ")
      (display (hash-table-get ht true))
      (newline)
      (display "  unknown => ")
      (display (hash-table-get ht "unknown" "DEFAULT"))
      (newline)
      (newline)
      
      (display "Updating 'age':")
      (newline)
      (hash-table-set! ht "age" 31)
      (display "  age => ")
      (display (hash-table-get ht "age"))
      (newline)
      (newline)
      
      (hash-table-display ht)
      (hash-table-stats ht)
      (hash-table-validate ht)
      ht)))

;;; Stress test with collision tracking
(define ht-test-stress
  (lambda (n)
    (newline)
    (display "=== Stress Test with Collision Tracking (")
    (display n)
    (display " entries) ===")
    (newline)
    
    (let ((ht (make-hash-table)))
      (display "Inserting...")
      (newline)
      (let loop ((i 0))
        (if (< i n)
            (begin
              (hash-table-set! ht 
                              (string-append "key-" (number->string i))
                              (* i i))
              (if (= (modulo i 100) 0)
                  (begin
                    (display ".")
                    (if (= (modulo i 1000) 0)
                        (display " "))))
              (loop (+ i 1)))))
      (newline)
      
      (hash-table-stats ht)
      (hash-table-validate ht)
      
      (newline)
      (display "Test completed!")
      (newline)
      ht)))

(newline)
(display "Hash Table Library (Fixed with Chaining) loaded.")
(newline)
(display "Supported key types: numbers, strings, symbols, booleans")
(newline)
(newline)
(display "Commands:")
(newline)
(display "  (ht-test-collision)   - Test hash collision handling")
(newline)
(display "  (ht-test-basic)       - Basic functionality test")
(newline)
(display "  (ht-test-stress 1000) - Stress test with N entries")
(newline)
