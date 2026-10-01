; SICP 5.1「レジスタ機械の設計」と 5.2「レジスタ機械のシミュレータ」を
; scheme13 で確認する。
;   5.1.1 レジスタ機械を記述する言語 / 5.1.2 機械設計の抽象
;   5.1.3 サブルーチン / 5.1.4 スタックによる再帰の実現 / 5.1.5 命令のまとめ
;   5.2.1 機械のモデル / 5.2.2 アセンブラ / 5.2.3 命令の実行手続き
;   5.2.4 機械の性能を測る
;
; **この節は scheme13 の設計そのものと直接向き合う。** scheme13 は式を命令列へ
; コンパイルしてスタック機械（SECD）で走らせる。5.1〜5.2 が扱うのは同じ主題を
; もう一段下げたもので、「レジスタと分岐とスタックだけの機械」を Scheme の上に
; 作り、その上でアルゴリズムを走らせる。
;
; 処理系側で問われるのは
;   - 局所状態を持つ物（レジスタ・スタック・機械）を大量に作って繋げること
;   - `apply` に、実行時に決まる手続きと引数リストを渡せること
;     （scheme13 の `apply` は特殊形式だが、値としての手続きを受ける）
;   - 命令の実行手続きを閉包で作り、`set-cdr!` で命令に後から差し込めること
;   - **機械の実行ループが末尾呼び出しであること。** 命令を1つ実行して次へ
;     進む再帰が末尾でなければ、階乗の20万命令でスタックが尽きる
;   - 算術が bignum へ透過に伸びること（20! も 30! も同じ機械が出す）
;
; 注記: 命令の書式は 5.1.5 のもの（assign / test / branch / goto / save /
; restore / perform と、const / reg / label / op）に揃えてある。

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
; 5.1.1 レジスタ機械を記述する言語 — GCD
; ============================================================
; 本文が最初に示す機械。レジスタ2本と剰余だけで、ループは `goto` で作る。
; 「制御器は命令の列で、分岐は flag を見る」という 5.1 の骨格がここに全部ある。
(define gcd-machine
  (make-machine
   '(a b t)
   (list (list 'rem remainder) (list '= =))
   '(test-b
       (test (op =) (reg b) (const 0))
       (branch (label gcd-done))
       (assign t (op rem) (reg a) (reg b))
       (assign a (reg b))
       (assign b (reg t))
       (goto (label test-b))
     gcd-done)))

