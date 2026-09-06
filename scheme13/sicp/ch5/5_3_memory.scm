; SICP 5.3「記憶の割り当てとごみ集め」を scheme13 で確認する。
;   5.3.1 ベクタとしての記憶 / 5.3.2 無限の記憶という錯覚を保つ
;
; **この節は scheme13 の足元を、scheme13 の上で作り直す。** scheme13 の対は
; Boehm GC が管理する C++ のオブジェクトだが、5.3 が言うのは「対とは2本の
; ベクタの同じ番地であり、ポインタとは番号である」。その模型を Scheme で
; 組み、その上でごみ集めをレジスタ機械として走らせる。
;
; 処理系側で問われるのは
;   - ベクタ（`make-vector` / `vector-ref` / `vector-set!`）が使えること
;   - 5.1〜5.2 のシミュレータが、**ベクタを持つレジスタ**でも同じに動くこと
;   - 相互に絡んだ制御（relocate を2箇所から呼び、`relocate-continue` で帰る）
;     が正しく回ること。これは 5.1.3 のサブルーチンの本気の使用例である
;
; 注記: 本書はポインタの型をビット列で表すが、ここでは `(型 . 値)` の対にする。
; 番地の計算は同じで、型を見る述語が `car` を見るだけになる。
; また `(op vector-ref) (reg the-cars) (op pointer-datum) (reg old)` のような
; 演算の入れ子は 5.1.5 の書式で書けないので、**ポインタを受けて番地を取り出す
; `heap-ref` / `heap-set!` を演算表に置いた**（本書がレジスタを1本足すのと同じ手）。
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
; 5.3.1 ベクタとしての記憶
; ============================================================
; 記憶は2本のベクタ `the-cars` と `the-cdrs`。対は「両方の同じ番地」であり、
; 対へのポインタは**番地そのもの**である。数や記号は番地を持たず、
; ポインタの中に値を直に入れる（本書の「型つきポインタ」）。

