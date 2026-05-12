;;;
;;; rbtree_lib_improved.scm : Red-Black Tree Library for scheme12 (Improved Display)
;;;

;;; Constants
(define BLACK 0)
(define RED 1)
(define RB-NIL ":nil")

;;; Utility: nil check
(define rb-null?
  (lambda (node)
    (or (null? node)
        (eq? node RB-NIL)
        (equal? node RB-NIL))))

;;; Node creation
(define make-rb-node
  (lambda (key data)
    (vector RB-NIL RB-NIL RED key data)))

;;; Accessors
(define rb-left
  (lambda (node)
    (if (rb-null? node) RB-NIL (vector-ref node 0))))

(define rb-right
  (lambda (node)
    (if (rb-null? node) RB-NIL (vector-ref node 1))))

(define rb-color
  (lambda (node)
    (if (rb-null? node) BLACK (vector-ref node 2))))

(define rb-key
  (lambda (node)
    (if (rb-null? node) 
        (begin (display "Error: rb-key on nil node") (newline) 0)
        (vector-ref node 3))))

(define rb-data
  (lambda (node)
    (if (rb-null? node) 
        (begin (display "Error: rb-data on nil node") (newline) false)
        (vector-ref node 4))))

;;; Setters
(define rb-set-left!
  (lambda (node left)
    (if (not (rb-null? node))
        (vector-set! node 0 left))))

(define rb-set-right!
  (lambda (node right)
    (if (not (rb-null? node))
        (vector-set! node 1 right))))

(define rb-set-color!
  (lambda (node color)
    (if (not (rb-null? node))
        (vector-set! node 2 color))))

(define rb-set-key!
  (lambda (node key)
    (if (not (rb-null? node))
        (vector-set! node 3 key))))

(define rb-set-data!
  (lambda (node data)
    (if (not (rb-null? node))
        (vector-set! node 4 data))))

;;; Color predicates
(define rb-is-red?
  (lambda (node)
    (if (rb-null? node) false (= (rb-color node) RED))))

(define rb-is-black?
  (lambda (node)
    (if (rb-null? node) true (= (rb-color node) BLACK))))

;;; Right rotation
(define rb-rotate-right
  (lambda (node)
    (if (rb-null? node)
        RB-NIL
        (let ((left-child (rb-left node)))
          (if (rb-null? left-child)
              node
              (let ((old-color (rb-color node)))
                (rb-set-left! node (rb-right left-child))
                (rb-set-right! left-child node)
                (rb-set-color! left-child old-color)
                (rb-set-color! node RED)
                left-child))))))

;;; Left rotation
(define rb-rotate-left
  (lambda (node)
    (if (rb-null? node)
        RB-NIL
        (let ((right-child (rb-right node)))
          (if (rb-null? right-child)
              node
              (let ((old-color (rb-color node)))
                (rb-set-right! node (rb-left right-child))
                (rb-set-left! right-child node)
                (rb-set-color! right-child old-color)
                (rb-set-color! node RED)
                right-child))))))

;;; Color flip (for insertion)
(define rb-flip-colors
  (lambda (node)
    (if (not (rb-null? node))
        (begin
          (rb-set-color! node RED)
          (rb-set-color! (rb-left node) BLACK)
          (rb-set-color! (rb-right node) BLACK)))))

;;; Color flip (for deletion)
(define rb-flip-colors-delete
  (lambda (node)
    (if (not (rb-null? node))
        (begin
          (rb-set-color! node (if (rb-is-red? node) BLACK RED))
          (if (not (rb-null? (rb-left node)))
              (rb-set-color! (rb-left node) 
                            (if (rb-is-red? (rb-left node)) BLACK RED)))
          (if (not (rb-null? (rb-right node)))
              (rb-set-color! (rb-right node)
                            (if (rb-is-red? (rb-right node)) BLACK RED)))))))

