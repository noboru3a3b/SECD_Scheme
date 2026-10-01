; SICP 5.4「明示的制御の評価器」を scheme13 で確認する。
;   5.4.1 評価器の中核 / 5.4.2 列の評価と末尾再帰
;   5.4.3 条件式・代入・定義 / 5.4.4 評価器を走らせる
;
; **この節が第5章の山であり、scheme13 の設計と正面から重なる。**
; 4.1 の超循環評価器は「評価とは何か」を Scheme の再帰で書いた。5.4 は同じ
; 評価器を**レジスタと分岐とスタックだけ**に落とす。手続き呼び出しも再帰も
; 言語の側からは消え、残るのは `goto` と `save` / `restore` である。
;
; scheme13 は式を命令列にコンパイルして SECD 機械で走らせる。5.4 の評価器は
; コンパイルせずに構文を毎回見るが、**「制御を明示的な状態にする」という点は
; まったく同じ**で、`continue` レジスタは scheme13 の戻り番地に、
; `env` レジスタは scheme13 の `Env*` の鎖に、`argl` は引数フレームに対応する。
;
; 処理系側で問われるのは
;   - 5.1〜5.2 のシミュレータの上で、40個近い機械演算を持つ大きな制御器が
;     正しく回ること
;   - **その上で走る被解釈言語の末尾呼び出しが、定数の場所で回ること。**
;     ここは scheme13 の末尾呼び出しとは無関係で、5.4.2 が言う
;     「列の最後の式では continue を先に戻す」という設計だけが効く。
;     10000 回のループが定数の深さで終われば、それが確かめられる
;   - 機械の実行ループ（1命令ごとの再帰）が、100万命令でも尽きないこと
;
; 注記: 5.4.4 の駆動ループ（read-eval-print-loop）は入れない。scheme13 の
; REPL の中で `read` を回すと、確認したいものと関係のない入出力の話になる。
; 代わりに `ec-eval` で式を1つ渡して `val` を受け取る形にした。
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

(define (no-clauses? clauses) (null? clauses))
(define (first-clause clauses) (car clauses))
(define (rest-clauses clauses) (cdr clauses))
(define (clause-predicate clause) (car clause))
(define (clause-actions clause) (cdr clause))

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
    ;; `cond` は差し替えられるように別の塊にしてある（演習5.24）。
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

; 演習5.23 の `cond` — **書き換えて入口へ戻すだけ。** 3命令で済む。
(define ec-cond-derived
  '(ev-cond
      (assign exp (op cond->if) (reg exp))
      (goto (label eval-dispatch))))

