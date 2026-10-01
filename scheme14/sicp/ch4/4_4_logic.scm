; SICP 4.4「論理プログラミング」を scheme13 で確認する。
;   4.4.1 演繹的情報検索 / 4.4.2 質問システムの仕組み
;   4.4.4 質問システムの実装（照合・単一化・規則）
;
; 「どう計算するか」ではなく「何が成り立つか」を書く言語を、scheme13 の上に作る。
; 中核は3つ:
;   - **照合（pattern matching）**: パターンとデータを、変数の束縛の下で合わせる
;   - **単一化（unification）**: 両側に変数がある場合の照合。規則に要る
;   - **規則**: 結論と本体。使うたびに変数を付け替える
;
; 書籍との違いを1つだけ明示しておく。**書籍は答えの集合をストリームで扱うが、
; ここではリストにした。** データベースが有限で、規則も無限に潜らない形に
; 書いてあるので結果は同じになる。ストリームが要るのは無限の答えを扱うときで、
; それは 3.5 で確かめてある（`ch3/3_5_streams.scm`）。
;
; 処理系側で問われるのは、記号データ・表・再帰・文字列（`?x` を `(? x)` に
; 直すところ）を、まとめて大きなプログラムの中で使えることである。

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

; --- 質問の構文: ?x を (? x) に直す ---
; scheme13 では文字は長さ1の文字列（凍結仕様 §2.2）なので、先頭文字の比較は
; `string=?` で書く。
(define (var-symbol? s)
  (and (symbol? s)
       (> (string-length (symbol->string s)) 1)
       (string=? (string-ref (symbol->string s) 0) "?")))
(define (var-name s)
  (let ((str (symbol->string s)))
    (string->symbol (substring str 1 (string-length str)))))
