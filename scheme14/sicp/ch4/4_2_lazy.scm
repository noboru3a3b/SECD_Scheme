; SICP 4.2「Scheme の変種 — 遅延評価」を scheme13 で確認する。
;   4.2.1 正規順序と適用順序 / 4.2.2 遅延評価の解釈系 / 4.2.3 遅延リスト
;
; 4.1 の評価器を、**引数を呼ばれるまで評価しない**ように作り替える。
; 引数は thunk（式と環境の組）に包み、必要になった時に force する。
;
; 処理系側で問われるのは
;   - thunk を作って表に溜め、後で書き換える（記憶化）こと。3.3 の
;     `set-car!` / `set-cdr!` がここでも土台になる
;   - **「評価しなかった」ことを主張できること**。`(try 0 (/ 1 0))` が
;     0除算を踏まずに 1 を返すのが、この節の要である

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
(define (check~ label expr expected eps)
  (set! total-count (+ total-count 1))
  (if (< (abs (- expr expected)) eps)
      (begin (display "ok   ") (display label) (newline))
      (begin (set! ng-count (+ ng-count 1))
             (display "NG   ") (display label)
             (display "  got=") (write expr)
             (display " want=") (write expected) (newline))))
(define (summary name)
  (display "=== ") (display name)
  (display "  total: ") (display total-count)
  (display "  NG: ") (display ng-count) (display " ===") (newline))

; --- 構文（4.1 と同じ。この節で変わるのは eval / apply だけ）---
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
(define (no-operands? ops) (null? ops))
(define (first-operand ops) (car ops))
(define (rest-operands ops) (cdr ops))
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

