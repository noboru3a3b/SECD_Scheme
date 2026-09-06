; SICP 演習5.45・5.46 — 3つのやり方を同じ計算で並べて測る。
;
; 同じ `(fact n)` と `(fib n)` を、
;   (1) **専用の機械**（5.1.4。その計算のためだけに書いた制御器）
;   (2) **翻訳された符号**（5.5。翻訳系が吐いた制御器）
;   (3) **解釈**（5.4。明示的制御の評価器が式を毎回見る）
; の3通りで走らせ、押し込みの回数・最大の深さ・実行命令数を比べる。
;
; **これは第5章全体の締めくくりの問いである。** 5.5 の冒頭が言う
; 「翻訳は解釈より速い」を、推測ではなく数で確かめる。演習5.45 は
; 「翻訳された符号は専用の機械にどこまで近づくか」、演習5.46 は
; 「木の再帰でも同じ傾向か」を問う。
;
; 処理系側で問われるのは、5.4 と 5.5 の両方を**1つのファイルの中に同居させて
; 同時に動かせること**。構文手続きと環境は共有し、機械だけを3つ持つ。
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
; 機械演算の側 — 構文・環境・手続き
; ============================================================
; **評価器の制御器は、式がリストであることを知らない。** 構文を見るのは
; ここに並ぶ述語と選択子だけで、制御器はそれを `(op ...)` として呼ぶ。
; 4.1 で書いたものと同じ役割だが、あちらは Scheme の手続きとして評価器の
; 中から呼ばれ、こちらは**機械の演算表**として外から渡される。

(define (tagged-list? exp tag) (and (pair? exp) (eq? (car exp) tag)))
(define (self-evaluating? exp)
  (or (number? exp) (string? exp) (boolean? exp)))
