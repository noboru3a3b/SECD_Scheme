;;; lib13.scm — scheme13 が足す R5RS 手続き
;;;
;;; system_lib.scm は scheme12 と共有している既存資産なので触らない。
;;; そこに無い R5RS の手続きだけをこのファイルに置き、起動時に
;;; system_lib.scm の**後**で読む（dev_memo.md の決定42）。
;;;
;;; 入れる基準は「**R5RS にあって scheme13 に無いもの**」の一本。
;;; sort / reduce / string-upcase のような便利な非標準手続きは入れない。
;;; 線を引かないと際限が無く、憲章 §1.1（機能追加の誘惑に負けない）に反する。
;;;
;;; 凍結仕様（dev_memo.md §2）に合わせてあること:
;;;   - 整数しかない。有理数・実数・複素数は無い（§2.2）
;;;   - 文字は長さ1の文字列（§2.2）
;;;   - 真は #f 以外すべて。偽は #f ただ一つ
;;;   - `/` は0方向への切り捨て、`modulo` の符号は除数に一致（§2.3）
;;;
;;; 引数の誤りは `error` で §4.2 の形に揃えて報告する。見出しは
;;; 「<誰が>: <何がまずいか>」、値は irritant にして `given:` に出す。

;;; ---------------------------------------------------------------- 数
;;; 整数しか無いので、R5RS の数値塔の述語はすべて「整数かどうか」に潰れる。
;;; 嘘をつかない範囲で答える: 整数は有理数でも実数でも複素数でもある。

(define integer?  (lambda (x) (number? x)))
(define rational? (lambda (x) (number? x)))
(define real?     (lambda (x) (number? x)))
(define complex?  (lambda (x) (number? x)))

