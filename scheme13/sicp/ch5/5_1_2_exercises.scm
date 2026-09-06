; SICP 5.1〜5.3 の演習を、演習そのものを目的として解く。
;   5.5 手で追う / 5.6 冗長な save/restore を削る / 5.9 ラベルへの演算を禁じる
;   5.10 命令の書式を変える / 5.11 restore の3つの意味 / 5.12 アセンブラで解析する
;   5.13 レジスタをアセンブル時に確保する / 5.17 ラベルつきの実況
;   5.18 レジスタの実況 / 5.19 ブレークポイント
;   5.21 count-leaves / 5.22 append と append!
;
; 24日目は「節の主題が動くか」を見た（`5_1_2_register_machine.scm`）。
; ここは**演習を解くことが目的**で、処理系にとっては別の意味がある:
; 演習の多くは**シミュレータそのものを書き換える**ので、
; 「シミュレータを組み替えても同じ機械が同じ答えを出すか」を見ることになる。
;
; 処理系側で問われるのは
;   - 手続きを `set!` で差し替えて閉包の作られ方を変えられること
;     （5.11・5.13・5.18 は、命令の実行手続きを作る側を組み替える）
;   - 命令列を**データとして走査**できること（5.12 の解析、5.10 の書式変換）
;   - 局所状態を持つ物を入れ子にできること（5.19 のブレークポイント）
(define ng-count 0)
(define total-count 0)
(define (check label expr expected)
  (set! total-count (+ total-count 1))
  (if (equal? expr expected)
      (begin (display "ok   ") (display label) (newline))
      (begin (set! ng-count (+ ng-count 1))
             (display "NG   ") (display label)
             (display "  got=") (write expr)
             (display " want=") (write expected) (newline))))
(define (check~ label expr expected tol)
  (set! total-count (+ total-count 1))
  (if (< (abs (- expr expected)) tol)
      (begin (display "ok   ") (display label) (newline))
      (begin (set! ng-count (+ ng-count 1))
             (display "NG   ") (display label)
             (display "  got=") (write expr)
             (display " want=") (write expected) (newline))))
(define (summary name)
  (display "=== ") (display name)
  (display "  total: ") (display total-count)
  (display "  NG: ") (display ng-count) (display " ===") (newline))
; ============================================================
; 5.2.1 機械のモデル
; ============================================================
; レジスタもスタックも機械も、第3章の「局所状態を持つ物」である。
; 内部の状態を `set!` で書き換え、メッセージで外から操作する。

