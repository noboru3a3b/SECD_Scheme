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
;;; 例外は `exit` / `quit` の1件だけ（15日目の決定64）。R5RS には無いが、
;;; 原典 micro_Scheme8.lisp にあった `quit` を scheme12 が落としていたので、
;;; 利用者の判断で復活させた。**基準を緩めたのではない**。足したいものが
;;; 出たら、そのつど利用者と決めること。
;;;
;;; 凍結仕様（dev_memo.md §2）に合わせてあること:
;;;   - 数は正確な整数と不正確な実数の2階建て。有理数・複素数は無い（§2.2）
;;;   - 算術は「一つでも不正確なら結果も不正確」（§2.3）。**ここに書く手続きは
;;;     この伝播に乗るだけでよく、自分で正確さを判断しない**
;;;   - 文字は長さ1の文字列（§2.2）
;;;   - 真は #f 以外すべて。偽は #f ただ一つ
;;;   - **整数どうしの `/` は0方向への切り捨て**、`modulo` の符号は除数に一致（§2.3）
;;;
;;; 引数の誤りは `error` で §4.2 の形に揃えて報告する。見出しは
;;; 「<誰が>: <何がまずいか>」、値は irritant にして `given:` に出す。
;;;
;;; **`%` で始まる名前は内部用**（決定60）。このファイルが使うためだけの口で、
;;; 利用者が呼ぶものではない。ここで定義するのは %isqrt / %list-tail-checked /
;;; %map-1 / %map-n / %any-null? の5つ。C++ 側の %sqrt / %expt / %values->list /
;;; %wind-push / %wind-pop / %wind-top-after / %exit を使っている。

;;; ---------------------------------------------------------------- 数
;;; 数は「正確な整数」と「不正確な実数」の2階建て（dev_memo.md §2.2）。
;;;
;;; **表現を見る手続きは C++ 側にある**（20日目の決定93）。
;;; integer? / rational? / real? / complex? / exact? / inexact? /
;;; exact->inexact / inexact->exact / floor / ceiling / truncate / round は
;;; ここには無い。ここに置くのは「= や < や算術だけで書けるもの」に限る。
;;; そうしておくと、正確さの伝播が算術1箇所で決まり、ここが嘘をつかない。

(define zero?     (lambda (x) (= x 0)))
(define positive? (lambda (x) (> x 0)))
(define negative? (lambda (x) (< x 0)))
(define even?     (lambda (x) (= (modulo x 2) 0)))
(define odd?      (lambda (x) (not (= (modulo x 2) 0))))

(define abs (lambda (x) (if (< x 0) (- 0 x) x)))