; 演習5.24 — `cond` を派生式ではなく**基本の特殊形式**として実装する。
; 節を順に見て、真になった節の本体を列として評価する。
; **`if` に潰さないので、書き換えの分だけ命令が減る**代わりに、
; 制御器が節の構造を直に知ることになる（`cond` の構文が制御器に染み出す）。
(define ec-cond-basic
  '(ev-cond
      (assign unev (op cond-clauses) (reg exp))
      (save continue)
    ev-cond-loop
      (test (op no-clauses?) (reg unev))
      (branch (label ev-cond-none))
      (assign exp (op first-clause) (reg unev))
      (test (op cond-else-clause?) (reg exp))
      (branch (label ev-cond-actions))
      (save unev)
      (save env)
      (assign exp (op clause-predicate) (reg exp))
      (assign continue (label ev-cond-decide))
      (goto (label eval-dispatch))
    ev-cond-decide
      (restore env)
      (restore unev)
      (test (op true?) (reg val))
      (branch (label ev-cond-chosen))
      (assign unev (op rest-clauses) (reg unev))
      (goto (label ev-cond-loop))
    ev-cond-chosen
      (assign exp (op first-clause) (reg unev))
    ev-cond-actions
      ;; continue は入口で積んである。列の最後の式がそれを戻すので、
      ;; **節の本体の末尾呼び出しも場所を食わない。**
      (assign unev (op clause-actions) (reg exp))
      (goto (label ev-sequence))
    ev-cond-none
      (restore continue)
      (assign val (const false))
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
   (list 'cond-clauses cond-clauses)
   (list 'cond-else-clause? cond-else-clause?)
   (list 'no-clauses? no-clauses?) (list 'first-clause first-clause)
   (list 'rest-clauses rest-clauses)
   (list 'clause-predicate clause-predicate)
   (list 'clause-actions clause-actions)
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
                (append ec-main ec-cond-derived ec-seq-tail ec-end)))
(define eceval-no-tail
  (make-machine ec-registers ec-operations
                (append ec-main ec-cond-derived ec-seq-naive ec-end)))
; 演習5.24 — `cond` だけを差し替えた評価器。**他は1行も違わない。**
(define eceval-cond-basic
  (make-machine ec-registers ec-operations
                (append ec-main ec-cond-basic ec-seq-tail ec-end)))

; ============================================================
; 5.4.4 評価器を走らせる
; ============================================================
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

(define the-global-environment (setup-environment))
(define (reset-global-environment!)
  (set! the-global-environment (setup-environment)))

; 式を1つ渡して val を受け取る。**機械は毎回入口から走り直す**が、環境は
; 外に持っているので、定義は次の式から見える（REPL と同じ状態の持ち方）。
(define (ec-eval-in machine exp env)
  (set! ec-error #f)
  (run machine (list (list 'exp exp) (list 'env env)))
  (get-register-contents machine 'val))
(define (ec-eval exp) (ec-eval-in eceval exp the-global-environment))
(define (ec-eval-seq exps)
  ; 何本かの式を順に評価し、最後の値を返す。
  (let loop ((es exps) (last 'none))
    (if (null? es) last (loop (cdr es) (ec-eval (car es))))))

; --- 5.4.1 部分式を持たない式 ---
(check "5.4.1 自己評価する式（数）" (ec-eval '42) 42)
(check "5.4.1 自己評価する式（文字列）" (ec-eval '"hi") "hi")
(check "5.4.1 引用" (ec-eval '(quote (a b c))) '(a b c))
(check "5.4.1 変数の参照" (ec-eval '(car (quote (1 2)))) 1)
(check "5.4.1 lambda は手続きを作る"
       (car (ec-eval '(lambda (x) x))) 'procedure)

; --- 5.4.1 適用 ---
(check "5.4.1 基本手続きの適用" (ec-eval '(+ 1 2)) 3)
(check "5.4.1 引数のない適用" (ec-eval '((lambda () 7))) 7)
(check "5.4.1 入れ子の適用" (ec-eval '(+ (* 2 3) (- 10 4))) 12)
(check "5.4.1 その場の lambda" (ec-eval '((lambda (x y) (* x y)) 6 7)) 42)
(check "5.4.1 閉包が環境を捕まえる"
       (ec-eval '(((lambda (x) (lambda (y) (+ x y))) 10) 5)) 15)

; 5.4 の評価器は被演算子を左から右へ評価する（first-operand が car、
; rest-operands が cdr だから）。副作用で順を見る。
(check "5.4.1 被演算子は左から右へ"
       (ec-eval-seq
        '((define order (quote ()))
          (define (note x) (set! order (cons x order)) x)
          (list (note 1) (note 2) (note 3))
          order))
       '(3 2 1))

; --- 5.4.3 条件式・代入・定義 ---
(check "5.4.3 if の真の枝" (ec-eval '(if (> 2 1) (quote yes) (quote no))) 'yes)
(check "5.4.3 if の偽の枝" (ec-eval '(if (< 2 1) (quote yes) (quote no))) 'no)
(check "5.4.3 else 節のない if" (ec-eval '(if (< 2 1) 1)) 'false)
(check "5.4.3 define は ok を返す" (ec-eval '(define zz 5)) 'ok)
(check "5.4.3 define した値が見える" (ec-eval 'zz) 5)
(check "5.4.3 set! で書き換える"
       (ec-eval-seq '((set! zz 9) zz)) 9)
(check "5.4.3 手続きの define（糖衣）"
       (ec-eval-seq '((define (sq x) (* x x)) (sq 12))) 144)
(check "5.4.3 begin は最後の値"
       (ec-eval '(begin 1 2 3)) 3)
(check "5.4.3 begin の途中も評価される"
       (ec-eval-seq '((define k 0) (begin (set! k 1) (set! k (+ k 10))) k)) 11)
(check "5.4.3 内側の define は外を隠す"
       (ec-eval-seq '((define w 1)
                      (define (f) (define w 2) w)
                      (list (f) w)))
       '(2 1))

; --- 演習5.23 派生式 ---
(check "演習5.23 cond" (ec-eval '(cond ((= 1 2) (quote a))
                                       ((= 1 1) (quote b))
                                       (else (quote c)))) 'b)
(check "演習5.23 cond の else" (ec-eval '(cond ((= 1 2) (quote a))
                                               (else (quote c)))) 'c)
(check "演習5.23 節の本体は複数の式"
       (ec-eval-seq '((define c 0)
                      (cond ((= 1 1) (set! c 5) (+ c 1))))) 6)
(check "演習5.23 どの節も真でないとき"
       (ec-eval '(cond ((= 1 2) (quote a)))) 'false)
(check "演習5.23 let" (ec-eval '(let ((a 3) (b 4)) (+ (* a a) (* b b)))) 25)
(check "演習5.23 let の外の値が見える"
       (ec-eval-seq '((define q 100) (let ((a 1)) (+ a q)))) 101)

; --- 再帰する手続き ---
(check "5.4 再帰の階乗"
       (ec-eval-seq '((define (fact n) (if (= n 1) 1 (* n (fact (- n 1)))))
                      (fact 10)))
       3628800)
(check "5.4 再帰の階乗が bignum へ伸びる"
       (ec-eval '(fact 25)) 15511210043330985984000000)
(check "5.4 木の再帰（fib）"
       (ec-eval-seq '((define (fib n)
                        (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
                      (fib 15)))
       610)
(check "5.4 相互再帰"
       (ec-eval-seq '((define (my-even? n) (if (= n 0) #t (my-odd? (- n 1))))
                      (define (my-odd? n) (if (= n 0) #f (my-even? (- n 1))))
                      (list (my-even? 10) (my-odd? 10))))
       (list #t #f))
(check "5.4 リストを扱う手続き"
       (ec-eval-seq '((define (my-map f xs)
                        (if (null? xs) (quote ())
                            (cons (f (car xs)) (my-map f (cdr xs)))))
                      (my-map (lambda (x) (* x x)) (list 1 2 3 4))))
       '(1 4 9 16))
(check "5.4 高階手続き"
       (ec-eval-seq '((define (compose f g) (lambda (x) (f (g x))))
                      ((compose (lambda (x) (+ x 1)) (lambda (x) (* x 2))) 5)))
       11)

; ============================================================
; 5.4.2 末尾再帰 — **この節の主張を実測する**
; ============================================================
; 反復のループを回し、スタックの最大の深さを見る。回数を増やしても深さが
; 変わらなければ、それが「末尾再帰である」ということの意味そのものである。
(define (loop-depth n)
  (ec-eval-seq
   (list '(define (count n) (if (= n 0) (quote done) (count (- n 1))))
         (list 'count n)))
  (stack-max-depth eceval))

(check "5.4.2 反復のループが動く"
       (ec-eval-seq '((define (count n) (if (= n 0) (quote done) (count (- n 1)))))
                    )
       'ok)
(check "5.4.2 100 回のループ" (ec-eval '(count 100)) 'done)
(check "5.4.2 深さは回数によらない"
       (= (loop-depth 10) (loop-depth 100) (loop-depth 1000)) #t)
; **10000 回でも同じ深さで終わる。** 被解釈言語の側に無限のループが書ける。
(check "5.4.2 10000 回でも深さが変わらない"
       (= (loop-depth 10) (loop-depth 10000)) #t)
(check "5.4.2 10000 回の答え" (ec-eval '(count 10000)) 'done)

; 演習5.26 — 反復の階乗。**呼び出しの入れ子は n 段だが、場所は定数。**
(define (iter-fact-profile n)
  (ec-eval-seq
   (list '(define (fact-iter n)
            (define (iter product counter)
              (if (> counter n) product (iter (* counter product) (+ counter 1))))
            (iter 1 1))
         (list 'fact-iter n)))
  (list (stack-max-depth eceval) (stack-pushes eceval)))

(check "演習5.26 反復の階乗の答え"
       (ec-eval-seq
        (list '(define (fact-iter n)
                 (define (iter product counter)
                   (if (> counter n)
                       product
                       (iter (* counter product) (+ counter 1))))
                 (iter 1 1))
              '(fact-iter 20)))
       2432902008176640000)
(check "演習5.26 最大の深さは n によらない"
       (= (car (iter-fact-profile 5)) (car (iter-fact-profile 50))) #t)
(check "演習5.26 押し込みの総数は n に比例する"
       (let ((a (cadr (iter-fact-profile 10)))
             (b (cadr (iter-fact-profile 20))))
         (and (> b a) (< b (* 3 a))))
       #t)

; 演習5.27 — 再帰の階乗。こちらは深さが n に比例して伸びる。
(define (rec-fact-profile n)
  (ec-eval-seq
   (list '(define (fact n) (if (= n 1) 1 (* n (fact (- n 1)))))
         (list 'fact n)))
  (list (stack-max-depth eceval) (stack-pushes eceval)))

(check "演習5.27 再帰の階乗は深さが n に比例する"
       (let ((d5 (car (rec-fact-profile 5)))
             (d10 (car (rec-fact-profile 10)))
             (d20 (car (rec-fact-profile 20))))
         (list (- d10 d5) (- d20 d10)))
       (let ((d5 (car (rec-fact-profile 5)))
             (d10 (car (rec-fact-profile 10))))
         (list (- d10 d5) (* 2 (- d10 d5)))))
(check "演習5.27 反復と再帰で深さが違う"
       (> (car (rec-fact-profile 20)) (* 3 (car (iter-fact-profile 20)))) #t)

; 演習5.28 — 末尾再帰をやめた評価器。**答えは同じで、場所だけが変わる。**
(define no-tail-env (setup-environment))
(define (no-tail-loop-depth n)
  (let loop ((es (list '(define (count n)
                          (if (= n 0) (quote done) (count (- n 1))))
                       (list 'count n)))
             (last 'none))
    (if (null? es)
        last
        (loop (cdr es) (ec-eval-in eceval-no-tail (car es) no-tail-env))))
  (stack-max-depth eceval-no-tail))

(check "演習5.28 答えは変わらない"
       (ec-eval-in eceval-no-tail
                   '(begin (define (count n)
                             (if (= n 0) (quote done) (count (- n 1))))
                           (count 200))
                   no-tail-env)
       'done)
(check "演習5.28 深さが回数に比例して伸びる"
       (let ((d10 (no-tail-loop-depth 10))
             (d20 (no-tail-loop-depth 20))
             (d40 (no-tail-loop-depth 40)))
         (list (> d20 d10) (= (- d40 d20) (* 2 (- d20 d10)))))
       (list #t #t))
(check "演習5.28 末尾再帰版とそうでない版の差"
       (> (no-tail-loop-depth 100) (* 5 (loop-depth 100))) #t)

; 演習5.29 — 木の再帰の押し込みの総数は fib(n) と同じ速さで増える。
(define (fib-pushes n)
  (ec-eval-seq
   (list '(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
         (list 'fib n)))
  (stack-pushes eceval))
(check "演習5.29 木の再帰は押し込みが指数で増える"
       (> (fib-pushes 12) (* 3 (fib-pushes 8))) #t)
(check "演習5.29 深さは n に比例する（押し込みとは違う）"
       (let ((d5 (begin (fib-pushes 5) (stack-max-depth eceval)))
             (d10 (begin (fib-pushes 10) (stack-max-depth eceval))))
         (< (- d10 d5) 60))
       #t)

; ============================================================
; 演習5.30 — 型の分からない式と手続き
; ============================================================
; scheme13 に Scheme レベルの例外捕捉が無いので、評価器の側で受け止める。
; **エラーを「値として signal-error に渡す」形にすれば、処理系を止めずに
; 済む**（本書の駆動ループが printf して読み込みへ戻るのと同じ扱い）。
(check "演習5.30 型の分からない式"
       (begin (ec-eval (vector 1 2)) ec-error) 'unknown-expression-type)
(check "演習5.30 手続きでない物の適用"
       (begin (ec-eval '((quote notaproc) 1)) ec-error) 'unknown-procedure-type)
(check "演習5.30 その後も評価器は生きている"
       (list (ec-eval '(+ 1 1)) ec-error) (list 2 #f))

; ============================================================
; 演習5.24 — cond を基本の特殊形式にする
; ============================================================
; `cond` だけを差し替えた評価器（`eceval-cond-basic`）で同じ主張を通す。
; **答えは1つも変わらない。** 変わるのは、制御器が節の構造を直に知ることと、
; 書き換えの手間が消えること。
(define cond-basic-env (setup-environment))
(define (cond-eval exp) (ec-eval-in eceval-cond-basic exp cond-basic-env))
(define (cond-eval-seq exps)
  (let loop ((es exps) (last 'none))
    (if (null? es) last (loop (cdr es) (cond-eval (car es))))))

(check "演習5.24 真になった節" (cond-eval '(cond ((= 1 2) (quote a))
                                                  ((= 1 1) (quote b))
                                                  (else (quote c)))) 'b)
(check "演習5.24 else 節" (cond-eval '(cond ((= 1 2) (quote a))
                                             (else (quote c)))) 'c)
(check "演習5.24 どの節も真でないとき"
       (cond-eval '(cond ((= 1 2) (quote a)))) 'false)
(check "演習5.24 節の本体は複数の式"
       (cond-eval-seq '((define c 0)
                        (cond ((= 1 1) (set! c 5) (+ c 1))))) 6)
(check "演習5.24 述語は左から順に1度だけ評価される"
       (cond-eval-seq
        '((define seen (quote ()))
          (define (p x v) (set! seen (cons x seen)) v)
          (cond ((p 1 #f) (quote a))
                ((p 2 #t) (quote b))
                ((p 3 #t) (quote c)))
          seen))
       '(2 1))
(check "演習5.24 節の中で手続きを呼べる"
       (cond-eval-seq '((define (sign n)
                          (cond ((> n 0) (quote pos))
                                ((< n 0) (quote neg))
                                (else (quote zero))))
                        (list (sign 3) (sign -3) (sign 0))))
       '(pos neg zero))
; **派生式版と基本形式版で答えが一致する。** これが差し替えの正しさの意味。
(check "演習5.24 派生式版と同じ答え"
       (map (lambda (e) (equal? (cond-eval e) (ec-eval e)))
            '((cond ((= 1 1) 1) (else 2))
              (cond ((= 1 2) 1) (else 2))
              (cond ((= 1 2) 1))
              (cond (#t (quote x) (quote y)))))
       (list #t #t #t #t))
; 節の本体の末尾呼び出しも場所を食わない（continue を入口で預けているため）。
(check "演習5.24 cond の本体でも末尾再帰が効く"
       (begin (cond-eval-seq
               '((define (down n) (cond ((= n 0) (quote done))
                                        (else (down (- n 1)))))
                 (down 20)))
              (let ((d20 (stack-max-depth eceval-cond-basic)))
                (cond-eval '(down 200))
                (= (stack-max-depth eceval-cond-basic) d20)))
       #t)
; **命令列は基本形式版のほうが長い。** 書き換えを制御器が肩代わりするので。
(check "演習5.24 基本形式版のほうが制御器が長い"
       (> (length ec-cond-basic) (length ec-cond-derived)) #t)

; ============================================================
; 機械としての大きさ
; ============================================================
(check "5.4 制御器の命令数"
       (> (length (append ec-main ec-cond-derived ec-seq-tail ec-end)) 100) #t)
(check "5.4 機械演算の数" (length ec-operations) 56)
(check "5.4 レジスタは7本" (length ec-registers) 7)
; 10000 回のループは百万命令を超える。**シミュレータの実行ループが
; 末尾呼び出しでなければ、ここでスタックが尽きる。**
(check "5.4 百万命令を走り切る"
       (begin (ec-eval '(count 10000)) (> (inst-count eceval) 1000000)) #t)

(summary "SICP 5.4")
