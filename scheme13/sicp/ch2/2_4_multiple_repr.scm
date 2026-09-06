; SICP 2.4「抽象データの多重表現」を scheme13 で確認する。
;   2.4.1 複素数の表現 / 2.4.2 タグ付きデータ
;   2.4.3 データ主導プログラミングと加法性
;
; 処理系側で問われるのは
;   - 手続きを値として表に入れ、取り出して `apply` で呼べること
;   - `set!` で大域の表を育てられること（加法性はこれで成り立つ）
;   - 三角関数と平方根が、直交形式と極形式の往復に耐える精度で動くこと
;
; 注記: scheme13 は複素数型を持たない（§2.3 で凍結）。ここで作る「複素数」は
; 書籍と同じく、対とタグだけで組み立てたものである。

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

(define (square x) (* x x))

; --- 操作と型の表（put / get）---
; 書籍は put/get を与えられたものとして使う。ここでは連想リストで作る。
(define op-table '())
(define (put op type item)
  (set! op-table (cons (list op type item) op-table)))
(define (get op type)
  (define (loop rows)
    (cond ((null? rows) #f)
          ((and (equal? (car (car rows)) op) (equal? (cadr (car rows)) type))
           (caddr (car rows)))
          (else (loop (cdr rows)))))
  (loop op-table))

(put 'test '(a) 'found)
(check "表に入れて取り出せる" (get 'test '(a)) 'found)
(check "無い組は #f"          (get 'test '(b)) #f)

; --- 2.4.2 タグ付きデータ ---
(define (attach-tag type-tag contents) (cons type-tag contents))
(define (type-tag datum)
  (if (pair? datum) (car datum) (error "Bad tagged datum -- TYPE-TAG" datum)))
(define (contents datum)
  (if (pair? datum) (cdr datum) (error "Bad tagged datum -- CONTENTS" datum)))

(check "タグを付ける"   (type-tag (attach-tag 'rectangular (cons 3 4))) 'rectangular)
(check "中身を取り出す" (contents (attach-tag 'rectangular (cons 3 4))) (cons 3 4))

; --- 2.4.3 データ主導: 直交形式のパッケージ ---
(define (install-rectangular-package)
  (define (real-part z) (car z))
  (define (imag-part z) (cdr z))
  (define (make-from-real-imag x y) (cons x y))
  (define (magnitude z) (sqrt (+ (square (real-part z)) (square (imag-part z)))))
  (define (angle z) (atan (imag-part z) (real-part z)))
  (define (make-from-mag-ang r a) (cons (* r (cos a)) (* r (sin a))))
  (define (tag x) (attach-tag 'rectangular x))
  (put 'real-part '(rectangular) real-part)
  (put 'imag-part '(rectangular) imag-part)
  (put 'magnitude '(rectangular) magnitude)
  (put 'angle '(rectangular) angle)
  (put 'make-from-real-imag 'rectangular (lambda (x y) (tag (make-from-real-imag x y))))
  (put 'make-from-mag-ang 'rectangular (lambda (r a) (tag (make-from-mag-ang r a))))
  'done)

; 極形式のパッケージ。**同じ操作名を、別の型のもとで登録する。**
(define (install-polar-package)
  (define (magnitude z) (car z))
  (define (angle z) (cdr z))
  (define (make-from-mag-ang r a) (cons r a))
  (define (real-part z) (* (magnitude z) (cos (angle z))))
  (define (imag-part z) (* (magnitude z) (sin (angle z))))
  (define (make-from-real-imag x y) (cons (sqrt (+ (square x) (square y))) (atan y x)))
  (define (tag x) (attach-tag 'polar x))
  (put 'real-part '(polar) real-part)
  (put 'imag-part '(polar) imag-part)
  (put 'magnitude '(polar) magnitude)
  (put 'angle '(polar) angle)
  (put 'make-from-real-imag 'polar (lambda (x y) (tag (make-from-real-imag x y))))
  (put 'make-from-mag-ang 'polar (lambda (r a) (tag (make-from-mag-ang r a))))
  'done)

(check "直交パッケージを入れる" (install-rectangular-package) 'done)
(check "極パッケージを入れる"   (install-polar-package) 'done)

(define (apply-generic op . args)
  (let ((type-tags (map type-tag args)))
    (let ((proc (get op type-tags)))
      (if proc
          (apply proc (map contents args))
          (error "No method for these types -- APPLY-GENERIC" (list op type-tags))))))

(define (real-part z) (apply-generic 'real-part z))
(define (imag-part z) (apply-generic 'imag-part z))
(define (magnitude z) (apply-generic 'magnitude z))
(define (angle z) (apply-generic 'angle z))
(define (make-from-real-imag x y) ((get 'make-from-real-imag 'rectangular) x y))
(define (make-from-mag-ang r a) ((get 'make-from-mag-ang 'polar) r a))

(define z-rect (make-from-real-imag 3.0 4.0))
(define z-polar (make-from-mag-ang 5.0 0.9272952180016122))   ; 上と同じ点

(check "直交形式のタグ"   (type-tag z-rect) 'rectangular)
(check "極形式のタグ"     (type-tag z-polar) 'polar)
(check "直交の実部"       (real-part z-rect) 3.0)
(check "直交の虚部"       (imag-part z-rect) 4.0)
(check "直交から絶対値"   (magnitude z-rect) 5.0)
(check~ "直交から偏角"    (angle z-rect) 0.9272952180016122 1e-15)
(check~ "極から実部"      (real-part z-polar) 3.0 1e-12)
(check~ "極から虚部"      (imag-part z-polar) 4.0 1e-12)
(check "極から絶対値"     (magnitude z-polar) 5.0)
; **同じ総称手続きが、表現の違う2つの値の両方に効く。** これがこの節の主張。
(check~ "表現が違っても実部は同じ" (real-part z-rect) (real-part z-polar) 1e-12)
(check~ "表現が違っても絶対値は同じ" (magnitude z-rect) (magnitude z-polar) 1e-12)

; 総称手続きの上に、複素数の算術を積む
(define (add-complex z1 z2)
  (make-from-real-imag (+ (real-part z1) (real-part z2))
                       (+ (imag-part z1) (imag-part z2))))
(define (sub-complex z1 z2)
  (make-from-real-imag (- (real-part z1) (real-part z2))
                       (- (imag-part z1) (imag-part z2))))
(define (mul-complex z1 z2)
  (make-from-mag-ang (* (magnitude z1) (magnitude z2))
                     (+ (angle z1) (angle z2))))
(define (div-complex z1 z2)
  (make-from-mag-ang (/ (magnitude z1) (magnitude z2))
                     (- (angle z1) (angle z2))))

(define i-unit (make-from-real-imag 0.0 1.0))
(check~ "(3+4i)+(3+4i) の実部" (real-part (add-complex z-rect z-rect)) 6.0 1e-12)
(check~ "(3+4i)-(3+4i) の実部" (real-part (sub-complex z-rect z-rect)) 0.0 1e-12)
; i*i = -1。**表現をまたいで計算しても正しい**（極形式で掛けて直交形式で読む）
(check~ "i*i の実部は -1" (real-part (mul-complex i-unit i-unit)) -1.0 1e-12)
(check~ "i*i の虚部は 0"  (imag-part (mul-complex i-unit i-unit)) 0.0 1e-12)
(check~ "(3+4i)*(3+4i) の実部" (real-part (mul-complex z-rect z-rect)) -7.0 1e-12)
(check~ "(3+4i)*(3+4i) の虚部" (imag-part (mul-complex z-rect z-rect)) 24.0 1e-12)
(check~ "z/z の実部は 1"  (real-part (div-complex z-rect z-rect)) 1.0 1e-12)

; 加法性: 新しい表現を後から足しても、既存のコードは1行も変えない。
; ここでは「実部だけを持つ実数」型を足してみる。
(define (install-realonly-package)
  (define (tag x) (attach-tag 'realonly x))
  (put 'real-part '(realonly) (lambda (z) z))
  (put 'imag-part '(realonly) (lambda (z) 0.0))
  (put 'magnitude '(realonly) (lambda (z) (abs z)))
  (put 'angle '(realonly) (lambda (z) (if (< z 0) 3.141592653589793 0.0)))
  (put 'make-realonly 'realonly (lambda (x) (tag x)))
  'done)
(check "第3の表現を後から足す" (install-realonly-package) 'done)
(define r5 ((get 'make-realonly 'realonly) 5.0))
(check "総称手続きはそのまま効く" (real-part r5) 5.0)
(check "虚部は0"                  (imag-part r5) 0.0)
(check "絶対値"                   (magnitude r5) 5.0)
; 既存の add-complex も、書き換えずに新しい型を受ける
(check~ "既存の算術が新しい型を受ける" (real-part (add-complex r5 z-rect)) 8.0 1e-12)

; --- 2.4.3 メッセージパッシング ---
; 表を持たず、データのほうが操作名で分岐する。
(define (make-from-real-imag-mp x y)
  (define (dispatch op)
    (cond ((eq? op 'real-part) x)
          ((eq? op 'imag-part) y)
          ((eq? op 'magnitude) (sqrt (+ (square x) (square y))))
          ((eq? op 'angle) (atan y x))
          (else (error "Unknown op -- MAKE-FROM-REAL-IMAG" op))))
  dispatch)
(define (apply-generic-mp op arg) (arg op))
(define zm (make-from-real-imag-mp 3.0 4.0))
(check "メッセージパッシング 実部"   (apply-generic-mp 'real-part zm) 3.0)
(check "メッセージパッシング 絶対値" (apply-generic-mp 'magnitude zm) 5.0)
(check "データが手続きになっている"  (procedure? zm) #t)

; 演習 2.75: 極形式もメッセージパッシングで
(define (make-from-mag-ang-mp r a)
  (lambda (op)
    (cond ((eq? op 'real-part) (* r (cos a)))
          ((eq? op 'imag-part) (* r (sin a)))
          ((eq? op 'magnitude) r)
          ((eq? op 'angle) a)
          (else (error "Unknown op -- MAKE-FROM-MAG-ANG" op)))))
(check~ "極のメッセージパッシング 実部"
        (apply-generic-mp 'real-part (make-from-mag-ang-mp 5.0 0.9272952180016122))
        3.0 1e-12)

; 表そのものの性質: 同じ操作名が型の数だけ入っている
(check "real-part は3つの型に登録されている"   ; rectangular / polar / realonly
       (length (filter (lambda (row) (eq? (car row) 'real-part)) op-table)) 3)

(summary "SICP 2.4")