; --- 4.2.2 thunk と force ---
; thunk は「式と環境」。force したら**中身を値で置き換える**（記憶化）。
; 置き換えに set-car! / set-cdr! を使うので、3.3 の変更可能データがここで要る。
(define force-count 0)                 ; force が何回「実際に計算した」か
(define (delay-it exp env) (list 'thunk exp env))
(define (thunk? obj) (tagged-list? obj 'thunk))
(define (thunk-exp thunk) (cadr thunk))
(define (thunk-env thunk) (caddr thunk))
(define (evaluated-thunk? obj) (tagged-list? obj 'evaluated-thunk))
(define (thunk-value evaluated-thunk) (cadr evaluated-thunk))
(define (force-it obj)
  (cond ((thunk? obj)
         (let ((result (actual-value (thunk-exp obj) (thunk-env obj))))
           (set! force-count (+ force-count 1))
           (set-car! obj 'evaluated-thunk)
           (set-car! (cdr obj) result)
           (set-cdr! (cdr obj) '())          ; 環境への参照を捨てる
           result))
        ((evaluated-thunk? obj) (thunk-value obj))
        (else obj)))
(define (actual-value exp env) (force-it (lazy-eval exp env)))

(define (lazy-eval exp env)
  (cond ((self-evaluating? exp) exp)
        ((variable? exp) (lookup-variable-value exp env))
        ((quoted? exp) (text-of-quotation exp))
        ((assignment? exp)
         (set-variable-value! (assignment-variable exp)
                              (lazy-eval (assignment-value exp) env) env) 'ok)
        ((definition? exp)
         (define-variable! (definition-variable exp)
                           (lazy-eval (definition-value exp) env) env) 'ok)
        ((if? exp)
         ; **述語だけは必ず force する。** ここを遅らせると分岐できない
         (if (true? (actual-value (if-predicate exp) env))
             (lazy-eval (if-consequent exp) env)
             (lazy-eval (if-alternative exp) env)))
        ((lambda? exp) (make-procedure (lambda-parameters exp) (lambda-body exp) env))
        ((begin? exp) (lazy-eval-sequence (begin-actions exp) env))
        ((cond? exp) (lazy-eval (cond->if exp) env))
        ((let? exp) (lazy-eval (let->combination exp) env))
        ((application? exp)
         ; 演算子は force する（手続きでなければ呼べない）。引数は包むだけ
         (lazy-apply (actual-value (operator exp) env) (operands exp) env))
        (else (error "Unknown expression type -- LAZY-EVAL" exp))))

(define (lazy-eval-sequence exps env)
  (cond ((last-exp? exps) (lazy-eval (first-exp exps) env))
        (else (actual-value (first-exp exps) env)   ; 副作用のために force する
              (lazy-eval-sequence (rest-exps exps) env))))

(define (list-of-arg-values exps env)             ; 基本手続き用: すべて force
  (if (no-operands? exps)
      '()
      (cons (actual-value (first-operand exps) env)
            (list-of-arg-values (rest-operands exps) env))))
(define (list-of-delayed-args exps env)           ; 合成手続き用: 包むだけ
  (if (no-operands? exps)
      '()
      (cons (delay-it (first-operand exps) env)
            (list-of-delayed-args (rest-operands exps) env))))

(define (primitive-procedure? proc) (tagged-list? proc 'primitive))
(define (primitive-implementation proc) (cadr proc))
(define (lazy-apply procedure arguments env)
  (cond ((primitive-procedure? procedure)
         (apply (primitive-implementation procedure)
                (list-of-arg-values arguments env)))
        ((compound-procedure? procedure)
         (lazy-eval-sequence
          (procedure-body procedure)
          (extend-environment (procedure-parameters procedure)
                              (list-of-delayed-args arguments env)
                              (procedure-environment procedure))))
        (else (error "Unknown procedure type -- LAZY-APPLY" procedure))))

(define primitive-procedures
  (list (list 'car car) (list 'cdr cdr) (list 'cons cons) (list 'null? null?)
        (list 'pair? pair?) (list 'eq? eq?) (list 'not not) (list 'list list)
        (list '+ +) (list '- -) (list '* *) (list '/ /)
        (list '= =) (list '< <) (list '> >) (list '<= <=) (list '>= >=)
        (list 'remainder remainder)))
(define (setup-environment)
  (let ((env (extend-environment (map car primitive-procedures)
                                 (map (lambda (p) (list 'primitive (cadr p)))
                                      primitive-procedures)
                                 the-empty-environment)))
    (define-variable! 'true #t env)
    (define-variable! 'false #f env)
    env))
(define genv (setup-environment))
(define (L exp) (actual-value exp genv))

; --- 4.2.1 正規順序と適用順序 ---
; 適用順序なら (/ 1 0) が先に評価されて落ちる。遅延評価なら踏まない。
(L '(define (try a b) (if (= a 0) 1 b)))
(check "使わない引数は評価されない" (L '(try 0 (/ 1 0))) 1)
(check "使う引数はちゃんと評価される" (L '(try 1 42)) 42)

; unless を**手続きとして**書ける（適用順序では書けない。演習 4.26）
(L '(define (unless condition usual-value exceptional-value)
      (if condition exceptional-value usual-value)))
(check "unless が手続きとして働く"
       (L '(unless (= 0 0) (/ 1 0) (quote safe))) 'safe)
(check "unless の逆の枝"
       (L '(unless (= 0 1) (quote used) (/ 1 0))) 'used)

; 基本手続きは正格。引数は必ず force される
(check "基本手続きは引数を force する" (L '(+ (* 2 3) (- 10 6))) 10)
(check "合成手続きは force しない"
       (begin (L '(define (first-only a b) a)) (L '(first-only 7 (/ 1 0)))) 7)

; --- 記憶化: 同じ thunk は1度しか計算しない ---
(L '(define counter 0))
(L '(define (bump) (set! counter (+ counter 1)) counter))
(L '(define (use-twice x) (+ x x)))
(check "同じ引数を2回使っても計算は1度" (L '(use-twice (bump))) 2)
(check "実際に増えたのは1回だけ"        (L 'counter) 1)
(L '(define (use-four x) (+ (+ x x) (+ x x))))
(check "4回使っても1度"                 (L '(use-four (bump))) 8)
(check "増えたのは合わせて2回"          (L 'counter) 2)

; --- 4.2.3 遅延リスト ---
; cons / car / cdr を**手続きとして**定義できる。特殊形式は要らない。
; 遅延評価では、cons の引数がそのまま遅れるので、これで無限リストが書ける。
(L '(define (cons x y) (lambda (m) (m x y))))
(L '(define (car z) (z (lambda (p q) p))))
(L '(define (cdr z) (z (lambda (p q) q))))
(check "手続きで作った対"     (L '(car (cons 1 2))) 1)
(check "その cdr"             (L '(cdr (cons 1 2))) 2)

(L '(define (list-ref items n)
      (if (= n 0) (car items) (list-ref (cdr items) (- n 1)))))
(L '(define (my-map f items)
      (if (null? items) (quote ()) (cons (f (car items)) (my-map f (cdr items))))))
(L '(define (add-lists a b)
      (cond ((null? a) b)
            ((null? b) a)
            (else (cons (+ (car a) (car b)) (add-lists (cdr a) (cdr b)))))))

; 無限リスト。**特殊形式なしで書ける**のがこの節の要点
(L '(define ones (cons 1 ones)))
(L '(define integers (cons 1 (add-lists ones integers))))
(check "無限リストの 0番目"   (L '(car integers)) 1)
(check "無限リストの 17番目"  (L '(list-ref integers 17)) 18)   ; 書籍の値
(check "map も無限リストに効く"
       (L '(list-ref (my-map (lambda (x) (* x x)) integers) 9)) 100)

; 無限リストの先頭 n 個を、解釈系の外に取り出す
(define (take-lazy exp n)
  (let loop ((i 0) (acc '()))
    (if (= i n)
        (reverse acc)
        (loop (+ i 1) (cons (L (list 'list-ref exp i)) acc)))))
(check "整数列の先頭6個" (take-lazy 'integers 6) '(1 2 3 4 5 6))

; 微分方程式を解く（3.5.4 と同じ題材。遅延評価なら delay を書かなくてよい）
(L '(define (scale-list items factor)
      (my-map (lambda (x) (* x factor)) items)))
(L '(define (integral integrand initial-value dt)
      (define int
        (cons initial-value (add-lists (scale-list integrand dt) int)))
      int))
(L '(define (solve f y0 dt)
      (define y (integral dy y0 dt))
      (define dy (my-map f y))
      y))
(check~ "dy/dt = y を解いて e に近づく"
        (L '(list-ref (solve (lambda (x) x) 1.0 0.01) 100))
        2.718281828459045 0.02)

(summary "SICP 4.2")
