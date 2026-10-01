; SICP 2.2「階層データと閉包性」を scheme13 で確認する。
;   2.2.1 並びの表現 / 2.2.2 階層構造 / 2.2.3 公認インターフェースとしての並び
;   2.2.4 例: 図形言語（座標とフレームの代数の部分だけ）
;
; 処理系側で問われるのは
;   - cons が閉じていること（対の中に対を入れられる＝木が作れる）
;   - 高階手続きと再帰の組み合わせが深さで壊れないこと
;   - `map` が2引数しか取らないこと（後述）が、書籍の題材のどこに響くか

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

(define (square x) (* x x))

; --- 2.2.1 並びの表現 ---
(define one-through-four (list 1 2 3 4))
(check "list が作る対の連なり" one-through-four '(1 2 3 4))
(check "car"        (car one-through-four) 1)
(check "cdr"        (cdr one-through-four) '(2 3 4))
(check "cons で伸ばす" (cons 10 one-through-four) '(10 1 2 3 4))

(define (my-list-ref items n)
  (if (= n 0) (car items) (my-list-ref (cdr items) (- n 1))))
(define (my-length items)
  (if (null? items) 0 (+ 1 (my-length (cdr items)))))
(define (length-iter items)
  (define (loop a count) (if (null? a) count (loop (cdr a) (+ count 1))))
  (loop items 0))
(define (my-append list1 list2)
  (if (null? list1) list2 (cons (car list1) (my-append (cdr list1) list2))))

(define squares (list 1 4 9 16 25))
(define odds (list 1 3 5 7))
(check "list-ref 3"      (my-list-ref squares 3) 16)
(check "length"          (my-length odds) 4)
(check "length 反復版"   (length-iter odds) 4)
(check "組み込みと一致"  (my-length squares) (length squares))
(check "append"          (my-append squares odds) '(1 4 9 16 25 1 3 5 7))
(check "組み込み append" (append squares odds) (my-append squares odds))

; 演習 2.17〜2.18
(define (last-pair items)
  (if (null? (cdr items)) items (last-pair (cdr items))))
(define (my-reverse items)
  (define (loop rest acc) (if (null? rest) acc (loop (cdr rest) (cons (car rest) acc))))
  (loop items '()))
(check "last-pair"  (last-pair (list 23 72 149 34)) '(34))
(check "reverse"    (my-reverse (list 1 4 9 16 25)) '(25 16 9 4 1))
(check "組み込み reverse と一致" (my-reverse squares) (reverse squares))

; 演習 2.20: 可変長引数
(define (same-parity first . rest)
  (define (keep items)
    (cond ((null? items) '())
          ((= (remainder (- (car items) first) 2) 0) (cons (car items) (keep (cdr items))))
          (else (keep (cdr items)))))
  (cons first (keep rest)))
(check "same-parity 奇数" (same-parity 1 2 3 4 5 6 7) '(1 3 5 7))
(check "same-parity 偶数" (same-parity 2 3 4 5 6 7) '(2 4 6))

(define (my-map proc items)
  (if (null? items) '() (cons (proc (car items)) (my-map proc (cdr items)))))
(define (scale-list items factor) (my-map (lambda (x) (* x factor)) items))
(check "map で 10倍" (scale-list (list 1 2 3 4 5) 10) '(10 20 30 40 50))
(check "組み込み map" (map (lambda (x) (* x x)) '(1 2 3)) '(1 4 9))
; 書籍が本文で示す例。正確な整数と非正確な実数が同じリストに混ざる。
(check "map abs 混合リスト" (map abs (list -10 2.5 -11.6 17)) '(10 2.5 11.6 17))

; **`map` が複数リストを取れないことが、ここで見つかった不足だった**
; （23日目の決定117・119）。いまは R5RS どおり何本でも取り、最短で止まる。
(check "map は2本のリストを取る"  (map + '(1 2 3) '(10 20 30)) '(11 22 33))
(check "map は3本でも取る"        (map * '(1 2) '(3 4) '(5 6)) '(15 48))
(check "map は最短のリストで止まる" (map + '(1 2 3) '(10 20)) '(11 22))
(check "map-2 も残っている"        (map-2 + '(1 2 3) '(10 20 30)) '(11 22 33))

; for-each は副作用のため。順序どおりに呼ばれることを見る
(define acc '())
(for-each (lambda (x) (set! acc (cons x acc))) '(1 2 3))
(check "for-each は左から右へ" acc '(3 2 1))

; --- 2.2.2 階層構造: 木 ---
(define x (cons (list 1 2) (list 3 4)))
(check "入れ子のリスト"  x '((1 2) 3 4))
(check "length は3"      (length x) 3)

(define (count-leaves t)
  (cond ((null? t) 0)
        ((not (pair? t)) 1)
        (else (+ (count-leaves (car t)) (count-leaves (cdr t))))))
(check "count-leaves"        (count-leaves x) 4)
(check "count-leaves 二重"   (count-leaves (list x x)) 8)
(check "深い木"              (count-leaves '(1 (2 (3 (4 (5)))))) 5)

(define (scale-tree tree factor)
  (cond ((null? tree) '())
        ((not (pair? tree)) (* tree factor))
        (else (cons (scale-tree (car tree) factor) (scale-tree (cdr tree) factor)))))
(check "scale-tree"
       (scale-tree (list 1 (list 2 (list 3 4) 5) (list 6 7)) 10)
       '(10 (20 (30 40) 50) (60 70)))
(define (tree-map proc tree)
  (my-map (lambda (sub) (if (pair? sub) (tree-map proc sub) (proc sub))) tree))
(check "tree-map で二乗"
       (tree-map square (list 1 (list 2 (list 3 4)) 5))
       '(1 (4 (9 16)) 25))

; 演習 2.27 / 2.28
(define (deep-reverse t)
  (if (pair? t) (reverse (my-map deep-reverse t)) t))
(check "deep-reverse" (deep-reverse '((1 2) (3 4))) '((4 3) (2 1)))
(define (fringe t)
  (cond ((null? t) '())
        ((not (pair? t)) (list t))
        (else (append (fringe (car t)) (fringe (cdr t))))))
(check "fringe" (fringe '((1 2) (3 4))) '(1 2 3 4))
(check "fringe 二重" (fringe (list '((1 2) (3 4)) '((1 2) (3 4)))) '(1 2 3 4 1 2 3 4))

; 演習 2.32: 部分集合
(define (subsets s)
  (if (null? s)
      (list '())
      (let ((rest (subsets (cdr s))))
        (append rest (my-map (lambda (set) (cons (car s) set)) rest)))))
(check "部分集合の個数" (length (subsets '(1 2 3))) 8)
(check "部分集合に空が含まれる" (if (member '() (subsets '(1 2 3))) #t #f) #t)
(check "部分集合に全体が含まれる" (if (member '(1 2 3) (subsets '(1 2 3))) #t #f) #t)

; --- 2.2.3 公認インターフェースとしての並び ---
(define (my-filter predicate seq)
  (cond ((null? seq) '())
        ((predicate (car seq)) (cons (car seq) (my-filter predicate (cdr seq))))
        (else (my-filter predicate (cdr seq)))))
(define (accumulate op initial seq)
  (if (null? seq) initial (op (car seq) (accumulate op initial (cdr seq)))))
(define (enumerate-interval low high)
  (if (> low high) '() (cons low (enumerate-interval (+ low 1) high))))
(define (enumerate-tree tree)
  (cond ((null? tree) '())
        ((not (pair? tree)) (list tree))
        (else (append (enumerate-tree (car tree)) (enumerate-tree (cdr tree))))))

(check "filter"            (my-filter odd? (list 1 2 3 4 5)) '(1 3 5))
(check "組み込み filter"   (filter odd? (list 1 2 3 4 5)) '(1 3 5))
(check "accumulate +"      (accumulate + 0 (list 1 2 3 4 5)) 15)
(check "accumulate *"      (accumulate * 1 (list 1 2 3 4 5)) 120)
(check "accumulate cons"   (accumulate cons '() (list 1 2 3 4 5)) '(1 2 3 4 5))
(check "enumerate-interval" (enumerate-interval 2 7) '(2 3 4 5 6 7))
(check "enumerate-tree"    (enumerate-tree (list 1 (list 2 (list 3 4)) 5)) '(1 2 3 4 5))

(define (fib n)
  (define (iter a b count) (if (= count 0) b (iter (+ a b) a (- count 1))))
  (iter 1 0 n))
(define (sum-odd-squares tree)
  (accumulate + 0 (my-map square (my-filter odd? (enumerate-tree tree)))))
(define (even-fibs n)
  (accumulate cons '() (my-filter even? (my-map fib (enumerate-interval 0 n)))))
(define (list-fib-squares n)
  (accumulate cons '() (my-map square (my-map fib (enumerate-interval 0 n)))))

(check "sum-odd-squares"  (sum-odd-squares (list 1 (list 2 (list 3 4)) 5)) 35)
(check "even-fibs 10"     (even-fibs 10) '(0 2 8 34))
(check "list-fib-squares 10" (list-fib-squares 10) '(0 1 1 4 9 25 64 169 441 1156 3025))

; 演習 2.33〜2.35
(define (map-via-accumulate p seq)
  (accumulate (lambda (a b) (cons (p a) b)) '() seq))
(define (append-via-accumulate seq1 seq2) (accumulate cons seq2 seq1))
(define (length-via-accumulate seq) (accumulate (lambda (a b) (+ 1 b)) 0 seq))
(check "accumulate で map"    (map-via-accumulate square '(1 2 3)) '(1 4 9))
(check "accumulate で append" (append-via-accumulate '(1 2) '(3 4)) '(1 2 3 4))
(check "accumulate で length" (length-via-accumulate '(a b c)) 3)

(define (horner-eval x coefficient-sequence)      ; 演習 2.34
  (accumulate (lambda (this-coeff higher-terms) (+ this-coeff (* x higher-terms)))
              0 coefficient-sequence))
(check "ホーナー法 1+3x+5x^3+x^5, x=2" (horner-eval 2 (list 1 3 0 5 0 1)) 79)

(define (count-leaves-acc t)                      ; 演習 2.35
  (accumulate + 0 (my-map (lambda (node) (if (pair? node) (count-leaves-acc node) 1)) t)))
(check "accumulate で count-leaves" (count-leaves-acc x) 4)

(define (accumulate-n op init seqs)               ; 演習 2.36
  (if (null? (car seqs))
      '()
      (cons (accumulate op init (my-map car seqs))
            (accumulate-n op init (my-map cdr seqs)))))
(check "accumulate-n" (accumulate-n + 0 '((1 2 3) (4 5 6) (7 8 9) (10 11 12))) '(22 26 30))

; 演習 2.37: 行列演算
(define (dot-product v w) (accumulate + 0 (map-2 * v w)))
(define (matrix-*-vector m v) (my-map (lambda (row) (dot-product row v)) m))
(define (transpose mat) (accumulate-n cons '() mat))
(define (matrix-*-matrix m n)
  (let ((cols (transpose n)))
    (my-map (lambda (row) (matrix-*-vector cols row)) m)))
(define mat '((1 2 3) (4 5 6)))
(check "内積"           (dot-product '(1 2 3) '(4 5 6)) 32)
(check "行列×ベクトル"  (matrix-*-vector mat '(1 1 1)) '(6 15))
(check "転置"           (transpose mat) '((1 4) (2 5) (3 6)))
(check "行列×行列"      (matrix-*-matrix mat (transpose mat)) '((14 32) (32 77)))

; 演習 2.38〜2.39: fold-left と fold-right の違い
; 書籍は (fold-right / 1 (list 1 2 3)) が 3/2、(fold-left / 1 (list 1 2 3)) が 1/6
; になると言う。**有理数が要る例なので、実数で書く。** 整数のままだと
; scheme13 の `/` は0方向に切り捨てるので (/ 2 3) が 0 になり、次で0除算になる。
(check "fold-right で /（実数）" (fold-right / 1.0 '(1.0 2.0 3.0)) 1.5)
(check "fold-left で /（実数）"  (fold-left / 1.0 '(1.0 2.0 3.0)) 0.16666666666666666)
(check "fold-right cons"  (fold-right cons '() '(1 2 3)) '(1 2 3))
(check "fold-left は結合の向きが逆"
       (fold-left (lambda (x y) (cons y x)) '() '(1 2 3)) '(3 2 1))
(check "fold-left で和"   (fold-left + 0 '(1 2 3 4)) 10)

; 入れ子のマッピング
(define (flatmap proc seq) (accumulate append '() (my-map proc seq)))
(define (prime? n)
  (define (find-divisor d) (cond ((> (square d) n) n) ((= 0 (remainder n d)) d)
                                 (else (find-divisor (+ d 1)))))
  (and (> n 1) (= n (find-divisor 2))))
(define (prime-sum? pair) (prime? (+ (car pair) (cadr pair))))
(define (make-pair-sum pair) (list (car pair) (cadr pair) (+ (car pair) (cadr pair))))
(define (prime-sum-pairs n)
  (my-map make-pair-sum
          (my-filter prime-sum?
                     (flatmap (lambda (i)
                                (my-map (lambda (j) (list i j))
                                        (enumerate-interval 1 (- i 1))))
                              (enumerate-interval 1 n)))))
(check "prime-sum-pairs 6"
       (prime-sum-pairs 6)
       '((2 1 3) (3 2 5) (4 1 5) (4 3 7) (5 2 7) (6 1 7) (6 5 11)))

(define (remove item seq) (my-filter (lambda (x) (not (= x item))) seq))
(define (permutations s)
  (if (null? s)
      (list '())
      (flatmap (lambda (item)
                 (my-map (lambda (perm) (cons item perm)) (permutations (remove item s))))
               s)))
(check "順列の個数 4!"  (length (permutations '(1 2 3 4))) 24)
(check "順列 (1 2 3)"   (permutations '(1 2 3))
       '((1 2 3) (1 3 2) (2 1 3) (2 3 1) (3 1 2) (3 2 1)))

; 演習 2.42: 8クイーン
(define empty-board '())
(define (adjoin-position row col rest) (cons (list row col) rest))
(define (safe? k positions)
  (let ((new (car positions)) (rest (cdr positions)))
    (define (ok? p)
      (and (not (= (car p) (car new)))
           (not (= (abs (- (car p) (car new))) (abs (- (cadr p) (cadr new)))))))
    (define (all ps) (cond ((null? ps) #t) ((ok? (car ps)) (all (cdr ps))) (else #f)))
    (all rest)))
(define (queens board-size)
  (define (queen-cols k)
    (if (= k 0)
        (list empty-board)
        (my-filter
         (lambda (positions) (safe? k positions))
         (flatmap (lambda (rest-of-queens)
                    (my-map (lambda (new-row) (adjoin-position new-row k rest-of-queens))
                            (enumerate-interval 1 board-size)))
                  (queen-cols (- k 1))))))
  (queen-cols board-size))
(check "4クイーンの解は2通り" (length (queens 4)) 2)
(check "6クイーンの解は4通り" (length (queens 6)) 4)
(check "8クイーンの解は92通り" (length (queens 8)) 92)

; --- 2.2.4 図形言語: 座標とフレームの代数 ---
; 描画そのものは処理系の外の話なので、ベクトルとフレームの計算だけを見る。
(define (make-vect x y) (cons x y))
(define (xcor-vect v) (car v))
(define (ycor-vect v) (cdr v))
(define (add-vect a b) (make-vect (+ (xcor-vect a) (xcor-vect b))
                                  (+ (ycor-vect a) (ycor-vect b))))
(define (sub-vect a b) (make-vect (- (xcor-vect a) (xcor-vect b))
                                  (- (ycor-vect a) (ycor-vect b))))
(define (scale-vect s v) (make-vect (* s (xcor-vect v)) (* s (ycor-vect v))))
(check "ベクトルの和"   (add-vect (make-vect 1 2) (make-vect 3 4)) (make-vect 4 6))
(check "ベクトルの差"   (sub-vect (make-vect 3 4) (make-vect 1 2)) (make-vect 2 2))
(check "スカラー倍"     (scale-vect 2 (make-vect 1.5 2.5)) (make-vect 3.0 5.0))

(define (make-frame origin edge1 edge2) (list origin edge1 edge2))
(define (origin-frame f) (car f))
(define (edge1-frame f) (cadr f))
(define (edge2-frame f) (caddr f))
(define (frame-coord-map frame)
  (lambda (v)
    (add-vect (origin-frame frame)
              (add-vect (scale-vect (xcor-vect v) (edge1-frame frame))
                        (scale-vect (ycor-vect v) (edge2-frame frame))))))
(define unit-frame (make-frame (make-vect 0.0 0.0) (make-vect 1.0 0.0) (make-vect 0.0 1.0)))
(define half-frame (make-frame (make-vect 0.0 0.0) (make-vect 0.5 0.0) (make-vect 0.0 1.0)))
(check "単位フレームは恒等"   ((frame-coord-map unit-frame) (make-vect 0.5 0.5))
                              (make-vect 0.5 0.5))
(check "原点は原点へ"         ((frame-coord-map half-frame) (make-vect 0.0 0.0))
                              (make-vect 0.0 0.0))
(check "横半分に潰れる"       ((frame-coord-map half-frame) (make-vect 1.0 1.0))
                              (make-vect 0.5 1.0))

; painter を「線分の並びを返す手続き」として実装すれば、beside/flip も数で確かめられる
(define (make-segment s e) (cons s e))
(define (start-segment s) (car s))
(define (end-segment s) (cdr s))
(define (segments->painter segs)
  (lambda (frame)
    (let ((m (frame-coord-map frame)))
      (my-map (lambda (s) (make-segment (m (start-segment s)) (m (end-segment s)))) segs))))
(define diag (segments->painter
              (list (make-segment (make-vect 0.0 0.0) (make-vect 1.0 1.0)))))
(check "painter は単位枠でそのまま"
       (diag unit-frame)
       (list (make-segment (make-vect 0.0 0.0) (make-vect 1.0 1.0))))
(check "painter は半分の枠で潰れる"
       (diag half-frame)
       (list (make-segment (make-vect 0.0 0.0) (make-vect 0.5 1.0))))

(define (transform-painter painter origin corner1 corner2)
  (lambda (frame)
    (let ((m (frame-coord-map frame)))
      (let ((new-origin (m origin)))
        (painter (make-frame new-origin
                             (sub-vect (m corner1) new-origin)
                             (sub-vect (m corner2) new-origin)))))))
(define (flip-vert painter)
  (transform-painter painter (make-vect 0.0 1.0) (make-vect 1.0 1.0) (make-vect 0.0 0.0)))
(check "上下反転で始点が上に来る"
       (start-segment (car ((flip-vert diag) unit-frame)))
       (make-vect 0.0 1.0))
(check "上下反転を2回で元に戻る"
       ((flip-vert (flip-vert diag)) unit-frame)
       (diag unit-frame))

(summary "SICP 2.2")
