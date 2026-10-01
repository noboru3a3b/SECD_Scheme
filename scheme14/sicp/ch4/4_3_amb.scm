; SICP 4.3「Scheme の変種 — 非決定性計算」を scheme13 で確認する。
;   4.3.1 amb と探索 / 4.3.2 非決定性プログラムの例 / 4.3.3 amb 評価器の実装
;
; 4.1.7 の解析する評価器を土台に、実行手続きが**2つの継続**を取るようにする。
;   成功継続: 値と「やり直し方」を受け取る
;   失敗継続: 別の選択肢を試しに戻る
; これで深さ優先の後戻り探索になる。
;
; 処理系側で問われるのは
;   - 深く入れ子になった閉包が正しく振る舞うこと（継続を手続きで表すので、
;     探索の深さがそのまま閉包の入れ子の深さになる）
;   - `set!` の**取り消し**（後戻りするとき、代入を元に戻す）
;   - 探索の途中経過が積み上がっても壊れないこと

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
(define (summary name)
  (display "=== ") (display name)
  (display "  total: ") (display total-count)
  (display "  NG: ") (display ng-count) (display " ===") (newline))

; --- 構文（4.1 と同じ。amb が1つ増える）---
(define (tagged-list? exp tag) (and (pair? exp) (eq? (car exp) tag)))
(define (self-evaluating? exp) (or (number? exp) (string? exp) (boolean? exp)))
(define (variable? exp) (symbol? exp))
(define (quoted? exp) (tagged-list? exp 'quote))
(define (text-of-quotation exp) (cadr exp))
(define (assignment? exp) (tagged-list? exp 'set!))
(define (assignment-variable exp) (cadr exp))
(define (assignment-value exp) (caddr exp))
(define (definition? exp) (tagged-list? exp 'define))
(define (definition-variable exp) (if (symbol? (cadr exp)) (cadr exp) (car (cadr exp))))
(define (make-lambda parameters body) (cons 'lambda (cons parameters body)))
(define (definition-value exp)
  (if (symbol? (cadr exp)) (caddr exp) (make-lambda (cdr (cadr exp)) (cddr exp))))
(define (lambda? exp) (tagged-list? exp 'lambda))
(define (lambda-parameters exp) (cadr exp))
(define (lambda-body exp) (cddr exp))
(define (if? exp) (tagged-list? exp 'if))
(define (if-predicate exp) (cadr exp))
(define (if-consequent exp) (caddr exp))
(define (if-alternative exp) (if (not (null? (cdddr exp))) (cadddr exp) 'false))
(define (make-if p c a) (list 'if p c a))
(define (begin? exp) (tagged-list? exp 'begin))
(define (begin-actions exp) (cdr exp))
(define (last-exp? seq) (null? (cdr seq)))
(define (first-exp seq) (car seq))
(define (rest-exps seq) (cdr seq))
(define (sequence->exp seq)
  (cond ((null? seq) seq) ((last-exp? seq) (first-exp seq)) (else (cons 'begin seq))))
(define (application? exp) (pair? exp))
(define (operator exp) (car exp))
(define (operands exp) (cdr exp))
(define (cond? exp) (tagged-list? exp 'cond))
(define (cond-clauses exp) (cdr exp))
(define (cond-predicate clause) (car clause))
(define (cond-actions clause) (cdr clause))
(define (cond-else-clause? clause) (eq? (cond-predicate clause) 'else))
(define (expand-clauses clauses)
  (if (null? clauses)
      'false
      (let ((first (car clauses)) (rest (cdr clauses)))
        (if (cond-else-clause? first)
            (sequence->exp (cond-actions first))
            (make-if (cond-predicate first)
                     (sequence->exp (cond-actions first))
                     (expand-clauses rest))))))
(define (cond->if exp) (expand-clauses (cond-clauses exp)))
(define (let? exp) (tagged-list? exp 'let))
(define (let->combination exp)
  (let ((bindings (cadr exp)) (body (cddr exp)))
    (cons (make-lambda (map car bindings) body) (map cadr bindings))))
; **これが新しい構文**
(define (amb? exp) (tagged-list? exp 'amb))
(define (amb-choices exp) (cdr exp))

(define (true? x) (not (eq? x #f)))
(define (make-procedure parameters body env) (list 'procedure parameters body env))
(define (compound-procedure? p) (tagged-list? p 'procedure))
(define (procedure-parameters p) (cadr p))
(define (procedure-body p) (caddr p))
(define (procedure-environment p) (cadddr p))

(define (enclosing-environment env) (cdr env))
(define (first-frame env) (car env))
(define the-empty-environment '())
(define (make-frame variables values) (cons variables values))
(define (frame-variables frame) (car frame))
(define (frame-values frame) (cdr frame))
(define (add-binding-to-frame! var val frame)
  (set-car! frame (cons var (car frame)))
  (set-cdr! frame (cons val (cdr frame))))
(define (extend-environment vars vals base-env)
  (if (= (length vars) (length vals))
      (cons (make-frame vars vals) base-env)
      (error "Wrong number of arguments" vars vals)))
(define (lookup-variable-value var env)
  (define (env-loop env)
    (define (scan vars vals)
      (cond ((null? vars) (env-loop (enclosing-environment env)))
            ((eq? var (car vars)) (car vals))
            (else (scan (cdr vars) (cdr vals)))))
    (if (eq? env the-empty-environment)
        (error "Unbound variable" var)
        (scan (frame-variables (first-frame env)) (frame-values (first-frame env)))))
  (env-loop env))
(define (set-variable-value! var val env)
  (define (env-loop env)
    (define (scan vars vals)
      (cond ((null? vars) (env-loop (enclosing-environment env)))
            ((eq? var (car vars)) (set-car! vals val))
            (else (scan (cdr vars) (cdr vals)))))
    (if (eq? env the-empty-environment)
        (error "Unbound variable -- SET!" var)
        (scan (frame-variables (first-frame env)) (frame-values (first-frame env)))))
  (env-loop env))
(define (define-variable! var val env)
  (let ((frame (first-frame env)))
    (define (scan vars vals)
      (cond ((null? vars) (add-binding-to-frame! var val frame))
            ((eq? var (car vars)) (set-car! vals val))
            (else (scan (cdr vars) (cdr vals)))))
    (scan (frame-variables frame) (frame-values frame))))

; --- 4.3.3 amb 評価器 ---
; 実行手続きは (env 成功継続 失敗継続) を取る。
; 成功継続は (値 やり直し方) を受け取り、失敗継続は引数なしで呼ばれる。
(define (analyze exp)
  (cond ((self-evaluating? exp) (analyze-self-evaluating exp))
        ((quoted? exp) (analyze-quoted exp))
        ((variable? exp) (analyze-variable exp))
        ((assignment? exp) (analyze-assignment exp))
        ((definition? exp) (analyze-definition exp))
        ((if? exp) (analyze-if exp))
        ((lambda? exp) (analyze-lambda exp))
        ((begin? exp) (analyze-sequence (begin-actions exp)))
        ((cond? exp) (analyze (cond->if exp)))
        ((let? exp) (analyze (let->combination exp)))
        ((amb? exp) (analyze-amb exp))
        ((application? exp) (analyze-application exp))
        (else (error "Unknown expression type -- ANALYZE" exp))))

(define (analyze-self-evaluating exp) (lambda (env succeed fail) (succeed exp fail)))
(define (analyze-quoted exp)
  (let ((qval (text-of-quotation exp))) (lambda (env succeed fail) (succeed qval fail))))
(define (analyze-variable exp)
  (lambda (env succeed fail) (succeed (lookup-variable-value exp env) fail)))
(define (analyze-lambda exp)
  (let ((vars (lambda-parameters exp)) (bproc (analyze-sequence (lambda-body exp))))
    (lambda (env succeed fail) (succeed (make-procedure vars bproc env) fail))))

(define (analyze-if exp)
  (let ((pproc (analyze (if-predicate exp)))
        (cproc (analyze (if-consequent exp)))
        (aproc (analyze (if-alternative exp))))
    (lambda (env succeed fail)
      (pproc env
             (lambda (pred-value fail2)
               (if (true? pred-value)
                   (cproc env succeed fail2)
                   (aproc env succeed fail2)))
             fail))))

(define (analyze-sequence exps)
  (define (sequentially a b)
    (lambda (env succeed fail)
      (a env (lambda (a-value fail2) (b env succeed fail2)) fail)))
  (define (loop first-proc rest-procs)
    (if (null? rest-procs)
        first-proc
        (loop (sequentially first-proc (car rest-procs)) (cdr rest-procs))))
  (if (null? exps)
      (error "Empty sequence -- ANALYZE")
      (let ((procs (map analyze exps))) (loop (car procs) (cdr procs)))))

(define (analyze-definition exp)
  (let ((var (definition-variable exp)) (vproc (analyze (definition-value exp))))
    (lambda (env succeed fail)
      (vproc env
             (lambda (val fail2) (define-variable! var val env) (succeed 'ok fail2))
             fail))))

; **代入は後戻りするとき元に戻す。** これが無いと、失敗して別の枝へ行った後も
; 書き換えが残り、答えが汚れる（4.3.3 の眼目）。
(define (analyze-assignment exp)
  (let ((var (assignment-variable exp)) (vproc (analyze (assignment-value exp))))
    (lambda (env succeed fail)
      (vproc env
             (lambda (val fail2)
               (let ((old-value (lookup-variable-value var env)))
                 (set-variable-value! var val env)
                 (succeed 'ok
                          (lambda ()          ; 後戻りするときに呼ばれる
                            (set-variable-value! var old-value env)
                            (fail2)))))
             fail))))

(define (analyze-application exp)
  (let ((fproc (analyze (operator exp))) (aprocs (map analyze (operands exp))))
    (lambda (env succeed fail)
      (fproc env
             (lambda (proc fail2)
               (get-args aprocs env
                         (lambda (args fail3) (execute-application proc args succeed fail3))
                         fail2))
             fail))))
(define (get-args aprocs env succeed fail)
  (if (null? aprocs)
      (succeed '() fail)
      ((car aprocs) env
       (lambda (arg fail2)
         (get-args (cdr aprocs) env
                   (lambda (args fail3) (succeed (cons arg args) fail3))
                   fail2))
       fail)))
(define (primitive-procedure? proc) (tagged-list? proc 'primitive))
(define (primitive-implementation proc) (cadr proc))
(define (execute-application proc args succeed fail)
  (cond ((primitive-procedure? proc)
         (succeed (apply (primitive-implementation proc) args) fail))
        ((compound-procedure? proc)
         ((procedure-body proc)
          (extend-environment (procedure-parameters proc) args
                              (procedure-environment proc))
          succeed fail))
        (else (error "Unknown procedure type -- EXECUTE-APPLICATION" proc))))

; amb 本体。選択肢を順に試し、失敗したら次へ
(define (analyze-amb exp)
  (let ((cprocs (map analyze (amb-choices exp))))
    (lambda (env succeed fail)
      (define (try-next choices)
        (if (null? choices)
            (fail)
            ((car choices) env succeed (lambda () (try-next (cdr choices))))))
      (try-next cprocs))))

(define primitive-procedures
  (list (list 'car car) (list 'cdr cdr) (list 'cons cons) (list 'null? null?)
        (list 'pair? pair?) (list 'eq? eq?) (list 'equal? equal?) (list 'not not)
        (list 'list list) (list 'length length) (list 'append append)
        (list 'member member) (list 'abs abs)
        (list '+ +) (list '- -) (list '* *) (list '=  =) (list '< <) (list '> >)
        (list '<= <=) (list '>= >=) (list 'remainder remainder)))
(define (setup-environment)
  (let ((env (extend-environment (map car primitive-procedures)
                                 (map (lambda (p) (list 'primitive (cadr p)))
                                      primitive-procedures)
                                 the-empty-environment)))
    (define-variable! 'true #t env)
    (define-variable! 'false #f env)
    env))
(define genv (setup-environment))

; 解を1つ取る / 全部取る。書籍の try-again をプログラムから使う形にした
(define (amb-first exp)
  (call/cc (lambda (return)
             ((analyze exp) genv
              (lambda (val fail) (return val))
              (lambda () (return 'no-solution))))))
(define (amb-all exp limit)
  (let ((found '()) (count 0))
    (call/cc
     (lambda (return)
       ((analyze exp) genv
        (lambda (val fail)
          (set! found (cons val found))
          (set! count (+ count 1))
          (if (>= count limit) (return 'limit) (fail)))     ; 次の解へ後戻りする
        (lambda () (return 'exhausted)))))
    (reverse found)))
(define (D exp) (amb-first exp))                 ; 定義を流し込む用

; --- 4.3.1 amb と探索 ---
(check "amb は最初の選択肢を返す" (D '(amb 1 2 3)) 1)
(check "選択肢が尽きたら失敗"     (D '(amb)) 'no-solution)
(check "後戻りで全部拾える"       (amb-all '(amb 1 2 3) 10) '(1 2 3))
(check "入れ子の amb は深さ優先"
       (amb-all '(list (amb 1 2) (amb (quote a) (quote b))) 10)
       '((1 a) (1 b) (2 a) (2 b)))

(D '(define (require p) (if (not p) (amb) false)))
(check "require が枝を刈る"
       (amb-all '(let ((x (amb 1 2 3 4 5))) (require (> x 3)) x) 10) '(4 5))

(D '(define (an-element-of items)
      (require (not (null? items)))
      (amb (car items) (an-element-of (cdr items)))))
(check "an-element-of"     (amb-all '(an-element-of (quote (a b c))) 10) '(a b c))
(check "空リストからは何も出ない" (D '(an-element-of (quote ()))) 'no-solution)

(D '(define (an-integer-between low high)
      (require (<= low high))
      (amb low (an-integer-between (+ low 1) high))))
(check "範囲の整数" (amb-all '(an-integer-between 1 5) 10) '(1 2 3 4 5))

; --- 4.3.2 非決定性プログラムの例 ---
; ピタゴラス数
(D '(define (a-pythagorean-triple-between low high)
      (let ((i (an-integer-between low high)))
        (let ((j (an-integer-between i high)))
          (let ((k (an-integer-between j high))) 
            (require (= (+ (* i i) (* j j)) (* k k)))
            (list i j k))))))
(check "最小のピタゴラス数"  (D '(a-pythagorean-triple-between 1 20)) '(3 4 5))
(check "20以下のピタゴラス数をすべて"
       (amb-all '(a-pythagorean-triple-between 1 20) 20)
       '((3 4 5) (5 12 13) (6 8 10) (8 15 17) (9 12 15) (12 16 20)))

; 素数の和になる対（書籍の例）
(D '(define (prime? n)
      (define (iter d)
        (cond ((> (* d d) n) true) ((= 0 (remainder n d)) false) (else (iter (+ d 1)))))
      (if (< n 2) false (iter 2))))
(D '(define (prime-sum-pair list1 list2)
      (let ((a (an-element-of list1)) (b (an-element-of list2)))
        (require (prime? (+ a b)))
        (list a b))))
(check "和が素数になる対"
       (amb-all '(prime-sum-pair (quote (1 3 5 8)) (quote (20 35 110))) 10)
       '((3 20) (3 110) (8 35)))

; 論理パズル: 5人と5階（書籍の multiple dwelling）
; **要求を早く置くほど枝が刈られる**（演習 4.40）。ここでは各人を選んだ直後に
; 分かる条件を置き、最後に「全員別の階」を確かめる。
(D '(define (distinct? items)
      (cond ((null? items) true)
            ((null? (cdr items)) true)
            ((member (car items) (cdr items)) false)
            (else (distinct? (cdr items))))))
(D '(define (multiple-dwelling)
      (let ((baker (amb 1 2 3 4)))                    ; baker は5階でない
        (let ((cooper (amb 2 3 4 5)))                 ; cooper は1階でない
          (let ((fletcher (amb 2 3 4)))               ; fletcher は1階でも5階でもない
            (require (not (= (abs (- fletcher cooper)) 1)))
            (let ((miller (amb 1 2 3 4 5)))
              (require (> miller cooper))
              (let ((smith (amb 1 2 3 4 5)))
                (require (not (= (abs (- smith fletcher)) 1)))
                (require (distinct? (list baker cooper fletcher miller smith)))
                (list (list (quote baker) baker) (list (quote cooper) cooper)
                      (list (quote fletcher) fletcher) (list (quote miller) miller)
                      (list (quote smith) smith)))))))))
(check "5人と5階のパズル"
       (D '(multiple-dwelling))
       '((baker 3) (cooper 2) (fletcher 4) (miller 5) (smith 1)))
(check "解は1つだけ" (length (amb-all '(multiple-dwelling) 5)) 1)

; --- 後戻りで代入が取り消されること ---
(D '(define trace (quote ())))
(D '(define (note x) (set! trace (cons x trace)) x))
; 1回目は失敗し、2回目で成功する。失敗した枝の set! は取り消されている
(check "後戻りすると set! が元に戻る"
       (begin (D '(let ((x (amb 1 2))) (set! trace (cons x trace)) (require (= x 2)) x))
              (D 'trace))
       '(2))

(summary "SICP 4.3")