(define (variable? exp) (symbol? exp))
(define (quoted? exp) (tagged-list? exp 'quote))
(define (text-of-quotation exp) (cadr exp))

(define (assignment? exp) (tagged-list? exp 'set!))
(define (assignment-variable exp) (cadr exp))
(define (assignment-value exp) (caddr exp))

(define (definition? exp) (tagged-list? exp 'define))
(define (definition-variable exp)
  (if (symbol? (cadr exp)) (cadr exp) (car (cadr exp))))
(define (definition-value exp)
  (if (symbol? (cadr exp))
      (caddr exp)
      (cons 'lambda (cons (cdr (cadr exp)) (cddr exp)))))

(define (lambda? exp) (tagged-list? exp 'lambda))
(define (lambda-parameters exp) (cadr exp))
(define (lambda-body exp) (cddr exp))

(define (if? exp) (tagged-list? exp 'if))
(define (if-predicate exp) (cadr exp))
(define (if-consequent exp) (caddr exp))
(define (if-alternative exp)
  (if (null? (cdddr exp)) 'false (cadddr exp)))

(define (begin? exp) (tagged-list? exp 'begin))
(define (begin-actions exp) (cdr exp))
(define (first-exp seq) (car seq))
(define (rest-exps seq) (cdr seq))
(define (last-exp? seq) (null? (cdr seq)))
(define (no-more-exps? seq) (null? seq))

(define (application? exp) (pair? exp))
(define (operator exp) (car exp))
(define (operands exp) (cdr exp))
(define (no-operands? ops) (null? ops))
(define (first-operand ops) (car ops))
(define (rest-operands ops) (cdr ops))
(define (last-operand? ops) (null? (cdr ops)))
(define (empty-arglist) '())
; **引数は後ろへ足す。** これで argl が左から右の順に並ぶ（5.4 の評価順）。
(define (adjoin-arg arg arglist) (append arglist (list arg)))

; 演習5.23 — cond と let は派生式。制御器に分岐を1つずつ足し、
; **式を書き換えて eval-dispatch へ戻す**だけで済む。
(define (cond? exp) (tagged-list? exp 'cond))
(define (cond-clauses exp) (cdr exp))
(define (cond-else-clause? clause) (eq? (car clause) 'else))
(define (cond->if exp) (expand-cond-clauses (cond-clauses exp)))
(define (expand-cond-clauses clauses)
  (if (null? clauses)
      'false
      (let ((first (car clauses)) (rest (cdr clauses)))
        (if (cond-else-clause? first)
            (cons 'begin (cdr first))
            (list 'if (car first)
                  (cons 'begin (cdr first))
                  (expand-cond-clauses rest))))))
(define (let? exp) (tagged-list? exp 'let))
(define (let->combination exp)
  (let ((bindings (cadr exp)) (body (cddr exp)))
    (cons (cons 'lambda (cons (map car bindings) body))
          (map cadr bindings))))

(define (true? x) (not (eq? x #f)))

; --- 環境 ---
; 枠は「名前の並びと値の並び」の対、環境は枠の並び。
; scheme13 の `Env*` の鎖と同じ形だが、あちらは可変長の末尾配列で、
; 名前はコンパイル時に添字へ落ちている（5.5.6 の字句アドレスに当たる）。
(define (make-frame variables values) (cons variables values))
(define (frame-variables frame) (car frame))
(define (frame-values frame) (cdr frame))
(define (add-binding-to-frame! var val frame)
  (set-car! frame (cons var (car frame)))
  (set-cdr! frame (cons val (cdr frame))))
(define the-empty-environment '())
(define (first-frame env) (car env))
(define (enclosing-environment env) (cdr env))
(define (extend-environment vars vals base-env)
  (cond ((= (length vars) (length vals))
         (cons (make-frame vars vals) base-env))
        ((< (length vars) (length vals))
         (error "eceval: too many arguments supplied" vars))
        (else (error "eceval: too few arguments supplied" vars))))

(define (env-scan var env found missing)
  ; 枠を外へ辿り、見つかったら値のセルを found に渡す。
  (if (null? env)
      (missing)
      (let loop ((vars (frame-variables (first-frame env)))
                 (vals (frame-values (first-frame env))))
        (cond ((null? vars) (env-scan var (enclosing-environment env)
                                      found missing))
              ((eq? var (car vars)) (found vals))
              (else (loop (cdr vars) (cdr vals)))))))

(define (lookup-variable-value var env)
  (env-scan var env car
            (lambda () (error "eceval: unbound variable" var))))
(define (set-variable-value! var val env)
  (env-scan var env (lambda (cell) (set-car! cell val) 'ok)
            (lambda () (error "eceval: unbound variable -- SET!" var))))
(define (define-variable! var val env)
  ; 定義は**いまの枠だけ**を見る。外に同じ名前があっても隠す。
  (let loop ((vars (frame-variables (first-frame env)))
             (vals (frame-values (first-frame env))))
    (cond ((null? vars)
           (add-binding-to-frame! var val (first-frame env)) 'ok)
          ((eq? var (car vars)) (set-car! vals val) 'ok)
          (else (loop (cdr vars) (cdr vals))))))

; --- 手続き ---
(define (make-procedure parameters body env)
  (list 'procedure parameters body env))
(define (compound-procedure? p) (tagged-list? p 'procedure))
(define (procedure-parameters p) (cadr p))
(define (procedure-body p) (caddr p))
(define (procedure-environment p) (cadddr p))
(define (primitive-procedure? p) (tagged-list? p 'primitive))
(define (apply-primitive-procedure p args) (apply (cadr p) args))

(define ec-error #f)
(define (signal-error message) (set! ec-error message) 'signalled)

; ============================================================
; 5.4.1 評価器の中核 / 5.4.3 条件式・代入・定義
; ============================================================
; レジスタは7本。
;   exp      いま評価している式
;   env      その環境
;   val      評価の結果
;   continue 評価が済んだらどこへ帰るか（**制御が値になった姿**）
;   proc     適用する手続き
;   argl     評価済みの引数の並び
;   unev     まだ評価していない部分式の並び
;
; 制御器は「式を場合分けして跳ぶ」だけの列で、再帰は `save` / `restore` と
; `continue` で作る。**言語の側に手続き呼び出しは1つも無い。**
;
; 列の評価（ev-sequence）だけを差し替えられるように、制御器を3つに割って
; 持つ。演習5.28（末尾再帰をやめる）を、他を1行も変えずに測るためである。

(define ec-main
  '(;; 入口 — continue に「終わり」を入れてから評価に入る
    (assign continue (label ec-done))
    (goto (label eval-dispatch))

    eval-dispatch
      (test (op self-evaluating?) (reg exp))
      (branch (label ev-self-eval))
      (test (op variable?) (reg exp))
      (branch (label ev-variable))
      (test (op quoted?) (reg exp))
      (branch (label ev-quoted))
      (test (op assignment?) (reg exp))
      (branch (label ev-assignment))
      (test (op definition?) (reg exp))
      (branch (label ev-definition))
      (test (op if?) (reg exp))
      (branch (label ev-if))
      (test (op lambda?) (reg exp))
      (branch (label ev-lambda))
      (test (op begin?) (reg exp))
      (branch (label ev-begin))
      (test (op cond?) (reg exp))
      (branch (label ev-cond))
      (test (op let?) (reg exp))
      (branch (label ev-let))
      (test (op application?) (reg exp))
      (branch (label ev-application))
      (goto (label unknown-expression-type))

    ;; --- 部分式を持たない式 — val に置いて帰るだけ ---
    ev-self-eval
      (assign val (reg exp))
      (goto (reg continue))
    ev-variable
      (assign val (op lookup-variable-value) (reg exp) (reg env))
      (goto (reg continue))
    ev-quoted
      (assign val (op text-of-quotation) (reg exp))
      (goto (reg continue))
    ev-lambda
      (assign unev (op lambda-parameters) (reg exp))
      (assign exp (op lambda-body) (reg exp))
      (assign val (op make-procedure) (reg unev) (reg exp) (reg env))
      (goto (reg continue))

    ;; --- 演習5.23 — 派生式は書き換えて入口へ戻す ---
    ev-cond
      (assign exp (op cond->if) (reg exp))
      (goto (label eval-dispatch))
    ev-let
      (assign exp (op let->combination) (reg exp))
      (goto (label eval-dispatch))

    ;; --- 適用 ---
    ;; 演算子を先に評価し、被演算子を左から右へ評価して argl に溜める。
    ;; **ここで積む continue が、後で ev-sequence の最後の式で戻される。**
    ;; その受け渡しが末尾再帰の全部である。
    ev-application
      (save continue)
      (save env)
      (assign unev (op operands) (reg exp))
      (save unev)
      (assign exp (op operator) (reg exp))
      (assign continue (label ev-appl-did-operator))
      (goto (label eval-dispatch))
    ev-appl-did-operator
      (restore unev)
      (restore env)
      (assign argl (op empty-arglist))
      (assign proc (reg val))
      (test (op no-operands?) (reg unev))
      (branch (label apply-dispatch))
      (save proc)
    ev-appl-operand-loop
      (save argl)
      (assign exp (op first-operand) (reg unev))
      (test (op last-operand?) (reg unev))
      (branch (label ev-appl-last-arg))
      (save env)
      (save unev)
      (assign continue (label ev-appl-accumulate-arg))
      (goto (label eval-dispatch))
    ev-appl-accumulate-arg
      (restore unev)
      (restore env)
      (restore argl)
      (assign argl (op adjoin-arg) (reg val) (reg argl))
      (assign unev (op rest-operands) (reg unev))
      (goto (label ev-appl-operand-loop))
    ev-appl-last-arg
      ;; 最後の引数では env も unev も要らないので積まない。
      (assign continue (label ev-appl-accum-last-arg))
      (goto (label eval-dispatch))
    ev-appl-accum-last-arg
      (restore argl)
      (assign argl (op adjoin-arg) (reg val) (reg argl))
      (restore proc)
      (goto (label apply-dispatch))

    apply-dispatch
      (test (op primitive-procedure?) (reg proc))
      (branch (label primitive-apply))
      (test (op compound-procedure?) (reg proc))
      (branch (label compound-apply))
      (goto (label unknown-procedure-type))
    primitive-apply
      (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
      (restore continue)
      (goto (reg continue))
    compound-apply
      ;; **ここで continue を戻さない。** 積みっぱなしのまま本体の列へ入り、
      ;; 列の最後の式が戻す。それが末尾呼び出しの成立する仕掛けである。
      (assign unev (op procedure-parameters) (reg proc))
      (assign env (op procedure-environment) (reg proc))
      (assign env (op extend-environment) (reg unev) (reg argl) (reg env))
      (assign unev (op procedure-body) (reg proc))
      (goto (label ev-sequence))

    ev-begin
      (assign unev (op begin-actions) (reg exp))
      (save continue)
      (goto (label ev-sequence))

    ;; --- 5.4.3 条件式 ---
    ev-if
      (save exp)
      (save env)
      (save continue)
      (assign continue (label ev-if-decide))
      (assign exp (op if-predicate) (reg exp))
      (goto (label eval-dispatch))
    ev-if-decide
      (restore continue)
      (restore env)
      (restore exp)
      (test (op true?) (reg val))
      (branch (label ev-if-consequent))
      ;; **枝は末尾の位置にある。** continue を戻したあとで飛び込むので、
      ;; 枝の中の呼び出しは場所を食わない。
      (assign exp (op if-alternative) (reg exp))
      (goto (label eval-dispatch))
    ev-if-consequent
      (assign exp (op if-consequent) (reg exp))
      (goto (label eval-dispatch))

    ;; --- 5.4.3 代入と定義 ---
    ev-assignment
      (assign unev (op assignment-variable) (reg exp))
      (save unev)
      (assign exp (op assignment-value) (reg exp))
      (save env)
      (save continue)
      (assign continue (label ev-assignment-1))
      (goto (label eval-dispatch))
    ev-assignment-1
      (restore continue)
      (restore env)
      (restore unev)
      (perform (op set-variable-value!) (reg unev) (reg val) (reg env))
      (assign val (const ok))
      (goto (reg continue))
    ev-definition
      (assign unev (op definition-variable) (reg exp))
      (save unev)
      (assign exp (op definition-value) (reg exp))
      (save env)
      (save continue)
      (assign continue (label ev-definition-1))
      (goto (label eval-dispatch))
    ev-definition-1
      (restore continue)
      (restore env)
      (restore unev)
      (perform (op define-variable!) (reg unev) (reg val) (reg env))
      (assign val (const ok))
      (goto (reg continue))

    ;; --- 演習5.30 の入口 — 型の分からない式と手続き ---
    unknown-expression-type
      (assign val (const unknown-expression-type))
      (goto (label signal-error))
    unknown-procedure-type
      (restore continue)
      (assign val (const unknown-procedure-type))
      (goto (label signal-error))
    signal-error
      (perform (op signal-error) (reg val))
      (goto (label ec-done))))

; --- 5.4.2 列の評価と末尾再帰 ---
; **最後の式だけを別に扱う。** continue を先に戻してから飛び込むので、
; そこが手続き呼び出しであっても、スタックには何も残らない。
(define ec-seq-tail
  '(ev-sequence
      (assign exp (op first-exp) (reg unev))
      (test (op last-exp?) (reg unev))
      (branch (label ev-sequence-last-exp))
      (save unev)
      (save env)
      (assign continue (label ev-sequence-continue))
      (goto (label eval-dispatch))
    ev-sequence-continue
      (restore env)
      (restore unev)
      (assign unev (op rest-exps) (reg unev))
      (goto (label ev-sequence))
    ev-sequence-last-exp
      (restore continue)
      (goto (label eval-dispatch))))

; 演習5.28 — 最後の式を特別扱いしない版。**制御器の他の場所は1行も違わない。**
; 帰ってくる場所が要るので unev と env を積み、抜けるときに continue を戻す。
(define ec-seq-naive
  '(ev-sequence
      (test (op no-more-exps?) (reg unev))
      (branch (label ev-sequence-end))
      (assign exp (op first-exp) (reg unev))
      (save unev)
      (save env)
      (assign continue (label ev-sequence-continue))
      (goto (label eval-dispatch))
    ev-sequence-continue
      (restore env)
      (restore unev)
      (assign unev (op rest-exps) (reg unev))
      (goto (label ev-sequence))
    ev-sequence-end
      (restore continue)
      (goto (reg continue))))

(define ec-end '(ec-done))

(define ec-operations
  (list
   (list 'self-evaluating? self-evaluating?) (list 'variable? variable?)
   (list 'quoted? quoted?) (list 'text-of-quotation text-of-quotation)
   (list 'assignment? assignment?)
   (list 'assignment-variable assignment-variable)
   (list 'assignment-value assignment-value)
   (list 'definition? definition?)
   (list 'definition-variable definition-variable)
   (list 'definition-value definition-value)
   (list 'if? if?) (list 'if-predicate if-predicate)
   (list 'if-consequent if-consequent) (list 'if-alternative if-alternative)
   (list 'lambda? lambda?) (list 'lambda-parameters lambda-parameters)
   (list 'lambda-body lambda-body) (list 'make-procedure make-procedure)
   (list 'begin? begin?) (list 'begin-actions begin-actions)
   (list 'first-exp first-exp) (list 'rest-exps rest-exps)
   (list 'last-exp? last-exp?) (list 'no-more-exps? no-more-exps?)
   (list 'cond? cond?) (list 'cond->if cond->if)
   (list 'let? let?) (list 'let->combination let->combination)
   (list 'application? application?)
   (list 'operator operator) (list 'operands operands)
   (list 'no-operands? no-operands?) (list 'first-operand first-operand)
   (list 'rest-operands rest-operands) (list 'last-operand? last-operand?)
   (list 'empty-arglist empty-arglist) (list 'adjoin-arg adjoin-arg)
   (list 'lookup-variable-value lookup-variable-value)
   (list 'set-variable-value! set-variable-value!)
   (list 'define-variable! define-variable!)
   (list 'extend-environment extend-environment)
   (list 'primitive-procedure? primitive-procedure?)
   (list 'compound-procedure? compound-procedure?)
   (list 'apply-primitive-procedure apply-primitive-procedure)
   (list 'procedure-parameters procedure-parameters)
   (list 'procedure-body procedure-body)
   (list 'procedure-environment procedure-environment)
   (list 'true? true?) (list 'signal-error signal-error)))

(define ec-registers '(exp env val proc argl continue unev))

(define eceval
  (make-machine ec-registers ec-operations
                (append ec-main ec-seq-tail ec-end)))
(define eceval-no-tail
  (make-machine ec-registers ec-operations
                (append ec-main ec-seq-naive ec-end)))

; ============================================================
; 5.4 の合成手続きが「引数の並び・本体・環境」だったのと比べると、
; 本体が命令列の中の一点に潰れている。これが翻訳の眼目そのもの。
(define (make-compiled-procedure entry env) (list 'compiled-procedure entry env))
(define (compiled-procedure? p) (tagged-list? p 'compiled-procedure))
(define (compiled-procedure-entry p) (cadr p))
(define (compiled-procedure-env p) (caddr p))
(define (primitive-procedure? p) (tagged-list? p 'primitive))
(define (apply-primitive-procedure p args) (apply (cadr p) args))
(define (false? x) (eq? x #f))

; 5.5.4 命令列の結合
; ============================================================
; 命令列は「必要とするレジスタ・書き換えるレジスタ・命令の並び」の3つ組。
; **この2本の名簿があるから、save / restore を機械的に、しかも要る所にだけ
; 入れられる。** 各生成器が自分で退避を書くのではなく、繋ぐ側が決める。

(define (make-instruction-seq needs modifies statements)
  (list needs modifies statements))
(define (registers-needed s) (if (symbol? s) '() (car s)))
(define (registers-modified s) (if (symbol? s) '() (cadr s)))
(define (statements s) (if (symbol? s) (list s) (caddr s)))
(define (needs-register? seq reg) (memq reg (registers-needed seq)))
(define (modifies-register? seq reg) (memq reg (registers-modified seq)))
(define empty-instruction-seq (make-instruction-seq '() '() '()))

(define (list-union s1 s2)
  (cond ((null? s1) s2)
        ((memq (car s1) s2) (list-union (cdr s1) s2))
        (else (cons (car s1) (list-union (cdr s1) s2)))))
(define (list-difference s1 s2)
  (cond ((null? s1) '())
        ((memq (car s1) s2) (list-difference (cdr s1) s2))
        (else (cons (car s1) (list-difference (cdr s1) s2)))))

(define (append-instruction-seqs . seqs)
  (define (append-2 seq1 seq2)
    (make-instruction-seq
     (list-union (registers-needed seq1)
                 (list-difference (registers-needed seq2)
                                  (registers-modified seq1)))
     (list-union (registers-modified seq1) (registers-modified seq2))
     (append (statements seq1) (statements seq2))))
  (if (null? seqs)
      empty-instruction-seq
      (append-2 (car seqs) (apply append-instruction-seqs (cdr seqs)))))

; **退避が要るのは、前の列が壊し、かつ後の列が要るレジスタだけ。**
; どちらか一方でも欠ければ save / restore は入らない。
(define (preserving regs seq1 seq2)
  (if (null? regs)
      (append-instruction-seqs seq1 seq2)
      (let ((r (car regs)))
        (if (and (needs-register? seq2 r) (modifies-register? seq1 r))
            (preserving (cdr regs)
                        (make-instruction-seq
                         (list-union (list r) (registers-needed seq1))
                         (list-difference (registers-modified seq1) (list r))
                         (append (list (list 'save r))
                                 (statements seq1)
                                 (list (list 'restore r))))
                        seq2)
            (preserving (cdr regs) seq1 seq2)))))

; 手続きの本体を後ろに置く。**続けて実行されるわけではない**ので、
; 名簿は前の列のものをそのまま使う。
(define (tack-on-instruction-seq seq body-seq)
  (make-instruction-seq (registers-needed seq) (registers-modified seq)
                        (append (statements seq) (statements body-seq))))
; if の2つの枝のように、**どちらか一方しか走らない**列を並べる。
(define (parallel-instruction-seqs seq1 seq2)
  (make-instruction-seq
   (list-union (registers-needed seq1) (registers-needed seq2))
   (list-union (registers-modified seq1) (registers-modified seq2))
   (append (statements seq1) (statements seq2))))

(define label-counter 0)
(define (make-label name)
  (set! label-counter (+ label-counter 1))
  (string->symbol (string-append (symbol->string name)
                                 (number->string label-counter))))

; ============================================================
; 5.5.6 字句アドレス（翻訳系より前に置く — 5.5.2 の変数の参照が使う）
; ============================================================
; **これは scheme13 が既定で行っていることの、教科書側の記述である。**
; 変数の位置は翻訳時に分かる。`(枠 位置)` — 何段外の枠の何番目か — まで
; 割り出しておけば、実行時に名前を照合する必要が無い。
; scheme13 の `LD (depth index)` はこれそのもので、`LDG` だけが
; 「翻訳時に枠が分からない大域名」のために残っている。
;
; 25日目に**翻訳時環境を `compile` の全再帰に通した**（演習5.40〜5.44）。
; 24日目は変数の参照だけを差し替える形だった。

; 翻訳時環境は「枠ごとの名前の並び」だけ。値は要らない。
(define (find-variable var ctenv)
  (let frame-loop ((frames ctenv) (frame-no 0))
    (if (null? frames)
        'not-found                      ; 大域変数。名前で引くしかない
        (let var-loop ((vars (car frames)) (disp 0))
          (cond ((null? vars) (frame-loop (cdr frames) (+ frame-no 1)))
                ((eq? (car vars) var) (list frame-no disp))
                (else (var-loop (cdr vars) (+ disp 1))))))))

(define (lexical-address-lookup address env)
  (let ((frame (list-ref env (car address))))
    (let ((val (list-ref (frame-values frame) (cadr address))))
      (if (eq? val '*unassigned*)
          (error "lexical: unassigned variable" address)
          val))))
(define (lexical-address-set! address env val)
  (let ((frame (list-ref env (car address))))
    (set-car! (list-tail (frame-values frame) (cadr address)) val)
    'ok))

; ============================================================
; 5.5.1 翻訳系の構造
; ============================================================
; `compile` は式・行き先のレジスタ（target）・翻訳後の続き方（linkage）を取る。
; linkage は `next`（そのまま次へ）・`return`（`continue` へ帰る）・ラベル。
; **`return` + target `val` が末尾呼び出しになる**（5.5.3）。

(define all-regs '(env proc val argl continue))

(define (compile-linkage linkage)
  (cond ((eq? linkage 'return)
         (make-instruction-seq '(continue) '() '((goto (reg continue)))))
        ((eq? linkage 'next) empty-instruction-seq)
        (else (make-instruction-seq '() '() (list (list 'goto (list 'label linkage)))))))
(define (end-with-linkage linkage instruction-seq)
  (preserving '(continue) instruction-seq (compile-linkage linkage)))

; 演習5.40 — **翻訳時環境（ctenv）を全再帰に通す。** これが入って初めて、
; 変数の参照が「名前で探す」から「何段外の何番目」へ変わる。
; 通す先は式の型ごとに違い、`lambda` だけが枠を1つ足す。
(define (compile-in exp target linkage ctenv)
  (cond ((self-evaluating? exp) (compile-self-evaluating exp target linkage))
        ((quoted? exp) (compile-quoted exp target linkage))
        ((variable? exp) (compile-variable exp target linkage ctenv))
        ((assignment? exp) (compile-assignment exp target linkage ctenv))
        ((definition? exp) (compile-definition exp target linkage ctenv))
        ((if? exp) (compile-if exp target linkage ctenv))
        ((lambda? exp) (compile-lambda exp target linkage ctenv))
        ((begin? exp)
         (compile-sequence (begin-actions exp) target linkage ctenv))
        ((let? exp) (compile-in (let->combination exp) target linkage ctenv))
        ((application? exp) (compile-application exp target linkage ctenv))
        (else (error "compile: unknown expression type" exp))))

; 大域では枠が1つも無い。**そこから見える名前は全部「翻訳時に分からない」**
; ので、`LDG` に当たる名前引きの命令になる。
(define (compile exp target linkage) (compile-in exp target linkage '()))

; --- 5.5.2 式の翻訳 ---
(define (compile-self-evaluating exp target linkage)
  (end-with-linkage
   linkage
   (make-instruction-seq '() (list target)
                         (list (list 'assign target (list 'const exp))))))
(define (compile-quoted exp target linkage)
  (end-with-linkage
   linkage
   (make-instruction-seq
    '() (list target)
    (list (list 'assign target (list 'const (text-of-quotation exp)))))))
; **変数の参照は命令1つ。** 5.4 の評価器は毎回 `variable?` から場合分けを
; やり直していた。その場合分けが翻訳時に消えるのが、翻訳の利得の第一である。
;
; 演習5.41〜5.42 — 翻訳時環境に載っていれば、名前ではなく `(枠 位置)` で引く。
; **載っていなければ大域名なので、名前で引くしかない。** この分かれ方が
; scheme13 の `LD` と `LDG` の分かれ方そのものである。
(define (compile-variable exp target linkage ctenv)
  (let ((address (find-variable exp ctenv)))
    (end-with-linkage
     linkage
     (make-instruction-seq
      '(env) (list target)
      (list (if (eq? address 'not-found)
                (list 'assign target '(op lookup-variable-value)
                      (list 'const exp) '(reg env))
                (list 'assign target '(op lexical-address-lookup)
                      (list 'const address) '(reg env))))))))
(define (compile-assignment exp target linkage ctenv)
  (let ((var (assignment-variable exp))
        (get-value-code (compile-in (assignment-value exp) 'val 'next ctenv)))
    (let ((address (find-variable var ctenv)))
      (end-with-linkage
       linkage
       (preserving
        '(env) get-value-code
        (make-instruction-seq
         '(env val) (list target)
         (list (if (eq? address 'not-found)
                   (list 'perform '(op set-variable-value!)
                         (list 'const var) '(reg val) '(reg env))
                   (list 'perform '(op lexical-address-set!)
                         (list 'const address) '(reg env) '(reg val)))
               (list 'assign target '(const ok)))))))))
; **`define` は字句アドレスにしない。** 枠に名前を足す操作なので、
; 位置が翻訳時に決まっていない（演習5.43 で本体の先頭に集めた分だけは
; 枠に載っているが、そちらは `set!` に化けている）。
(define (compile-definition exp target linkage ctenv)
  (let ((var (definition-variable exp))
        (get-value-code (compile-in (definition-value exp) 'val 'next ctenv)))
    (end-with-linkage
     linkage
     (preserving
      '(env) get-value-code
      (make-instruction-seq
       '(env val) (list target)
       (list (list 'perform '(op define-variable!)
                   (list 'const var) '(reg val) '(reg env))
             (list 'assign target '(const ok))))))))

(define (compile-if exp target linkage ctenv)
  (let ((t-branch (make-label 'true-branch))
        (f-branch (make-label 'false-branch))
        (after-if (make-label 'after-if)))
    (let ((consequent-linkage (if (eq? linkage 'next) after-if linkage)))
      (let ((p-code (compile-in (if-predicate exp) 'val 'next ctenv))
            (c-code (compile-in (if-consequent exp) target
                                consequent-linkage ctenv))
            (a-code (compile-in (if-alternative exp) target linkage ctenv)))
        (preserving
         '(env continue) p-code
         (append-instruction-seqs
          (make-instruction-seq
           '(val) '()
           (list '(test (op false?) (reg val))
                 (list 'branch (list 'label f-branch))))
          (parallel-instruction-seqs
           (append-instruction-seqs t-branch c-code)
           (append-instruction-seqs f-branch a-code))
          after-if))))))

(define (compile-sequence seq target linkage ctenv)
  (if (last-exp? seq)
      (compile-in (first-exp seq) target linkage ctenv)
      (preserving '(env continue)
                  (compile-in (first-exp seq) target 'next ctenv)
                  (compile-sequence (rest-exps seq) target linkage ctenv))))

; --- 5.5.2 lambda ---
; **本体は命令列の中に置き去りにし、その上を `goto` で跳び越す。**
; 手続きの値は「入口のラベルと、いまの環境」だけになる。
(define (compile-lambda exp target linkage ctenv)
  (let ((proc-entry (make-label 'entry))
        (after-lambda (make-label 'after-lambda)))
    (let ((lambda-linkage (if (eq? linkage 'next) after-lambda linkage)))
      (append-instruction-seqs
       (tack-on-instruction-seq
        (end-with-linkage
         lambda-linkage
         (make-instruction-seq
          '(env) (list target)
          (list (list 'assign target '(op make-compiled-procedure)
                      (list 'label proc-entry) '(reg env)))))
        (compile-lambda-body exp proc-entry ctenv))
       after-lambda))))

; 演習5.43 — **本体の先頭の `define` を掃き出す。** 内部定義は本来
; 「本体に入った時点で全部の名前がある」意味なので、名前を仮の値で枠に並べ、
; 定義を `set!` に変える。**これで枠の中身が翻訳時に確定する**ので、
; 内部定義された名前も字句アドレスで引ける。
(define (scan-out-defines body)
  (let ((defs (filter-defines body)))
    (if (null? defs)
        body
        (list
         (cons (cons 'lambda
                     (cons (map definition-variable defs)
                           (map (lambda (e)
                                  (if (definition? e)
                                      (list 'set! (definition-variable e)
                                            (definition-value e))
                                      e))
                                body)))
               (map (lambda (d) '(quote *unassigned*)) defs))))))
(define (filter-defines body)
  (cond ((null? body) '())
        ((definition? (car body)) (cons (car body) (filter-defines (cdr body))))
        (else (filter-defines (cdr body)))))

(define (compile-lambda-body exp proc-entry ctenv)
  (let ((formals (lambda-parameters exp)))
    (append-instruction-seqs
     (make-instruction-seq
      '(env proc argl) '(env)
      (list proc-entry
            '(assign env (op compiled-procedure-env) (reg proc))
            (list 'assign 'env '(op extend-environment)
                  (list 'const formals) '(reg argl) '(reg env))))
     ; **本体は必ず target = val、linkage = return で翻訳する。**
     ; ここが末尾呼び出しの成立する場所である（5.5.3）。
     ; **枠を1つ足した翻訳時環境で本体を翻訳する**のが演習5.40 の要点。
     (compile-sequence (scan-out-defines (lambda-body exp)) 'val 'return
                       (cons formals ctenv)))))

; ============================================================
; 5.5.3 組み合わせの翻訳
; ============================================================
; 演算子を `proc` に、被演算子を `argl` に集める。**被演算子は後ろから
; 翻訳する**（cons で前に足していくと、実行時は右から左の順になる）。
; 5.4 の評価器が左から右だったのと逆で、演習5.36 が問うのはこの点である。
; 演習5.38・5.44 — 基本演算を開いて埋め込む。既定では切ってあり、
; 演習の測定のときだけ立てる（既存の主張を動かさないため）。
(define open-coding? #f)
(define open-coded-primitives '(+ - * =))
; **埋め込んでよいのは、その名前が翻訳時環境に隠されていないときだけ**
; （演習5.44）。翻訳時環境があるから、ここが翻訳時に判定できる。
(define (open-codable? exp ctenv)
  (and open-coding?
       (pair? exp)
       (memq (operator exp) open-coded-primitives)
       (= (length (operands exp)) 2)
       (eq? (find-variable (operator exp) ctenv) 'not-found)))
; 引数を2本のレジスタへ散らし、演算命令を1つ吐く。
; **手続きオブジェクトも argl も要らず、基本／翻訳済みの分岐も消える。**
; **`arg1` は演算命令まで生き延びなければならない。** 2つ目の引数が
; それ自体埋め込まれた演算だと `arg1` を上書きするので、`preserving` の
; 内側に演算命令を置いて名簿に見せる。外に append すると退避が入らず、
; `(+ (* 2 3) (- 10 4))` が 16 になる（実際に踏んだ）。
; **名簿を持つ設計の値打ちが、そのまま出る場所。**
(define (compile-open-coded exp target linkage ctenv)
  (end-with-linkage
   linkage
   (preserving
    '(env)
    (compile-in (car (operands exp)) 'arg1 'next ctenv)
    (preserving
     '(arg1)
     (compile-in (cadr (operands exp)) 'val 'next ctenv)
     (make-instruction-seq
      '(arg1 val) (list target)
      (list (list 'assign target (list 'op (operator exp))
                  '(reg arg1) '(reg val))))))))

(define (compile-application exp target linkage ctenv)
  (if (open-codable? exp ctenv)
      (compile-open-coded exp target linkage ctenv)
      (compile-application-general exp target linkage ctenv)))
(define (compile-application-general exp target linkage ctenv)
  (let ((proc-code (compile-in (operator exp) 'proc 'next ctenv))
        (operand-codes (map (lambda (operand)
                              (compile-in operand 'val 'next ctenv))
                            (operands exp))))
    (preserving '(env continue) proc-code
                (preserving '(proc continue)
                            (construct-arglist operand-codes)
                            (compile-procedure-call target linkage)))))

(define (construct-arglist operand-codes)
  (let ((codes (reverse operand-codes)))
    (if (null? codes)
        (make-instruction-seq '() '(argl) '((assign argl (const ()))))
        (let ((last-arg-code
               (append-instruction-seqs
                (car codes)
                (make-instruction-seq '(val) '(argl)
                                      '((assign argl (op list) (reg val)))))))
          (if (null? (cdr codes))
              last-arg-code
              (preserving '(env) last-arg-code
                          (code-to-get-rest-args (cdr codes))))))))
(define (code-to-get-rest-args operand-codes)
  (let ((next-arg-code
         (preserving '(argl) (car operand-codes)
                     (make-instruction-seq
                      '(val argl) '(argl)
                      '((assign argl (op cons) (reg val) (reg argl)))))))
    (if (null? (cdr operand-codes))
        next-arg-code
        (preserving '(env) next-arg-code
                    (code-to-get-rest-args (cdr operand-codes))))))

; 基本手続きと翻訳された手続きで分かれる。5.4 の apply-dispatch と同じ形だが、
; **分岐が翻訳時に命令として書き出される**ぶん、実行時の場合分けは1回で済む。
(define (compile-procedure-call target linkage)
  (let ((primitive-branch (make-label 'primitive-branch))
        (compiled-branch (make-label 'compiled-branch))
        (after-call (make-label 'after-call)))
    (let ((compiled-linkage (if (eq? linkage 'next) after-call linkage)))
      (append-instruction-seqs
       (make-instruction-seq
        '(proc) '()
        (list '(test (op primitive-procedure?) (reg proc))
              (list 'branch (list 'label primitive-branch))))
       (parallel-instruction-seqs
        (append-instruction-seqs compiled-branch
                                 (compile-proc-appl target compiled-linkage))
        (append-instruction-seqs
         primitive-branch
         (end-with-linkage
          linkage
          (make-instruction-seq
           '(proc argl) (list target)
           (list (list 'assign target '(op apply-primitive-procedure)
                       '(reg proc) '(reg argl)))))))
       after-call))))

; **4通りのうち、3番目が末尾呼び出しである。**
; 値を val に置き、continue へ帰る約束のまま相手の入口へ跳ぶので、
; `continue` を積み直さない。scheme13 の `TAPP` と同じ扱い。
(define (compile-proc-appl target linkage)
  (cond ((and (eq? target 'val) (not (eq? linkage 'return)))
         (make-instruction-seq
          '(proc) all-regs
          (list (list 'assign 'continue (list 'label linkage))
                '(assign val (op compiled-procedure-entry) (reg proc))
                '(goto (reg val)))))
        ((and (not (eq? target 'val)) (not (eq? linkage 'return)))
         (let ((proc-return (make-label 'proc-return)))
           (make-instruction-seq
            '(proc) all-regs
            (list (list 'assign 'continue (list 'label proc-return))
                  '(assign val (op compiled-procedure-entry) (reg proc))
                  '(goto (reg val))
                  proc-return
                  (list 'assign target '(reg val))
                  (list 'goto (list 'label linkage))))))
        ((and (eq? target 'val) (eq? linkage 'return))
         (make-instruction-seq
          '(proc continue) all-regs
          '((assign val (op compiled-procedure-entry) (reg proc))
            (goto (reg val)))))       ; ← 末尾呼び出し。何も積まない
        (else (error "compile: return linkage, target not val" target))))

; --- 基本手続きと大域環境（5.4.4。翻訳側もこれを共有する）---
(define (primitive-entry name proc) (list name (list 'primitive proc)))
(define (setup-environment)
  (extend-environment
   (map car ec-primitives) (map cadr ec-primitives)
   the-empty-environment))
(define ec-primitives
  (list (primitive-entry 'car car) (primitive-entry 'cdr cdr)
        (primitive-entry 'cons cons) (primitive-entry 'null? null?)
        (primitive-entry 'pair? pair?) (primitive-entry 'list list)
        (primitive-entry 'not not) (primitive-entry 'eq? eq?)
        (primitive-entry 'equal? equal?)
        (primitive-entry '+ +) (primitive-entry '- -)
        (primitive-entry '* *) (primitive-entry '/ /)
        (primitive-entry '= =) (primitive-entry '< <) (primitive-entry '> >)
        (primitive-entry 'remainder remainder)
        (primitive-entry 'append append)
        (primitive-entry 'length length)))


; ============================================================
; 3つの機械を並べる
; ============================================================
; 環境は 5.4 の側のものを共有する。**翻訳された符号と解釈される符号が
; 同じ環境と同じ手続き表現を使える**のが 5.5.7 の主張で、それがそのまま
; この比較を成り立たせている。

(define compiler-operations
  (list (list 'lookup-variable-value lookup-variable-value)
        (list 'set-variable-value! set-variable-value!)
        (list 'define-variable! define-variable!)
        (list 'extend-environment extend-environment)
        (list 'make-compiled-procedure make-compiled-procedure)
        (list 'compiled-procedure-entry compiled-procedure-entry)
        (list 'compiled-procedure-env compiled-procedure-env)
        (list 'primitive-procedure? primitive-procedure?)
        (list 'apply-primitive-procedure apply-primitive-procedure)
        (list 'false? false?)
        (list 'lexical-address-lookup lexical-address-lookup)
        (list 'lexical-address-set! lexical-address-set!)
        (list 'list list) (list 'cons cons)
        (list '+ +) (list '- -) (list '* *) (list '= =)))
(define machine-regs (cons 'arg1 all-regs))

; (2) 翻訳された符号 — 機械は1つで、式ごとに命令列を積み込む（5.5.7）。
(define compiled-machine (make-machine machine-regs compiler-operations '()))
(define compiled-env (setup-environment))
(define (run-compiled exp)
  (let ((code (statements (compile exp 'val 'next))))
    ((compiled-machine 'install-instruction-sequence)
     (assemble code compiled-machine))
    (run compiled-machine (list (list 'env compiled-env)))
    (get-register-contents compiled-machine 'val)))
(define (run-compiled-seq exps)
  (let loop ((es exps) (last 'none))
    (if (null? es) last (loop (cdr es) (run-compiled (car es))))))

; (3) 解釈 — 5.4 の評価器。
(define interpreted-env (setup-environment))
(define (run-interpreted exp)
  (set! ec-error #f)
  (run eceval (list (list 'exp exp) (list 'env interpreted-env)))
  (get-register-contents eceval 'val))
(define (run-interpreted-seq exps)
  (let loop ((es exps) (last 'none))
    (if (null? es) last (loop (cdr es) (run-interpreted (car es))))))

; (1) 専用の機械 — その計算のためだけに書いた制御器（5.1.4）。
(define special-fact
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
     fact-done)))
(define special-fib
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

(define fact-source
  '(define (fact n) (if (= n 1) 1 (* n (fact (- n 1))))))
(define fib-source
  '(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))
(run-compiled fact-source)
(run-compiled fib-source)
(run-interpreted fact-source)
(run-interpreted fib-source)

; --- 3通りが同じ答えを出すこと（比較の前提）---
(define (special-fact-of n)
  (run special-fact (list (list 'n n)))
  (get-register-contents special-fact 'val))
(define (special-fib-of n)
  (run special-fib (list (list 'n n)))
  (get-register-contents special-fib 'val))

(check "演習5.45 3通りが同じ階乗を出す"
       (map (lambda (n) (let ((a (special-fact-of n))
                              (b (run-compiled (list 'fact n)))
                              (c (run-interpreted (list 'fact n))))
                          (and (= a b) (= b c) a)))
            '(1 2 5 10 15))
       '(1 2 120 3628800 1307674368000))
(check "演習5.46 3通りが同じ fib を出す"
       (map (lambda (n) (let ((a (special-fib-of n))
                              (b (run-compiled (list 'fib n)))
                              (c (run-interpreted (list 'fib n))))
                          (and (= a b) (= b c) a)))
            '(0 1 5 10))
       '(0 1 5 55))

; ============================================================
; 演習5.45 — 階乗で3通りを測る
; ============================================================
; 測るのは**押し込みの回数**（総仕事量に効く）と**最大の深さ**（要る場所）。
; どちらも n の1次式になるので、n を2つ取れば傾きが出る。
; **有理数が無い**（凍結仕様。`(/ 3 2)` は `1`）ので、比を取るときは
; 実数に落とすか、掛け算で比べる。傾きは割り切れるので整数のままでよい。
(define (slope f a b) (/ (- (f b) (f a)) (- b a)))
(define (ratio a b) (/ (exact->inexact a) b))

(define (special-fact-pushes n)
  (special-fact-of n) (stack-pushes special-fact))
(define (compiled-fact-pushes n)
  (run-compiled (list 'fact n)) (stack-pushes compiled-machine))
(define (interpreted-fact-pushes n)
  (run-interpreted (list 'fact n)) (stack-pushes eceval))
(define (special-fact-depth n)
  (special-fact-of n) (stack-max-depth special-fact))
(define (compiled-fact-depth n)
  (run-compiled (list 'fact n)) (stack-max-depth compiled-machine))
(define (interpreted-fact-depth n)
  (run-interpreted (list 'fact n)) (stack-max-depth eceval))

; 1段あたりに何回積むか。**これが3つのやり方の値打ちの差そのもの。**
(check "演習5.45 専用の機械は1段あたり2回積む"
       (slope special-fact-pushes 10 20) 2)
(check "演習5.45 翻訳された符号の1段あたりの押し込み"
       (slope compiled-fact-pushes 10 20) 6)
(check "演習5.45 解釈の1段あたりの押し込み"
       (slope interpreted-fact-pushes 10 20) 32)
(check "演習5.45 順序は 専用 < 翻訳 < 解釈"
       (< (slope special-fact-pushes 10 20)
          (slope compiled-fact-pushes 10 20)
          (slope interpreted-fact-pushes 10 20))
       #t)
; **翻訳は専用の機械の 3 倍、解釈はさらにその 5.3 倍（専用の 16 倍）。**
; 5.5 の冒頭の主張「翻訳は解釈より速い」が数で出る。
(check "演習5.45 翻訳は専用の機械の3倍積む"
       (/ (slope compiled-fact-pushes 10 20)
          (slope special-fact-pushes 10 20))
       3)
(check "演習5.45 解釈は専用の機械の16倍積む"
       (/ (slope interpreted-fact-pushes 10 20)
          (slope special-fact-pushes 10 20))
       16)
(check "演習5.45 解釈は翻訳の5倍強を積む"
       (ratio (slope interpreted-fact-pushes 10 20)
              (slope compiled-fact-pushes 10 20))
       (/ 32.0 6))

; **深さは押し込みと同じ順序にはならない。** ここが測って初めて分かった点で、
; 翻訳と解釈は深さの傾きが同じ 3 であり、差は定数（+6）でしかない。
;   専用   押し込み 2n-2   深さ 2n-2
;   翻訳   押し込み 6n-4   深さ 3n-1
;   解釈   押し込み 32n-16 深さ 3n+5
; **解釈の高くつく所は「要る場所」ではなく「した仕事の量」である。**
; 1段ごとに積んでは降ろすものが大量にあり、その大半は同じ段の中で解ける。
(check "演習5.45 専用の機械の深さの傾き" (slope special-fact-depth 10 20) 2)
(check "演習5.45 翻訳された符号の深さの傾き" (slope compiled-fact-depth 10 20) 3)
(check "演習5.45 解釈の深さの傾き" (slope interpreted-fact-depth 10 20) 3)
(check "演習5.45 翻訳と解釈は深さの傾きが同じ"
       (= (slope compiled-fact-depth 10 20)
          (slope interpreted-fact-depth 10 20))
       #t)
(check "演習5.45 差は定数（同じ n での深さの差）"
       (= (- (interpreted-fact-depth 10) (compiled-fact-depth 10))
          (- (interpreted-fact-depth 20) (compiled-fact-depth 20)))
       #t)
(check "演習5.45 押し込みの側は3通りとも違う"
       (< (slope special-fact-pushes 10 20)
          (slope compiled-fact-pushes 10 20)
          (slope interpreted-fact-pushes 10 20))
       #t)

; 実行命令数でも見る。**翻訳された符号は構文の場合分けを1度も実行しない**
; ので、解釈より1桁近く少ない。
(define (compiled-fact-insts n)
  (run-compiled (list 'fact n)) (inst-count compiled-machine))
(define (interpreted-fact-insts n)
  (run-interpreted (list 'fact n)) (inst-count eceval))
(check "演習5.45 解釈のほうが実行命令数が多い"
       (> (interpreted-fact-insts 20) (* 4 (compiled-fact-insts 20))) #t)
(check "演習5.45 どちらも n の1次式"
       (= (slope compiled-fact-insts 10 20) (slope compiled-fact-insts 20 30))
       #t)

; ============================================================
; 演習5.46 — 木の再帰でも同じ傾向か
; ============================================================
; fib は呼び出しの回数が fib(n) で増えるので、押し込みは n の1次式にならない。
; **比べるのは傾きではなく比**になる。
(define (special-fib-pushes n)
  (special-fib-of n) (stack-pushes special-fib))
(define (compiled-fib-pushes n)
  (run-compiled (list 'fib n)) (stack-pushes compiled-machine))
(define (interpreted-fib-pushes n)
  (run-interpreted (list 'fib n)) (stack-pushes eceval))

(check "演習5.46 木の再帰でも 専用 < 翻訳 < 解釈"
       (< (special-fib-pushes 10) (compiled-fib-pushes 10)
          (interpreted-fib-pushes 10))
       #t)
(check "演習5.46 比は n によらずほぼ一定（翻訳/専用）"
       (let ((r10 (ratio (compiled-fib-pushes 10) (special-fib-pushes 10)))
             (r14 (ratio (compiled-fib-pushes 14) (special-fib-pushes 14))))
         (< (abs (- r10 r14)) 0.1))
       #t)
(check "演習5.46 比は n によらずほぼ一定（解釈/翻訳）"
       (let ((r10 (ratio (interpreted-fib-pushes 10) (compiled-fib-pushes 10)))
             (r14 (ratio (interpreted-fib-pushes 14) (compiled-fib-pushes 14))))
         (< (abs (- r10 r14)) 0.1))
       #t)
; 深さは n の1次式のまま（木の深さは n）。**押し込みだけが指数で増える。**
(check "演習5.46 深さは3通りとも n の1次式"
       (let ((f (lambda (g) (= (- (g 10) (g 8)) (- (g 14) (g 12))))))
         (list (f (lambda (n) (begin (special-fib-of n)
                                     (stack-max-depth special-fib))))
               (f (lambda (n) (begin (run-compiled (list 'fib n))
                                     (stack-max-depth compiled-machine))))
               (f (lambda (n) (begin (run-interpreted (list 'fib n))
                                     (stack-max-depth eceval))))))
       (list #t #t #t))

; ============================================================
; 分かったこと（この比較そのものの主張）
; ============================================================
(check "5.5 翻訳は専用の機械に近く、解釈からは遠い"
       (let ((s (slope special-fact-pushes 10 20))
             (c (slope compiled-fact-pushes 10 20))
             (i (slope interpreted-fact-pushes 10 20)))
         (< (- c s) (- i c)))
       #t)
; 押し込みの式そのものを固定しておく。**翻訳系や評価器を触れば、
; ここが真っ先に動く。**
(check "5.5 3通りの押し込みの式（n=5,10,15,20）"
       (list (map special-fact-pushes '(5 10 15 20))
             (map compiled-fact-pushes '(5 10 15 20))
             (map interpreted-fact-pushes '(5 10 15 20)))
       '((8 18 28 38) (26 56 86 116) (144 304 464 624)))
; **末尾呼び出しは3通りとも成立する。** どのやり方でも、反復のループは
; 定数の場所で回る（5.4.2 と 5.5.3 でそれぞれ確かめた性質が、
; ここで同じ土俵に乗る）。
(run-compiled '(define (count n) (if (= n 0) (quote done) (count (- n 1)))))
(run-interpreted '(define (count n) (if (= n 0) (quote done) (count (- n 1)))))
(check "5.4/5.5 翻訳された末尾呼び出しは定数の場所"
       (= (begin (run-compiled '(count 100)) (stack-max-depth compiled-machine))
          (begin (run-compiled '(count 1000)) (stack-max-depth compiled-machine)))
       #t)
(check "5.4/5.5 解釈された末尾呼び出しも定数の場所"
       (= (begin (run-interpreted '(count 100)) (stack-max-depth eceval))
          (begin (run-interpreted '(count 1000)) (stack-max-depth eceval)))
       #t)
(check "5.4/5.5 ただし解釈のほうが深く積む"
       (> (begin (run-interpreted '(count 100)) (stack-max-depth eceval))
          (begin (run-compiled '(count 100)) (stack-max-depth compiled-machine)))
       #t)

(summary "SICP 5.45-5.46")
