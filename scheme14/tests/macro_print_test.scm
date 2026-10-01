;;; macro_print_test.scm — (macro-print) の回帰（17日目の決定76〜78）
;;;
;;; scheme12 には macro-print が無い（無視して #t を返す）ので、これは
;;; scheme13 自身のテスト。見たいのは3つ:
;;;
;;;   1. **入れ子の展開が見えること。** これが macroexpand との差で、
;;;      入れた理由そのもの（16日目の決定73）
;;;   2. 組み込みの特殊形式の書き換え（let / cond / quasiquote）も見えること
;;;   3. 切り替えであること。OFF にしたら何も出ないこと
;;;
;;; 位置が出るので、**この行を動かすとゴールデンがずれる**。

(define-macro inc (lambda (x) (list '+ x 1)))
(define-macro twice (lambda (x) (list '+ x x)))

;; 1. 入れ子。macroexpand は最外しか展開しないので、内側の (inc 5) は
;;    ここでしか見えない。
(macro-print)
(display (inc (inc 5)))
(newline)

;; 2. 利用者のマクロと組み込みの特殊形式が混ざった場合。
(display (let ((a (twice 3))) (cond ((> a 5) 'big) (else 'small))))
(newline)

;; 3. 切り替え。OFF の後は何も出ない。
(macro-print)
(display (inc (twice 2)))
(newline)
