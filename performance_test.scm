;;;
;;; performance_test.scm : 環境フレーム最適化のパフォーマンス確認
;;;

(display "===========================================")
(newline)
(display "  Performance Test: Vector Environment")
(newline)
(display "===========================================")
(newline)
(newline)

;;; ベンチマーク用ヘルパー
(define benchmark
  (lambda (name thunk iterations)
    (display "Running: ")
    (display name)
    (display " (")
    (display iterations)
    (display " iterations)...")
    (newline)
    (let ((start-time (current-second)))
      (let loop ((i 0))
        (if (< i iterations)
            (begin
              (thunk)
              (loop (+ i 1)))))
      (let ((elapsed (- (current-second) start-time)))
        (display "  Time: ")
        (display elapsed)
        (display " seconds")
        (newline)
        elapsed))))

;;; Note: current-second は実装依存
;;; 代わりに単純な反復カウントで確認
(define simple-benchmark
  (lambda (name thunk iterations)
    (display "Running: ")
    (display name)
    (display " (")
    (display iterations)
    (display " iterations)...")
    (newline)
    (let loop ((i 0))
      (if (< i iterations)
          (begin
            (thunk)
            (loop (+ i 1)))))
    (display "  Completed")
    (newline)))

;;; Test 1: 多数の変数アクセス
(define test-many-vars
  (lambda ()
    (let ((v0 0) (v1 1) (v2 2) (v3 3) (v4 4)
          (v5 5) (v6 6) (v7 7) (v8 8) (v9 9)
          (v10 10) (v11 11) (v12 12) (v13 13) (v14 14)
          (v15 15) (v16 16) (v17 17) (v18 18) (v19 19))
      (+ v0 v5 v10 v15 v19))))

(simple-benchmark "Many variables access" test-many-vars 1000)

;;; Test 2: 深い再帰
(define fib
  (lambda (n)
    (if (<= n 1)
        n
        (+ (fib (- n 1)) (fib (- n 2))))))

(simple-benchmark "Fibonacci 15" (lambda () (fib 15)) 10)

;;; Test 3: 多数のset!
(define test-many-sets
  (lambda ()
    (let ((a 0) (b 0) (c 0) (d 0) (e 0))
      (set! a 1)
      (set! b 2)
      (set! c 3)
      (set! d 4)
      (set! e 5)
      (+ a b c d e))))

(simple-benchmark "Multiple set!" test-many-sets 10000)

(newline)
(display "===========================================")
(newline)
(display "Performance test completed!")
(newline)
(display "If optimization is working, these should be faster")
(newline)
(display "than the previous list-based implementation.")
(newline)
(display "===========================================")
(newline)
