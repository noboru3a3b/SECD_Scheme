;;; exit_test.scm — (exit) の回帰（15日目の決定64）
;;;
;;; scheme12 には exit が無いので、これは scheme13 自身のテスト
;;; （ゴールデンも scheme13 の出力で採ってある）。見たいのは2つ:
;;;
;;;   1. 外へ出る dynamic-wind の after が**内側から順に**走ること
;;;   2. その後で本当に終わること（exit=3 で、後続の式が動かないこと）
;;;
;;; 終了コードそのものの一覧（引数なし / #t / #f / 整数）は
;;; run_golden.sh の「終了コード」の節が見ている。1ファイルでは
;;; 一度しか終われないため。

(display "start") (newline)

(dynamic-wind
  (lambda () (display "before outer") (newline))
  (lambda ()
    (dynamic-wind
      (lambda () (display "before inner") (newline))
      (lambda ()
        (display "body") (newline)
        (exit 3)
        (display "after exit -- must not run") (newline))
      (lambda () (display "after inner") (newline))))
  (lambda () (display "after outer") (newline)))

(display "top level after dynamic-wind -- must not run") (newline)