(define (query->internal exp)
  (cond ((var-symbol? exp) (list '? (var-name exp)))
        ((pair? exp) (cons (query->internal (car exp)) (query->internal (cdr exp))))
        (else exp)))
(define (var? exp) (and (pair? exp) (eq? (car exp) '?)))
(define (constant-symbol? exp) (symbol? exp))

(check "?x を内部形式に直す"   (query->internal '?x) '(? x))
(check "入れ子も直す"          (query->internal '(job ?person ?title))
                               '(job (? person) (? title)))
(check "変数でない ? 単独"     (var-symbol? '?) #f)
(check "変数の判定"            (var? '(? x)) #t)

; --- 束縛（フレーム）---
(define the-empty-frame '())
(define (binding-in-frame variable frame) (assoc variable frame))
(define (binding-variable binding) (car binding))
(define (binding-value binding) (cdr binding))
(define (extend variable value frame) (cons (cons variable value) frame))

; --- 照合 ---
(define (pattern-match pat dat frame)
  (cond ((eq? frame 'failed) 'failed)
        ((equal? pat dat) frame)
        ((var? pat) (extend-if-consistent pat dat frame))
        ((and (pair? pat) (pair? dat))
         (pattern-match (cdr pat) (cdr dat) (pattern-match (car pat) (car dat) frame)))
        (else 'failed)))
(define (extend-if-consistent var dat frame)
  (let ((binding (binding-in-frame var frame)))
    (if binding
        (pattern-match (binding-value binding) dat frame)   ; 既に束縛済み
        (extend var dat frame))))

(check "定数どうしの照合" (pattern-match '(a b) '(a b) the-empty-frame) the-empty-frame)
(check "合わないと失敗"   (pattern-match '(a b) '(a c) the-empty-frame) 'failed)
(check "変数が束縛される"
       (pattern-match (query->internal '(job ?x programmer)) '(job alice programmer)
                      the-empty-frame)
       (list (cons '(? x) 'alice)))
(check "同じ変数は同じ値でなければならない"
       (pattern-match (query->internal '(pair ?x ?x)) '(pair a b) the-empty-frame)
       'failed)
(check "同じ値なら通る"
       (pattern-match (query->internal '(pair ?x ?x)) '(pair a a) the-empty-frame)
       (list (cons '(? x) 'a)))

; --- 単一化（両側に変数がありうる）---
(define (unify-match p1 p2 frame)
  (cond ((eq? frame 'failed) 'failed)
        ((equal? p1 p2) frame)
        ((var? p1) (extend-if-possible p1 p2 frame))
        ((var? p2) (extend-if-possible p2 p1 frame))
        ((and (pair? p1) (pair? p2))
         (unify-match (cdr p1) (cdr p2) (unify-match (car p1) (car p2) frame)))
        (else 'failed)))
(define (extend-if-possible var val frame)
  (let ((binding (binding-in-frame var frame)))
    (cond (binding (unify-match (binding-value binding) val frame))
          ((var? val)
           (let ((binding2 (binding-in-frame val frame)))
             (if binding2
                 (unify-match var (binding-value binding2) frame)
                 (extend var val frame))))
          ((depends-on? val var frame) 'failed)   ; ?x と (f ?x) は単一化できない
          (else (extend var val frame)))))
(define (depends-on? exp var frame)
  (define (tree-walk e)
    (cond ((var? e)
           (if (equal? var e)
               #t
               (let ((b (binding-in-frame e frame)))
                 (if b (tree-walk (binding-value b)) #f))))
          ((pair? e) (or (tree-walk (car e)) (tree-walk (cdr e))))
          (else #f)))
  (tree-walk exp))

(check "変数どうしの単一化"
       (unify-match (query->internal '(?x b)) (query->internal '(a ?y)) the-empty-frame)
       (list (cons '(? y) 'b) (cons '(? x) 'a)))
(check "自分を含む式とは単一化できない"
       (unify-match (query->internal '?x) (query->internal '(f ?x)) the-empty-frame)
       'failed)
(check "同じ変数どうしは通る"
       (unify-match (query->internal '?x) (query->internal '?x) the-empty-frame)
       the-empty-frame)

; --- データベース ---
; 書籍の例題とは別の、自分で作った小さなデータベース。
(define assertions
  (map query->internal
       '((job alice (engineering programmer))
         (job bob (engineering programmer))
         (job carol (engineering manager))
         (job dave (accounting clerk))
         (salary alice 60000)
         (salary bob 45000)
         (salary carol 90000)
         (salary dave 30000)
         (supervisor alice carol)
         (supervisor bob carol)
         (supervisor dave carol)
         (parent carol alice)
         (parent carol bob)
         (parent alice erin)
         (parent alice frank)
         (parent bob grace))))

; 規則は (rule 結論 本体)。本体が無ければ常に成り立つ
(define rules
  (map query->internal
       '((rule (grandparent ?g ?c) (and (parent ?g ?p) (parent ?p ?c)))
         (rule (sibling ?a ?b)
               (and (parent ?p ?a) (parent ?p ?b) (not (same ?a ?b))))
         (rule (same ?x ?x))
         (rule (ancestor ?a ?d) (parent ?a ?d))
         (rule (ancestor ?a ?d) (and (parent ?a ?p) (ancestor ?p ?d)))
         (rule (colleague ?a ?b)
               (and (supervisor ?a ?s) (supervisor ?b ?s) (not (same ?a ?b)))))))

(define (rule? x) (and (pair? x) (eq? (car x) 'rule)))
(define (conclusion rule) (cadr rule))
(define (rule-body rule) (if (null? (cddr rule)) '(always-true) (caddr rule)))

; 規則を使うたびに変数を付け替える（別の呼び出しの変数と混ざらないように）
(define rule-counter 0)
(define (new-rule-application-id) (set! rule-counter (+ rule-counter 1)) rule-counter)
(define (make-new-variable var id) (cons '? (cons id (cdr var))))
(define (rename-variables-in rule)
  (let ((id (new-rule-application-id)))
    (define (tree-walk exp)
      (cond ((var? exp) (make-new-variable exp id))
            ((pair? exp) (cons (tree-walk (car exp)) (tree-walk (cdr exp))))
            (else exp)))
    (tree-walk rule)))

; --- 評価器 ---
; 質問と「今わかっている束縛の並び」を受け取り、束縛の並びを返す。
(define (qeval query frames)
  (cond ((eq? (car query) 'and) (conjoin (cdr query) frames))
        ((eq? (car query) 'or) (disjoin (cdr query) frames))
        ((eq? (car query) 'not) (negate (cdr query) frames))
        ((eq? (car query) 'lisp-value) (lisp-value (cdr query) frames))
        ((eq? (car query) 'always-true) frames)
        (else (simple-query query frames))))

(define (simple-query query-pattern frames)
  (append-map (lambda (frame)
                (append (find-assertions query-pattern frame)
                        (apply-rules query-pattern frame)))
              frames))
(define (append-map f lst)
  (if (null? lst) '() (append (f (car lst)) (append-map f (cdr lst)))))

(define (find-assertions pattern frame)
  (define (loop as acc)
    (if (null? as)
        (reverse acc)
        (let ((result (pattern-match pattern (car as) frame)))
          (loop (cdr as) (if (eq? result 'failed) acc (cons result acc))))))
  (loop assertions '()))

(define (apply-rules pattern frame)
  (append-map (lambda (rule) (apply-a-rule rule pattern frame)) rules))
(define (apply-a-rule rule query-pattern query-frame)
  (let ((clean-rule (rename-variables-in rule)))
    (let ((unify-result (unify-match query-pattern (conclusion clean-rule) query-frame)))
      (if (eq? unify-result 'failed)
          '()
          (qeval (rule-body clean-rule) (list unify-result))))))

(define (conjoin conjuncts frames)
  (if (null? conjuncts)
      frames
      (conjoin (cdr conjuncts) (qeval (car conjuncts) frames))))
(define (disjoin disjuncts frames)
  (if (null? disjuncts)
      '()
      (append (qeval (car disjuncts) frames) (disjoin (cdr disjuncts) frames))))
(define (negate operands frames)
  ; **否定は「今の束縛のもとで答えが無いこと」**。閉世界の仮定である
  (filter (lambda (frame) (null? (qeval (car operands) (list frame)))) frames))
(define (lisp-value call frames)
  (filter (lambda (frame)
            (let ((args (map (lambda (a) (instantiate a frame (lambda (v f) v)))
                             (cdr call))))
              (apply (lookup-lisp-value (car call)) args)))
          frames))
(define (lookup-lisp-value sym)
  (cond ((eq? sym '>) >) ((eq? sym '<) <) ((eq? sym '=) =)
        ((eq? sym 'even?) even?) ((eq? sym 'odd?) odd?)
        (else (error "Unknown lisp-value operator" sym))))

; 束縛を当てはめて、答えの形にする
(define (instantiate exp frame unbound-var-handler)
  (define (copy exp)
    (cond ((var? exp)
           (let ((binding (binding-in-frame exp frame)))
             (if binding (copy (binding-value binding)) (unbound-var-handler exp frame))))
          ((pair? exp) (cons (copy (car exp)) (copy (cdr exp))))
          (else exp)))
  (copy exp))

; 質問を1つ走らせ、答えを（重複を除いて）並べる
(define (ask query)
  (let ((q (query->internal query)))
    (define (dedup lst acc)
      (cond ((null? lst) (reverse acc))
            ((member (car lst) acc) (dedup (cdr lst) acc))
            (else (dedup (cdr lst) (cons (car lst) acc)))))
    (dedup (map (lambda (frame) (instantiate q frame (lambda (v f) v)))
                (qeval q (list the-empty-frame)))
           '())))

; --- 4.4.1 演繹的情報検索 ---
(check "職種で引く"
       (ask '(job ?x (engineering programmer)))
       '((job alice (engineering programmer)) (job bob (engineering programmer))))
(check "部分パターンでは合わない（照合は構造まで見る）"
       (ask '(job ?x programmer)) '())
(check "給与を引く" (ask '(salary bob ?amount)) '((salary bob 45000)))
(check "全部の給与" (length (ask '(salary ?p ?a))) 4)

(check "and で結ぶ"
       (ask '(and (job ?person (engineering programmer)) (salary ?person ?amount)))
       '((and (job alice (engineering programmer)) (salary alice 60000))
         (and (job bob (engineering programmer)) (salary bob 45000))))
; **答えは「質問全体に束縛を当てはめたもの」**（書籍の駆動ループと同じ）。
; だから or の両方の枝に、その回の ?p が入って出てくる。
(check "or で束ねる"
       (ask '(or (salary ?p 90000) (salary ?p 30000)))
       '((or (salary carol 90000) (salary carol 30000))
         (or (salary dave 90000) (salary dave 30000))))
(check "or が拾った人は2人"
       (map cadr (map cadr (ask '(or (salary ?p 90000) (salary ?p 30000)))))
       '(carol dave))
(check "not で除く"
       (length (ask '(and (job ?p ?j) (not (supervisor ?p carol))))) 1)
(check "lisp-value で絞る"
       (ask '(and (salary ?p ?a) (lisp-value > ?a 50000)))
       '((and (salary alice 60000) (lisp-value > 60000 50000))
         (and (salary carol 90000) (lisp-value > 90000 50000))))
(check "5万より上は2人"
       (length (ask '(and (salary ?p ?a) (lisp-value > ?a 50000)))) 2)
(check "3万より下は誰もいない"
       (ask '(and (salary ?p ?a) (lisp-value < ?a 30000))) '())

; --- 4.4.2〜4.4.4 規則 ---
(check "規則: 祖父母"
       (ask '(grandparent carol ?c))
       '((grandparent carol erin) (grandparent carol frank) (grandparent carol grace)))
(check "規則: 祖父母を逆から引く"
       (ask '(grandparent ?g erin)) '((grandparent carol erin)))
(check "規則: きょうだい"
       (ask '(sibling alice ?x)) '((sibling alice bob)))
(check "規則: 同僚（同じ上司を持ち、自分自身でない）"
       (ask '(colleague alice ?x))
       '((colleague alice bob) (colleague alice dave)))

; 再帰する規則。**親の関係が有限で循環しないので、リストでも止まる**
(check "規則: 先祖（1段）"     (ask '(ancestor alice ?d))
       '((ancestor alice erin) (ancestor alice frank)))
(check "規則: 先祖（2段まで辿る）"
       (ask '(ancestor carol ?d))
       '((ancestor carol alice) (ancestor carol bob)
         (ancestor carol erin) (ancestor carol frank) (ancestor carol grace)))
(check "規則: 先祖を逆から引く"
       (ask '(ancestor ?a grace)) '((ancestor bob grace) (ancestor carol grace)))

; 規則の変数は呼び出しごとに付け替えられている（混ざらない）
(check "同じ規則を2回使っても混ざらない"
       (equal? (ask '(grandparent carol ?c)) (ask '(grandparent carol ?c))) #t)
(check "変数の付け替えが起きている" (> rule-counter 10) #t)

; 束縛されない変数はそのまま出る
(check "答えに現れない変数は残る"
       (instantiate (query->internal '(f ?x ?y)) (list (cons '(? x) 'a))
                    (lambda (v f) '?))
       '(f a ?))

(summary "SICP 4.4")