;;; Search
(define rb-search
  (lambda (node key)
    (if (rb-null? node)
        false
        (let ((node-key (rb-key node)))
          (cond ((= key node-key) (rb-data node))
                ((< key node-key) (rb-search (rb-left node) key))
                (else (rb-search (rb-right node) key)))))))

;;; Fix-up
(define rb-fix-up
  (lambda (node)
    (if (rb-null? node)
        RB-NIL
        (let ((node1 node))
          (if (and (rb-is-red? (rb-right node1))
                   (rb-is-black? (rb-left node1)))
              (set! node1 (rb-rotate-left node1)))
          
          (if (and (rb-is-red? (rb-left node1))
                   (not (rb-null? (rb-left node1)))
                   (rb-is-red? (rb-left (rb-left node1))))
              (set! node1 (rb-rotate-right node1)))
          
          (if (and (rb-is-red? (rb-left node1))
                   (rb-is-red? (rb-right node1)))
              (rb-flip-colors node1))
          
          node1))))

;;; Insert implementation
(define rb-insert-impl
  (lambda (node key data)
    (if (rb-null? node)
        (make-rb-node key data)
        (let ((node-key (rb-key node)))
          (cond ((< key node-key)
                 (rb-set-left! node (rb-insert-impl (rb-left node) key data)))
                ((> key node-key)
                 (rb-set-right! node (rb-insert-impl (rb-right node) key data)))
                (else
                 (rb-set-data! node data)))
          (rb-fix-up node)))))

;;; Insert (external interface)
(define rb-insert
  (lambda (node key data)
    (let ((result (rb-insert-impl node key data)))
      (if (not (rb-null? result))
          (rb-set-color! result BLACK))
      result)))

;;; Find minimum node
(define rb-search-min-node
  (lambda (node)
    (if (rb-null? node)
        RB-NIL
        (if (rb-null? (rb-left node))
            node
            (rb-search-min-node (rb-left node))))))

;;; Move red left
(define rb-move-red-left
  (lambda (node)
    (if (rb-null? node)
        RB-NIL
        (begin
          (rb-flip-colors-delete node)
          (if (and (not (rb-null? (rb-right node)))
                   (rb-is-red? (rb-left (rb-right node))))
              (begin
                (rb-set-right! node (rb-rotate-right (rb-right node)))
                (set! node (rb-rotate-left node))
                (rb-flip-colors-delete node)))
          node))))

;;; Move red right
(define rb-move-red-right
  (lambda (node)
    (if (rb-null? node)
        RB-NIL
        (begin
          (rb-flip-colors-delete node)
          (if (and (not (rb-null? (rb-left node)))
                   (rb-is-red? (rb-left (rb-left node))))
              (begin
                (set! node (rb-rotate-right node))
                (rb-flip-colors-delete node)))
          node))))

;;; Delete minimum
(define rb-delete-min
  (lambda (node)
    (if (rb-null? node)
        RB-NIL
        (if (rb-null? (rb-left node))
            RB-NIL
            (begin
              (if (and (rb-is-black? (rb-left node))
                       (not (rb-null? (rb-left node)))
                       (rb-is-black? (rb-left (rb-left node))))
                  (set! node (rb-move-red-left node)))
              (rb-set-left! node (rb-delete-min (rb-left node)))
              (rb-fix-up node))))))

;;; Delete implementation
(define rb-delete-impl
  (lambda (node key)
    (if (rb-null? node)
        RB-NIL
        (let ((node-key (rb-key node)))
          (if (< key node-key)
              (begin
                (if (not (rb-null? (rb-left node)))
                    (if (and (rb-is-black? (rb-left node))
                             (not (rb-null? (rb-left node)))
                             (rb-is-black? (rb-left (rb-left node))))
                        (set! node (rb-move-red-left node))))
                (rb-set-left! node (rb-delete-impl (rb-left node) key))
                (rb-fix-up node))
              (begin
                (if (rb-is-red? (rb-left node))
                    (set! node (rb-rotate-right node)))
                
                (if (and (= key (rb-key node))
                         (rb-null? (rb-right node)))
                    RB-NIL
                    (begin
                      (if (not (rb-null? (rb-right node)))
                          (if (and (rb-is-black? (rb-right node))
                                   (not (rb-null? (rb-right node)))
                                   (rb-is-black? (rb-left (rb-right node))))
                              (set! node (rb-move-red-right node))))
                      
                      (if (= key (rb-key node))
                          (let ((min-node (rb-search-min-node (rb-right node))))
                            (rb-set-key! node (rb-key min-node))
                            (rb-set-data! node (rb-data min-node))
                            (rb-set-right! node (rb-delete-min (rb-right node))))
                          (rb-set-right! node (rb-delete-impl (rb-right node) key)))
                      
                      (rb-fix-up node)))))))))

