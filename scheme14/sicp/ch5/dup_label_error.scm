; 演習5.8「同じラベルが2度出たらどうするか」の確認。
;
; ラベルは「命令列のその先」を指すので、二重定義は**どちらへ跳ぶか決まらない**
; ことを意味する。走らせてから片方が黙って選ばれるより、アセンブルの時点で
; 止まるほうがよい。
;
; scheme13 に Scheme レベルの例外捕捉は無い（dev_memo §1.4-3）ので、
; エラーは処理系ごと止まる。**したがってこの確認だけは別ファイルにして、
; 終了状態と標準エラーの文面をシェル側で見る。**
; 期待: 終了状態 1 と、下の expect-error 行の文面。
; expect-error: assemble: multiply defined label

; アセンブラのうち、ラベルを採る側だけを最小限で持つ（本体は
; 5_1_2_register_machine.scm にある）。
(define (make-instruction text) (cons text '()))
(define (make-label-entry name insts) (cons name insts))
(define (extract-labels text receive)
  (if (null? text)
      (receive '() '())
      (extract-labels
       (cdr text)
       (lambda (insts labels)
         (let ((next (car text)))
           (if (symbol? next)
               (if (assoc next labels)
                   (error "assemble: multiply defined label" next)
                   (receive insts (cons (make-label-entry next insts) labels)))
               (receive (cons (make-instruction next) insts) labels)))))))

(display "one label is fine: ")
(extract-labels '(here (assign a (const 1)) (goto (label here)))
                (lambda (insts labels) (display (length labels)) (newline)))

(extract-labels '(here
                  (assign a (const 1))
                  here
                  (goto (label here)))
                (lambda (insts labels) (display "unreachable") (newline)))
(display "unreachable") (newline)
