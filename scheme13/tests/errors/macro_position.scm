; マクロが生んだ式でエラーになったとき、**利用者が書いた行**を指すこと
; （決定52・53）。指すべきは下の (twice "not a number") の行であって、
; マクロ本体の中ではない。
(define-macro (twice x) (list '+ x x))
(display "before")
(newline)
(twice "not a number")