;;; Delete (external interface)
(define rb-delete
  (lambda (node key)
    (if (rb-null? node)
        RB-NIL
        (let ((result (rb-delete-impl node key)))
          (if (not (rb-null? result))
              (rb-set-color! result BLACK))
          result))))

;;; In-order traversal (silent, returns list)
(define rb-to-list
  (lambda (node)
    (if (rb-null? node)
        '()
        (append (rb-to-list (rb-left node))
                (list (rb-key node))
                (rb-to-list (rb-right node))))))

;;; In-order traversal (with display)
(define rb-traverse
  (lambda (node)
    (if (not (rb-null? node))
        (begin
          (rb-traverse (rb-left node))
          (display (rb-key node))
          (newline)
          (rb-traverse (rb-right node))))))

;;; Validate red-black properties
(define rb-check-property
  (lambda (node)
    (if (rb-null? node)
        1
        (begin
          (if (rb-is-red? node)
              (if (or (rb-is-red? (rb-left node))
                      (rb-is-red? (rb-right node)))
                  (begin
                    (display "ERROR: Red node has red child at key ")
                    (display (rb-key node))
                    (newline)
                    -1)
                  (let ((left-height (rb-check-property (rb-left node)))
                        (right-height (rb-check-property (rb-right node))))
                    (if (or (= left-height -1) (= right-height -1))
                        -1
                        (if (not (= left-height right-height))
                            (begin
                              (display "ERROR: Black height mismatch at node ")
                              (display (rb-key node))
                              (newline)
                              -1)
                            left-height))))
              (let ((left-height (rb-check-property (rb-left node)))
                    (right-height (rb-check-property (rb-right node))))
                (if (or (= left-height -1) (= right-height -1))
                    -1
                    (if (not (= left-height right-height))
                        (begin
                          (display "ERROR: Black height mismatch at node ")
                          (display (rb-key node))
                          (newline)
                          -1)
                        (+ left-height 1)))))))))

;;; Validate (external interface) - IMPROVED
(define rb-validate
  (lambda (node)
    (cond
      ((rb-null? node)
       (display "Tree is valid (empty)")
       (newline)
       true)
      ((rb-is-red? node)
       (display "ERROR: Root is not black!")
       (newline)
       false)
      (else
       (let ((height (rb-check-property node)))
         (if (= height -1)
             (begin
               (display "Tree is INVALID")
               (newline)
               false)
             (begin
               (display "Tree is valid (black height: ")
               (display height)
               (display ")")
               (newline)
               true)))))))

;;; Count nodes
(define rb-count-nodes
  (lambda (node)
    (if (rb-null? node)
        0
        (+ 1 
           (rb-count-nodes (rb-left node))
           (rb-count-nodes (rb-right node))))))

;;; Print tree structure - SIMPLIFIED VERSION
(define rb-print-tree
  (lambda (node)
    (display "Tree structure (key:color):")
    (newline)
    (rb-print-node-simple node 0)
    (newline)))

(define rb-print-node-simple
  (lambda (node depth)
    (if (not (rb-null? node))
        (begin
          (rb-print-node-simple (rb-right node) (+ depth 1))
          (rb-print-indent depth)
          (display (rb-key node))
          (display ":")
          (display (if (rb-is-red? node) "R" "B"))
          (newline)
          (rb-print-node-simple (rb-left node) (+ depth 1))))))

