; ポート（10日目の決定46〜50）の回帰テスト。
;
; 原典のテスト機構（6日目に復活させたもの）を使う。式の次の行が期待する
; write 表現で、大小文字は無視して照合される（決定30）。
;
;   scheme13/tests/run_golden.sh がこれを走らせ、出力全体をゴールデンと
;   バイト単位で比べる。一時ファイル test-port-temp*.txt はあちらが消す。
;
; #<eof> や #<output-port> は**読み戻せない**（§2.1 の注記）ので、
; 期待値には書けない。述語で確かめる。表示そのものは --selftest が押さえている。

(test-start)
TRUE

;;; --- 標準ポートの向き（決定46）---

(input-port? (current-input-port))
TRUE

(output-port? (current-output-port))
TRUE

(output-port? (current-input-port))
FALSE

(input-port? (current-output-port))
FALSE

(input-port? 5)
FALSE

(output-port? "x")
FALSE

;;; R5RS では変数ではなく手続き。毎回作らず同じ値を返す。

(procedure? current-input-port)
TRUE

(procedure? current-output-port)
TRUE

(eq? (current-output-port) (current-output-port))
TRUE

;;; --- 標準ポートは閉じない（決定46）---
;;; fclose(stdout) を一度でも許すと、以後の出力がすべて黙って消える。

(close-output-port (current-output-port))
TRUE

(output-port? (current-output-port))
TRUE

;;; 行頭に出る | が「閉じたあとも書けている」証拠。
;;; port 引数を省いた display / write-char が既定の出力先を使うこと（決定49）も
;;; ここで同時に見ている。

(display "|")
"|"

(write-char "!")
"!"

;;; --- ファイルポートへ書く ---

(define out (open-output-file "test-port-temp.txt"))
out

(output-port? out)
TRUE

(input-port? out)
FALSE

(display "abc" out)
"abc"

(write-char "d" out)
"d"

(newline out)
NIL

(write (list 1 "x") out)
(1 "x")

(close-output-port out)
TRUE

;;; 閉じても向きは変わらない（R5RS では閉じたポートもポート）

(output-port? out)
TRUE

;;; --- 読み戻す ---
;;; いま test-port-temp.txt の中身は  abcd 改行 (1 "x")

(define in (open-input-file "test-port-temp.txt"))
in

(input-port? in)
TRUE

;;; 通常ファイルは待たされない

(char-ready? in)
TRUE

;;; peek-char は消費しない（決定50）

(peek-char in)
"a"

(peek-char in)
"a"

(read-char in)
"a"

;;; 先読みを持ったままでも char-ready? は真

(char-ready? in)
TRUE

(read-char in)
"b"

;;; 先読みした1文字は read-line にも引き継がれる

(peek-char in)
"c"

(read-line in)
"cd"

(read in)
(1 "x")

;;; --- 末尾 ---

(eof-object? (peek-char in))
TRUE

(eof-object? (read-char in))
TRUE

(eof-object? (read-line in))
TRUE

;;; EOF でも「読んでも待たされない」ので真

(char-ready? in)
TRUE

(close-input-port in)
TRUE

(input-port? in)
TRUE

;;; --- ファイル入出力の便宜手続き（28日目の決定138・139）---
;;;
;;; R5RS 6.6.1 の4つ。call-with-* は**開いて渡して閉じるだけ**、
;;; with-* は**標準ポートを差し替える**（差し替えの口は C++ 側の
;;; %set-current-*-port! で、戻す責任は dynamic-wind が持つ）。
;;;
;;; **読み戻せることが「閉じた」ことの証拠**である。閉じていなければ中身は
;;; stdio のバッファに残り、同じ実行の中では見えない（決定139）。
;;; 閉じたかどうかを直に見る述語は無く、`#<closed-port>` は読み戻せないので
;;; 期待値にも書けない。だからここでは読み戻しで確かめる。

(call-with-output-file "test-port-temp2.txt"
  (lambda (p) (display "alpha" p) (newline p) (quote wrote)))
wrote

(call-with-input-file "test-port-temp2.txt" (lambda (p) (read-line p)))
"alpha"

;;; with-output-to-file は **port 引数を省いた** display / newline の
;;; 行き先を変える（決定48）。返り値は thunk の値。

(with-output-to-file "test-port-temp2.txt"
  (lambda () (display "beta") (newline) (quote redirected)))
redirected

(call-with-input-file "test-port-temp2.txt" (lambda (p) (read-line p)))
"beta"

;;; with-input-from-file は port 引数を省いた read-line / read-char の
;;; 出どころを変える。

(with-input-from-file "test-port-temp2.txt" (lambda () (read-line)))
"beta"

;;; --- 差し替えの前後 ---

(define saved-out (current-output-port))
saved-out

;;; 差し替え中は current-output-port も差し替わっている

(with-output-to-file "test-port-temp3.txt"
  (lambda () (eq? (current-output-port) saved-out)))
FALSE

;;; 抜けたら元へ戻っている

(eq? (current-output-port) saved-out)
TRUE

;;; 入れ子。内側から抜けたら**外側の差し替えへ**戻る（起動時の標準出力では
;;; ない）。saved ひとつしか覚えていないのに入れ子が成り立つのは、
;;; 積み重なりを dynamic-wind の枠が持っているため。

(with-output-to-file "test-port-temp2.txt"
  (lambda ()
    (let ((outer (current-output-port)))
      (with-output-to-file "test-port-temp3.txt" (lambda () (quote inner)))
      (eq? (current-output-port) outer))))
TRUE

;;; 継続で外へ跳んでも、dynamic-wind の after が標準ポートを戻す（決定59）。
;;; **継続を使う項目は1つのフォームに閉じて書くこと**（凍結仕様 §2.7）。

(begin
  (call/cc
    (lambda (k)
      (with-output-to-file "test-port-temp3.txt" (lambda () (k (quote escaped))))))
  (eq? (current-output-port) saved-out))
TRUE

(test-end)
