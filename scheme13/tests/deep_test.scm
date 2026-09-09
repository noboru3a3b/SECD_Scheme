; 深いリスト — cdr 方向を再帰で辿っていないこと（dev_memo.md §4.3-1）
;
; 設計憲章 §4.3 は「リストの cdr 方向を再帰で辿らない。equal?、to_string、
; length、append などは必ずループにする」と定めている。scheme12 で C スタックを
; 溢れさせたバグが2件あったのが理由で、受け入れ基準 §5.2 にも
; 「長いリストの equal? — 20万要素同士 → TRUE（SIGSEGV しない）」の行がある。
;
; **31日目に変異法で測ったら、後ろ盾があったのは equal? だけだった。**
; write / append を素朴な再帰に書き換えても --selftest も golden も
; 一つも落ちなかった（決定148 の表）。このファイルはその穴を埋める。
;
; **100万という数には根拠がある。** 既定のスタック 8MB のとき、append を
; 素朴な再帰で書くと25万〜30万の間で溢れる（31日目に実測）。3倍強の余裕を
; 取ってあるので、スタックが 24MB ある機械でも溢れる。
; **ここを小さくすると、静かに何も測らなくなる。**
;
; **length だけは、この方法では測れない。** 素朴な再帰に書き換えても
; clang -O2 が末尾以外の再帰を畳んでループに戻してしまい、-O0 でしか
; 溢れない（決定149）。並べてあるのは、最適化に頼らない形を保つため。
;
; 原典のテスト機構（6日目に復活させたもの）を使う。式の次の行が期待する
; write 表現。**リストそのものを値にしないこと** — 100万要素が出力に出る。

(test-start)
TRUE

;;; 100万要素のリストを1本作って使い回す。作るほう（mk）は末尾再帰なので
;;; VM の中で回り、C スタックは伸びない。

(define big
  (letrec ((mk (lambda (n acc) (if (= n 0) acc (mk (- n 1) (cons n acc))))))
    (mk 1000000 '())))
big

;;; --- 数え上げと連結 ---

(length big)
1000000

(list? big)
TRUE

(length (append big (list 0)))
1000001

(car (append (list 0) big))
0

;;; --- 探索。見つからない要素を探させて最後まで歩かせる ---

(memq 'nowhere big)
FALSE

(assq 'nowhere (list (cons 'a 1) (cons 'b 2)))
FALSE

;;; --- 変換 ---

(vector-length (list->vector big))
1000000

(length (vector->list (list->vector big)))
1000000

(string-length (list->string (string->list (make-string 1000000 "a"))))
1000000

;;; --- 比較（§5.2 の行。--selftest は20万で見ているが、ここは100万）---

(equal? big big)
TRUE

(equal? big (append big (list 0)))
FALSE

;;; --- 表示。書いた中身は捨てる（100万要素をゴールデンに載せないため）---

(define sink (open-output-file "/dev/null"))
sink

(begin (write big sink) 'wrote)
wrote

(begin (display big sink) 'displayed)
displayed

(close-output-port sink)
TRUE

;;; --- 引数リスト。apply は list_to_vector を通る ---

(apply + (list 1 2 3))
6

(test-end)