(define rb-print-indent
  (lambda (n)
    (if (> n 0)
        (begin
          (display "  ")
          (rb-print-indent (- n 1))))))

;;; Test function - IMPROVED
(define rb-test
  (lambda ()
    (newline)
    (display "=== Red-Black Tree Test ===")
    (newline)
    (newline)
    
    (let ((root RB-NIL))
      (display "Inserting: 10, 5, 20, 15, 30, 25, 35, 3, 7, 40, 45, 11, 12")
      (newline)
      (set! root (rb-insert root 10 "aaa"))
      (set! root (rb-insert root 5 "bbb"))
      (set! root (rb-insert root 20 "ccc"))
      (set! root (rb-insert root 15 "ddd"))
      (set! root (rb-insert root 30 "eee"))
      (set! root (rb-insert root 25 "fff"))
      (set! root (rb-insert root 35 "ggg"))
      (set! root (rb-insert root 3 "hhh"))
      (set! root (rb-insert root 7 "iii"))
      (set! root (rb-insert root 40 "jjj"))
      (set! root (rb-insert root 45 "kkk"))
      (set! root (rb-insert root 11 "lll"))
      (set! root (rb-insert root 12 "mmm"))
      
      (newline)
      (display "Keys in order: ")
      (display (rb-to-list root))
      (newline)
      (newline)
      (rb-validate root)
      
      (newline)
      (display "Searching for key 15: ")
      (display (rb-search root 15))
      (newline)
      
      (newline)
      (display "Deleting key 10")
      (newline)
      (set! root (rb-delete root 10))
      (display "Keys in order: ")
      (display (rb-to-list root))
      (newline)
      (rb-validate root)
      
      (newline)
      (display "Deleting key 20")
      (newline)
      (set! root (rb-delete root 20))
      (display "Keys in order: ")
      (display (rb-to-list root))
      (newline)
      (rb-validate root)
      
      (newline)
      (display "Tree structure:")
      (newline)
      (rb-print-tree root)
      
      (newline)
      (display "=== Stress Test ===")
      (newline)
      (set! root RB-NIL)
      
      (display "Inserting 0-49...")
      (newline)
      (let loop ((i 0))
        (if (< i 50)
            (begin
              (set! root (rb-insert root i i))
              (loop (+ i 1)))))
      
      (display "Node count: ")
      (display (rb-count-nodes root))
      (newline)
      (rb-validate root)
      
      (newline)
      (display "Deleting even numbers...")
      (newline)
      (let loop ((i 0))
        (if (< i 50)
            (begin
              (set! root (rb-delete root i))
              (loop (+ i 2)))))
      
      (display "Node count: ")
      (display (rb-count-nodes root))
      (newline)
      (display "Remaining keys: ")
      (display (rb-to-list root))
      (newline)
      (rb-validate root)
      
      (newline)
      (display "=== Test Complete ===")
      (newline)
      root)))

;;; Simple usage example
(define rb-example
  (lambda ()
    (newline)
    (display "=== Simple Example ===")
    (newline)
    (let ((tree RB-NIL))
      (set! tree (rb-insert tree 100 "hundred"))
      (set! tree (rb-insert tree 50 "fifty"))
      (set! tree (rb-insert tree 150 "one-fifty"))
      (set! tree (rb-insert tree 25 "twenty-five"))
      (set! tree (rb-insert tree 75 "seventy-five"))
      
      (display "Search 50: ")
      (display (rb-search tree 50))
      (newline)
      
      (display "All keys: ")
      (display (rb-to-list tree))
      (newline)
      
      (rb-validate tree)
      
      (newline)
      (rb-print-tree tree)
      tree)))

(newline)
(display "Red-Black Tree Library (Improved) loaded.")
(newline)
(display "Commands:")
(newline)
(display "  (rb-test)      - Run comprehensive tests")
(newline)
(display "  (rb-example)   - Run simple example")
(newline)
