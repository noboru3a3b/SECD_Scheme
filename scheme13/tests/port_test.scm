; ポート（10日目の決定46〜50）の回帰テスト。
;
; 原典のテスト機構（6日目に復活させたもの）を使う。式の次の行が期待する
; write 表現で、大小文字は無視して照合される（決定30）。
;
;   scheme13/tests/run_golden.sh がこれを走らせ、出力全体をゴールデンと
;   バイト単位で比べる。一時ファイル test-port-temp.txt はあちらが消す。
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

(test-end)