;; R5RS の max / min は1個以上の可変長。畳み込みは末尾再帰で書く（§4.3）。
;;
;; **引数に不正確な数が1つでもあれば、結果も不正確**（R5RS）。(max 2 1.0) は
;; 2 ではなく 2.0。「大きいほうを選ぶ」ことと「不正確さを伝えること」は別の話
;; なので、畳み込みの状態を2つ持って最後に1度だけ変換する。
;; 選ぶ側で exact->inexact を挟むと、選ばれなかった側の不正確さが消える。
(define max
  (lambda (x . rest)
    (letrec ((go (lambda (acc saw ls)
                   (if (null? ls)
                       (if saw (exact->inexact acc) acc)
                       (go (if (> (car ls) acc) (car ls) acc)
                           (if (inexact? (car ls)) #t saw)
                           (cdr ls))))))
      (go x (inexact? x) rest))))

(define min
  (lambda (x . rest)
    (letrec ((go (lambda (acc saw ls)
                   (if (null? ls)
                       (if saw (exact->inexact acc) acc)
                       (go (if (< (car ls) acc) (car ls) acc)
                           (if (inexact? (car ls)) #t saw)
                           (cdr ls))))))
      (go x (inexact? x) rest))))

;; quotient / remainder はここに無い。**C++ 側のプリミティブである**
;; （23日目の決定118）。22日目まではここで `/` の別名として定義していたが、
;; `/` が実数を受けるようになった19日目に意味が変わり、(quotient 7.0 2) が
;; 3.5 を返していた。整数だけを受けるものを、実数も受けるものの別名で
;; 定義してはいけない。

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

;; 底も指数も正確で、指数が0以上なら**繰り返し二乗で正確に**求める。
;; 多倍長へ抜けてもそのまま正しい（(expt 99999999999 3) が丸まらない）。
;; それ以外は %expt に落とす: (expt 2 -3) は 0.125、(expt 2.0 3) は 8.0。
;;
;; **正確な道を先に試すのが肝心。** 先に %expt へ渡すと (expt 2 100) が
;; 倍精度に丸まってしまう。
(define expt
  (lambda (b n)
    (if (and (exact? b) (exact? n) (>= n 0))
        (letrec ((go (lambda (acc b n)
                       (if (= n 0)
                           acc
                           (go (if (= (modulo n 2) 1) (* acc b) acc)
                               (* b b)
                               (quotient n 2))))))
          (go 1 b n))
        (%expt b n))))

;; R5RS: 正確な引数の平方根が正確に表せるならその数を、そうでなければ
;; 不正確な数を返す。(sqrt 16) は 4、(sqrt 2) は 1.4142135623730951。
;;
;; 平方数かどうかの判定には、**これまで「平方根の整数部」を求めていた
;; ニュートン法をそのまま使う**（整数の割り算で回るので多倍長でも正確）。
;; 求めた整数を二乗して元に戻れば、それが正確な答えである。
;;
;; **負の引数はエラーのまま。** 実数を入れても答えは虚数のままで、表せない
;; ものは表せない。+nan.0 を返すと「数でない」と嘘をつくことになる。
;; 平方根の整数部（内部用）。初期値を 1 以上に取って単調減少で止める。
(define %isqrt
  (lambda (x)
    (if (< x 2)
        x
        (letrec ((go (lambda (g)
                       (let ((next (quotient (+ g (quotient x g)) 2)))
                         (if (< next g) (go next) g)))))
          (go (quotient (+ x 1) 2))))))

(define sqrt
  (lambda (x)
    (if (< x 0)
        (error "sqrt: argument out of range" x)
        (if (exact? x)
            (let ((r (%isqrt x)))
              (if (= (* r r) x) r (%sqrt (exact->inexact x))))
            (%sqrt x)))))

;;; -------------------------------------------------------------- リスト
;;; cdr 方向は末尾再帰で辿る（§4.3 の「cdr 方向を再帰で辿らない」と同じ趣旨。
;;; 末尾再帰なら VM のダンプも積まない）。

;;; R5RS は c…r の合成を**4段まで**定める（全28個）。scheme13 は2段の4個
;;; （C++ 側）と3段の8個（caar/cadr/cdar/cddr/caddr/cdddr が C++、残りは
;;; system_lib.scm）まで持っていて、**4段の16個が無かった**。
;;; 23日目に SICP 2.3.4（ハフマン符号木）で `cadddr` を踏んで見つかった
;;; （決定117・119）。8日目の R5RS 不足の数え上げに入っていなかった。
;;;
;;; 定義は3段のものに1段かぶせるだけ。名前は**外側から**読む:
;;; cadddr は (car (cdr (cdr (cdr x)))) であって、その逆ではない。

(define caaaar   (lambda (x) (car (caaar x))))
(define caaadr   (lambda (x) (car (caadr x))))
(define caadar   (lambda (x) (car (cadar x))))
(define caaddr   (lambda (x) (car (caddr x))))
(define cadaar   (lambda (x) (car (cdaar x))))
(define cadadr   (lambda (x) (car (cdadr x))))
(define caddar   (lambda (x) (car (cddar x))))
(define cadddr   (lambda (x) (car (cdddr x))))
(define cdaaar   (lambda (x) (cdr (caaar x))))
(define cdaadr   (lambda (x) (cdr (caadr x))))
(define cdadar   (lambda (x) (cdr (cadar x))))
(define cdaddr   (lambda (x) (cdr (caddr x))))
(define cddaar   (lambda (x) (cdr (cdaar x))))
(define cddadr   (lambda (x) (cdr (cdadr x))))
(define cdddar   (lambda (x) (cdr (cddar x))))
(define cddddr   (lambda (x) (cdr (cdddr x))))


;; 内側の go は k を減らしていくので、**報告するのは元の k** でなければ
;; ならない。減った途中の値を出すと、利用者が渡していない数が given: に出る。
;; who を引数に取るのも同じ理由で、list-ref から来たときに list-tail の
;; 名前を出さないため。
(define %list-tail-checked
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

(define list-tail (lambda (ls k) (%list-tail-checked ls k "list-tail")))

(define list-ref
  (lambda (ls k)
    (let ((tail (%list-tail-checked ls k "list-ref")))
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

;;; R5RS の `map` はリストを**何本でも**取り、最短のものに合わせて止まる。
;;; system_lib.scm の `map` は1本しか取らない（`map-2` が別にある）。
;;;
;;; ここは **`define` ではなく `set!` である。** 起動時ライブラリの読み込みは
;;; 定義済みの名前を持つ `define` を飛ばす（先に読んだ system_lib.scm が勝つ）
;;; ので、`define` では届かない。既存資産の振る舞いを変えないという保証
;;; （dev_memo.md §1.4-1）は、**1本のときは system_lib.scm の実装をそのまま
;;; 呼ぶ**ことで守る。増えるのは2本以上の道だけである（決定119）。
;;;
;;; `map-2` はそのまま残す。既存資産が使っているかもしれず、消す理由が無い。
;;; `for-each` は1本のままにしてある（R5RS は複数を許す。決定119 の保留）。

(define %map-1 map)

(define %map-n
  (lambda (fn lss)
    (if (%any-null? lss)
        '()
        (cons (apply fn (%map-1 car lss))
              (%map-n fn (%map-1 cdr lss))))))

(define %any-null?
  (lambda (lss)
    (if (null? lss)
        #f
        (if (null? (car lss)) #t (%any-null? (cdr lss))))))

(set! map
  (lambda (fn ls . more)
    (if (null? more)
        (%map-1 fn ls)
        (%map-n fn (cons ls more)))))

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

;;; ---------------------------------------------------------------- 終了
;;; (exit) / (exit obj) — 処理系を終える（15日目の決定64）。
;;;
;;; **R5RS には無い**（R7RS 6.14）。このファイルの採用基準の唯一の例外で、
;;; 利用者の判断で入れた。理由は、原典 micro_Scheme8.lisp には `quit` が
;;; あったのに scheme12 がそれを落とし、scheme13 がそのまま継いでいたため。
;;; REPL を抜ける手段が EOF (Ctrl-D) しか無く、(help) にもその旨が無かった。
;;;
;;; **後始末は先に済ませてから %exit を呼ぶ。** 外へ出る dynamic-wind の
;;; after を、内側から順に呼ぶ。%wind-pop を (after) より**先**に呼ぶのが
;;; 肝で、after の中からまた exit されても同じ枠を二度巻き戻さない
;;; （セクション10 の build_rewind_code が同じ理由で同じ順序にしている）。
;;;
;;; ここで継続を使って外へ跳ばれたら exit は成立しない。それでよい。
;;; after が跳んだのなら、それは exit より後に決まった行き先である。

(define exit
  (lambda args
    (let loop ()
      (let ((after (%wind-top-after)))
        (if after
            (begin (%wind-pop) (after) (loop)))))
    (%exit (if (null? args) 0 (car args)))))

;;; 原典の名前。原典では `quit` は自分自身に束縛された**変数**で、REPL が
;;; 評価結果を見て抜ける仕掛けだった。それをそのまま復活させると
;;; `(display 'quit)` のような式まで終了の合図になりかねないので、
;;; scheme13 では手続きの別名にする。`(quit)` と書く。

(define quit exit)
