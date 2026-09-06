; SICP 3.3「変更可能データによるモデル化」を scheme13 で確認する。
;   3.3.1 変更可能なリスト構造 / 3.3.2 キューの表現 / 3.3.3 表の表現
;   （3.3.4 論理回路と 3.3.5 制約の伝播は 3_3_simulator.scm に分けた）
;
; 処理系側で問われるのは
;   - `set-car!` / `set-cdr!` が対そのものを書き換えること
;   - **共有**が観察できること（同じ対を2箇所から指すと、変更が両方に見える）
;   - 環を作れること、そして環を作った後も処理系が壊れないこと
;
; 注記: 環を持つ構造を `write` / `display` / `equal?` に渡すと止まらない。
; ここでは `eq?` と辿る回数だけで確かめる。

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

; --- 3.3.1 変更可能なリスト構造 ---
(define a1 (list 'a 'b 'c))
(check "set-car!" (begin (set-car! a1 'x) a1) '(x b c))
(check "set-cdr!" (begin (set-cdr! (cdr a1) '(z)) a1) '(x b z))
; 返り値は R5RS では未規定。scheme13 は**格納した値**を返す（原典から継いだ形）。
; 書籍のコードは返り値を使わないので、どちらでも題材は動く。
(check "set-car! は格納した値を返す" (set-car! (list 1) 2) 2)
(check "set-cdr! も同じ"             (set-cdr! (list 1) '(2)) '(2))

; 共有。同じ対を2箇所から指すと、片方の変更がもう片方に見える
(define shared (list 'a 'b))
(define z1 (cons shared shared))
(check "共有の前"   z1 '((a b) a b))
(set-car! (car z1) 'wow)
(check "片方を変えると両方見える" z1 '((wow b) wow b))
(check "car と cdr は同じ対"      (eq? (car z1) (cdr z1)) #t)

; 別々に作れば共有されない
(define z2 (cons (list 'a 'b) (list 'a 'b)))
(set-car! (car z2) 'wow)
(check "共有していなければ片方だけ" z2 '((wow b) a b))
(check "見た目が同じでも別の対"     (eq? (car z2) (cdr z2)) #f)
(check "equal? は中身を見る"        (equal? (list 'a 'b) (list 'a 'b)) #t)
(check "eq? は同一性を見る"         (eq? (list 'a 'b) (list 'a 'b)) #f)

; 演習 3.12: append と append! の違い
(define (my-last-pair x) (if (null? (cdr x)) x (my-last-pair (cdr x))))
(define (append! x y) (set-cdr! (my-last-pair x) y) x)
(define ax (list 'a 'b))
(define ay (list 'c 'd))
(define appended (append ax ay))
(check "append は元を壊さない"     ax '(a b))
(check "append の結果"             appended '(a b c d))
(define bx (list 'a 'b))
(define by (list 'c 'd))
(define appended! (append! bx by))
(check "append! の結果"            appended! '(a b c d))
(check "append! は元を壊す"        bx '(a b c d))
(check "append! は同じ対を返す"    (eq? appended! bx) #t)
(check "後ろのリストは共有される"  (eq? (cddr bx) by) #t)

; 演習 3.14: cdr を付け替えて反転する（元のリストは先頭1個になる）
(define (mystery x)
  (define (loop x y)
    (if (null? x)
        y
        (let ((temp (cdr x)))
          (set-cdr! x y)
          (loop temp x))))
  (loop x '()))
(define v (list 'a 'b 'c 'd))
(define w (mystery v))
(check "破壊的な反転"       w '(d c b a))
(check "元の変数は先頭だけ" v '(a))

; 演習 3.16〜3.18: 対の数え上げと、環の検出
(define (count-pairs-naive x)
  (if (not (pair? x))
      0
      (+ (count-pairs-naive (car x)) (count-pairs-naive (cdr x)) 1)))
(define three (list 'a 'b 'c))
(check "共有が無ければ3"     (count-pairs-naive three) 3)
(define shared3 (let ((p (list 'a))) (cons p (cons p '()))))
(check "共有があると数えすぎる" (count-pairs-naive shared3) 4)  ; 実際の対は3個

; 正しく数える版（見た対を覚える）
(define (count-pairs x)
  (let ((seen '()))
    (define (walk x)
      (if (or (not (pair? x)) (memq x seen))
          0
          (begin (set! seen (cons x seen))
                 (+ (walk (car x)) (walk (cdr x)) 1))))
    (walk x)))
(check "覚えておけば正しく3" (count-pairs shared3) 3)
(check "共有が無い場合も3"   (count-pairs three) 3)

; 環を作る。**ここから先は write / equal? に渡してはいけない**
(define (make-cycle x) (set-cdr! (my-last-pair x) x) x)
(define cyc (make-cycle (list 'a 'b 'c)))
(check "環は3周目で戻る" (eq? (cdddr cyc) cyc) #t)
(check "環の要素を辿れる" (car (cdr (cdr (cdr cyc)))) 'a)
(check "環でも数えられる" (count-pairs cyc) 3)

; 演習 3.18: 環かどうかを判定する（Floyd の2ポインタ）
(define (has-cycle? x)
  (define (loop slow fast)
    (cond ((or (not (pair? fast)) (not (pair? (cdr fast)))) #f)
          ((eq? slow (cdr fast)) #t)
          ((eq? (cdr slow) (cdr (cdr fast))) #t)
          (else (loop (cdr slow) (cdr (cdr fast))))))
  (if (pair? x) (loop x x) #f))
(check "環を見つける"       (has-cycle? cyc) #t)
(check "環でないものは偽"   (has-cycle? (list 1 2 3 4 5)) #f)
(check "空リストは偽"       (has-cycle? '()) #f)
(check "共有だけなら偽"     (has-cycle? shared3) #f)

; --- 3.3.2 キューの表現 ---
; 先頭と末尾の両方を持つことで、追加も削除も定数時間になる
(define (front-ptr queue) (car queue))
(define (rear-ptr queue) (cdr queue))
(define (set-front-ptr! queue item) (set-car! queue item))
(define (set-rear-ptr! queue item) (set-cdr! queue item))
(define (empty-queue? queue) (null? (front-ptr queue)))
(define (make-queue) (cons '() '()))
(define (front-queue queue)
  (if (empty-queue? queue)
      (error "FRONT called with an empty queue" queue)
      (car (front-ptr queue))))
(define (insert-queue! queue item)
  (let ((new-pair (cons item '())))
    (cond ((empty-queue? queue)
           (set-front-ptr! queue new-pair)
           (set-rear-ptr! queue new-pair)
           queue)
          (else
           (set-cdr! (rear-ptr queue) new-pair)
           (set-rear-ptr! queue new-pair)
           queue))))
(define (delete-queue! queue)
  (cond ((empty-queue? queue) (error "DELETE! called with an empty queue" queue))
        (else (set-front-ptr! queue (cdr (front-ptr queue)))
              queue)))
(define (queue->list queue) (front-ptr queue))

(define q1 (make-queue))
(check "作った直後は空"     (empty-queue? q1) #t)
(insert-queue! q1 'a)
(check "1つ入れた"          (queue->list q1) '(a))
(insert-queue! q1 'b)
(check "2つ目は後ろに付く"  (queue->list q1) '(a b))
(check "先頭を見る"         (front-queue q1) 'a)
(delete-queue! q1)
(check "先頭を取り除く"     (queue->list q1) '(b))
(delete-queue! q1)
(check "空に戻る"           (empty-queue? q1) #t)
(check "空にしてから入れ直せる"
       (begin (insert-queue! q1 'c) (queue->list q1)) '(c))
; 末尾ポインタが正しく動いていること（ここを間違えるとキューが壊れる）
(check "末尾は最後の対を指す" (eq? (rear-ptr q1) (my-last-pair (front-ptr q1))) #t)
(define q2 (make-queue))
(for-each (lambda (i) (insert-queue! q2 i)) '(1 2 3 4 5))
(check "順番どおりに出てくる"
       (let loop ((acc '()))
         (if (empty-queue? q2)
             (reverse acc)
             (let ((x (front-queue q2))) (delete-queue! q2) (loop (cons x acc)))))
       '(1 2 3 4 5))

; --- 3.3.3 表の表現 ---
; 1次元の表。先頭にダミーの対を置くのは、空の表にも insert! できるようにするため
(define (make-table) (list '*table*))
(define (lookup key table)
  (let ((record (assoc key (cdr table))))
    (if record (cdr record) #f)))
(define (insert! key value table)
  (let ((record (assoc key (cdr table))))
    (if record
        (set-cdr! record value)
        (set-cdr! table (cons (cons key value) (cdr table)))))
  'ok)

(define t1 (make-table))
(check "無い鍵は #f"       (lookup 'a t1) #f)
(check "入れる"            (insert! 'a 1 t1) 'ok)
(check "引ける"            (lookup 'a t1) 1)
(check "上書きできる"      (begin (insert! 'a 2 t1) (lookup 'a t1)) 2)
(check "別の鍵も入る"      (begin (insert! 'b 3 t1) (lookup 'b t1)) 3)
(check "上書きで増えない"  (length (cdr t1)) 2)
(check "文字列の鍵も引ける（assoc は equal?）"
       (begin (insert! "s" 9 t1) (lookup "s" t1)) 9)

; 2次元の表。表の中に表を入れる
(define (make-table2) (list '*table*))
(define (lookup2 key-1 key-2 table)
  (let ((subtable (assoc key-1 (cdr table))))
    (if subtable
        (let ((record (assoc key-2 (cdr subtable))))
          (if record (cdr record) #f))
        #f)))
(define (insert2! key-1 key-2 value table)
  (let ((subtable (assoc key-1 (cdr table))))
    (if subtable
        (let ((record (assoc key-2 (cdr subtable))))
          (if record
              (set-cdr! record value)
              (set-cdr! subtable (cons (cons key-2 value) (cdr subtable)))))
        (set-cdr! table (cons (list key-1 (cons key-2 value)) (cdr table)))))
  'ok)

(define t2 (make-table2))
(insert2! 'math '+ 43 t2)
(insert2! 'math '- 45 t2)
(insert2! 'letters 'a 97 t2)
(check "2次元 引ける"          (lookup2 'math '+ t2) 43)
(check "2次元 別の第2鍵"       (lookup2 'math '- t2) 45)
(check "2次元 別の第1鍵"       (lookup2 'letters 'a t2) 97)
(check "無い組は #f"           (lookup2 'math '* t2) #f)
(check "無い第1鍵も #f"        (lookup2 'nope 'a t2) #f)
(check "2次元 上書き"          (begin (insert2! 'math '+ 99 t2) (lookup2 'math '+ t2)) 99)

; 表を局所状態として閉じ込める（3.3.3 の「メッセージパッシング流」）
(define (make-object-table)
  (let ((local-table (list '*table*)))
    (define (lookup- key)
      (let ((record (assoc key (cdr local-table))))
        (if record (cdr record) #f)))
    (define (insert-! key value)
      (let ((record (assoc key (cdr local-table))))
        (if record
            (set-cdr! record value)
            (set-cdr! local-table (cons (cons key value) (cdr local-table)))))
      'ok)
    (lambda (m)
      (cond ((eq? m 'lookup) lookup-)
            ((eq? m 'insert!) insert-!)
            (else (error "Unknown operation -- TABLE" m))))))
(define ot (make-object-table))
((ot 'insert!) 'k 42)
(check "閉じ込めた表"       ((ot 'lookup) 'k) 42)
(define ot2 (make-object-table))
(check "別の表は独立"       ((ot2 'lookup) 'k) #f)

(summary "SICP 3.3（1〜3）")
