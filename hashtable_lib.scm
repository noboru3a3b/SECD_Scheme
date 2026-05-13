;;;
;;; hashtable_lib.scm : Hash Table Library based on Red-Black Tree
;;;
;;; Proper implementation using symbol->string for consistent symbol hashing
;;;

;;; Load the red-black tree library
;; (load "rbtree_lib_improved.scm")

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
       ;; Numbers: use modulo to ensure valid range
       (modulo key 2147483647))
      ((string? key) 
       ;; Strings: use hash function
       (hash-string key))
      ((symbol? key) 
       ;; Symbols: convert to string and hash
       (hash-string (symbol->string key)))
      ((boolean? key) 
       ;; Booleans: simple numeric mapping
       (if key 1 0))
      (else 
       ;; Fallback: hash the string representation
       (hash-string "unknown")))))

;;;============================================================================
;;; Hash Table Structure
;;;============================================================================

;;; Hash table structure: #(tree size metadata)
;;;   tree: red-black tree storing hash-key -> (original-key . value)
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
;;; Entry Structure
;;;============================================================================

;;; Entry: (original-key . value)
(define make-ht-entry
  (lambda (key value)
    (cons key value)))

(define ht-entry-key
  (lambda (entry)
    (car entry)))

(define ht-entry-value
  (lambda (entry)
    (cdr entry)))

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

;;;============================================================================
;;; Core Hash Table Operations
;;;============================================================================

;;; Set a key-value pair
(define hash-table-set!
  (lambda (ht key value)
    (let* ((hash-key (hash-value key))
           (tree (ht-tree ht))
           (existing (rb-search tree hash-key)))
      (if existing
          ;; Hash key exists - check if same original key
          (let ((entry existing))
            (if (ht-keys-equal? (ht-entry-key entry) key)
                ;; Same key, update value
                (ht-set-entry-value! entry value)
                ;; Hash collision with different key (rare but possible)
                (begin
                  (display "Warning: Hash collision between ")
                  (display (ht-entry-key entry))
                  (display " and ")
                  (display key)
                  (newline)
                  ;; Overwrite (proper implementation would use chaining)
                  (ht-set-entry-value! entry value))))
          ;; New key, insert
          (begin
            (ht-set-tree! ht (rb-insert tree hash-key (make-ht-entry key value)))
            (ht-inc-size! ht)))
      value)))

;;; Get a value by key
(define hash-table-get
  (lambda (ht key . default)
    (let* ((hash-key (hash-value key))
           (tree (ht-tree ht))
           (result (rb-search tree hash-key)))
      (if result
          (if (ht-keys-equal? (ht-entry-key result) key)
              (ht-entry-value result)
              ;; Hash collision - different key
              (if (null? default)
                  false
                  (car default)))
          (if (null? default)
              false
              (car default))))))

;;; Check if key exists
(define hash-table-has-key?
  (lambda (ht key)
    (let* ((hash-key (hash-value key))
           (tree (ht-tree ht))
           (result (rb-search tree hash-key)))
      (if result
          (ht-keys-equal? (ht-entry-key result) key)
          false))))