;; 不正確な数が存在しないので、数ならば必ず正確。
(define exact?
  (lambda (x)
    (if (number? x) #t (error "exact?: wrong type of argument" x))))
(define inexact?
  (lambda (x)
    (if (number? x) #f (error "inexact?: wrong type of argument" x))))

(define zero?     (lambda (x) (= x 0)))
(define positive? (lambda (x) (> x 0)))
(define negative? (lambda (x) (< x 0)))
(define even?     (lambda (x) (= (modulo x 2) 0)))
(define odd?      (lambda (x) (not (= (modulo x 2) 0))))

(define abs (lambda (x) (if (< x 0) (- 0 x) x)))

;; R5RS の max / min は1個以上の可変長。畳み込みは末尾再帰で書く（§4.3）。
(define max
  (lambda (x . rest)
    (letrec ((go (lambda (acc ls)
                   (if (null? ls)
                       acc
                       (go (if (> (car ls) acc) (car ls) acc) (cdr ls))))))
      (go x rest))))

(define min
  (lambda (x . rest)
    (letrec ((go (lambda (acc ls)
                   (if (null? ls)
                       acc
                       (go (if (< (car ls) acc) (car ls) acc) (cdr ls))))))
      (go x rest))))

;; quotient は0方向への切り捨て。`/` が既にそれ（§2.3）。
(define quotient (lambda (x y) (/ x y)))

;; remainder の符号は**被除数**に一致する。modulo（符号は除数に一致）とは
;; 負の数で答えが違う: (remainder -7 2) は -1、(modulo -7 2) は 1。
(define remainder (lambda (x y) (- x (* y (quotient x y)))))

;; gcd / lcm は引数0個も許す（R5RS: (gcd) は 0、(lcm) は 1）。
(define gcd
  (lambda args
    (letrec ((gcd2 (lambda (a b) (if (= b 0) a (gcd2 b (modulo a b)))))
             (go   (lambda (acc ls)
                     (if (null? ls) acc (go (gcd2 acc (abs (car ls))) (cdr ls))))))
      (go 0 args))))

(define lcm
  (lambda args
    (letrec ((go (lambda (acc ls)
                   (if (null? ls)
                       acc
                       (if (= (car ls) 0)
                           0
                           (go (/ (* acc (abs (car ls))) (gcd acc (car ls)))
                               (cdr ls)))))))
      (go 1 args))))

;; 整数しか無いので負の指数は表せない。黙って 0 を返さずに知らせる。
(define expt
  (lambda (b n)
    (if (< n 0)
        (error "expt: argument out of range" n)
        (letrec ((go (lambda (acc b n)
                       (if (= n 0)
                           acc
                           (go (if (= (modulo n 2) 1) (* acc b) acc)
                               (* b b)
                               (/ n 2))))))
          (go 1 b n)))))

;; 整数しか無いので**平方根の整数部**を返す（R5RS の「正確な数の平方根が
;; 正確でなければ不正確な数を返す」は、不正確な数が無いので採れない）。
;; ニュートン法。初期値を 1 以上に取って単調減少で止める。
(define sqrt
  (lambda (x)
    (if (< x 0)
        (error "sqrt: argument out of range" x)
        (if (< x 2)
            x
            (letrec ((go (lambda (g)
                           (let ((next (/ (+ g (/ x g)) 2)))
                             (if (< next g) (go next) g)))))
              (go (/ (+ x 1) 2)))))))

;; 整数しか無いので、丸めはすべて恒等。R5RS の名前を受け付けること自体に
;; 意味がある（他所から持ってきたコードがそのまま動く）。
(define floor    (lambda (x) (if (number? x) x (error "floor: wrong type of argument" x))))
(define ceiling  (lambda (x) (if (number? x) x (error "ceiling: wrong type of argument" x))))
(define truncate (lambda (x) (if (number? x) x (error "truncate: wrong type of argument" x))))
(define round    (lambda (x) (if (number? x) x (error "round: wrong type of argument" x))))

;;; -------------------------------------------------------------- リスト
;;; cdr 方向は末尾再帰で辿る（§4.3 の「cdr 方向を再帰で辿らない」と同じ趣旨。
;;; 末尾再帰なら VM のダンプも積まない）。

;; 内側の go は k を減らしていくので、**報告するのは元の k** でなければ
;; ならない。減った途中の値を出すと、利用者が渡していない数が given: に出る。
;; who を引数に取るのも同じ理由で、list-ref から来たときに list-tail の
;; 名前を出さないため。
(define list-tail-checked
  (lambda (ls k who)
    (letrec ((go (lambda (ls n)
                   (if (= n 0)
                       ls
                       (if (pair? ls)
                           (go (cdr ls) (- n 1))
                           (error (string-append who ": index out of range") k))))))
      (if (< k 0)
          (error (string-append who ": index out of range") k)
          (go ls k)))))

(define list-tail (lambda (ls k) (list-tail-checked ls k "list-tail")))

(define list-ref
  (lambda (ls k)
    (let ((tail (list-tail-checked ls k "list-ref")))
      (if (pair? tail)
          (car tail)
          (error "list-ref: index out of range" k)))))

;; member / assoc は equal? で比べる（memq/assq は eq?、memv/assv は eqv?）。
(define member
  (lambda (x ls)
    (if (null? ls)
        #f
        (if (equal? x (car ls))
            ls
            (member x (cdr ls))))))

(define assoc
  (lambda (x ls)
    (if (null? ls)
        #f
        (if (equal? x (car (car ls)))
            (car ls)
            (assoc x (cdr ls))))))

;;; -------------------------------------------------------------- 文字列
;;; 文字は長さ1の文字列（§2.2）。だから (string "a" "b") は string-append。

(define string (lambda args (apply string-append args)))

(define string-copy (lambda (s) (substring s 0 (string-length s))))

(define string-fill!
  (lambda (s ch)
    (letrec ((go (lambda (i)
                   (if (< i (string-length s))
                       (begin (string-set! s i ch) (go (+ i 1)))
                       :undef))))
      (go 0))))

;;; -------------------------------------------------------------- ベクタ

(define vector-fill!
  (lambda (v x)
    (letrec ((go (lambda (i)
                   (if (< i (vector-length v))
                       (begin (vector-set! v i x) (go (+ i 1)))
                       :undef))))
      (go 0))))

;;; ------------------------------------------------- 多値と dynamic-wind

;;; call-with-values は producer の結果の箱を開けて consumer に渡すだけ。
;;; 多値は「1個なら値そのもの、それ以外は Values の箱」なので、
;;; %values->list はどちらでもリストにして返す（決定58）。

(define call-with-values
  (lambda (producer consumer)
    (apply consumer (%values->list (producer)))))

;;; dynamic-wind の**普通の道**はここに書けばよい。before を呼び、枠を積み、
;;; thunk を呼び、枠を降ろして after を呼ぶ。
;;;
;;; **脱出と再入は書かない。** thunk の中から継続で外へ跳ぶと、%wind-pop も
;;; (after) も飛ばされるが、枠は積まれたままなので、継続を起動する側が
;;; 差分の after を走らせる（決定59。セクション10 の build_rewind_code）。
;;; 再入も同じ仕組みで before が走る。
;;;
;;; before を呼んでから枠を積む順序に意味がある。before 自身が脱出したときに
;;; after を呼ばせないため（R5RS もそう定めている）。

(define dynamic-wind
  (lambda (before thunk after)
    (before)
    (%wind-push before after)
    (let ((result (thunk)))
      (%wind-pop)
      (after)
      result)))
