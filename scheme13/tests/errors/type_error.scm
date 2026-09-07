; 型エラーの包み一式。
; エラーより**前**の出力は残り（stderr へ書く前に stdout を流す）、
; **後ろ**は実行されない。
(display "before the error")
(newline)
(car 5)
(display "this line never runs")
(newline)