(define (machine-gcd a b)
  (run gcd-machine (list (list 'a a) (list 'b b)))
  (get-register-contents gcd-machine 'a))

(check "5.1.1 gcd 206 40" (machine-gcd 206 40) 2)
(check "5.1.1 gcd 24 36" (machine-gcd 24 36) 12)
(check "5.1.1 gcd 17 5" (machine-gcd 17 5) 1)
(check "5.1.1 gcd n 0（ループに入らない）" (machine-gcd 9 0) 9)
; bignum も同じ機械が回す。レジスタは値を選ばない。
(check "5.1.1 gcd が bignum で回る"
       (machine-gcd (* 123456789 987654321) (* 123456789 111111111))
       (* 123456789 (gcd 987654321 111111111)))

; `(assign a (reg b))` はレジスタ間の複写で、演算を通さない（5.1.5 の第1の形）。
; 上の機械が正しく回っている時点でこれは効いているが、命令数でも見ておく。
; 206/40 は 4 周回る（b が 40→6→4→2、そこで 0 になる）。1周は
; test / branch / assign t / assign a / assign b / goto の 6 命令、
; 抜けるときの test と branch で 2 命令。
(check "5.2.4 gcd 206 40 の実行命令数"
       (begin (machine-gcd 206 40) (inst-count gcd-machine))
       (+ (* 6 4) 2))
(check "5.1.1 gcd はスタックを使わない" (stack-pushes gcd-machine) 0)

; ============================================================
; 5.1.2 機械設計の抽象 — remainder を引き算で開く
; ============================================================
; `rem` を基本演算として与えず、内側のループで作る。**外側の機械の記述は
; 一字も変わらない**（`(op rem)` が消えて内側のラベルになるだけ）というのが
; この節の主張で、抽象の層を1つ剥がしても答えは同じであることを確かめる。
(define gcd-machine-open
  (make-machine
   '(a b t)
   (list (list '= =) (list '- -) (list '< <))
   '(test-b
       (test (op =) (reg b) (const 0))
       (branch (label gcd-done))
       (assign t (reg a))
     rem-loop
       (test (op <) (reg t) (reg b))
       (branch (label rem-done))
       (assign t (op -) (reg t) (reg b))
       (goto (label rem-loop))
     rem-done
       (assign a (reg b))
       (assign b (reg t))
       (goto (label test-b))
     gcd-done)))

(define (open-gcd a b)
  (run gcd-machine-open (list (list 'a a) (list 'b b)))
  (get-register-contents gcd-machine-open 'a))

(check "5.1.2 引き算で開いた gcd 206 40" (open-gcd 206 40) 2)
(check "5.1.2 引き算で開いた gcd 1071 462" (open-gcd 1071 462) 21)
(check "5.1.2 抽象を剥がしても答えは同じ"
       (map (lambda (p) (= (machine-gcd (car p) (cadr p))
                           (open-gcd (car p) (cadr p))))
            '((206 40) (24 36) (17 5) (100 75) (81 27)))
       (list #t #t #t #t #t))
; 開いたほうが命令を食う。抽象の層は「速さ」ではなく「記述」の話だという裏。
(check "5.1.2 開いた版のほうが命令数が多い"
       (begin (machine-gcd 206 40)
              (let ((closed (inst-count gcd-machine)))
                (open-gcd 206 40)
                (> (inst-count gcd-machine-open) closed)))
       #t)

; ============================================================
; 5.1.3 サブルーチン — 戻り先をレジスタに入れて `(goto (reg continue))`
; ============================================================
; gcd を1つだけ持ち、2箇所から呼ぶ。呼ぶ側が `continue` に戻り先のラベルを
; 入れてから跳び、gcd の末尾で `(goto (reg continue))` で帰る。
; **これが 5.4 の `continue` レジスタと、scheme13 の呼び出し規約の原型である。**
(define two-gcds-machine
  (make-machine
   '(a b t continue x y sum)
   (list (list 'rem remainder) (list '= =) (list '+ +))
   '((assign a (reg x))
     (assign b (reg y))
     (assign continue (label after-first))
     (goto (label gcd-sub))
   after-first
     (assign sum (reg a))
     (assign a (reg y))
     (assign b (const 91))
     (assign continue (label after-second))
     (goto (label gcd-sub))
   after-second
     (assign sum (op +) (reg sum) (reg a))
     (goto (label done))
   gcd-sub
     (test (op =) (reg b) (const 0))
     (branch (label gcd-ret))
     (assign t (op rem) (reg a) (reg b))
     (assign a (reg b))
     (assign b (reg t))
     (goto (label gcd-sub))
   gcd-ret
     (goto (reg continue))
   done)))

(define (two-gcds x y)
  (run two-gcds-machine (list (list 'x x) (list 'y y)))
  (get-register-contents two-gcds-machine 'sum))

; (gcd 206 40) = 2、(gcd 40 91) = 1
(check "5.1.3 サブルーチンを2箇所から呼ぶ" (two-gcds 206 40) 3)
(check "5.1.3 もう一組" (two-gcds 1071 462) (+ 21 (gcd 462 91)))
(check "5.1.3 サブルーチンでもスタックは要らない"
       (stack-pushes two-gcds-machine) 0)

; ============================================================
; 5.1.4 スタックによる再帰の実現
; ============================================================
; 再帰する階乗。**レジスタは1組しか無いので、呼ぶ前に自分の分を退避する。**
; `save` / `restore` が入って初めて再帰が書ける、というのがこの節の主張。
(define fact-machine
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

(define (machine-fact n)
  (run fact-machine (list (list 'n n)))
  (get-register-contents fact-machine 'val))

(check "5.1.4 再帰の階乗 1" (machine-fact 1) 1)
(check "5.1.4 再帰の階乗 5" (machine-fact 5) 120)
(check "5.1.4 再帰の階乗 10" (machine-fact 10) 3628800)
; **fixnum を溢れても機械は何も知らない。** 演算表の `*` が bignum を返すだけ。
(check "5.1.4 再帰の階乗 20（fixnum を溢れる）"
       (machine-fact 20) 2432902008176640000)
(check "5.1.4 再帰の階乗 30（bignum）"
       (machine-fact 30) 265252859812191058636308480000000)

; 演習5.14 — n! の押し込み回数と最大の深さを測る。
; 1回の再帰で continue と n を押すので 2(n-1)、深さも同じだけ積む。
(define (fact-stack-profile n)
  (machine-fact n)
  (list (stack-pushes fact-machine) (stack-max-depth fact-machine)))
(check "5.1.4/演習5.14 n=1 の統計" (fact-stack-profile 1) (list 0 0))
(check "5.1.4/演習5.14 n=2 の統計" (fact-stack-profile 2) (list 2 2))
(check "5.1.4/演習5.14 n=5 の統計" (fact-stack-profile 5) (list 8 8))
(check "5.1.4/演習5.14 深さは n に比例する"
       (map (lambda (n) (cadr (fact-stack-profile n))) '(1 2 3 4 5 6 7))
       (map (lambda (n) (* 2 (- n 1))) '(1 2 3 4 5 6 7)))

; 演習5.2 — 反復の階乗。**同じ答えを、スタックを1度も使わずに出す。**
; 5.1.4 の「再帰は場所を食う」がアルゴリズムの性質であって
; 機械の限界ではないことが、この2つの機械の対比で出る。
(define fact-iter-machine
  (make-machine
   '(n product counter)
   (list (list '> >) (list '+ +) (list '* *))
   '((assign product (const 1))
     (assign counter (const 1))
     fact-loop
       (test (op >) (reg counter) (reg n))
       (branch (label fact-done))
       (assign product (op *) (reg counter) (reg product))
       (assign counter (op +) (reg counter) (const 1))
       (goto (label fact-loop))
     fact-done)))

(define (machine-fact-iter n)
  (run fact-iter-machine (list (list 'n n)))
  (get-register-contents fact-iter-machine 'product))

(check "演習5.2 反復の階乗 5" (machine-fact-iter 5) 120)
(check "演習5.2 反復の階乗 20" (machine-fact-iter 20) 2432902008176640000)
(check "演習5.2 反復の階乗 0（ループに入らない）" (machine-fact-iter 0) 1)
(check "演習5.2 反復と再帰は同じ答え"
       (map (lambda (n) (= (machine-fact n) (machine-fact-iter n)))
            '(1 2 3 5 8 13 20))
       (list #t #t #t #t #t #t #t))
(check "演習5.2 反復はスタックを使わない"
       (begin (machine-fact-iter 30) (stack-pushes fact-iter-machine)) 0)

; フィボナッチ（5.1.4）。**再帰が2回あるので、1回目の答えを退避してから
; 2回目を呼ぶ。** save / restore の対が入れ子になる最初の例。
(define fib-machine
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

(define (machine-fib n)
  (run fib-machine (list (list 'n n)))
  (get-register-contents fib-machine 'val))

(check "5.1.4 fib 0" (machine-fib 0) 0)
(check "5.1.4 fib 1" (machine-fib 1) 1)
(check "5.1.4 fib 10" (machine-fib 10) 55)
(check "5.1.4 fib 20" (machine-fib 20) 6765)
(check "5.1.4 fib は木の再帰"
       (map machine-fib '(0 1 2 3 4 5 6 7 8 9))
       '(0 1 1 2 3 5 8 13 21 34))
; 演習5.29 の下ごしらえ。木の再帰の最大の深さは n に比例するが、
; 押し込みの総数は fib(n) に比例して増える。
(check "5.1.4 fib の深さは n に比例する"
       (map (lambda (n) (begin (machine-fib n) (stack-max-depth fib-machine)))
            '(2 3 4 5 6))
       (map (lambda (n) (* 2 (- n 1))) '(2 3 4 5 6)))
(check "5.1.4 fib の押し込みは深さより速く増える"
       (begin (machine-fib 10)
              (let ((p10 (stack-pushes fib-machine)))
                (machine-fib 15)
                (> (stack-pushes fib-machine) (* 5 p10))))
       #t)

; ============================================================
; 演習5.3 — ニュートン法の平方根
; ============================================================
; `good-enough?` と `improve` を基本演算として与えず、算術だけで開く
; （演習が要求する後半の形）。**1.1.7 と同じ手順を、同じ初期値から回すので、
; 出る数も 1.1.7 と同じでなければならない。** 実数の演算がレジスタ機械の
; 上でも1ビットもずれないことが、ここで測れる。
(define sqrt-machine
  (make-machine
   '(x guess t)
   (list (list '* *) (list '- -) (list '+ +) (list '/ /)
         (list '< <) (list 'abs abs))
   '((assign guess (const 1.0))
     sqrt-loop
       (assign t (op *) (reg guess) (reg guess))
       (assign t (op -) (reg t) (reg x))
       (assign t (op abs) (reg t))
       (test (op <) (reg t) (const 0.001))
       (branch (label sqrt-done))
       (assign t (op /) (reg x) (reg guess))
       (assign t (op +) (reg guess) (reg t))
       (assign guess (op /) (reg t) (const 2.0))
       (goto (label sqrt-loop))
     sqrt-done)))

; 同じ手順を素の Scheme でも書いておく。**機械の上の実数と、素の Scheme の
; 実数が同じ値を出すこと**が、この節で確かめたい一点である。
(define (sqrt-1-1-7 x)
  (define (good-enough? guess) (< (abs (- (* guess guess) x)) 0.001))
  (define (improve guess) (/ (+ guess (/ x guess)) 2.0))
  (define (iter guess) (if (good-enough? guess) guess (iter (improve guess))))
  (iter 1.0))

(define (machine-sqrt x)
  (run sqrt-machine (list (list 'x x)))
  (get-register-contents sqrt-machine 'guess))

; 書籍 1.1.7 が本文に印字している値をそのまま期待値にする。
(check "演習5.3 sqrt 9（書籍 1.1.7 の印字）"
       (machine-sqrt 9) 3.00009155413138)
(check "演習5.3 sqrt 2（書籍 1.1.7 の印字）"
       (machine-sqrt 2) 1.4142156862745097)
(check "演習5.3 sqrt 1（1回で抜ける）" (machine-sqrt 1) 1.0)
(check~ "演習5.3 sqrt 100" (machine-sqrt 100) 10.0 0.001)
(check "演習5.3 実数がレジスタ機械の上でもずれない"
       (= (machine-sqrt 2) (sqrt-1-1-7 2))
       #t)

; ============================================================
; 演習5.4 — べき乗（再帰と反復）
; ============================================================
(define expt-rec-machine
  (make-machine
   '(b n val continue)
   (list (list '= =) (list '- -) (list '* *))
   '((assign continue (label expt-done))
     expt-loop
       (test (op =) (reg n) (const 0))
       (branch (label base-case))
       (assign n (op -) (reg n) (const 1))
       (save continue)
       (assign continue (label after-expt))
       (goto (label expt-loop))
     after-expt
       (restore continue)
       (assign val (op *) (reg b) (reg val))
       (goto (reg continue))
     base-case
       (assign val (const 1))
       (goto (reg continue))
     expt-done)))

(define (machine-expt b n)
  (run expt-rec-machine (list (list 'b b) (list 'n n)))
  (get-register-contents expt-rec-machine 'val))

(define expt-iter-machine
  (make-machine
   '(b n counter product)
   (list (list '= =) (list '- -) (list '* *))
   '((assign counter (reg n))
     (assign product (const 1))
     expt-iter
       (test (op =) (reg counter) (const 0))
       (branch (label expt-done))
       (assign counter (op -) (reg counter) (const 1))
       (assign product (op *) (reg b) (reg product))
       (goto (label expt-iter))
     expt-done)))

(define (machine-expt-iter b n)
  (run expt-iter-machine (list (list 'b b) (list 'n n)))
  (get-register-contents expt-iter-machine 'product))

(check "演習5.4 再帰の expt 2 10" (machine-expt 2 10) 1024)
(check "演習5.4 再帰の expt b 0" (machine-expt 7 0) 1)
(check "演習5.4 反復の expt 2 10" (machine-expt-iter 2 10) 1024)
(check "演習5.4 反復の expt 3 5" (machine-expt-iter 3 5) 243)
(check "演習5.4 2^100 は bignum"
       (machine-expt-iter 2 100) (expt 2 100))
(check "演習5.4 再帰と反復は同じ答え"
       (map (lambda (n) (= (machine-expt 2 n) (machine-expt-iter 2 n)))
            '(0 1 2 5 10 20))
       (list #t #t #t #t #t #t))
; **この対比が演習5.4 の眼目。** 再帰版は n に比例して積み、反復版は積まない。
(check "演習5.4 再帰版はスタックを n だけ積む"
       (begin (machine-expt 2 10) (stack-max-depth expt-rec-machine)) 10)
(check "演習5.4 反復版は1度も積まない"
       (begin (machine-expt-iter 2 10) (stack-pushes expt-iter-machine)) 0)

; ============================================================
; 5.1.5 命令のまとめ — perform と、レジスタに入れたラベル
; ============================================================
; `perform` は値をレジスタに残さず、副作用だけを起こす。5.4 の評価器では
; 表示や環境の書き換えがこの形になる。ここでは訪れた値を外の箱に溜めて、
; 「命令が外の世界に触れられる」ことだけを見る。
(define visited '())
(define (record! x) (set! visited (cons x visited)) 'ok)

(define countdown-machine
  (make-machine
   '(n)
   (list (list '= =) (list '- -) (list 'record! record!))
   '(loop
       (test (op =) (reg n) (const 0))
       (branch (label done))
       (perform (op record!) (reg n))
       (assign n (op -) (reg n) (const 1))
       (goto (label loop))
     done)))

(check "5.1.5 perform が副作用だけを起こす"
       (begin (set! visited '())
              (run countdown-machine (list (list 'n 5)))
              (reverse visited))
       '(5 4 3 2 1))
(check "5.1.5 perform はレジスタを変えない"
       (get-register-contents countdown-machine 'n) 0)

; ============================================================
; 5.2.2 アセンブラ — ラベルは「そこから先の命令列」
; ============================================================
; アセンブルの結果を外から覗く。ラベルが命令列の残りを指すことと、
; 命令に実行手続きが差し込まれていることを直に確かめる。
(define asm-labels '())
(define asm-insts '())
(extract-labels
 '((assign a (const 1))
   here
   (assign b (const 2))
   (goto (label here)))
 (lambda (insts labels) (set! asm-insts insts) (set! asm-labels labels)))

(check "5.2.2 ラベルは命令列に入らない" (length asm-insts) 3)
(check "5.2.2 ラベルは1つ" (length asm-labels) 1)
(check "5.2.2 ラベルの名前" (car (car asm-labels)) 'here)
(check "5.2.2 ラベルは「そこから先」を指す"
       (map instruction-text (cdr (car asm-labels)))
       '((assign b (const 2)) (goto (label here))))
(check "5.2.2 アセンブル前の実行手続きは空"
       (instruction-execution-proc (car asm-insts)) '())
(check "5.2.2 アセンブル後は手続きが入る"
       (procedure? (instruction-execution-proc
                    (car (assemble '((assign a (const 1)))
                                   (make-machine '(a) '() '())))))
       #t)

; ============================================================
; 5.2.3 部分式 — const / reg / label / op
; ============================================================
; 命令の中の4つの形を、機械を1つ作って通す。`(assign r (label l))` で
; ラベルを値としてレジスタに入れ、`(goto (reg r))` でそこへ跳ぶ
; （5.1.3 の `continue` と同じ仕掛けを、明示的に測る）。
(define exp-machine
  (make-machine
   '(a b target)
   (list (list '+ +) (list 'true? (lambda (x) x)))
   '((assign a (const 41))         ; const
     (assign b (reg a))            ; reg
     (assign target (label skip))  ; label を値として入れる
     (assign a (op +) (reg a) (const 1))   ; op
     (goto (reg target))           ; レジスタ経由の goto
     (assign a (const 0))          ; ← 飛び越されるので実行されない
   skip)))

(check "5.2.3 const / reg / label / op と goto (reg)"
       (begin (run exp-machine '()) 
              (list (get-register-contents exp-machine 'a)
                    (get-register-contents exp-machine 'b)))
       (list 42 41))

; test は flag を立てるだけで、跳ぶのは branch（5.1.5 の分離）。
(define branch-machine
  (make-machine
   '(n out)
   (list (list '= =))
   '((test (op =) (reg n) (const 0))
     (branch (label zero))
     (assign out (const nonzero))
     (goto (label done))
   zero
     (assign out (const zero))
   done)))
(check "5.1.5 test と branch は分かれている"
       (list (begin (run branch-machine (list (list 'n 0)))
                    (get-register-contents branch-machine 'out))
             (begin (run branch-machine (list (list 'n 7)))
                    (get-register-contents branch-machine 'out)))
       '(zero nonzero))

; ============================================================
; 5.2.4 機械の性能を測る — 実行命令数と、命令の実況（演習5.15・5.16）
; ============================================================
(check "演習5.15 命令数は走らせるたびに数え直す"
       (begin (machine-fact-iter 5)
              (let ((a (inst-count fact-iter-machine)))
                (machine-fact-iter 5)
                (= a (inst-count fact-iter-machine))))
       #t)
(check "演習5.15 反復の階乗の命令数は n に比例する"
       (map (lambda (n) (begin (machine-fact-iter n)
                               (inst-count fact-iter-machine)))
            '(1 2 3 4))
       (map (lambda (n) (+ 4 (* 5 n))) '(1 2 3 4)))
; 演習5.16 の実況は出力を伴うので、ここでは切り替えが効くことだけ見る。
(check "演習5.16 実況の切り替え"
       (list (fib-machine 'trace-on) (fib-machine 'trace-off))
       '(done done))

; 演習5.8 — 同じラベルが2度出たら、アセンブル時に弾く。
; 「どちらへ跳ぶか決まらない」ので、走らせてから気づいては遅い。
; scheme13 には Scheme レベルの例外捕捉が無いので、**エラーになること自体の
; 主張は `dup_label_error.scm` に分けてある**（ランナーが終了状態と文面を見る）。

(summary "SICP 5.1-5.2")