;;; Delete a key
(define hash-table-delete!
  (lambda (ht key)
    (let* ((hash-key (hash-value key))
           (tree (ht-tree ht))
           (existing (rb-search tree hash-key)))
      (if existing
          (if (ht-keys-equal? (ht-entry-key existing) key)
              (begin
                (ht-set-tree! ht (rb-delete tree hash-key))
                (ht-dec-size! ht)
                true)
              false)
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

;;; Internal: Extract entries from tree (in-order)
(define ht-tree-to-entries
  (lambda (node)
    (if (rb-null? node)
        '()
        (append (ht-tree-to-entries (rb-left node))
                (list (rb-data node))
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
    (let ((entries (ht-tree-to-entries (ht-tree ht))))
      (map (lambda (entry)
             (cons (ht-entry-key entry) (ht-entry-value entry)))
           entries))))

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

;;; Show hash statistics
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
    (display "  Tree nodes: ")
    (display (rb-count-nodes (ht-tree ht)))
    (newline)))

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
      
      (display "Key existence:")
      (newline)
      (display "  Has 'name'? ")
      (display (hash-table-has-key? ht "name"))
      (newline)
      (display "  Has 'status'? ")
      (display (hash-table-has-key? ht 'status))
      (newline)
      (display "  Has 'unknown'? ")
      (display (hash-table-has-key? ht "unknown"))
      (newline)
      (newline)
      
      (display "Updating 'age':")
      (newline)
      (hash-table-set! ht "age" 31)
      (display "  age => ")
      (display (hash-table-get ht "age"))
      (newline)
      (newline)
      
      (display "Deleting 'city':")
      (newline)
      (hash-table-delete! ht "city")
      (display "  Size: ")
      (display (hash-table-size ht))
      (newline)
      (display "  Has 'city'? ")
      (display (hash-table-has-key? ht "city"))
      (newline)
      (newline)
      
      (display "Final contents:")
      (newline)
      (hash-table-display ht)
      
      (hash-table-validate ht)
      (newline)
      (display "Test completed!")
      (newline)
      ht)))

;;; Symbol key test
(define ht-test-symbols
  (lambda ()
    (newline)
    (display "=== Symbol Key Test ===")
    (newline)
    
    (let ((ht (make-hash-table)))
      (display "Setting symbol keys:")
      (newline)
      (hash-table-set! ht 'apple "red fruit")
      (hash-table-set! ht 'banana "yellow fruit")
      (hash-table-set! ht 'cherry "red fruit")
      (hash-table-set! ht 'date "brown fruit")
      (hash-table-set! ht 'elderberry "purple fruit")
      
      (newline)
      (hash-table-display ht)
      
      (display "Retrieving by symbol:")
      (newline)
      (display "  apple => ")
      (display (hash-table-get ht 'apple))
      (newline)
      (display "  banana => ")
      (display (hash-table-get ht 'banana))
      (newline)
      (display "  cherry => ")
      (display (hash-table-get ht 'cherry))
      (newline)
      (newline)
      
      (display "Updating symbol key:")
      (newline)
      (hash-table-set! ht 'apple "green fruit")
      (display "  apple => ")
      (display (hash-table-get ht 'apple))
      (newline)
      (newline)
      
      (display "Deleting symbol key:")
      (newline)
      (hash-table-delete! ht 'date)
      (display "  Size: ")
      (display (hash-table-size ht))
      (newline)
      (display "  Has 'date'? ")
      (display (hash-table-has-key? ht 'date))
      (newline)
      (newline)
      
      (hash-table-validate ht)
      ht)))

;;; Type mixing test
(define ht-test-types
  (lambda ()
    (newline)
    (display "=== Mixed Type Key Test ===")
    (newline)
    
    (let ((ht (make-hash-table)))
      (display "Setting different key types:")
      (newline)
      (hash-table-set! ht "string" 1)
      (hash-table-set! ht 42 2)
      (hash-table-set! ht 'symbol 3)
      (hash-table-set! ht true 4)
      (hash-table-set! ht false 5)
      
      (newline)
      (hash-table-display ht)
      
      (display "Retrieving all:")
      (newline)
      (display "  String: ")
      (display (hash-table-get ht "string"))
      (newline)
      (display "  Number: ")
      (display (hash-table-get ht 42))
      (newline)
      (display "  Symbol: ")
      (display (hash-table-get ht 'symbol))
      (newline)
      (display "  True: ")
      (display (hash-table-get ht true))
      (newline)
      (display "  False: ")
      (display (hash-table-get ht false))
      (newline)
      (newline)
      
      (hash-table-validate ht)
      ht)))

;;; Iteration test
(define ht-test-iteration
  (lambda ()
    (newline)
    (display "=== Iteration Test ===")
    (newline)
    
    (let ((ht (make-hash-table)))
      (hash-table-set! ht "a" 1)
      (hash-table-set! ht "b" 2)
      (hash-table-set! ht "c" 3)
      (hash-table-set! ht "d" 4)
      (hash-table-set! ht "e" 5)
      
      (display "Original:")
      (newline)
      (hash-table-display ht)
      (newline)
      
      (display "For-each (multiply by 10):")
      (newline)
      (hash-table-for-each ht
        (lambda (k v)
          (display "  ")
          (display k)
          (display " * 10 = ")
          (display (* v 10))
          (newline)))
      (newline)
      
      (display "Map (square):")
      (newline)
      (display "  ")
      (display (hash-table-map ht (lambda (k v) (* v v))))
      (newline)
      (newline)
      
      (display "Filter (even values):")
      (newline)
      (let ((filtered (hash-table-filter ht (lambda (k v) (= (modulo v 2) 0)))))
        (hash-table-display filtered))
      (newline)
      
      (display "Fold (sum):")
      (newline)
      (display "  ")
      (display (hash-table-fold ht (lambda (k v acc) (+ v acc)) 0))
      (newline)
      (newline)
      
      (display "To alist:")
      (newline)
      (display "  ")
      (display (hash-table->alist ht))
      (newline)
      
      ht)))

;;; Stress test
(define ht-test-stress
  (lambda (n)
    (newline)
    (display "=== Stress Test (")
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
      
      (display "Size: ")
      (display (hash-table-size ht))
      (newline)
      (hash-table-validate ht)
      
      (newline)
      (display "Sample lookups:")
      (newline)
      (display "  key-0 => ")
      (display (hash-table-get ht "key-0"))
      (newline)
      (display "  key-50 => ")
      (display (hash-table-get ht "key-50"))
      (newline)
      (display "  key-100 => ")
      (display (hash-table-get ht "key-100"))
      (newline)
      (newline)
      
      (display "Deleting half...")
      (newline)
      (let loop ((i 0))
        (if (< i n)
            (begin
              (if (= (modulo i 2) 0)
                  (hash-table-delete! ht (string-append "key-" (number->string i))))
              (loop (+ i 1)))))
      
      (display "Size after deletion: ")
      (display (hash-table-size ht))
      (newline)
      (hash-table-validate ht)
      
      (newline)
      (display "Test completed!")
      (newline)
      ht)))

;;; Simple usage example
(define ht-example
  (lambda ()
    (newline)
    (display "=== Simple Example ===")
    (newline)
    
    (let ((phonebook (make-hash-table)))
      (display "Creating phonebook...")
      (newline)
      
      (hash-table-set! phonebook "Alice" "090-1234-5678")
      (hash-table-set! phonebook "Bob" "080-9876-5432")
      (hash-table-set! phonebook "Charlie" "070-1111-2222")
      
      (display "Entries:")
      (newline)
      (hash-table-display phonebook)
      (newline)
      
      (display "Looking up Alice: ")
      (display (hash-table-get phonebook "Alice"))
      (newline)
      (newline)
      
      (display "Updating Bob:")
      (newline)
      (hash-table-set! phonebook "Bob" "080-0000-1111")
      (display "Bob => ")
      (display (hash-table-get phonebook "Bob"))
      (newline)
      (newline)
      
      (display "Using macros:")
      (newline)
      (display "  (ht-ref phonebook \"Charlie\") => ")
      (display (ht-ref phonebook "Charlie"))
      (newline)
      (display "  (ht-has? phonebook \"Alice\") => ")
      (display (ht-has? phonebook "Alice"))
      (newline)
      (newline)
      
      (display "Test completed!")
      (newline)
      phonebook)))

(newline)
(display "Hash Table Library loaded.")
(newline)
(display "Supported key types: numbers, strings, symbols, booleans")
(newline)
(newline)
(display "Commands:")
(newline)
(display "  (ht-example)          - Simple phonebook example")
(newline)
(display "  (ht-test-basic)       - Basic functionality test")
(newline)
(display "  (ht-test-symbols)     - Symbol key test")
(newline)
(display "  (ht-test-types)       - Mixed type test")
(newline)
(display "  (ht-test-iteration)   - Iteration test")
(newline)
(display "  (ht-test-stress 1000) - Stress test with N entries")
(newline)