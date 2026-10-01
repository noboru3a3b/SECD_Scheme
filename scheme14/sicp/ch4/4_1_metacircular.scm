; SICP 4.1「超循環評価器」を scheme13 で確認する。
;   4.1.1 評価器の中核 / 4.1.2 式の表現 / 4.1.3 評価器のデータ構造
;   4.1.4 評価器をプログラムとして走らせる / 4.1.6 内部定義
;   4.1.7 構文解析と実行の分離
;
; **この章は処理系そのものの試験として最も重い。** Scheme で書いた Scheme を
; scheme13 の上で動かし、その中でさらにプログラムを走らせる。
;
; 処理系側で問われるのは
;   - 記号データと表（第2章）、局所状態と `set!`（第3章）を同時に、大きな
;     プログラムの中で使えること
;   - **相互再帰する eval と apply が、末尾呼び出しを保つこと。**
;     被解釈言語のループが、解釈系の再帰を通して scheme13 の末尾呼び出しに
;     落ちなければ、10000 回のループでスタックが尽きる
;   - `apply` で任意個数の引数を基本手続きに渡せること
;
; 注記: `eval` / `apply` という名前は使わない。scheme13 の `apply` は特殊形式で、
; 上書きすると足元が崩れる。書籍も同じ理由で apply-in-underlying-scheme を置く。

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

; --- 4.1.2 式の表現 ---
; 構文を判定する述語と、部品を取り出す選択子。**評価器の本体は、式が
; リストで表されていることを知らない**（データ抽象の壁）。
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
      (make-lambda (cdr (cadr exp)) (cddr exp))))   ; (define (f x) ...) の糖衣

