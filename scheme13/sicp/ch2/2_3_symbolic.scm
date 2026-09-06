; SICP 2.3「記号データ」を scheme13 で確認する。
;   2.3.1 クォート / 2.3.2 例: 記号微分
;   2.3.3 例: 集合の表現 / 2.3.4 例: ハフマン符号木
;
; 処理系側で問われるのは
;   - シンボルが同一性で比べられること（インターン。eq? が使えること）
;   - クォートと準クォートが読めること
;   - 記号を要素にした木構造を、数と同じ手つきで扱えること
;
; 注記: scheme13 のシンボルは**大小文字を区別する**（'abc と 'ABC は別）。
; 土台にした micro_Scheme8.lisp は Common Lisp のリーダで大文字に畳んでいたが、
; scheme13 は畳まない。書籍のコードは小文字なので、そのまま動く。

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

; --- 2.3.1 クォート ---
(define b 2)
(check "(list 'a 'b)"  (list 'a 'b) '(a b))
(check "(list 'a b)"   (list 'a b)  '(a 2))
(check "car of quoted" (car '(a b c)) 'a)
(check "cdr of quoted" (cdr '(a b c)) '(b c))
(check "クォートは評価しない" (car ''abc) 'quote)
(check "シンボルは同一性で比べられる" (eq? 'a 'a) #t)
(check "違うシンボルは違う"           (eq? 'a 'b) #f)
(check "大小文字を区別する"           (eq? 'abc 'ABC) #f)
(check "文字列からシンボルへ"         (eq? (string->symbol "xyz") 'xyz) #t)
(check "シンボルから文字列へ"         (symbol->string 'xyz) "xyz")
(check "symbol?"                      (symbol? 'a) #t)
(check "数はシンボルではない"         (symbol? 1) #f)
(check "memq 見つからない" (memq 'apple '(pear banana prune)) #f)
(check "memq 見つかる"     (memq 'apple '(x (apple sauce) y apple pear)) '(apple pear))
(check "equal? は木を辿る" (equal? '(this (is a) list) '(this (is a) list)) #t)
(check "eq? は辿らない"    (eq? '(1 2) '(1 2)) #f)
(check "準クォート"        `(1 ,(+ 1 1) 3) '(1 2 3))
(check "準クォートの展開"  `(a ,@(list 'b 'c) d) '(a b c d))

; --- 2.3.2 記号微分 ---
; まず簡約なしの版。書籍が示すとおり、正しいが冗長な式が出る。
(define (variable? x) (symbol? x))
(define (same-variable? v1 v2) (and (variable? v1) (variable? v2) (eq? v1 v2)))
(define (sum? x) (and (pair? x) (eq? (car x) '+)))
(define (addend s) (cadr s))
(define (augend s) (caddr s))
(define (product? x) (and (pair? x) (eq? (car x) '*)))
(define (multiplier p) (cadr p))
(define (multiplicand p) (caddr p))

(define (make-sum-raw a1 a2) (list '+ a1 a2))
(define (make-product-raw m1 m2) (list '* m1 m2))
(define (deriv-raw exp var)
  (cond ((number? exp) 0)
        ((variable? exp) (if (same-variable? exp var) 1 0))
        ((sum? exp) (make-sum-raw (deriv-raw (addend exp) var)
                                  (deriv-raw (augend exp) var)))
        ((product? exp)
         (make-sum-raw
          (make-product-raw (multiplier exp) (deriv-raw (multiplicand exp) var))
          (make-product-raw (deriv-raw (multiplier exp) var) (multiplicand exp))))
        (else (error "unknown expression type -- DERIV" exp))))

(check "d(x+3)/dx 簡約なし"  (deriv-raw '(+ x 3) 'x) '(+ 1 0))
(check "d(xy)/dx 簡約なし"   (deriv-raw '(* x y) 'x) '(+ (* x 0) (* 1 y)))
(check "d(xy(x+3))/dx 簡約なし"
       (deriv-raw '(* (* x y) (+ x 3)) 'x)
       '(+ (* (* x y) (+ 1 0)) (* (+ (* x 0) (* 1 y)) (+ x 3))))

; 構成子に簡約を入れた版。答えが読める形になる。
(define (=number? exp num) (and (number? exp) (= exp num)))
(define (make-sum a1 a2)
  (cond ((=number? a1 0) a2)
        ((=number? a2 0) a1)
        ((and (number? a1) (number? a2)) (+ a1 a2))
        (else (list '+ a1 a2))))
(define (make-product m1 m2)
  (cond ((or (=number? m1 0) (=number? m2 0)) 0)
        ((=number? m1 1) m2)
        ((=number? m2 1) m1)
        ((and (number? m1) (number? m2)) (* m1 m2))
        (else (list '* m1 m2))))
; 演習 2.56: べき乗も微分できるようにする
(define (exponentiation? x) (and (pair? x) (eq? (car x) '**)))
(define (base e) (cadr e))
(define (exponent e) (caddr e))
(define (make-exponentiation b e)
  (cond ((=number? e 0) 1)
        ((=number? e 1) b)
        (else (list '** b e))))
(define (deriv exp var)
  (cond ((number? exp) 0)
        ((variable? exp) (if (same-variable? exp var) 1 0))
        ((sum? exp) (make-sum (deriv (addend exp) var) (deriv (augend exp) var)))
        ((product? exp)
         (make-sum (make-product (multiplier exp) (deriv (multiplicand exp) var))
                   (make-product (deriv (multiplier exp) var) (multiplicand exp))))
        ((exponentiation? exp)
         (make-product
          (make-product (exponent exp)
                        (make-exponentiation (base exp) (- (exponent exp) 1)))
          (deriv (base exp) var)))
        (else (error "unknown expression type -- DERIV" exp))))

(check "d(x+3)/dx"       (deriv '(+ x 3) 'x) 1)
(check "d(xy)/dx"        (deriv '(* x y) 'x) 'y)
(check "d(xy(x+3))/dx"   (deriv '(* (* x y) (+ x 3)) 'x) '(+ (* x y) (* y (+ x 3))))
(check "定数の微分は0"   (deriv '5 'x) 0)
(check "他の変数で微分"  (deriv '(* x y) 'z) 0)
(check "d(x**3)/dx"      (deriv '(** x 3) 'x) '(* 3 (** x 2)))
(check "d(x**2)/dx"      (deriv '(** x 2) 'x) '(* 2 x))
(check "d(x**1)/dx"      (deriv '(** x 1) 'x) 1)

; --- 2.3.3 集合の表現 ---
; (1) 順序なしリスト
(define (element-of-set? x set)
  (cond ((null? set) #f)
        ((equal? x (car set)) #t)
        (else (element-of-set? x (cdr set)))))
(define (adjoin-set x set) (if (element-of-set? x set) set (cons x set)))
(define (intersection-set set1 set2)
  (cond ((or (null? set1) (null? set2)) '())
        ((element-of-set? (car set1) set2)
         (cons (car set1) (intersection-set (cdr set1) set2)))
        (else (intersection-set (cdr set1) set2))))
(define (union-set set1 set2)                    ; 演習 2.59
  (cond ((null? set1) set2)
        ((element-of-set? (car set1) set2) (union-set (cdr set1) set2))
        (else (cons (car set1) (union-set (cdr set1) set2)))))

(check "元がある"       (element-of-set? 'b '(a b c)) #t)
(check "元がない"       (element-of-set? 'z '(a b c)) #f)
(check "重複は入れない" (adjoin-set 'b '(a b c)) '(a b c))
(check "無いものは足す" (adjoin-set 'z '(a b c)) '(z a b c))
(check "積集合"         (intersection-set '(a b c) '(b c d)) '(b c))
(check "和集合"         (union-set '(a b c) '(b c d)) '(a b c d))
(check "空との積"       (intersection-set '() '(a)) '())

; (2) 順序つきリスト
(define (element-of-set2? x set)
  (cond ((null? set) #f)
        ((= x (car set)) #t)
        ((< x (car set)) #f)
        (else (element-of-set2? x (cdr set)))))
(define (intersection-set2 set1 set2)
  (if (or (null? set1) (null? set2))
      '()
      (let ((x1 (car set1)) (x2 (car set2)))
        (cond ((= x1 x2) (cons x1 (intersection-set2 (cdr set1) (cdr set2))))
              ((< x1 x2) (intersection-set2 (cdr set1) set2))
              (else (intersection-set2 set1 (cdr set2)))))))
(define (adjoin-set2 x set)                      ; 演習 2.61
  (cond ((null? set) (list x))
        ((= x (car set)) set)
        ((< x (car set)) (cons x set))
        (else (cons (car set) (adjoin-set2 x (cdr set))))))
(define (union-set2 set1 set2)                   ; 演習 2.62
  (cond ((null? set1) set2)
        ((null? set2) set1)
        (else (let ((x1 (car set1)) (x2 (car set2)))
                (cond ((= x1 x2) (cons x1 (union-set2 (cdr set1) (cdr set2))))
                      ((< x1 x2) (cons x1 (union-set2 (cdr set1) set2)))
                      (else (cons x2 (union-set2 set1 (cdr set2)))))))))

(check "順序つき 見つかる"   (element-of-set2? 3 '(1 3 5 7)) #t)
(check "順序つき 途中で諦める" (element-of-set2? 4 '(1 3 5 7)) #f)
(check "順序つき 積集合"     (intersection-set2 '(1 3 5 7) '(3 4 5 6)) '(3 5))
(check "順序つき 挿入"       (adjoin-set2 4 '(1 3 5 7)) '(1 3 4 5 7))
(check "順序つき 和集合"     (union-set2 '(1 3 5) '(2 3 6)) '(1 2 3 5 6))

; (3) 二分木
(define (entry tree) (car tree))
(define (left-branch tree) (cadr tree))
(define (right-branch tree) (caddr tree))
(define (make-tree entry left right) (list entry left right))
(define (element-of-set3? x set)
  (cond ((null? set) #f)
        ((= x (entry set)) #t)
        ((< x (entry set)) (element-of-set3? x (left-branch set)))
        (else (element-of-set3? x (right-branch set)))))
(define (adjoin-set3 x set)
  (cond ((null? set) (make-tree x '() '()))
        ((= x (entry set)) set)
        ((< x (entry set))
         (make-tree (entry set) (adjoin-set3 x (left-branch set)) (right-branch set)))
        (else (make-tree (entry set) (left-branch set) (adjoin-set3 x (right-branch set))))))
(define (tree->list tree)                        ; 演習 2.63
  (if (null? tree)
      '()
      (append (tree->list (left-branch tree))
              (cons (entry tree) (tree->list (right-branch tree))))))
(define (list->tree-naive lst)
  (define (loop rest acc) (if (null? rest) acc (loop (cdr rest) (adjoin-set3 (car rest) acc))))
  (loop lst '()))

(define t1 (list->tree-naive '(7 3 9 1 5 11)))
(check "二分木 見つかる"     (element-of-set3? 5 t1) #t)
(check "二分木 見つからない" (element-of-set3? 6 t1) #f)
(check "二分木を整列リストへ" (tree->list t1) '(1 3 5 7 9 11))
(check "挿入しても整列は保たれる" (tree->list (adjoin-set3 6 t1)) '(1 3 5 6 7 9 11))
(check "同じ元を入れても増えない" (tree->list (adjoin-set3 5 t1)) '(1 3 5 7 9 11))
; 形の違う木でも、同じ集合なら同じ整列リストになる
(check "挿入順が違っても同じ集合"
       (tree->list (list->tree-naive '(1 3 5 7 9 11)))
       (tree->list t1))

; --- 2.3.4 ハフマン符号木 ---
(define (make-leaf symbol weight) (list 'leaf symbol weight))
(define (leaf? object) (eq? (car object) 'leaf))
(define (symbol-leaf x) (cadr x))
(define (weight-leaf x) (caddr x))
(define (left-branch-h tree) (car tree))
(define (right-branch-h tree) (cadr tree))
; `cadddr` はここで踏んで見つかった不足だった。23日目に4段の16個を
; `lib13.scm` に入れた（決定117・119）ので、**いまは補わずに使える。**
(check "cadddr は処理系が持っている" (cadddr '(1 2 3 4)) 4)
(define (symbols tree) (if (leaf? tree) (list (symbol-leaf tree)) (caddr tree)))
(define (weight tree) (if (leaf? tree) (weight-leaf tree) (cadddr tree)))
(define (make-code-tree left right)
  (list left right (append (symbols left) (symbols right)) (+ (weight left) (weight right))))

(define (choose-branch bit branch)
  (cond ((= bit 0) (left-branch-h branch))
        ((= bit 1) (right-branch-h branch))
        (else (error "bad bit -- CHOOSE-BRANCH" bit))))
(define (decode bits tree)
  (define (decode-1 bits current-branch)
    (if (null? bits)
        '()
        (let ((next-branch (choose-branch (car bits) current-branch)))
          (if (leaf? next-branch)
              (cons (symbol-leaf next-branch) (decode-1 (cdr bits) tree))
              (decode-1 (cdr bits) next-branch)))))
  (decode-1 bits tree))

(define (encode-symbol sym tree)
  (cond ((leaf? tree) '())
        ((memq sym (symbols (left-branch-h tree)))
         (cons 0 (encode-symbol sym (left-branch-h tree))))
        ((memq sym (symbols (right-branch-h tree)))
         (cons 1 (encode-symbol sym (right-branch-h tree))))
        (else (error "symbol not in tree -- ENCODE-SYMBOL" sym))))
(define (encode message tree)
  (if (null? message)
      '()
      (append (encode-symbol (car message) tree) (encode (cdr message) tree))))

; 木を作る（演習 2.69）
(define (adjoin-leaf-set x set)
  (cond ((null? set) (list x))
        ((< (weight x) (weight (car set))) (cons x set))
        (else (cons (car set) (adjoin-leaf-set x (cdr set))))))
(define (make-leaf-set pairs)
  (if (null? pairs)
      '()
      (let ((pair (car pairs)))
        (adjoin-leaf-set (make-leaf (car pair) (cadr pair)) (make-leaf-set (cdr pairs))))))
(define (successive-merge set)
  (if (null? (cdr set))
      (car set)
      (successive-merge (adjoin-leaf-set (make-code-tree (car set) (cadr set)) (cddr set)))))
(define (generate-huffman-tree pairs) (successive-merge (make-leaf-set pairs)))

; 書籍の例と同じ木を、手で組む版
(define sample-tree
  (make-code-tree (make-leaf 'A 4)
                  (make-code-tree (make-leaf 'B 2)
                                  (make-code-tree (make-leaf 'D 1) (make-leaf 'C 1)))))
(define sample-message '(0 1 1 0 0 1 0 1 0 1 1 1 0))
(check "復号"        (decode sample-message sample-tree) '(A D A B B C A))
(check "符号化して戻る" (encode '(A D A B B C A) sample-tree) sample-message)
(check "木の重み"    (weight sample-tree) 8)
(check "木の記号"    (symbols sample-tree) '(A B D C))
(check "A は1ビット" (encode-symbol 'A sample-tree) '(0))
(check "C は3ビット" (length (encode-symbol 'C sample-tree)) 3)

; 演習 2.67〜2.70: 頻度から木を作り、往復させる。
; 書籍の例題そのものではなく、同じ形の題材（8記号・頻度の偏りが大きい）を自分で作る。
(define freq-pairs '((e 16) (t 9) (a 4) (o 3) (i 2) (n 2) (s 2) (h 1)))
(define freq-tree (generate-huffman-tree freq-pairs))
(define msg '(e t a e e o i e t n e s e h e t e a e e))
(check "頻度から作った木で往復する" (decode (encode msg freq-tree) freq-tree) msg)
(check "8記号の固定長なら 3ビット/記号" (* 3 (length msg)) 60)
; 48 は手で検算した値: 木は (e (t ((o (h i)) (a (n s))))) になり、符号長は
; e=1 t=2 a=o=4 i=n=s=h=5。出現数は e10 t3 a2 o1 i1 n1 s1 h1 なので
; 10+6+8+4+5+5+5+5 = 48。
(check "ハフマンなら 48ビット"          (length (encode msg freq-tree)) 48)
(check "固定長より短い"
       (< (length (encode msg freq-tree)) (* 3 (length msg))) #t)
(check "頻度の高い記号ほど短い"
       (< (length (encode-symbol 'e freq-tree)) (length (encode-symbol 'h freq-tree))) #t)
(check "最頻の記号は1ビット" (encode-symbol 'e freq-tree) '(0))
(check "木の総重量は頻度の和"
       (weight freq-tree) (fold-left + 0 (map cadr freq-pairs)))

(summary "SICP 2.3")
