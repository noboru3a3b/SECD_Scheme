; SICP 5.5「翻訳系」を scheme13 で確認する。
;   5.5.1 翻訳系の構造 / 5.5.2 式の翻訳 / 5.5.3 組み合わせの翻訳
;   5.5.4 命令列の結合 / 5.5.5 翻訳された符号の例
;   5.5.6 字句アドレス / 5.5.7 翻訳された符号と評価器をつなぐ
;
; **ここが scheme13 の設計そのものである。** 5.4 の評価器は式を毎回見て
; 場合分けしたが、5.5 は同じ場合分けを**一度だけ**行い、結果を命令列として
; 残す。scheme13 のコンパイラが `LDG` / `LD` / `APP` / `TAPP` を吐くのと
; まったく同じ話で、レジスタ機械という下地が違うだけである。
;
; 対応はこうなる:
;   5.5 の linkage `return` + target `val`   → scheme13 の `TAPP`（末尾呼び出し）
;   5.5 の linkage が label / next            → scheme13 の `APP`
;   5.5 の `preserving` が入れる save/restore  → scheme13 が継続に積む枠
;   5.5.6 の字句アドレス (frame . displacement) → scheme13 の `LD (depth index)`
;
; **scheme13 は 5.5.6 を既定で行っている。** 局所変数は名前ではなく
; 「何段外の何番目」で引かれる。5.5.6 を通すことは、その設計が教科書の
; 言うとおりのものであることの確認になる。
;
; 処理系側で問われるのは
;   - 準引用（quasiquote）で命令を組み立てられること。**命令列は
;     データであり、コンパイラはそれを継ぎ足していく手続きである**
;   - `apply` で可変個引数の手続きを再帰的に呼べること
;     （`append-instruction-seqs` が可変個を取る）
;   - 生成した命令列が、5.1〜5.2 のシミュレータでそのまま走ること
;   - **翻訳された末尾呼び出しが定数の場所で回ること。**
;     5.4 で測ったのと同じ性質を、今度は生成された符号について測る
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
; 構文・環境・手続き（5.4 と同じ道具立て）
; ============================================================
(define (tagged-list? exp tag) (and (pair? exp) (eq? (car exp) tag)))
(define (self-evaluating? exp) (or (number? exp) (string? exp) (boolean? exp)))
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
(define (if-alternative exp) (if (null? (cdddr exp)) '(quote false) (cadddr exp)))
(define (begin? exp) (tagged-list? exp 'begin))
(define (begin-actions exp) (cdr exp))
(define (first-exp seq) (car seq))
(define (rest-exps seq) (cdr seq))
(define (last-exp? seq) (null? (cdr seq)))
(define (let? exp) (tagged-list? exp 'let))
(define (let->combination exp)
  (let ((bindings (cadr exp)) (body (cddr exp)))
    (cons (cons 'lambda (cons (map car bindings) body)) (map cadr bindings))))
(define (application? exp) (pair? exp))
(define (operator exp) (car exp))
(define (operands exp) (cdr exp))

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
  (if (= (length vars) (length vals))
      (cons (make-frame vars vals) base-env)
      (error "compiled: wrong number of arguments" vars)))
(define (env-scan var env found missing)
  (if (null? env)
      (missing)
      (let loop ((vars (frame-variables (first-frame env)))
                 (vals (frame-values (first-frame env))))
        (cond ((null? vars)
               (env-scan var (enclosing-environment env) found missing))
              ((eq? var (car vars)) (found vals))
              (else (loop (cdr vars) (cdr vals)))))))
(define (lookup-variable-value var env)
  (env-scan var env car (lambda () (error "compiled: unbound variable" var))))
(define (set-variable-value! var val env)
  (env-scan var env (lambda (cell) (set-car! cell val) 'ok)
            (lambda () (error "compiled: unbound variable -- SET!" var))))
(define (define-variable! var val env)
  (let loop ((vars (frame-variables (first-frame env)))
             (vals (frame-values (first-frame env))))
    (cond ((null? vars) (add-binding-to-frame! var val (first-frame env)) 'ok)
          ((eq? var (car vars)) (set-car! vals val) 'ok)
          (else (loop (cdr vars) (cdr vals))))))

; **翻訳された手続きは「入口のラベルと環境」の対である。**
; 5.4 の合成手続きが「引数の並び・本体・環境」だったのと比べると、
; 本体が命令列の中の一点に潰れている。これが翻訳の眼目そのもの。
(define (make-compiled-procedure entry env) (list 'compiled-procedure entry env))
(define (compiled-procedure? p) (tagged-list? p 'compiled-procedure))
(define (compiled-procedure-entry p) (cadr p))
(define (compiled-procedure-env p) (caddr p))
(define (primitive-procedure? p) (tagged-list? p 'primitive))
(define (apply-primitive-procedure p args) (apply (cadr p) args))
(define (false? x) (eq? x #f))

; ============================================================
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

(define (compile exp target linkage)
  (cond ((self-evaluating? exp) (compile-self-evaluating exp target linkage))
        ((quoted? exp) (compile-quoted exp target linkage))
        ((variable? exp) (compile-variable exp target linkage))
        ((assignment? exp) (compile-assignment exp target linkage))
        ((definition? exp) (compile-definition exp target linkage))
        ((if? exp) (compile-if exp target linkage))
        ((lambda? exp) (compile-lambda exp target linkage))
        ((begin? exp) (compile-sequence (begin-actions exp) target linkage))
        ((let? exp) (compile (let->combination exp) target linkage))
        ((application? exp) (compile-application exp target linkage))
        (else (error "compile: unknown expression type" exp))))

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
(define (compile-variable exp target linkage)
  (end-with-linkage
   linkage
   (make-instruction-seq
    '(env) (list target)
    (list (list 'assign target '(op lookup-variable-value)
                (list 'const exp) '(reg env))))))
(define (compile-assignment exp target linkage)
  (let ((var (assignment-variable exp))
        (get-value-code (compile (assignment-value exp) 'val 'next)))
    (end-with-linkage
     linkage
     (preserving
      '(env) get-value-code
      (make-instruction-seq
       '(env val) (list target)
       (list (list 'perform '(op set-variable-value!)
                   (list 'const var) '(reg val) '(reg env))
             (list 'assign target '(const ok))))))))
(define (compile-definition exp target linkage)
  (let ((var (definition-variable exp))
        (get-value-code (compile (definition-value exp) 'val 'next)))
    (end-with-linkage
     linkage
     (preserving
      '(env) get-value-code
      (make-instruction-seq
       '(env val) (list target)
       (list (list 'perform '(op define-variable!)
                   (list 'const var) '(reg val) '(reg env))
             (list 'assign target '(const ok))))))))

(define (compile-if exp target linkage)
  (let ((t-branch (make-label 'true-branch))
        (f-branch (make-label 'false-branch))
        (after-if (make-label 'after-if)))
    (let ((consequent-linkage (if (eq? linkage 'next) after-if linkage)))
      (let ((p-code (compile (if-predicate exp) 'val 'next))
            (c-code (compile (if-consequent exp) target consequent-linkage))
            (a-code (compile (if-alternative exp) target linkage)))
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

(define (compile-sequence seq target linkage)
  (if (last-exp? seq)
      (compile (first-exp seq) target linkage)
      (preserving '(env continue)
                  (compile (first-exp seq) target 'next)
                  (compile-sequence (rest-exps seq) target linkage))))

; --- 5.5.2 lambda ---
; **本体は命令列の中に置き去りにし、その上を `goto` で跳び越す。**
; 手続きの値は「入口のラベルと、いまの環境」だけになる。
(define (compile-lambda exp target linkage)
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
        (compile-lambda-body exp proc-entry))
       after-lambda))))
(define (compile-lambda-body exp proc-entry)
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
     (compile-sequence (lambda-body exp) 'val 'return))))

; ============================================================
; 5.5.3 組み合わせの翻訳
; ============================================================
; 演算子を `proc` に、被演算子を `argl` に集める。**被演算子は後ろから
; 翻訳する**（cons で前に足していくと、実行時は右から左の順になる）。
; 5.4 の評価器が左から右だったのと逆で、演習5.36 が問うのはこの点である。
(define (compile-application exp target linkage)
  (let ((proc-code (compile (operator exp) 'proc 'next))
        (operand-codes (map (lambda (operand) (compile operand 'val 'next))
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

; ============================================================
; 5.5.7 翻訳された符号を走らせる
; ============================================================
(define (primitive-entry name proc) (list name (list 'primitive proc)))
(define compiler-primitives
  (list (primitive-entry 'car car) (primitive-entry 'cdr cdr)
        (primitive-entry 'cons cons) (primitive-entry 'null? null?)
        (primitive-entry 'list list) (primitive-entry 'not not)
        (primitive-entry 'eq? eq?) (primitive-entry 'equal? equal?)
        (primitive-entry '+ +) (primitive-entry '- -)
        (primitive-entry '* *) (primitive-entry '= =)
        (primitive-entry '< <) (primitive-entry '> >)
        (primitive-entry 'remainder remainder)))
(define (setup-environment)
  (extend-environment (map car compiler-primitives)
                      (map cadr compiler-primitives)
                      the-empty-environment))
(define the-global-environment (setup-environment))

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
        (list 'list list) (list 'cons cons)))

; 翻訳して、その命令列そのものを制御器にした機械を作って走らせる。
; **生成された符号が 5.1.5 の書式に収まっていなければ、ここでアセンブルに
; 失敗する。** 翻訳系の出力が本当にレジスタ機械の言語であることの確認になる。
;
; **機械は1つでなければならない。** 翻訳された手続きの値は「入口のラベル」、
; すなわち*その機械の*命令列の中の一点を指す。式ごとに機械を作り直すと、
; 前に定義した手続きの入口が別の機械のレジスタを掴んだままになり、
; 呼び出した先で `proc` が空のままになる。5.5.7 が翻訳した符号を評価器の
; 機械へ「積み込む」形にしているのは、まさにこの理由である。
(define compiled-machine (make-machine all-regs compiler-operations '()))
(define last-machine compiled-machine)
(define (run-compiled exp)
  (let ((code (statements (compile exp 'val 'next))))
    ((compiled-machine 'install-instruction-sequence)
     (assemble code compiled-machine))
    (run compiled-machine (list (list 'env the-global-environment)))
    (get-register-contents compiled-machine 'val)))
(define (run-compiled-seq exps)
  (let loop ((es exps) (last 'none))
    (if (null? es) last (loop (cdr es) (run-compiled (car es))))))

; --- 5.5.2 の式が翻訳されて走る ---
(check "5.5.2 数" (run-compiled '42) 42)
(check "5.5.2 引用" (run-compiled '(quote (a b))) '(a b))
(check "5.5.2 変数" (run-compiled '(quote ())) '())
(check "5.5.2 define と参照"
       (run-compiled-seq '((define n 7) n)) 7)
(check "5.5.2 set!"
       (run-compiled-seq '((set! n 8) n)) 8)
(check "5.5.2 if の真の枝" (run-compiled '(if (> 2 1) 10 20)) 10)
(check "5.5.2 if の偽の枝" (run-compiled '(if (< 2 1) 10 20)) 20)
(check "5.5.2 begin は最後の値" (run-compiled '(begin 1 2 3)) 3)
(check "5.5.2 lambda は翻訳された手続きを作る"
       (car (run-compiled '(lambda (x) x))) 'compiled-procedure)

; --- 5.5.3 組み合わせ ---
(check "5.5.3 基本手続きの適用" (run-compiled '(+ 1 2)) 3)
(check "5.5.3 引数のない適用" (run-compiled '((lambda () 5))) 5)
(check "5.5.3 入れ子の適用" (run-compiled '(+ (* 2 3) (- 10 4))) 12)
(check "5.5.3 その場の lambda" (run-compiled '((lambda (x y) (* x y)) 6 7)) 42)
(check "5.5.3 閉包が環境を捕まえる"
       (run-compiled '(((lambda (x) (lambda (y) (+ x y))) 10) 5)) 15)
(check "5.5.3 let" (run-compiled '(let ((a 3) (b 4)) (+ (* a a) (* b b)))) 25)
(check "5.5.3 引数を5つ取る"
       (run-compiled '((lambda (a b c d e) (list a b c d e)) 1 2 3 4 5))
       '(1 2 3 4 5))
; 演習5.36 — 翻訳系は被演算子を右から左へ評価する（5.4 の評価器と逆）。
(check "演習5.36 被演算子は右から左へ"
       (run-compiled-seq
        '((define order (quote ()))
          (define (note x) (set! order (cons x order)) x)
          (list (note 1) (note 2) (note 3))
          order))
       '(1 2 3))

; --- 5.5.5 翻訳された符号の例（階乗）---
(check "5.5.5 再帰の階乗"
       (run-compiled-seq
        '((define (fact n) (if (= n 1) 1 (* n (fact (- n 1)))))
          (fact 10)))
       3628800)
(check "5.5.5 階乗が bignum へ伸びる" (run-compiled '(fact 25))
       15511210043330985984000000)
(check "5.5.5 木の再帰"
       (run-compiled-seq
        '((define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
          (fib 15)))
       610)
(check "5.5.5 相互再帰"
       (run-compiled-seq
        '((define (ev? n) (if (= n 0) #t (od? (- n 1))))
          (define (od? n) (if (= n 0) #f (ev? (- n 1))))
          (list (ev? 10) (od? 10))))
       (list #t #f))
(check "5.5.5 リストを扱う手続き"
       (run-compiled-seq
        '((define (my-map f xs)
            (if (null? xs) (quote ()) (cons (f (car xs)) (my-map f (cdr xs)))))
          (my-map (lambda (x) (* x x)) (list 1 2 3 4))))
       '(1 4 9 16))

; --- 5.5.3 末尾呼び出し — 翻訳された符号の側で測る ---
; 5.4 で評価器について測ったのと同じ性質を、いま生成された命令列について測る。
; **`compile-proc-appl` の3番目の場合が効いていなければ、ここで深さが伸びる。**
(define (compiled-loop-depth n)
  (run-compiled-seq
   (list '(define (count n) (if (= n 0) (quote done) (count (- n 1))))
         (list 'count n)))
  (stack-max-depth last-machine))
(check "5.5.3 反復のループが動く" (run-compiled-seq
                                  (list '(define (count n)
                                           (if (= n 0) (quote done) (count (- n 1))))
                                        '(count 100)))
       'done)
(check "5.5.3 翻訳された末尾呼び出しは場所を食わない"
       (= (compiled-loop-depth 10) (compiled-loop-depth 100)
          (compiled-loop-depth 1000))
       #t)
(check "5.5.3 10000 回でも同じ" (= (compiled-loop-depth 10)
                                   (compiled-loop-depth 10000)) #t)
; 深さは 2 で止まる。**述語 `(= n 0)` を評価する間だけ env と continue を
; 預けるためで、これは繰り返しの回数に依らない。** 積みっぱなしにならない
; ことが末尾呼び出しの意味であって、1つも積まないことではない。
(check "5.5.3 その深さは回数によらず 2" (compiled-loop-depth 1000) 2)
; 再帰のほうは n に比例して積む。**翻訳しても、アルゴリズムの性質は変わらない。**
(define (compiled-fact-depth n)
  (run-compiled-seq
   (list '(define (fact n) (if (= n 1) 1 (* n (fact (- n 1)))))
         (list 'fact n)))
  (stack-max-depth last-machine))
(check "5.5.5 再帰の階乗は n に比例して積む"
       (let ((d5 (compiled-fact-depth 5)) (d10 (compiled-fact-depth 10)))
         (= (- d10 d5) (* 5 (/ (- d10 d5) 5))))
       #t)
(check "5.5.5 深さの伸びが一定"
       (let ((d5 (compiled-fact-depth 5))
             (d10 (compiled-fact-depth 10))
             (d15 (compiled-fact-depth 15)))
         (= (- d10 d5) (- d15 d10)))
       #t)

; --- 5.5.4 preserving が要る所にだけ save を入れる ---
; **変数の参照は何も壊さないので、退避は1つも入らない。**
; 5.4 の評価器は同じ場面で continue と env と unev を積んでいた。
(define (count-saves code)
  (length (filter-save (statements code))))
(define (filter-save insts)
  (cond ((null? insts) '())
        ((and (pair? (car insts)) (eq? (car (car insts)) 'save))
         (cons (car insts) (filter-save (cdr insts))))
        (else (filter-save (cdr insts)))))
(check "5.5.4 変数の参照に save は入らない"
       (count-saves (compile 'x 'val 'next)) 0)
(check "5.5.4 定数にも入らない"
       (count-saves (compile '5 'val 'next)) 0)
(check "5.5.4 基本手続きの単純な適用でも入らない"
       (count-saves (compile '(f) 'val 'next)) 0)
; **引数が変数や定数なら、いくつ並んでも退避は入らない。** 引き当ては
; どのレジスタも壊さないからで、これが 5.5.4 の名簿を持つ理由そのもの。
(check "5.5.4 引数が変数だけなら退避は入らない"
       (count-saves (compile '(f x y z) 'val 'next)) 0)
; 引数の中に呼び出しがあると、その間 env が壊れるので退避が入る。
(check "5.5.4 引数が呼び出しなら退避が入る"
       (> (count-saves (compile '(f (g 1) (h 2)) 'val 'next)) 0) #t)
(check "5.5.4 名簿は3つ組"
       (length (compile '5 'val 'next)) 3)
(check "5.5.4 変数の参照は env を要り、target を壊す"
       (list (registers-needed (compile 'x 'val 'next))
             (registers-modified (compile 'x 'val 'next)))
       '((env) (val)))
(check "5.5.4 定数は何も要らない"
       (registers-needed (compile '5 'val 'next)) '())
; preserving は「壊し、かつ要る」ときだけ入れる。片方だけなら入らない。
(check "5.5.4 preserving は要らない退避を入れない"
       (length (statements
                (preserving '(env)
                            (make-instruction-seq '() '(val) '((assign val (const 1))))
                            (make-instruction-seq '(env) '() '((goto (reg env)))))))
       2)
(check "5.5.4 壊して、かつ要るときは入れる"
       (length (statements
                (preserving '(env)
                            (make-instruction-seq '() '(env) '((assign env (const 1))))
                            (make-instruction-seq '(env) '() '((goto (reg env)))))))
       4)

; --- 生成された符号が本当にレジスタ機械の言語であること ---
(check "5.5 生成された命令は 5.1.5 の書式"
       (let loop ((insts (statements (compile '(f (g x) 2) 'val 'next))))
         (cond ((null? insts) #t)
               ((symbol? (car insts)) (loop (cdr insts)))   ; ラベル
               ((memq (car (car insts))
                      '(assign test branch goto save restore perform))
                (loop (cdr insts)))
               (else (car insts))))
       #t)
(check "5.5 翻訳は式の大きさに比例した命令列を出す"
       (< (length (statements (compile '(+ 1 2) 'val 'next)))
          (length (statements (compile '(+ 1 (* 2 (- 3 4))) 'val 'next))))
       #t)

; ============================================================
; 5.5.6 字句アドレス
; ============================================================
; **これは scheme13 が既定で行っていることの、教科書側の記述である。**
; 変数の位置は翻訳時に分かる。`(frame . displacement)` — 何段外の枠の
; 何番目か — まで割り出しておけば、実行時に名前を照合する必要が無い。
; scheme13 の `LD (depth index)` はこれそのもので、`LDG` だけが
; 「翻訳時に枠が分からない大域名」のために残っている。
;
; 範囲について正直に書く: ここでは**アドレスの割り出しと引き当て**を確かめる。
; 翻訳時環境を `compile` の全再帰に通す作業（演習5.41〜5.44）は、
; 5.5 の主張の確認には要らないので入れていない。
; 変数の参照だけを差し替える形で、生成される命令が変わることまで見る。

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

(define sample-ctenv '((y z) (a b c d e) (x y)))
(check "5.5.6 いまの枠の先頭" (find-variable 'y sample-ctenv) '(0 0))
(check "5.5.6 いまの枠の2番目" (find-variable 'z sample-ctenv) '(0 1))
(check "5.5.6 1段外の枠" (find-variable 'c sample-ctenv) '(1 2))
(check "5.5.6 2段外の枠" (find-variable 'x sample-ctenv) '(2 0))
(check "5.5.6 内側の名前が外側を隠す" (find-variable 'y sample-ctenv) '(0 0))
(check "5.5.6 見つからなければ大域" (find-variable 'w sample-ctenv) 'not-found)

; 割り出したアドレスで、実行時環境から名前を使わずに引ける。
(define sample-env
  (extend-environment
   '(y z) '(10 20)
   (extend-environment
    '(a b c d e) '(1 2 3 4 5)
    (extend-environment '(x y) '(100 200) the-empty-environment))))
(check "5.5.6 アドレスで引ける"
       (lexical-address-lookup (find-variable 'c sample-ctenv) sample-env) 3)
(check "5.5.6 外の枠もアドレスで引ける"
       (lexical-address-lookup (find-variable 'x sample-ctenv) sample-env) 100)
; **名前で引いた結果と一致する。** これが字句アドレスが正しいことの意味。
(check "5.5.6 名前で引いた結果と一致する"
       (map (lambda (v)
              (equal? (lexical-address-lookup (find-variable v sample-ctenv)
                                              sample-env)
                      (lookup-variable-value v sample-env)))
            '(y z a b c d e x))
       (list #t #t #t #t #t #t #t #t))
(check "5.5.6 アドレスで書き換えられる"
       (begin (lexical-address-set! (find-variable 'b sample-ctenv)
                                    sample-env 99)
              (lookup-variable-value 'b sample-env))
       99)

; 変数の参照の翻訳を、翻訳時環境を見る形に差し替える。
; **枠が分かっていれば探索の命令が消え、分からなければ元のまま**という
; 分かれ方が、scheme13 の `LD` と `LDG` の分かれ方と同じである。
(define (compile-variable-lexical exp target linkage ctenv)
  (let ((address (find-variable exp ctenv)))
    (end-with-linkage
     linkage
     (if (eq? address 'not-found)
         (make-instruction-seq
          '(env) (list target)
          (list (list 'assign target '(op lookup-variable-value)
                      (list 'const exp) '(reg env))))
         (make-instruction-seq
          '(env) (list target)
          (list (list 'assign target '(op lexical-address-lookup)
                      (list 'const address) '(reg env))))))))

(check "5.5.6 局所変数は字句アドレスで引く命令になる"
       (car (statements (compile-variable-lexical 'c 'val 'next sample-ctenv)))
       '(assign val (op lexical-address-lookup) (const (1 2)) (reg env)))
(check "5.5.6 大域名は名前で引く命令のまま"
       (car (statements (compile-variable-lexical 'w 'val 'next sample-ctenv)))
       '(assign val (op lookup-variable-value) (const w) (reg env)))
(check "5.5.6 命令の数は変わらない"
       (= (length (statements (compile-variable-lexical 'c 'val 'next sample-ctenv)))
          (length (statements (compile 'c 'val 'next))))
       #t)
; 生成した命令が本当に走ることを、機械を1つ作って確かめる。
(define lexical-machine
  (make-machine
   all-regs
   (cons (list 'lexical-address-lookup lexical-address-lookup)
         compiler-operations)
   (statements (compile-variable-lexical 'e 'val 'next sample-ctenv))))
(check "5.5.6 字句アドレスの命令が機械の上で走る"
       (begin (run lexical-machine (list (list 'env sample-env)))
              (get-register-contents lexical-machine 'val))
       5)

; ============================================================
; 5.5.7 翻訳された符号と評価器をつなぐ
; ============================================================
; **翻訳された手続きと基本手続きは、呼び出し規約を共有している。**
; proc に手続き、argl に引数、continue に帰り先。だから互いを呼べる。
; 5.4 の評価器がこの規約で書かれているのは、そのためである。
(check "5.5.7 翻訳された手続きが基本手続きを呼ぶ"
       (run-compiled-seq '((define (inc x) (+ x 1)) (inc 41))) 42)
(check "5.5.7 翻訳された手続きを引数に渡せる"
       (run-compiled-seq
        '((define (twice f x) (f (f x)))
          (twice (lambda (n) (* n n)) 3)))
       81)
(check "5.5.7 翻訳された手続きを返せる"
       (run-compiled-seq
        '((define (adder n) (lambda (x) (+ x n)))
          ((adder 10) 5)))
       15)
(check "5.5.7 大域環境は式をまたいで残る"
       (run-compiled-seq '((define counter 0)
                           (define (bump) (set! counter (+ counter 1)) counter)
                           (bump) (bump) (bump)))
       3)
(check "5.5.7 同じ機械に命令を積み込み続ける"
       (> (length (statements (compile '(bump) 'val 'next))) 0) #t)

; --- 翻訳系と評価器の対比（5.5 全体の主張） ---
; 同じ式について、翻訳された符号のほうが実行する命令が少ない。
; **構文の場合分けが翻訳時に済んでいるから。**
(define (compiled-fact-insts n)
  (run-compiled-seq
   (list '(define (fact n) (if (= n 1) 1 (* n (fact (- n 1)))))
         (list 'fact n)))
  (inst-count compiled-machine))
(check "5.5 翻訳された階乗の命令数は n に正比例する"
       ; 1段あたりの命令数が一定であること = 構文の場合分けが残っていないこと。
       ; 解釈系なら段ごとに式の型を見直すので、ここは一定にならない。
       (let ((i5 (compiled-fact-insts 5))
             (i10 (compiled-fact-insts 10))
             (i15 (compiled-fact-insts 15)))
         (= (- i10 i5) (- i15 i10)))
       #t)
(check "5.5 1段あたりの命令数"
       (- (compiled-fact-insts 10) (compiled-fact-insts 9)) 47)
(check "5.5 翻訳された符号にも scheme13 と同じ2つの呼び出しがある"
       ; 末尾（continue を積まない）と非末尾（積む）の2通り
       (list (length (statements (compile-proc-appl 'val 'return)))
             (length (statements (compile-proc-appl 'val 'somelabel))))
       '(2 3))

(summary "SICP 5.5")