(define (make-register name)
  (let ((contents '*unassigned*))
    (lambda (message)
      (cond ((eq? message 'get) contents)
            ((eq? message 'set) (lambda (value) (set! contents value)))
            ((eq? message 'name) name)
            (else (error "register: unknown request" message))))))
(define (get-contents register) (register 'get))
(define (set-contents! register value) ((register 'set) value))

; スタックは 5.2.4 の統計つき。押した回数と最大の深さを覚える。
; **この2つが、5.1.4 の「再帰は場所を食う」という主張を測る道具**であり、
; 5.4 で末尾再帰を確かめるときにもそのまま効く。
(define (make-stack)
  (let ((s '()) (pushes 0) (max-depth 0) (depth 0))
    (define (push x)
      (set! s (cons x s))
      (set! pushes (+ pushes 1))
      (set! depth (+ depth 1))
      (if (> depth max-depth) (set! max-depth depth) 'ok))
    (define (pop)
      (if (null? s)
          (error "stack: empty stack -- POP")
          (let ((top (car s)))
            (set! s (cdr s))
            (set! depth (- depth 1))
            top)))
    (define (initialize)
      (set! s '()) (set! pushes 0) (set! max-depth 0) (set! depth 0)
      'done)
    (lambda (message)
      (cond ((eq? message 'push) push)
            ((eq? message 'pop) (pop))
            ((eq? message 'initialize) (initialize))
            ((eq? message 'pushes) pushes)
            ((eq? message 'max-depth) max-depth)
            (else (error "stack: unknown request" message))))))
(define (pop stack) (stack 'pop))
(define (push stack value) ((stack 'push) value))

; 機械そのもの。pc と flag は他のレジスタと同じ物で作る（5.2.1）。
; 命令の実行回数を数える（演習5.15）と、実行する命令を出す（演習5.16）を
; 最初から入れてある。どちらも実行ループに1行ずつ足すだけで済む。
(define (make-new-machine)
  (let ((pc (make-register 'pc))
        (flag (make-register 'flag))
        (stack (make-stack))
        (the-instruction-sequence '())
        (the-ops '())
        (register-table '())
        (inst-count 0)
        (trace? #f))
    (define (allocate-register name)
      (if (assoc name register-table)
          (error "machine: multiply defined register" name)
          (set! register-table
                (cons (list name (make-register name)) register-table)))
      'register-allocated)
    (define (lookup-register name)
      (let ((val (assoc name register-table)))
        (if val (cadr val) (error "machine: unknown register" name))))
    (define (execute)
      (let ((insts (get-contents pc)))
        (if (null? insts)
            'done
            (begin
              (set! inst-count (+ inst-count 1))
              (if trace? (begin (write (instruction-text (car insts)))
                                (newline))
                  'ok)
              ((instruction-execution-proc (car insts)))
              (execute)))))       ; ← 末尾呼び出し。ここが切れたら何も走らない
    (set! the-ops (list (list 'initialize-stack
                              (lambda () (stack 'initialize)))))
    (set! register-table (list (list 'pc pc) (list 'flag flag)))
    (lambda (message)
      (cond ((eq? message 'start)
             (set-contents! pc the-instruction-sequence)
             (execute))
            ((eq? message 'install-instruction-sequence)
             (lambda (seq) (set! the-instruction-sequence seq)))
            ((eq? message 'allocate-register) allocate-register)
            ((eq? message 'get-register) lookup-register)
            ((eq? message 'install-operations)
             (lambda (ops) (set! the-ops (append the-ops ops))))
            ((eq? message 'stack) stack)
            ((eq? message 'operations) the-ops)
            ((eq? message 'inst-count) inst-count)
            ((eq? message 'reset-inst-count) (set! inst-count 0) 'done)
            ((eq? message 'trace-on) (set! trace? #t) 'done)
            ((eq? message 'trace-off) (set! trace? #f) 'done)
            (else (error "machine: unknown request" message))))))

(define (start machine) (machine 'start))
(define (get-register-contents machine name)
  (get-contents (get-register machine name)))
(define (set-register-contents! machine name value)
  (set-contents! (get-register machine name) value)
  'done)
(define (get-register machine name) ((machine 'get-register) name))

; 機械を1つ作る入口。レジスタを確保し、演算表を入れ、制御器の文をアセンブルする。
(define (make-machine register-names ops controller-text)
  (let ((machine (make-new-machine)))
    (for-each (lambda (name) ((machine 'allocate-register) name))
              register-names)
    ((machine 'install-operations) ops)
    ((machine 'install-instruction-sequence)
     (assemble controller-text machine))
    machine))

; ============================================================
; 5.2.2 アセンブラ
; ============================================================
; 2回に分ける。1回目でラベルの位置を採り（extract-labels）、2回目で各命令に
; 実行手続きを差し込む（update-insts!）。ラベルは命令列の**残り全体**を指すので、
; `(goto (label ...))` は pc にその残りを入れるだけで跳べる。

(define (make-instruction text) (cons text '()))
(define (instruction-text inst) (car inst))
(define (instruction-execution-proc inst) (cdr inst))
(define (set-instruction-execution-proc! inst proc) (set-cdr! inst proc))

(define (make-label-entry label-name insts) (cons label-name insts))
(define (lookup-label labels label-name)
  (let ((val (assoc label-name labels)))
    (if val (cdr val) (error "assemble: undefined label" label-name))))

; 継続渡しで後ろから組み立てる。ラベルは命令ではないので命令列には入らず、
; 「そこから先の命令列」に名前を付けるだけである。
; 同じラベルが2回出たらここで弾く（演習5.8）。ラベルが命令列の位置を指す以上、
; 二重定義は「どちらへ跳ぶか決まらない」という意味になる。
(define (extract-labels text receive)
  (if (null? text)
      (receive '() '())
      (extract-labels
       (cdr text)
       (lambda (insts labels)
         (let ((next-inst (car text)))
           (if (symbol? next-inst)
               (if (assoc next-inst labels)
                   (error "assemble: multiply defined label" next-inst)
                   (receive insts
                            (cons (make-label-entry next-inst insts) labels)))
               (receive (cons (make-instruction next-inst) insts)
                        labels)))))))

(define (update-insts! insts labels machine)
  (let ((pc (get-register machine 'pc))
        (flag (get-register machine 'flag))
        (stack (machine 'stack))
        (ops (machine 'operations)))
    (for-each
     (lambda (inst)
       (set-instruction-execution-proc!
        inst
        (make-execution-procedure
         (instruction-text inst) labels machine pc flag stack ops)))
     insts)))

(define (assemble controller-text machine)
  (extract-labels controller-text
                  (lambda (insts labels)
                    (update-insts! insts labels machine)
                    insts)))

; ============================================================
; 5.2.3 命令の実行手続き
; ============================================================
; **命令ごとに閉包を1つ作り、以後はそれを呼ぶだけにする。** レジスタの引き当ても
; ラベルの解決もアセンブル時に済むので、実行時に残るのは値の読み書きと分岐だけ。
; これは scheme13 のコンパイラが `LDG` へ大域名の格納場所を焼き込むのと同じ考えで、
; 5.5 の「解析は一度でよい」という主張の芽になっている。

(define (make-execution-procedure inst labels machine pc flag stack ops)
  (let ((kind (car inst)))
    (cond ((eq? kind 'assign) (make-assign inst machine labels ops pc))
          ((eq? kind 'test) (make-test inst machine labels ops flag pc))
          ((eq? kind 'branch) (make-branch inst machine labels flag pc))
          ((eq? kind 'goto) (make-goto inst machine labels pc))
          ((eq? kind 'save) (make-save inst machine stack pc))
          ((eq? kind 'restore) (make-restore inst machine stack pc))
          ((eq? kind 'perform) (make-perform inst machine labels ops pc))
          (else (error "assemble: unknown instruction" inst)))))

(define (advance-pc pc) (set-contents! pc (cdr (get-contents pc))))

(define (assign-reg-name inst) (cadr inst))
(define (assign-value-exp inst) (cddr inst))
(define (make-assign inst machine labels operations pc)
  (let ((target (get-register machine (assign-reg-name inst)))
        (value-exp (assign-value-exp inst)))
    (let ((value-proc
           (if (operation-exp? value-exp)
               (make-operation-exp value-exp machine labels operations)
               (make-primitive-exp (car value-exp) machine labels))))
      (lambda () (set-contents! target (value-proc)) (advance-pc pc)))))

(define (test-condition inst) (cdr inst))
(define (make-test inst machine labels operations flag pc)
  (let ((condition (test-condition inst)))
    (if (operation-exp? condition)
        (let ((condition-proc
               (make-operation-exp condition machine labels operations)))
          (lambda () (set-contents! flag (condition-proc)) (advance-pc pc)))
        (error "assemble: bad TEST instruction" inst))))

(define (branch-dest inst) (cadr inst))
(define (make-branch inst machine labels flag pc)
  (let ((dest (branch-dest inst)))
    (if (label-exp? dest)
        (let ((insts (lookup-label labels (label-exp-label dest))))
          (lambda ()
            (if (get-contents flag)
                (set-contents! pc insts)
                (advance-pc pc))))
        (error "assemble: bad BRANCH instruction" inst))))

(define (goto-dest inst) (cadr inst))
(define (make-goto inst machine labels pc)
  (let ((dest (goto-dest inst)))
    (cond ((label-exp? dest)
           (let ((insts (lookup-label labels (label-exp-label dest))))
             (lambda () (set-contents! pc insts))))
          ((register-exp? dest)
           ; 5.1.3 のサブルーチン。戻り先をレジスタに入れておいて、そこへ跳ぶ。
           (let ((reg (get-register machine (register-exp-reg dest))))
             (lambda () (set-contents! pc (get-contents reg)))))
          (else (error "assemble: bad GOTO instruction" inst)))))

(define (stack-inst-reg-name inst) (cadr inst))
(define (make-save inst machine stack pc)
  (let ((reg (get-register machine (stack-inst-reg-name inst))))
    (lambda () (push stack (get-contents reg)) (advance-pc pc))))
(define (make-restore inst machine stack pc)
  (let ((reg (get-register machine (stack-inst-reg-name inst))))
    (lambda () (set-contents! reg (pop stack)) (advance-pc pc))))

(define (perform-action inst) (cdr inst))
(define (make-perform inst machine labels operations pc)
  (let ((action (perform-action inst)))
    (if (operation-exp? action)
        (let ((action-proc
               (make-operation-exp action machine labels operations)))
          (lambda () (action-proc) (advance-pc pc)))
        (error "assemble: bad PERFORM instruction" inst))))

; --- 部分式 ---
(define (tagged? exp tag) (and (pair? exp) (eq? (car exp) tag)))
(define (register-exp? exp) (tagged? exp 'reg))
(define (register-exp-reg exp) (cadr exp))
(define (constant-exp? exp) (tagged? exp 'const))
(define (constant-exp-value exp) (cadr exp))
(define (label-exp? exp) (tagged? exp 'label))
(define (label-exp-label exp) (cadr exp))

(define (make-primitive-exp exp machine labels)
  (cond ((constant-exp? exp)
         (let ((c (constant-exp-value exp))) (lambda () c)))
        ((label-exp? exp)
         (let ((insts (lookup-label labels (label-exp-label exp))))
           (lambda () insts)))
        ((register-exp? exp)
         (let ((r (get-register machine (register-exp-reg exp))))
           (lambda () (get-contents r))))
        (else (error "assemble: unknown expression type" exp))))

(define (operation-exp? exp) (and (pair? exp) (tagged? (car exp) 'op)))
(define (operation-exp-op exp) (cadr (car exp)))
(define (operation-exp-operands exp) (cdr exp))
(define (lookup-prim symbol operations)
  (let ((val (assoc symbol operations)))
    (if val (cadr val) (error "assemble: unknown operation" symbol))))

; **ここが処理系に一番効く。** 演算の実体は実行時に決まる手続きで、引数の個数も
; 命令ごとに違う。`apply` に手続きの値と引数リストを渡せなければ書けない。
(define (make-operation-exp exp machine labels operations)
  (let ((op (lookup-prim (operation-exp-op exp) operations))
        (aprocs (map (lambda (e) (make-primitive-exp e machine labels))
                     (operation-exp-operands exp))))
    (lambda () (apply op (map (lambda (p) (p)) aprocs)))))

; --- 測るための小道具（5.2.4） ---
(define (stack-pushes machine) ((machine 'stack) 'pushes))
(define (stack-max-depth machine) ((machine 'stack) 'max-depth))
(define (inst-count machine) (machine 'inst-count))
(define (run machine assignments)
  ; レジスタに初期値を入れ、スタックと命令数を初期化してから走らせる。
  (machine 'reset-inst-count)
  ((machine 'stack) 'initialize)
  (for-each (lambda (a) (set-register-contents! machine (car a) (cadr a)))
            assignments)
  (start machine))

; ============================================================
; 演習5.5 — 手で追う
; ============================================================
; 階乗とフィボナッチを紙の上で追う演習。**「積んだ順」を機械に言わせて、
; 手で追った結果と突き合わせる**形にした。スタックに何が何の順で乗るかは、
; 5.1.4 の主張（再帰は場所を食う）の中身そのものである。
(define push-log '())
(define (make-logging-stack)
  (let ((s '()) (pushes 0) (max-depth 0) (depth 0))
    (define (push x)
      (set! push-log (cons x push-log))
      (set! s (cons x s)) (set! pushes (+ pushes 1))
      (set! depth (+ depth 1))
      (if (> depth max-depth) (set! max-depth depth) 'ok))
    (define (pop)
      (if (null? s) (error "stack: empty stack -- POP")
          (let ((top (car s))) (set! s (cdr s)) (set! depth (- depth 1)) top)))
    (lambda (message)
      (cond ((eq? message 'push) push)
            ((eq? message 'pop) (pop))
            ((eq? message 'initialize)
             (set! s '()) (set! pushes 0) (set! max-depth 0) (set! depth 0)
             'done)
            ((eq? message 'pushes) pushes)
            ((eq? message 'max-depth) max-depth)
            (else (error "stack: unknown request" message))))))

; スタックを差し替えて機械を作る。**`make-stack` を一時的に置き換える**
; だけでよい。閉包が作られる時点の定義が捕まるので、以後は元へ戻してよい。
(define real-make-stack make-stack)
(define (with-logging-stack thunk)
  (set! make-stack make-logging-stack)
  (let ((result (thunk)))
    (set! make-stack real-make-stack)
    result))

(define logged-fact
  (with-logging-stack
   (lambda ()
     (make-machine
      '(n val continue)
      (list (list '= =) (list '- -) (list '* *))
      '((assign continue (label fact-done))
        fact-loop
          (test (op =) (reg n) (const 1))
          (branch (label base-case))
          (save continue)
          (save n)
          (assign n (op -) (reg n) (const 1))
          (assign continue (label after-fact))
          (goto (label fact-loop))
        after-fact
          (restore n)
          (restore continue)
          (assign val (op *) (reg n) (reg val))
          (goto (reg continue))
        base-case
          (assign val (const 1))
          (goto (reg continue))
        fact-done)))))

; `continue` はラベル（＝命令列）なので値としては比べにくい。n だけ見る。
(define (fact-pushed-ns n)
  (set! push-log '())
  (run logged-fact (list (list 'n n)))
  (let keep ((l (reverse push-log)) (acc '()))
    (cond ((null? l) (reverse acc))
          ((number? (car l)) (keep (cdr l) (cons (car l) acc)))
          (else (keep (cdr l) acc)))))

(check "演習5.5 (fact 3) は n を 3, 2 の順で積む" (fact-pushed-ns 3) '(3 2))
(check "演習5.5 (fact 5) は n を 5..2 の順で積む" (fact-pushed-ns 5) '(5 4 3 2))
(check "演習5.5 (fact 1) は何も積まない" (fact-pushed-ns 1) '())
(check "演習5.5 答えは変わらない"
       (begin (run logged-fact (list (list 'n 6)))
              (get-register-contents logged-fact 'val))
       720)

; ============================================================
; 演習5.6 — フィボナッチの冗長な save/restore を削る
; ============================================================
; 24日目の fib 機械は、`afterfib-n-1` で `continue` を積み直してから
; すぐ `restore` する形になっていない代わりに、**`(restore continue)` の
; 直後に `(save continue)` が来る対**を持っている。その対は打ち消し合うので
; 削れる。**答えが変わらず、命令数だけが減ることを測る。**
(define fib-plain
  (make-machine
   '(n val continue)
   (list (list '< <) (list '- -) (list '+ +))
   '((assign continue (label fib-done))
     fib-loop
       (test (op <) (reg n) (const 2))
       (branch (label immediate-answer))
       (save continue)
       (assign continue (label afterfib-n-1))
       (save n)
       (assign n (op -) (reg n) (const 1))
       (goto (label fib-loop))
     afterfib-n-1
       (restore n)
       (restore continue)          ; ← この2つは
       (save continue)             ; ← 打ち消し合う
       (assign n (op -) (reg n) (const 2))
       (assign continue (label afterfib-n-2))
       (save val)
       (goto (label fib-loop))
     afterfib-n-2
       (assign n (reg val))
       (restore val)
       (restore continue)
       (assign val (op +) (reg val) (reg n))
       (goto (reg continue))
     immediate-answer
       (assign val (reg n))
       (goto (reg continue))
     fib-done)))

(define fib-tight
  (make-machine
   '(n val continue)
   (list (list '< <) (list '- -) (list '+ +))
   '((assign continue (label fib-done))
     fib-loop
       (test (op <) (reg n) (const 2))
       (branch (label immediate-answer))
       (save continue)
       (assign continue (label afterfib-n-1))
       (save n)
       (assign n (op -) (reg n) (const 1))
       (goto (label fib-loop))
     afterfib-n-1
       (restore n)                 ; restore/save の対を削った
       (assign n (op -) (reg n) (const 2))
       (assign continue (label afterfib-n-2))
       (save val)
       (goto (label fib-loop))
     afterfib-n-2
       (assign n (reg val))
       (restore val)
       (restore continue)
       (assign val (op +) (reg val) (reg n))
       (goto (reg continue))
     immediate-answer
       (assign val (reg n))
       (goto (reg continue))
     fib-done)))

(define (fib-of m n) (run m (list (list 'n n))) (get-register-contents m 'val))
(check "演習5.6 削る前と後で答えが一致する"
       (map (lambda (n) (= (fib-of fib-plain n) (fib-of fib-tight n)))
            '(0 1 2 5 10 15))
       (list #t #t #t #t #t #t))
(check "演習5.6 答えそのもの" (fib-of fib-tight 15) 610)
(check "演習5.6 命令数が減る"
       (begin (fib-of fib-plain 10)
              (let ((before (inst-count fib-plain)))
                (fib-of fib-tight 10)
                (< (inst-count fib-tight) before)))
       #t)
(check "演習5.6 押し込みの回数も減る"
       (begin (fib-of fib-plain 10)
              (let ((before (stack-pushes fib-plain)))
                (fib-of fib-tight 10)
                (< (stack-pushes fib-tight) before)))
       #t)
; 削れたのは「積んで、何もせずに降ろす」対だけ。**深さは変わらない。**
(check "演習5.6 最大の深さは変わらない"
       (begin (fib-of fib-plain 10)
              (let ((d (stack-max-depth fib-plain)))
                (fib-of fib-tight 10)
                (= (stack-max-depth fib-tight) d)))
       #t)

; ============================================================
; 演習5.9 — ラベルへの演算を禁じる
; ============================================================
; `(op +) (label here) (const 1)` のような式には意味が無い。ラベルは
; 実行時の値ではなく**アセンブル時に命令列へ解決される**ものだからである。
; アセンブラが弾けるように、演算の引数を検査する。
(define (operand-ok? e) (or (constant-exp? e) (register-exp? e)))
(define (operation-exp-ok? exp)
  (let check-all ((ops (operation-exp-operands exp)))
    (cond ((null? ops) #t)
          ((operand-ok? (car ops)) (check-all (cdr ops)))
          (else #f))))
(check "演習5.9 レジスタと定数なら通る"
       (operation-exp-ok? '((op +) (reg a) (const 1))) #t)
(check "演習5.9 ラベルは通さない"
       (operation-exp-ok? '((op +) (label here) (const 1))) #f)
(check "演習5.9 引数が無ければ通る" (operation-exp-ok? '((op read))) #t)
(check "演習5.9 2つ目がラベルでも弾く"
       (operation-exp-ok? '((op +) (reg a) (label here))) #f)
; **`(assign r (label l))` は正しい。** 禁じるのは*演算の引数*としてのラベル。
(check "演習5.9 assign のラベルは別の話（禁じない）"
       (operation-exp? '((label here))) #f)

; ============================================================
; 演習5.10 — 命令の書式を変える
; ============================================================
; **シミュレータの中核に触らずに書式を変えられるか**を問う演習。
; 答えは「変換を1枚かませればよい」。命令の意味は変わらないので、
; 実行手続きを作る側は 1行も変えなくてよい。
;   (r <- (const 5))            → (assign r (const 5))
;   (r <- (+ (reg a) (reg b)))  → (assign r (op +) (reg a) (reg b))
;   (if (= (reg n) (const 0)) -> done)
;                               → (test (op =) ...) (branch (label done))
;   (jump done)                 → (goto (label done))
(define (translate-instruction inst)
  (cond ((symbol? inst) (list inst))                     ; ラベル
        ((eq? (cadr inst) '<-)
         (let ((rhs (caddr inst)))
           (if (memq (car rhs) '(const reg label))
               (list (list 'assign (car inst) rhs))
               (list (append (list 'assign (car inst) (list 'op (car rhs)))
                             (cdr rhs))))))
        ((eq? (car inst) 'if)
         (let ((cond-exp (cadr inst)) (dest (cadddr inst)))
           (list (append (list 'test (list 'op (car cond-exp)))
                         (cdr cond-exp))
                 (list 'branch (list 'label dest)))))
        ((eq? (car inst) 'jump) (list (list 'goto (list 'label (cadr inst)))))
        (else (list inst))))
(define (translate-controller text)
  (if (null? text)
      '()
      (append (translate-instruction (car text))
              (translate-controller (cdr text)))))

(check "演習5.10 定数の代入"
       (translate-instruction '(r <- (const 5))) '((assign r (const 5))))
(check "演習5.10 演算の代入"
       (translate-instruction '(r <- (+ (reg a) (reg b))))
       '((assign r (op +) (reg a) (reg b))))
(check "演習5.10 条件分岐は2命令になる"
       (translate-instruction '(if (= (reg n) (const 0)) -> done))
       '((test (op =) (reg n) (const 0)) (branch (label done))))
(check "演習5.10 無条件の跳躍"
       (translate-instruction '(jump loop)) '((goto (label loop))))

; 新しい書式で書いた階乗が、そのまま走る。
(define new-syntax-fact
  (make-machine
   '(n product counter)
   (list (list '> >) (list '+ +) (list '* *))
   (translate-controller
    '((product <- (const 1))
      (counter <- (const 1))
      fact-loop
      (if (> (reg counter) (reg n)) -> fact-done)
      (product <- (* (reg counter) (reg product)))
      (counter <- (+ (reg counter) (const 1)))
      (jump fact-loop)
      fact-done))))
(check "演習5.10 新しい書式の階乗が走る"
       (begin (run new-syntax-fact (list (list 'n 6)))
              (get-register-contents new-syntax-fact 'product))
       720)
(check "演習5.10 シミュレータの中核は1行も変えていない"
       (begin (run new-syntax-fact (list (list 'n 20)))
              (get-register-contents new-syntax-fact 'product))
       2432902008176640000)

; ============================================================
; 演習5.11 — restore の3つの意味
; ============================================================
; `(save y)` してから `(restore x)` としたとき、何が起きるべきか。
; 3つの答えがあり、**どれもシミュレータの save/restore の実行手続きだけを
; 差し替えれば済む**（他の命令には触らない）。
;
;   (a) 何も気にしない。積んだ値がそのまま x に入る（24日目の実装）
;   (b) 積んだときのレジスタ名を覚えておき、違えば誤り
;   (c) レジスタごとに別のスタックを持つ

(define base-make-save make-save)
(define base-make-restore make-restore)
(define (with-stack-discipline save-maker restore-maker thunk)
  (set! make-save save-maker)
  (set! make-restore restore-maker)
  (let ((result (thunk)))
    (set! make-save base-make-save)
    (set! make-restore base-make-restore)
    result))

; --- (a) 24日目の実装。積んだ物は誰でも受け取れる ---
(define swap-machine
  (make-machine
   '(x y)
   '()
   '((save x)
     (save y)
     (restore x)          ; y の値が x に入る
     (restore y))))       ; x の値が y に入る
(check "演習5.11(a) 名前を見ないので入れ替えになる"
       (begin (run swap-machine (list (list 'x 1) (list 'y 2)))
              (list (get-register-contents swap-machine 'x)
                    (get-register-contents swap-machine 'y)))
       '(2 1))

; --- (b) 名前を覚えておく ---
; 積むときに `(名前 . 値)` にし、降ろすときに名前を照合する。
; 誤りは `error` ではなく印を残す形にした（ファイル内で主張したいため）。
(define restore-mismatch #f)
(define (make-save-named inst machine stack pc)
  (let ((name (stack-inst-reg-name inst)))
    (let ((reg (get-register machine name)))
      (lambda () (push stack (cons name (get-contents reg))) (advance-pc pc)))))
(define (make-restore-named inst machine stack pc)
  (let ((name (stack-inst-reg-name inst)))
    (let ((reg (get-register machine name)))
      (lambda ()
        (let ((entry (pop stack)))
          (if (eq? (car entry) name)
              (set-contents! reg (cdr entry))
              (set! restore-mismatch (list (car entry) name)))
          (advance-pc pc))))))

(define named-ok
  (with-stack-discipline
   make-save-named make-restore-named
   (lambda ()
     (make-machine '(x y) '()
                   '((save x) (save y) (restore y) (restore x))))))
(define named-bad
  (with-stack-discipline
   make-save-named make-restore-named
   (lambda ()
     (make-machine '(x y) '() '((save y) (restore x))))))

(check "演習5.11(b) 対応が取れていれば通る"
       (begin (set! restore-mismatch #f)
              (run named-ok (list (list 'x 1) (list 'y 2)))
              (list (get-register-contents named-ok 'x)
                    (get-register-contents named-ok 'y)
                    restore-mismatch))
       (list 1 2 #f))
(check "演習5.11(b) 名前が違えば誤りとして見える"
       (begin (set! restore-mismatch #f)
              (run named-bad (list (list 'x 1) (list 'y 2)))
              restore-mismatch)
       '(y x))
(check "演習5.11(b) 誤りのときレジスタは書き換わらない"
       (get-register-contents named-bad 'x) 1)

; --- (c) レジスタごとに別のスタック ---
; 積む順と降ろす順が絡まない。**入れ子の再帰では、この形のほうが
; 「何を預けたか」を追いやすい。**
(define per-reg-stacks '())
(define (stack-for name)
  (let ((found (assoc name per-reg-stacks)))
    (if found
        (cdr found)
        (let ((s (real-make-stack)))
          (set! per-reg-stacks (cons (cons name s) per-reg-stacks))
          s))))
(define (make-save-per-reg inst machine stack pc)
  (let ((name (stack-inst-reg-name inst)))
    (let ((reg (get-register machine name)))
      (lambda () (push (stack-for name) (get-contents reg)) (advance-pc pc)))))
(define (make-restore-per-reg inst machine stack pc)
  (let ((name (stack-inst-reg-name inst)))
    (let ((reg (get-register machine name)))
      (lambda () (set-contents! reg (pop (stack-for name))) (advance-pc pc)))))

(define per-reg-machine
  (with-stack-discipline
   make-save-per-reg make-restore-per-reg
   (lambda ()
     (make-machine '(x y) '()
                   '((save x) (save y) (restore x) (restore y))))))
(check "演習5.11(c) 降ろす順が違っても各自の値が戻る"
       (begin (set! per-reg-stacks '())
              (run per-reg-machine (list (list 'x 1) (list 'y 2)))
              (list (get-register-contents per-reg-machine 'x)
                    (get-register-contents per-reg-machine 'y)))
       '(1 2))
(check "演習5.11(c) スタックはレジスタごとに立つ"
       (length per-reg-stacks) 2)
; (a) と (c) で結果が食い違うのが、この演習の眼目。
(check "演習5.11 (a) と (c) は同じ命令列に別の意味を与える"
       (equal? (begin (run swap-machine (list (list 'x 1) (list 'y 2)))
                      (list (get-register-contents swap-machine 'x)
                            (get-register-contents swap-machine 'y)))
               '(1 2))
       #f)

; ============================================================
; 演習5.12 — アセンブラで機械を解析する
; ============================================================
; アセンブルの途中で命令を走査し、機械の姿を数え上げる。
; **命令列はデータなので、走らせずに分かることがかなりある**（5.2.3 の
; 「実際のレジスタの中身を知らなくても有用な解析ができる」の実演）。
(define (analyze-controller text)
  (let ((insts (let strip ((t text))
                 (cond ((null? t) '())
                       ((symbol? (car t)) (strip (cdr t)))
                       (else (cons (car t) (strip (cdr t))))))))
    (list
     (list 'kinds (sort-symbols (unique (map car insts))))
     (list 'entry-registers          ; (goto (reg r)) で跳ぶ先になるレジスタ
           (sort-symbols
            (unique (map (lambda (i) (register-exp-reg (goto-dest i)))
                         (keep (lambda (i) (and (eq? (car i) 'goto)
                                                (register-exp? (goto-dest i))))
                               insts)))))
     (list 'stack-registers
           (sort-symbols
            (unique (map cadr (keep (lambda (i) (memq (car i) '(save restore)))
                                    insts)))))
     (list 'assign-sources
           (map (lambda (r)
                  (list r (unique (map (lambda (i) (cddr i))
                                       (keep (lambda (i)
                                               (and (eq? (car i) 'assign)
                                                    (eq? (cadr i) r)))
                                             insts)))))
                (sort-symbols
                 (unique (map cadr (keep (lambda (i) (eq? (car i) 'assign))
                                         insts)))))))))
(define (keep pred xs)
  (cond ((null? xs) '())
        ((pred (car xs)) (cons (car xs) (keep pred (cdr xs))))
        (else (keep pred (cdr xs)))))
(define (unique xs)
  (cond ((null? xs) '())
        ((member (car xs) (cdr xs)) (unique (cdr xs)))
        (else (cons (car xs) (unique (cdr xs))))))
(define (sort-symbols xs)
  ; 名前の順に並べる。挿入ソートで足りる（数が小さい）。
  (define (insert x sorted)
    (cond ((null? sorted) (list x))
          ((string<? (symbol->string x) (symbol->string (car sorted)))
           (cons x sorted))
          (else (cons (car sorted) (insert x (cdr sorted))))))
  (if (null? xs) '() (insert (car xs) (sort-symbols (cdr xs)))))

(define fib-text
  '((assign continue (label fib-done))
    fib-loop
      (test (op <) (reg n) (const 2))
      (branch (label immediate-answer))
      (save continue)
      (assign continue (label afterfib-n-1))
      (save n)
      (assign n (op -) (reg n) (const 1))
      (goto (label fib-loop))
    afterfib-n-1
      (restore n)
      (assign n (op -) (reg n) (const 2))
      (assign continue (label afterfib-n-2))
      (save val)
      (goto (label fib-loop))
    afterfib-n-2
      (assign n (reg val))
      (restore val)
      (restore continue)
      (assign val (op +) (reg val) (reg n))
      (goto (reg continue))
    immediate-answer
      (assign val (reg n))
      (goto (reg continue))
    fib-done))
(define fib-analysis (analyze-controller fib-text))
(define (analysis-part name) (cadr (assoc name fib-analysis)))

(check "演習5.12 使われている命令の種類"
       (analysis-part 'kinds) '(assign branch goto restore save test))
(check "演習5.12 goto (reg) の跳び先になるレジスタ"
       (analysis-part 'entry-registers) '(continue))
(check "演習5.12 save / restore されるレジスタ"
       (analysis-part 'stack-registers) '(continue n val))
(check "演習5.12 代入されるレジスタ"
       (map car (analysis-part 'assign-sources)) '(continue n val))
(check "演習5.12 continue に入るのはラベルだけ"
       (cadr (assoc 'continue (analysis-part 'assign-sources)))
       '(((label fib-done)) ((label afterfib-n-1)) ((label afterfib-n-2))))
(check "演習5.12 val に入るのは足し算と n"
       (cadr (assoc 'val (analysis-part 'assign-sources)))
       '(((op +) (reg val) (reg n)) ((reg n))))

; ============================================================
; 演習5.13 — レジスタをアセンブル時に確保する
; ============================================================
; 機械を作るときにレジスタ名を並べて渡すのをやめ、**制御器の文から拾う。**
; 書き落としで「未定義のレジスタ」に当たることが無くなる代わりに、
; 綴りを間違えたレジスタが黙って新しいレジスタになる。
(define (registers-in-controller text)
  (sort-symbols
   (unique
    (let walk ((t text) (acc '()))
      (cond ((null? t) acc)
            ((symbol? (car t)) (walk (cdr t) acc))
            (else (walk (cdr t) (append (registers-in-instruction (car t))
                                        acc))))))))
(define (registers-in-instruction inst)
  (cond ((memq (car inst) '(save restore)) (list (cadr inst)))
        ((eq? (car inst) 'assign)
         (cons (cadr inst) (registers-in-exps (cddr inst))))
        ((eq? (car inst) 'goto) (registers-in-exps (cdr inst)))
        (else (registers-in-exps (cdr inst)))))
(define (registers-in-exps exps)
  (cond ((null? exps) '())
        ((register-exp? (car exps))
         (cons (register-exp-reg (car exps)) (registers-in-exps (cdr exps))))
        (else (registers-in-exps (cdr exps)))))
(define (make-machine-auto ops controller-text)
  (make-machine (registers-in-controller controller-text) ops controller-text))

(check "演習5.13 制御器からレジスタを拾う"
       (registers-in-controller fib-text) '(continue n val))
(check "演習5.13 拾ったレジスタで機械が組める"
       (let ((m (make-machine-auto
                 (list (list '< <) (list '- -) (list '+ +)) fib-text)))
         (run m (list (list 'n 15)))
         (get-register-contents m 'val))
       610)
(check "演習5.13 名前を並べて渡した機械と同じ答え"
       (let ((m (make-machine-auto
                 (list (list '< <) (list '- -) (list '+ +)) fib-text)))
         (map (lambda (n) (begin (run m (list (list 'n n)))
                                 (get-register-contents m 'val)))
              '(0 1 5 10 20)))
       '(0 1 5 55 6765))

; ============================================================
; 演習5.17〜5.19 — 実況とブレークポイント
; ============================================================
; ここだけは機械の実行ループそのものに触るので、拡張版を1つ作る。
; **命令に「直前のラベル」を持たせるのは、アセンブル時の仕事**である
; （演習5.17）。実行時に探すと、命令数を狂わせずに出すことができない。
; 命令は `(本文 実行手続き ラベル そのラベルからの番号)` の4つ組にする。
(define (make-instruction-ex text) (list text '() '*start* 0))
(define (instruction-text-ex inst) (car inst))
(define (instruction-proc-ex inst) (cadr inst))
(define (set-instruction-proc-ex! inst proc) (set-car! (cdr inst) proc))
(define (label-of-instruction inst) (caddr inst))
(define (offset-of-instruction inst) (cadddr inst))
(define (set-instruction-place! inst label offset)
  (set-car! (cddr inst) label)
  (set-car! (cdddr inst) offset))

(define (extract-labels-ex text receive)
  (if (null? text)
      (receive '() '())
      (extract-labels-ex
       (cdr text)
       (lambda (insts labels)
         (let ((next (car text)))
           (if (symbol? next)
               (receive insts (cons (cons next insts) labels))
               (receive (cons (make-instruction-ex next) insts) labels)))))))

; **「直前のラベルと、そこから何番目か」はアセンブル時に決まる**（演習5.17）。
; 実行時に数えると、繰り返しでラベルへ戻ったときに番号が戻らない
; （最初はそう書いて、演習5.19 の2周目で止まらなくなった）。
(define (label-at labels tail)
  (cond ((null? labels) #f)
        ((eq? (cdr (car labels)) tail) (car (car labels)))
        (else (label-at (cdr labels) tail))))
(define (annotate-places! insts labels)
  (let loop ((tail insts) (current '*start*) (offset 0))
    (if (null? tail)
        'done
        (let ((found (label-at labels tail)))
          (let ((lbl (if found found current))
                (off (if found 1 (+ offset 1))))
            (set-instruction-place! (car tail) lbl off)
            (loop (cdr tail) lbl off))))))

(define trace-log '())
(define (make-new-machine-ex)
  (let ((pc (make-register 'pc))
        (flag (make-register 'flag))
        (stack (real-make-stack))
        (the-instruction-sequence '())
        (the-ops '())
        (register-table '())
        (inst-count 0)
        (trace? #f)
        (breakpoints '()))
    (define (allocate-register name)
      (if (assoc name register-table)
          (error "machine: multiply defined register" name)
          (set! register-table
                (cons (list name (make-register name)) register-table)))
      'register-allocated)
    (define (lookup-register name)
      (let ((val (assoc name register-table)))
        (if val (cadr val) (error "machine: unknown register" name))))
    (define (step! inst)
      (set! inst-count (+ inst-count 1))
      ; 演習5.17 — 命令の前に、直前のラベルを添えて出す。
      ; **命令数は増やさない**（ラベルは命令ではない）。
      (if trace?
          (set! trace-log (cons (list (label-of-instruction inst)
                                      (instruction-text-ex inst))
                                trace-log))
          'ok)
      ((instruction-proc-ex inst)))
    ; 演習5.19 — ラベルと、そのラベルから何番目かでブレークポイントを置く。
    (define (execute)
      (let ((insts (get-contents pc)))
        (if (null? insts)
            'done
            (let ((inst (car insts)))
              (if (member (list (label-of-instruction inst)
                                (offset-of-instruction inst))
                          breakpoints)
                  'break                ; pc を進めずに止まる
                  (begin (step! inst) (execute)))))))
    (set! the-ops (list (list 'initialize-stack
                              (lambda () (stack 'initialize)))))
    (set! register-table (list (list 'pc pc) (list 'flag flag)))
    (lambda (message)
      (cond ((eq? message 'start)
             (set-contents! pc the-instruction-sequence)
             (execute))
            ((eq? message 'proceed)
             ; 止まった命令から再開する。**その1つは飛ばさない。**
             (let ((insts (get-contents pc)))
               (if (null? insts)
                   'done
                   (begin (step! (car insts)) (execute)))))
            ((eq? message 'install-instruction-sequence)
             (lambda (seq) (set! the-instruction-sequence seq)))
            ((eq? message 'allocate-register) allocate-register)
            ((eq? message 'get-register) lookup-register)
            ((eq? message 'install-operations)
             (lambda (ops) (set! the-ops (append the-ops ops))))
            ((eq? message 'stack) stack)
            ((eq? message 'operations) the-ops)
            ((eq? message 'inst-count) inst-count)
            ((eq? message 'reset-inst-count) (set! inst-count 0) 'done)
            ((eq? message 'trace-on) (set! trace? #t) 'done)
            ((eq? message 'trace-off) (set! trace? #f) 'done)
            ((eq? message 'set-breakpoint)
             (lambda (label n)
               (set! breakpoints (cons (list label n) breakpoints)) 'done))
            ((eq? message 'cancel-breakpoint)
             (lambda (label n)
               (set! breakpoints
                     (keep (lambda (b) (not (equal? b (list label n))))
                           breakpoints))
               'done))
            ((eq? message 'cancel-all-breakpoints) (set! breakpoints '()) 'done)
            ((eq? message 'breakpoints) breakpoints)
            (else (error "machine: unknown request" message))))))

(define (assemble-ex text machine)
  (extract-labels-ex
   text
   (lambda (insts labels)
     (annotate-places! insts labels)
     (let ((pc (get-register machine 'pc))
           (flag (get-register machine 'flag))
           (stack (machine 'stack))
           (ops (machine 'operations)))
       (for-each
        (lambda (inst)
          (set-instruction-proc-ex!
           inst
           (make-execution-procedure (instruction-text-ex inst)
                                     labels machine pc flag stack ops)))
        insts))
     insts)))
(define (make-machine-ex register-names ops controller-text)
  (let ((machine (make-new-machine-ex)))
    (for-each (lambda (n) ((machine 'allocate-register) n)) register-names)
    ((machine 'install-operations) ops)
    ((machine 'install-instruction-sequence) (assemble-ex controller-text machine))
    machine))

(define countdown-text
  '((assign n (const 3))
    loop
      (test (op =) (reg n) (const 0))
      (branch (label done))
      (assign n (op -) (reg n) (const 1))
      (goto (label loop))
    done))
(define ex-machine
  (make-machine-ex '(n) (list (list '= =) (list '- -)) countdown-text))

; --- 演習5.17 ラベルつきの実況 ---
(check "演習5.17 実況にラベルが付く"
       (begin (set! trace-log '())
              (ex-machine 'trace-on)
              (start ex-machine)
              (ex-machine 'trace-off)
              (car (reverse trace-log)))
       '(*start* (assign n (const 3))))
(check "演習5.17 ラベルの中の命令にはそのラベルが付く"
       (cadr (reverse trace-log)) '(loop (test (op =) (reg n) (const 0))))
(check "演習5.17 ラベルは命令数を増やさない"
       (= (length trace-log) (inst-count ex-machine)) #t)

; --- 演習5.18 レジスタの実況 ---
; **`make-register` を差し替えるだけで済む。** 機械の側は1行も変わらない。
(define register-log '())
(define real-make-register make-register)
(define (make-tracing-register name)
  (let ((contents '*unassigned*) (trace? #f))
    (lambda (message)
      (cond ((eq? message 'get) contents)
            ((eq? message 'set)
             (lambda (value)
               (if trace?
                   (set! register-log
                         (cons (list name contents value) register-log))
                   'ok)
               (set! contents value)))
            ((eq? message 'trace-on) (set! trace? #t) 'done)
            ((eq? message 'trace-off) (set! trace? #f) 'done)
            ((eq? message 'name) name)
            (else (error "register: unknown request" message))))))

(define traced-machine
  (begin (set! make-register make-tracing-register)
         (let ((m (make-machine '(n) (list (list '= =) (list '- -))
                                countdown-text)))
           (set! make-register real-make-register)
           m)))
(check "演習5.18 レジスタの書き換えを新旧の値つきで拾う"
       (begin (set! register-log '())
              ((get-register traced-machine 'n) 'trace-on)
              (run traced-machine '())
              ((get-register traced-machine 'n) 'trace-off)
              (reverse register-log))
       '((n *unassigned* 3) (n 3 2) (n 2 1) (n 1 0)))
(check "演習5.18 切れば拾わない"
       (begin (set! register-log '())
              (run traced-machine '())
              register-log)
       '())
(check "演習5.18 実況しても答えは変わらない"
       (get-register-contents traced-machine 'n) 0)

; --- 演習5.19 ブレークポイント ---
(check "演習5.19 ラベルと番号で止まる"
       (begin (ex-machine 'cancel-all-breakpoints)
              ((ex-machine 'set-breakpoint) 'loop 3)   ; loop の3番目
              (start ex-machine)
              (get-register-contents ex-machine 'n))
       3)
(check "演習5.19 止まった所から続けられる"
       (begin (ex-machine 'proceed)
              (get-register-contents ex-machine 'n))
       2)
(check "演習5.19 次の周回でも同じ所で止まる"
       (begin (ex-machine 'proceed)
              (get-register-contents ex-machine 'n))
       1)
(check "演習5.19 取り消せば最後まで走る"
       (begin ((ex-machine 'cancel-breakpoint) 'loop 3)
              (ex-machine 'cancel-all-breakpoints)
              (start ex-machine)
              (get-register-contents ex-machine 'n))
       0)
(check "演習5.19 ブレークポイントは複数置ける"
       (begin ((ex-machine 'set-breakpoint) 'loop 2)
              ((ex-machine 'set-breakpoint) 'loop 4)
              (length (ex-machine 'breakpoints)))
       2)
(check "演習5.19 全部消す"
       (begin (ex-machine 'cancel-all-breakpoints)
              (ex-machine 'breakpoints))
       '())

; ============================================================
; 演習5.21 — count-leaves
; ============================================================
; 木を数える。**再帰が2つあるので、1つ目の答えを退避してから2つ目を呼ぶ。**
; 5.1.4 の fib と同じ骨格だが、扱うのが数ではなく対である。
(define count-leaves-machine
  (make-machine
   '(tree val continue tmp)
   (list (list 'pair? pair?) (list 'null? null?)
         (list 'car car) (list 'cdr cdr) (list '+ +))
   '((assign continue (label cl-done))
     cl-loop
       (test (op null?) (reg tree))
       (branch (label cl-zero))
       (test (op pair?) (reg tree))
       (branch (label cl-pair))
       (assign val (const 1))          ; 葉
       (goto (reg continue))
     cl-zero
       (assign val (const 0))
       (goto (reg continue))
     cl-pair
       (save continue)
       (save tree)
       (assign tree (op car) (reg tree))
       (assign continue (label cl-after-car))
       (goto (label cl-loop))
     cl-after-car
       (restore tree)
       (assign tree (op cdr) (reg tree))
       (save val)                      ; car 側の答えを預ける
       (assign continue (label cl-after-cdr))
       (goto (label cl-loop))
     cl-after-cdr
       (restore tmp)
       (restore continue)
       (assign val (op +) (reg val) (reg tmp))
       (goto (reg continue))
     cl-done)))

(define (machine-count-leaves tree)
  (run count-leaves-machine (list (list 'tree tree)))
  (get-register-contents count-leaves-machine 'val))
(check "演習5.21 空の木" (machine-count-leaves '()) 0)
(check "演習5.21 葉が1つ" (machine-count-leaves '(a)) 1)
(check "演習5.21 平たいリスト" (machine-count-leaves '(a b c)) 3)
(check "演習5.21 入れ子の木" (machine-count-leaves '((a b) c (d (e f)))) 6)
(check "演習5.21 深い木" (machine-count-leaves '(1 (2 (3 (4 (5)))))) 5)
(check "演習5.21 深さに比例して積む"
       (> (begin (machine-count-leaves '(1 (2 (3 (4 (5))))))
                 (stack-max-depth count-leaves-machine))
          (begin (machine-count-leaves '(1 2 3))
                 (stack-max-depth count-leaves-machine)))
       #t)

; ============================================================
; 演習5.22 — append と append!
; ============================================================
; `append` は1本目を写して2本目に繋ぐ（再帰。場所を食う）。
; `append!` は1本目の最後の対を書き換える（反復。場所を食わない）。
; **同じ「繋ぐ」でも、機械の形がまったく違う**のがこの演習の眼目。
(define append-machine
  (make-machine
   '(x y val continue)
   (list (list 'null? null?) (list 'car car) (list 'cdr cdr)
         (list 'cons cons))
   '((assign continue (label ap-done))
     ap-loop
       (test (op null?) (reg x))
       (branch (label ap-base))
       (save continue)
       (save x)
       (assign x (op cdr) (reg x))
       (assign continue (label ap-after))
       (goto (label ap-loop))
     ap-after
       (restore x)
       (restore continue)
       (assign x (op car) (reg x))
       (assign val (op cons) (reg x) (reg val))
       (goto (reg continue))
     ap-base
       (assign val (reg y))
       (goto (reg continue))
     ap-done)))
(define (machine-append x y)
  (run append-machine (list (list 'x x) (list 'y y)))
  (get-register-contents append-machine 'val))

(define append!-machine
  (make-machine
   '(x y tmp y2)
   (list (list 'null? null?) (list 'cdr cdr) (list 'set-cdr! set-cdr!))
   '((test (op null?) (reg x))
     (branch (label ap!-done))       ; 空なら何もしない
     (assign tmp (reg x))
   last-pair-loop
     (assign y2 (op cdr) (reg tmp))
     (test (op null?) (reg y2))
     (branch (label ap!-join))
     (assign tmp (reg y2))
     (goto (label last-pair-loop))
   ap!-join
     (perform (op set-cdr!) (reg tmp) (reg y))
   ap!-done)))

(check "演習5.22 append の基本" (machine-append '(1 2) '(3 4)) '(1 2 3 4))
(check "演習5.22 1本目が空" (machine-append '() '(3 4)) '(3 4))
(check "演習5.22 2本目が空" (machine-append '(1 2) '()) '(1 2))
(check "演習5.22 append は1本目を写す（元は変わらない）"
       (let ((a (list 1 2)))
         (machine-append a '(3))
         a)
       '(1 2))
(check "演習5.22 append は1本目の長さだけ積む"
       (begin (machine-append '(1 2 3 4) '(5))
              (stack-max-depth append-machine))
       8)

; `append!` は写さない。**1本目の最後の対を書き換えて2本目に繋ぐ**ので、
; 元のリストが変わり、スタックは1度も使わない。
(define (machine-append! x y)
  (run append!-machine (list (list 'x x) (list 'y y)))
  x)
(check "演習5.22 append! の基本" (machine-append! (list 1 2) (list 3 4))
       '(1 2 3 4))
(check "演習5.22 append! は元のリストを書き換える"
       (let ((a (list 1 2)))
         (machine-append! a (list 3))
         a)
       '(1 2 3))
(check "演習5.22 append! は1本目が空なら何もしない"
       (machine-append! '() '(3 4)) '())
(check "演習5.22 append! はスタックを使わない"
       (begin (machine-append! (list 1 2 3 4) (list 5))
              (stack-pushes append!-machine))
       0)
; **同じ結果を、片方は場所を食って、片方は食わずに出す。**
(check "演習5.22 append と append! は同じ並びを返す"
       (equal? (machine-append '(1 2 3) '(4 5))
               (machine-append! (list 1 2 3) (list 4 5)))
       #t)

(summary "SICP 5.1-5.3 演習")