(define (make-pointer type datum) (cons type datum))
(define (pointer-type p) (car p))
(define (pointer-datum p) (cdr p))
(define (pair-pointer? p) (eq? (car p) 'p))
(define (broken-heart? p) (eq? (car p) 'bh))
(define the-empty-pointer (make-pointer 'e 0))
(define (num->pointer n) (make-pointer 'n n))
(define (pointer->num p) (cdr p))

; ポインタを受けて番地を引く。演算の入れ子を避けるための1段。
(define (heap-ref vec ptr) (vector-ref vec (pointer-datum ptr)))
(define (heap-set! vec ptr val) (vector-set! vec (pointer-datum ptr) val))

; --- cons をレジスタ機械として書く ---
; **`free` を1つ進めるだけが割り当てである。** 空き番地を探しもしなければ
; 誰も返しもしない。5.3.2 のごみ集めは、この「進めるだけ」を成立させ続ける
; ための仕掛けとして出てくる。
(define cons-machine
  (make-machine
   '(the-cars the-cdrs free carval cdrval result)
   (list (list 'vector-set! vector-set!)
         (list 'make-pair-pointer (lambda (i) (make-pointer 'p i)))
         (list '+ +))
   '((perform (op vector-set!) (reg the-cars) (reg free) (reg carval))
     (perform (op vector-set!) (reg the-cdrs) (reg free) (reg cdrval))
     (assign result (op make-pair-pointer) (reg free))
     (assign free (op +) (reg free) (const 1)))))

; 記憶そのものは Scheme 側で持ち、機械へ渡しては受け取る。
(define the-cars '())
(define the-cdrs '())
(define new-cars '())
(define new-cdrs '())
(define free 0)
(define (reset-memory! size)
  (set! the-cars (make-vector size the-empty-pointer))
  (set! the-cdrs (make-vector size the-empty-pointer))
  (set! new-cars (make-vector size the-empty-pointer))
  (set! new-cdrs (make-vector size the-empty-pointer))
  (set! free 0)
  'done)

(define (mem-cons car-ptr cdr-ptr)
  (run cons-machine (list (list 'the-cars the-cars) (list 'the-cdrs the-cdrs)
                          (list 'free free)
                          (list 'carval car-ptr) (list 'cdrval cdr-ptr)))
  (set! free (get-register-contents cons-machine 'free))
  (get-register-contents cons-machine 'result))

(define (mem-car ptr) (heap-ref the-cars ptr))
(define (mem-cdr ptr) (heap-ref the-cdrs ptr))
(define (mem-set-car! ptr v) (heap-set! the-cars ptr v))
(define (mem-set-cdr! ptr v) (heap-set! the-cdrs ptr v))

; 記憶の中の構造を、素の Scheme の値に読み戻す道具。
; **これが無いと「壊れていないこと」を主張できない。**
(define (fetch ptr)
  (cond ((eq? (pointer-type ptr) 'e) '())
        ((eq? (pointer-type ptr) 'n) (pointer->num ptr))
        ((eq? (pointer-type ptr) 'sym) (pointer-datum ptr))
        ((pair-pointer? ptr) (cons (fetch (mem-car ptr)) (fetch (mem-cdr ptr))))
        (else (list '? ptr))))

; 素の Scheme のリストを記憶に積む。
(define (store! x)
  (cond ((null? x) the-empty-pointer)
        ((number? x) (num->pointer x))
        ((symbol? x) (make-pointer 'sym x))
        ((pair? x) (let ((a (store! (car x))))    ; car を先に積む
                     (mem-cons a (store! (cdr x)))))
        (else (error "store!: unsupported" x))))

(reset-memory! 60)
(define p12 (mem-cons (num->pointer 1) (num->pointer 2)))
(check "5.3.1 cons が対を1つ作る" (fetch p12) '(1 . 2))
(check "5.3.1 ポインタは番地である" p12 (make-pointer 'p 0))
(check "5.3.1 割り当ては free を1つ進めるだけ" free 1)
(check "5.3.1 car は the-cars の vector-ref" (fetch (mem-car p12)) 1)
(check "5.3.1 cdr は the-cdrs の vector-ref" (fetch (mem-cdr p12)) 2)
(check "5.3.1 the-cars に直に入っている"
       (vector-ref the-cars 0) (num->pointer 1))

(define lst (store! '(1 2 3)))
(check "5.3.1 リストは対の鎖" (fetch lst) '(1 2 3))
(check "5.3.1 リスト3個で番地を3つ使う" free 4)
(check "5.3.1 set-car! は vector-set!"
       (begin (mem-set-car! lst (num->pointer 99)) (fetch lst))
       '(99 2 3))
(check "5.3.1 set-cdr! も同じ"
       (begin (mem-set-cdr! lst the-empty-pointer) (fetch lst))
       '(99))
; **共有は「同じ番地を指すこと」でしかない。** 対を2箇所から指せば、
; 片方を書き換えたことがもう片方から見える。
(define shared (mem-cons (num->pointer 5) (num->pointer 6)))
(define two (mem-cons shared (mem-cons shared the-empty-pointer)))
(check "5.3.1 共有は同じ番地" (equal? (mem-car two) (mem-car (mem-cdr two))) #t)
(check "5.3.1 共有された対" (fetch two) '((5 . 6) (5 . 6)))
(check "5.3.1 片方を書けば両方から見える"
       (begin (mem-set-car! shared (num->pointer 50)) (fetch two))
       '((50 . 6) (50 . 6)))

; 5.3.1 の終わり — スタックも記憶の中の鎖にできる。
; push は cons、pop は cdr を辿るだけ。**別の機構ではない。**
(define the-stack the-empty-pointer)
(define (mem-push! ptr) (set! the-stack (mem-cons ptr the-stack)))
(define (mem-pop!)
  (let ((top (mem-car the-stack)))
    (set! the-stack (mem-cdr the-stack))
    top))
(mem-push! (num->pointer 10))
(mem-push! (num->pointer 20))
(check "5.3.1 記憶の中のスタック（後入れ先出し）"
       (list (fetch (mem-pop!)) (fetch (mem-pop!))) '(20 10))
(check "5.3.1 スタックが空に戻る" the-stack the-empty-pointer)

; ============================================================
; 5.3.2 停止＆複写のごみ集め
; ============================================================
; 記憶を2つに割り、片方が埋まったら**届く物だけ**をもう片方へ写して役割を
; 入れ替える。写した跡地には「壊れた心臓」を置き、行き先を cdr に残す。
; 2度目に同じ対へ来たら、跡地を見て新しい番地を教える。
; **これで共有も環も壊れずに写る。**
;
; scan は「写したが、中身をまだ直していない」対の先頭。free は次の空き。
; この2つが出会えば、届く物は全部写り終わっている。

(define gc-machine
  (make-machine
   '(the-cars the-cdrs new-cars new-cdrs
     root free scan old new oldcr temp relocate-continue)
   (list (list 'vector-ref vector-ref) (list 'vector-set! vector-set!)
         (list 'heap-ref heap-ref) (list 'heap-set! heap-set!)
         (list 'pair-pointer? pair-pointer?)
         (list 'broken-heart? broken-heart?)
         (list 'make-pair-pointer (lambda (i) (make-pointer 'p i)))
         (list '= =) (list '+ +))
   '(begin-garbage-collection
       (assign free (const 0))
       (assign scan (const 0))
       (assign old (reg root))
       (assign relocate-continue (label reassign-root))
       (goto (label relocate-old-result-in-new))
     reassign-root
       (assign root (reg new))
       (goto (label gc-loop))

     gc-loop
       (test (op =) (reg scan) (reg free))
       (branch (label gc-flip))
       (assign old (op vector-ref) (reg new-cars) (reg scan))
       (assign relocate-continue (label update-car))
       (goto (label relocate-old-result-in-new))
     update-car
       (perform (op vector-set!) (reg new-cars) (reg scan) (reg new))
       (assign old (op vector-ref) (reg new-cdrs) (reg scan))
       (assign relocate-continue (label update-cdr))
       (goto (label relocate-old-result-in-new))
     update-cdr
       (perform (op vector-set!) (reg new-cdrs) (reg scan) (reg new))
       (assign scan (op +) (reg scan) (const 1))
       (goto (label gc-loop))

     ;; old のポインタを新しい記憶へ写し、その行き先を new に置いて帰る。
     ;; **2箇所から呼ばれるので、帰り先は relocate-continue に入っている**
     ;; （5.1.3 のサブルーチンそのもの）。
     relocate-old-result-in-new
       (test (op pair-pointer?) (reg old))
       (branch (label relocate-pair))
       (assign new (reg old))            ; 数や記号は写す先を持たない
       (goto (reg relocate-continue))
     relocate-pair
       (assign oldcr (op heap-ref) (reg the-cars) (reg old))
       (test (op broken-heart?) (reg oldcr))
       (branch (label already-moved))
       (assign new (op make-pair-pointer) (reg free))
       (perform (op vector-set!) (reg new-cars) (reg free) (reg oldcr))
       (assign temp (op heap-ref) (reg the-cdrs) (reg old))
       (perform (op vector-set!) (reg new-cdrs) (reg free) (reg temp))
       (perform (op heap-set!) (reg the-cars) (reg old) (const (bh . 0)))
       (perform (op heap-set!) (reg the-cdrs) (reg old) (reg new))
       (assign free (op +) (reg free) (const 1))
       (goto (reg relocate-continue))
     already-moved
       (assign new (op heap-ref) (reg the-cdrs) (reg old))
       (goto (reg relocate-continue))

     ;; 役割の入れ替え。ここから先、新しい記憶が「働く記憶」になる。
     gc-flip
       (assign temp (reg the-cars))
       (assign the-cars (reg new-cars))
       (assign new-cars (reg temp))
       (assign temp (reg the-cdrs))
       (assign the-cdrs (reg new-cdrs))
       (assign new-cdrs (reg temp)))))

(define (collect-garbage! root-ptr)
  (run gc-machine (list (list 'the-cars the-cars) (list 'the-cdrs the-cdrs)
                        (list 'new-cars new-cars) (list 'new-cdrs new-cdrs)
                        (list 'root root-ptr)))
  (set! the-cars (get-register-contents gc-machine 'the-cars))
  (set! the-cdrs (get-register-contents gc-machine 'the-cdrs))
  (set! new-cars (get-register-contents gc-machine 'new-cars))
  (set! new-cdrs (get-register-contents gc-machine 'new-cdrs))
  (set! free (get-register-contents gc-machine 'free))
  (get-register-contents gc-machine 'root))

; --- 演習5.20 の形 — x = (cons 1 2)、y = (list x x) ---
(reset-memory! 60)
(define x (mem-cons (num->pointer 1) (num->pointer 2)))
(define y (mem-cons x (mem-cons x the-empty-pointer)))
(check "演習5.20 x と y" (list (fetch x) (fetch y)) '((1 . 2) ((1 . 2) (1 . 2))))
(check "演習5.20 番地を3つ使う" free 3)
(check "演習5.20 x は最初の番地" x (make-pointer 'p 0))
(check "演習5.20 y の2つの car は同じ番地"
       (equal? (mem-car y) (mem-car (mem-cdr y))) #t)

; 誰からも届かない対を作ってから集める。
(mem-cons (num->pointer 77) (num->pointer 88))
(mem-cons (num->pointer 99) the-empty-pointer)
(check "5.3.2 ごみを作ると free が伸びる" free 5)
(define y2 (collect-garbage! y))
(check "5.3.2 集めても届く物は壊れない" (fetch y2) '((1 . 2) (1 . 2)))
(check "5.3.2 ごみの分だけ free が戻る" free 3)
(check "5.3.2 共有は共有のまま写る"
       (equal? (mem-car y2) (mem-car (mem-cdr y2))) #t)
(check "5.3.2 写した先も1つの対"
       (begin (mem-set-car! (mem-car y2) (num->pointer 7)) (fetch y2))
       '((7 . 2) (7 . 2)))

; もう一度集めても、同じだけしか使わない（写し終えたら安定する）。
(define y3 (collect-garbage! y2))
(check "5.3.2 2度目の集め（べき等）" (fetch y3) '((7 . 2) (7 . 2)))
(check "5.3.2 2度目でも free は同じ" free 3)

; --- 環を写す ---
; **停止＆複写が「壊れた心臓」を置く理由がここに出る。** 印を残さなければ、
; 環を辿って永久に写し続ける。
(reset-memory! 60)
(define ring (mem-cons (num->pointer 1) the-empty-pointer))
(mem-set-cdr! ring ring)
(check "5.3.2 環を作る" (equal? (mem-cdr ring) ring) #t)
(define ring2 (collect-garbage! ring))
(check "5.3.2 環が環のまま写る" (equal? (mem-cdr ring2) ring2) #t)
(check "5.3.2 環の中身も無事" (fetch (mem-car ring2)) 1)
(check "5.3.2 環は対1つ" free 1)

; --- 深い構造とスタックを、根の下に束ねて集める ---
; 根は1本しか無いので、生かしたい物は根の下へ繋いでおく（本書と同じ扱い）。
(reset-memory! 200)
(define deep (store! '(1 (2 (3 (4 (5)))) 6)))
(define stk (store! '(a b c)))
(define garbage (store! '(x y z)))
(define used-before free)
(define root (mem-cons deep (mem-cons stk the-empty-pointer)))
(define root2 (collect-garbage! root))
(check "5.3.2 入れ子の構造がそのまま生き残る"
       (fetch (mem-car root2)) '(1 (2 (3 (4 (5)))) 6))
(check "5.3.2 スタックも生き残る" (fetch (mem-car (mem-cdr root2))) '(a b c))
(check "5.3.2 根から届かない物は消える" (< free used-before) #t)
(check "5.3.2 生き残った対の数"
       free (+ 10 3 2))         ; deep が10対、stk が3対、根の2対

; ごみ集めのあと、続けて割り当てられる（記憶が本当に空いている）。
(define after (mem-cons (num->pointer 1) (num->pointer 2)))
(check "5.3.2 集めた後も cons が続く" (fetch after) '(1 . 2))
(check "5.3.2 新しい対は free の位置に来る" after (make-pointer 'p 15))

; ごみ集めは 5.1.3 のサブルーチンを本気で使う。relocate は3箇所から呼ばれ、
; 帰り先はレジスタに入っている。それが正しく回った証拠として、命令数を見ておく。
(check "5.3.2 ごみ集めが有限の命令数で終わる"
       (and (> (inst-count gc-machine) 0) (< (inst-count gc-machine) 10000))
       #t)
(check "5.3.2 ごみ集めはスタックを使わない（帰り先はレジスタ）"
       (stack-pushes gc-machine) 0)

(summary "SICP 5.3")
