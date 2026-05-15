;;;
;;; test_improvements.scm : 改善版の動作確認テスト
;;;

(display "===========================================")
(newline)
(display "  scheme12 Improvement Verification Tests")
(newline)
(display "===========================================")
(newline)
(newline)

;;; テスト結果カウンター
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

(define test-error
  (lambda (name thunk expected-error-substring)
    (set! test-count (+ test-count 1))
    (let ((result
           (call/cc
            (lambda (k)
              (let ((old-error-handler
                     (lambda (msg)
                       (k (cons 'error msg)))))
                (thunk)
                (cons 'no-error ""))))))
      (if (and (pair? result)
               (eq? (car result) 'error))
          (begin
            (set! pass-count (+ pass-count 1))
            (display "[PASS] ")
            (display name)
            (display " (error caught)")
            (newline))
          (begin
            (set! fail-count (+ fail-count 1))
            (display "[FAIL] ")
            (display name)
            (display " (should have raised error)")
            (newline))))))

;;; ===========================================
;;; Test 1: (/ x) 単独除算の禁止確認
;;; ===========================================
(newline)
(display "--- Test 1: Single-argument division ---")
(newline)

;; 正常系：2引数以上はOK
(test-result "Division with 2 args" (/ 10 2) 5)
(test-result "Division with 3 args" (/ 100 5 2) 10)

;; エラー系：1引数はエラーになるべき
(display "Testing single-argument division (should fail)...")
(newline)
(display "  Attempting: (/ 5)")
(newline)
(let ((result
       (call/cc
        (lambda (return)
          (let ((error-caught false))
            ;; エラーをキャッチする簡易実装
            (let ((val (begin
                         ;; この時点でエラーが出るはず
                         (display "  ")
                         ;; 実際には実行時にエラーになるので、
                         ;; 手動でテストするか、Scheme側でエラーハンドリングが必要
                         (display "  (Manual test required: verify error message)")
                         (newline)
                         'manual-test-required)))
              val))))))
  (display "  Note: Please manually verify that (/ 5) raises an error")
  (newline))

;;; ===========================================
;;; Test 2: 角括弧[]のサポート削除確認
;;; ===========================================
(newline)
(display "--- Test 2: Square bracket support ---")
(newline)
(display "  Note: Square brackets are no longer supported.")
(newline)
(display "  Attempting to read: [1 2 3]")
(newline)
(display "  (Manual test: input '[1 2 3]' in REPL and verify it's treated as symbols/error)")
(newline)

;;; ===========================================
;;; Test 3: eq?/eqv? の仕様確認
;;; ===========================================
(newline)
(display "--- Test 3: eq? and eqv? behavior ---")
(newline)

;; 数値の値比較（このシステムの仕様）
(test-result "eq? numbers (same value)" (eq? 42 42) true)
(test-result "eqv? numbers (same value)" (eqv? 42 42) true)
(test-result "eq? numbers (different)" (eq? 42 43) false)

;; シンボルの比較
(test-result "eq? symbols (same)" (eq? 'abc 'abc) true)
(test-result "eqv? symbols (same)" (eqv? 'abc 'abc) true)
(test-result "eq? symbols (different)" (eq? 'abc 'xyz) false)

;; 文字列の比較（eq?では偽のはず）
(define str1 "hello")
(define str2 "hello")
(test-result "eq? strings (same content)" (eq? str1 str2) false)
(test-result "eqv? strings (same content)" (eqv? str1 str2) false)
(test-result "equal? strings (same content)" (equal? str1 str2) true)

;;; ===========================================
;;; Test 4: modulo の符号規則確認（Scheme準拠）
;;; ===========================================
(newline)
(display "--- Test 4: modulo sign rules (Scheme-compliant) ---")
(newline)

;; Scheme準拠：剰余の符号は除数に一致
(test-result "modulo(13, 5)" (modulo 13 5) 3)
(test-result "modulo(-13, 5)" (modulo -13 5) 2)   ; 2 (not -3)
(test-result "modulo(13, -5)" (modulo 13 -5) -2)  ; -2 (not 3)
(test-result "modulo(-13, -5)" (modulo -13 -5) -3)

(display "  Expected results follow R5RS modulo specification:")
(newline)
(display "    modulo(-13, 5)  = 2  (remainder has sign of divisor)")
(newline)
(display "    modulo(13, -5)  = -2 (remainder has sign of divisor)")
(newline)

;;; ===========================================
;;; Test 5: equal? のベクタ対応確認
;;; ===========================================
(newline)
(display "--- Test 5: equal? with vectors ---")
(newline)

(define vec1 (vector 1 2 3))
(define vec2 (vector 1 2 3))
(define vec3 (vector 1 2 4))

(test-result "equal? vectors (same content)" (equal? vec1 vec2) true)
(test-result "equal? vectors (different)" (equal? vec1 vec3) false)

;; ネストしたベクタ
(define vec-nested1 (vector 1 (vector 2 3) 4))
(define vec-nested2 (vector 1 (vector 2 3) 4))
(test-result "equal? nested vectors" (equal? vec-nested1 vec-nested2) true)

;;; ===========================================
;;; Test 6: EOF専用オブジェクト確認
;;; ===========================================
(newline)
(display "--- Test 6: EOF object type ---")
(newline)

;; EOFオブジェクトを取得（read-lineなどから）
(display "  Creating EOF object via file I/O...")
(newline)

(let ((port (open-output-file "test-eof-temp.txt")))
  (close-output-port port))

(let* ((port (open-input-file "test-eof-temp.txt"))
       (eof-obj (read-line port)))
  (close-input-port port)
  
  (test-result "eof-object? on EOF" (eof-object? eof-obj) true)
  (test-result "eof-object? on non-EOF" (eof-object? 42) false)
  (test-result "eof-object? on symbol" (eof-object? ':eof) false)
  
  (display "  EOF is a dedicated object, not symbol :eof")
  (newline))

;;; ===========================================
;;; Test 7: 循環検出確認
;;; ===========================================
(newline)
(display "--- Test 7: Circular structure detection ---")
(newline)

;; 循環リストの作成
(define circ-list (list 1 2 3))
(set-cdr! (cdr (cdr circ-list)) circ-list)  ; 循環

(display "  Created circular list: (1 2 3 ...) -> loop")
(newline)
(display "  Displaying circular list:")
(newline)
(display "    ")
(display circ-list)  ; Should show #<circular>
(newline)

;; equal?での循環検出
(display "  Testing equal? with circular structure...")
(newline)
(let ((result
       (call/cc
        (lambda (return)
          (equal? circ-list circ-list)
          'completed))))
  (if (eq? result 'completed)
      (display "    [PASS] equal? handles circular structures")
      (display "    [INFO] equal? behavior with circular structures"))
  (newline))

;;; ===========================================
;;; Test 8: 大整数演算確認（Boehm使用時）
;;; ===========================================
(newline)
(display "--- Test 8: Big integer arithmetic ---")
(newline)

(define big1 (* 123456789 123456789))
(define big2 (* big1 big1))

(test-result "Large multiplication" 
             (> big1 1000000000) 
             true)

(display "  big1 = ")
(display big1)
(newline)
(display "  big2 = big1 * big1 = ")
(display big2)
(newline)

;;; ===========================================
;;; 結果サマリー
;;; ===========================================
(newline)
(display "===========================================")
(newline)
(display "  Test Summary")
(newline)
(display "===========================================")
(newline)
(display "Total tests:  ")
(display test-count)
(newline)
(display "Passed:       ")
(display pass-count)
(newline)
(display "Failed:       ")
(display fail-count)
(newline)

(if (= fail-count 0)
    (begin
      (newline)
      (display "*** ALL TESTS PASSED ***")
      (newline))
    (begin
      (newline)
      (display "*** SOME TESTS FAILED ***")
      (newline)))

(newline)
(display "===========================================")
(newline)
(display "  Manual Tests Required:")
(newline)
(display "===========================================")
(newline)
(display "1. Test (/ 5) in REPL - should raise error")
(newline)
(display "2. Test [1 2 3] in REPL - should fail to parse")
(newline)
(display "3. Verify trace-on/trace-off commands work")
(newline)
(display "4. Run (help) and verify documentation")
(newline)
(newline)

;; クリーンアップ
(display "Cleaning up test files...")
(newline)
;; test-eof-temp.txt は残っていても問題なし