(define (lambda? exp) (tagged-list? exp 'lambda))
(define (lambda-parameters exp) (cadr exp))
(define (lambda-body exp) (cddr exp))
(define (make-lambda parameters body) (cons 'lambda (cons parameters body)))

(define (if? exp) (tagged-list? exp 'if))
(define (if-predicate exp) (cadr exp))
(define (if-consequent exp) (caddr exp))
(define (if-alternative exp)
  (if (not (null? (cdddr exp))) (cadddr exp) 'false))
(define (make-if predicate consequent alternative)
  (list 'if predicate consequent alternative))

(define (begin? exp) (tagged-list? exp 'begin))
(define (begin-actions exp) (cdr exp))
(define (last-exp? seq) (null? (cdr seq)))
(define (first-exp seq) (car seq))
(define (rest-exps seq) (cdr seq))
(define (sequence->exp seq)
  (cond ((null? seq) seq)
        ((last-exp? seq) (first-exp seq))
        (else (cons 'begin seq))))

(define (application? exp) (pair? exp))
(define (operator exp) (car exp))
(define (operands exp) (cdr exp))
(define (no-operands? ops) (null? ops))
(define (first-operand ops) (car ops))
(define (rest-operands ops) (cdr ops))

; cond と let は**派生形式**。if と lambda に書き換えるだけで、
; 評価器の中核には手を入れない（4.1.2 の主張）。
(define (cond? exp) (tagged-list? exp 'cond))
(define (cond-clauses exp) (cdr exp))
(define (cond-else-clause? clause) (eq? (cond-predicate clause) 'else))
(define (cond-predicate clause) (car clause))
(define (cond-actions clause) (cdr clause))
(define (expand-clauses clauses)
  (if (null? clauses)
      'false
      (let ((first (car clauses)) (rest (cdr clauses)))
        (if (cond-else-clause? first)
            (if (null? rest)
                (sequence->exp (cond-actions first))
                (error "ELSE clause isn't last -- COND->IF" clauses))
            (make-if (cond-predicate first)
                     (sequence->exp (cond-actions first))
                     (expand-clauses rest))))))
(define (cond->if exp) (expand-clauses (cond-clauses exp)))

(define (let? exp) (tagged-list? exp 'let))
(define (let->combination exp)                       ; 演習 4.6
  (let ((bindings (cadr exp)) (body (cddr exp)))
    (cons (make-lambda (map car bindings) body) (map cadr bindings))))

; --- 4.1.3 評価器のデータ構造 ---
(define (true? x) (not (eq? x #f)))
(define (false? x) (eq? x #f))

(define (make-procedure parameters body env) (list 'procedure parameters body env))
(define (compound-procedure? p) (tagged-list? p 'procedure))
(define (procedure-parameters p) (cadr p))
(define (procedure-body p) (caddr p))
(define (procedure-environment p) (cadddr p))

; 環境は「フレームの並び」。フレームは (変数の並び . 値の並び) で、
; set-car! / set-cdr! で書き換える（3.3 の変更可能データがここで効く）。
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
  (cond ((= (length vars) (length vals)) (cons (make-frame vars vals) base-env))
        ((< (length vars) (length vals)) (error "Too many arguments supplied" vars vals))
        (else (error "Too few arguments supplied" vars vals))))

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

; --- 4.1.1 中核: eval と apply の輪 ---
(define (my-eval exp env)
  (cond ((self-evaluating? exp) exp)
        ((variable? exp) (lookup-variable-value exp env))
        ((quoted? exp) (text-of-quotation exp))
        ((assignment? exp) (eval-assignment exp env))
        ((definition? exp) (eval-definition exp env))
        ((if? exp) (eval-if exp env))
        ((lambda? exp)
         (make-procedure (lambda-parameters exp) (lambda-body exp) env))
        ((begin? exp) (eval-sequence (begin-actions exp) env))
        ((cond? exp) (my-eval (cond->if exp) env))
        ((let? exp) (my-eval (let->combination exp) env))
        ((application? exp)
         (my-apply (my-eval (operator exp) env)
                   (list-of-values (operands exp) env)))
        (else (error "Unknown expression type -- EVAL" exp))))

(define (my-apply procedure arguments)
  (cond ((primitive-procedure? procedure)
         (apply-primitive-procedure procedure arguments))
        ((compound-procedure? procedure)
         (eval-sequence
          (procedure-body procedure)
          (extend-environment (procedure-parameters procedure)
                              arguments
                              (procedure-environment procedure))))
        (else (error "Unknown procedure type -- APPLY" procedure))))

(define (list-of-values exps env)
  (if (no-operands? exps)
      '()
      (cons (my-eval (first-operand exps) env)
            (list-of-values (rest-operands exps) env))))
(define (eval-if exp env)
  (if (true? (my-eval (if-predicate exp) env))
      (my-eval (if-consequent exp) env)
      (my-eval (if-alternative exp) env)))
(define (eval-sequence exps env)
  (cond ((last-exp? exps) (my-eval (first-exp exps) env))
        (else (my-eval (first-exp exps) env)
              (eval-sequence (rest-exps exps) env))))
(define (eval-assignment exp env)
  (set-variable-value! (assignment-variable exp) (my-eval (assignment-value exp) env) env)
  'ok)
(define (eval-definition exp env)
  (define-variable! (definition-variable exp) (my-eval (definition-value exp) env) env)
  'ok)

; --- 4.1.4 基本手続きと大域環境 ---
(define (primitive-procedure? proc) (tagged-list? proc 'primitive))
(define (primitive-implementation proc) (cadr proc))
(define primitive-procedures
  (list (list 'car car) (list 'cdr cdr) (list 'cons cons) (list 'null? null?)
        (list 'pair? pair?) (list 'eq? eq?) (list 'equal? equal?) (list 'not not)
        (list 'list list) (list 'length length) (list 'append append)
        (list '+ +) (list '- -) (list '* *) (list '/ /)
        (list '= =) (list '< <) (list '> >) (list '<= <=) (list '>= >=)
        (list 'remainder remainder) (list 'quotient quotient) (list 'abs abs)))
(define (primitive-procedure-names) (map car primitive-procedures))
(define (primitive-procedure-objects)
  (map (lambda (proc) (list 'primitive (cadr proc))) primitive-procedures))
(define (apply-primitive-procedure proc args)
  (apply (primitive-implementation proc) args))
(define (setup-environment)
  (let ((initial-env (extend-environment (primitive-procedure-names)
                                         (primitive-procedure-objects)
                                         the-empty-environment)))
    (define-variable! 'true #t initial-env)
    (define-variable! 'false #f initial-env)
    initial-env)) 

(define genv (setup-environment))
(define (E exp) (my-eval exp genv))          ; 被解釈言語で1つ評価する

; --- ここから「被解釈言語」を動かす ---
(check "自己評価する数"     (E '42) 42)
(check "文字列"             (E '"hi") "hi")
(check "クォート"           (E '(quote (a b))) '(a b))
(check "基本手続きの呼び出し" (E '(+ 1 2 3)) 6)
(check "入れ子の呼び出し"   (E '(+ (* 2 3) (- 10 6))) 10)
(check "car / cdr"          (E '(car (quote (1 2 3)))) 1)
(check "append"             (E '(append (quote (a b c)) (quote (d e f)))) '(a b c d e f))

(check "define して使う"    (begin (E '(define x 7)) (E 'x)) 7)
(check "define は ok を返す" (E '(define y 1)) 'ok)
(check "set!"               (begin (E '(set! y 99)) (E 'y)) 99)
(check "if 真"              (E '(if (> 2 1) (quote yes) (quote no))) 'yes)
(check "if 偽"              (E '(if (< 2 1) (quote yes) (quote no))) 'no)
(check "if の別枝が無いとき" (E '(if (< 2 1) (quote yes))) #f)
(check "begin は最後の値"   (E '(begin 1 2 3)) 3)
(check "begin は順に評価する"
       (begin (E '(define acc 0))
              (E '(begin (set! acc (+ acc 1)) (set! acc (* acc 10)) acc)))
       10)

(check "lambda を作って呼ぶ" (E '((lambda (a b) (+ a b)) 3 4)) 7)
(check "手続きオブジェクトの形"
       (car (E '(lambda (x) x))) 'procedure)
(check "define の糖衣"
       (begin (E '(define (double n) (* n 2))) (E '(double 21))) 42)

(check "cond は派生形式"
       (begin (E '(define (sign n) (cond ((> n 0) (quote pos))
                                         ((< n 0) (quote neg))
                                         (else (quote zero)))))
              (list (E '(sign 5)) (E '(sign -5)) (E '(sign 0))))
       '(pos neg zero))
(check "let も派生形式" (E '(let ((a 3) (b 4)) (+ (* a a) (* b b)))) 25)
(check "let は同時束縛"
       (begin (E '(define v 5)) (E '(let ((v 3) (w v)) (+ v w)))) 8)

; 再帰。大域環境の名前を通して自分を呼ぶ
(check "階乗"
       (begin (E '(define (fact n) (if (= n 1) 1 (* n (fact (- n 1))))))
              (E '(fact 10)))
       3628800)
(check "階乗が bignum へ抜ける" (E '(fact 25)) 15511210043330985984000000)
(check "フィボナッチ（木構造再帰）"
       (begin (E '(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))
              (E '(fib 15)))
       610)

; レキシカルスコープと閉包
(check "閉包が作られた環境を覚えている"
       (begin (E '(define (make-adder n) (lambda (x) (+ x n))))
              (E '(define add5 (make-adder 5)))
              (E '(define n 1000))
              (E '(add5 10)))
       15)
(check "局所状態（3.1 の口座が被解釈言語で動く）"
       (begin (E '(define (make-account balance)
                    (define (withdraw amount)
                      (if (>= balance amount)
                          (begin (set! balance (- balance amount)) balance)
                          "Insufficient funds"))
                    (define (deposit amount) (set! balance (+ balance amount)) balance)
                    (define (dispatch m)
                      (cond ((eq? m (quote withdraw)) withdraw)
                            ((eq? m (quote deposit)) deposit)
                            (else (error "Unknown request"))))
                    dispatch))
              (E '(define acc (make-account 100)))
              (list (E '((acc (quote withdraw)) 50))
                    (E '((acc (quote deposit)) 40))
                    (E '((acc (quote withdraw)) 60))))
       '(50 90 30))
(check "口座は独立している"
       (begin (E '(define acc2 (make-account 100))) (E '((acc2 (quote withdraw)) 10)))
       90)

; --- 4.1.6 内部定義 ---
(check "内部定義が使える"
       (begin (E '(define (f x)
                    (define (helper y) (* y y))
                    (+ (helper x) 1)))
              (E '(f 4)))
       17)
(check "内部定義の相互再帰"
       (begin (E '(define (parity n)
                    (define (ev? k) (if (= k 0) true (od? (- k 1))))
                    (define (od? k) (if (= k 0) false (ev? (- k 1))))
                    (if (ev? n) (quote even) (quote odd))))
              (list (E '(parity 10)) (E '(parity 7))))
       '(even odd))

; 高階手続きを被解釈言語の中で定義する
(check "被解釈言語の中で map を書く"
       (begin (E '(define (my-map f xs)
                    (if (null? xs) (quote ()) (cons (f (car xs)) (my-map f (cdr xs))))))
              (E '(my-map (lambda (x) (* x x)) (quote (1 2 3 4)))))
       '(1 4 9 16))

; **末尾呼び出しが保たれるか。** 被解釈言語のループが解釈系の再帰を通って
; scheme13 の末尾呼び出しに落ちなければ、ここでスタックが尽きる。
(check "被解釈言語で1万回ループ"
       (begin (E '(define (loop i acc) (if (= i 0) acc (loop (- i 1) (+ acc 1)))))
              (E '(loop 10000 0)))
       10000)

; --- 4.1.7 構文解析と実行の分離 ---
; 式を1度だけ解析して「実行手続き」を作り、環境はあとから渡す。
; **これは scheme13 自身がやっていること（コンパイルしてから VM で走らせる）と
; 同じ主題である。** 違いは、生成物が命令列か閉包か、だけ。
(define analyze-count 0)                      ; 解析が何回起きたかを数える
(define (analyze exp)
  (set! analyze-count (+ analyze-count 1))
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
        ((application? exp) (analyze-application exp))
        (else (error "Unknown expression type -- ANALYZE" exp))))

(define (analyze-self-evaluating exp) (lambda (env) exp))
(define (analyze-quoted exp)
  (let ((qval (text-of-quotation exp))) (lambda (env) qval)))
(define (analyze-variable exp) (lambda (env) (lookup-variable-value exp env)))
(define (analyze-assignment exp)
  (let ((var (assignment-variable exp)) (vproc (analyze (assignment-value exp))))
    (lambda (env) (set-variable-value! var (vproc env) env) 'ok)))
(define (analyze-definition exp)
  (let ((var (definition-variable exp)) (vproc (analyze (definition-value exp))))
    (lambda (env) (define-variable! var (vproc env) env) 'ok)))
(define (analyze-if exp)
  (let ((pproc (analyze (if-predicate exp)))
        (cproc (analyze (if-consequent exp)))
        (aproc (analyze (if-alternative exp))))
    (lambda (env) (if (true? (pproc env)) (cproc env) (aproc env)))))
(define (analyze-lambda exp)
  (let ((vars (lambda-parameters exp)) (bproc (analyze-sequence (lambda-body exp))))
    (lambda (env) (make-procedure vars bproc env))))
(define (analyze-sequence exps)
  (define (sequentially proc1 proc2) (lambda (env) (proc1 env) (proc2 env)))
  (define (loop first-proc rest-procs)
    (if (null? rest-procs)
        first-proc
        (loop (sequentially first-proc (car rest-procs)) (cdr rest-procs))))
  (if (null? exps)
      (error "Empty sequence -- ANALYZE")
      (let ((procs (map analyze exps)))
        (loop (car procs) (cdr procs)))))
(define (analyze-application exp)
  (let ((fproc (analyze (operator exp))) (aprocs (map analyze (operands exp))))
    (lambda (env)
      (execute-application (fproc env) (map (lambda (aproc) (aproc env)) aprocs)))))
(define (execute-application proc args)
  (cond ((primitive-procedure? proc) (apply-primitive-procedure proc args))
        ((compound-procedure? proc)
         ((procedure-body proc)                ; 本体は既に実行手続きになっている
          (extend-environment (procedure-parameters proc) args
                              (procedure-environment proc))))
        (else (error "Unknown procedure type -- EXECUTE-APPLICATION" proc))))
(define (eval-analyzed exp env) ((analyze exp) env))

(define genv2 (setup-environment))
(define (A exp) (eval-analyzed exp genv2))

(check "解析版: 算術"     (A '(+ 1 2 3)) 6)
(check "解析版: define と再帰"
       (begin (A '(define (fact n) (if (= n 1) 1 (* n (fact (- n 1))))))
              (A '(fact 10)))
       3628800)
(check "解析版: 閉包"
       (begin (A '(define (make-adder n) (lambda (x) (+ x n))))
              (A '((make-adder 5) 10)))
       15)
(check "解析版: cond と let"
       (A '(let ((a 3)) (cond ((> a 2) (quote big)) (else (quote small))))) 'big)
(check "解析版: 1万回ループ"
       (begin (A '(define (loop i acc) (if (= i 0) acc (loop (- i 1) (+ acc 1)))))
              (A '(loop 10000 0)))
       10000)

; **解析は1度きり。** 実行のたびに構文を見直さないことが、この節の主張。
; **解析が済んだ実行手続きは、何度走らせても解析を増やさない。**
; `A` を呼び直すと、その式そのものの解析が新たに1回起きる（当たり前）。
; 見たいのは「手続きの本体が呼び出しのたびに解析され直さないこと」なので、
; 実行手続きを1度だけ作り、それを2回走らせる。
(A '(define (count-up n) (if (= n 0) 0 (+ 1 (count-up (- n 1))))))
(define exec-count-up (analyze '(count-up 50)))
(check "実行手続きは正しい値を出す" (exec-count-up genv2) 50)
(check "100回の再帰呼び出しで解析は1回も増えない"
       (let ((c0 analyze-count))
         (exec-count-up genv2)
         (exec-count-up genv2)
         (= analyze-count c0))
       #t)

; 2つの評価器が同じ答えを出すこと
(check "両者の階乗が一致"   (E '(fact 20)) (A '(fact 20)))
(check "両者のフィボナッチが一致"
       (begin (A '(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))
              (E '(fib 12)))
       (A '(fib 12)))

(summary "SICP 4.1")
