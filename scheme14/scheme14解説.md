# scheme14 解説文書

scheme13 のあと、scheme14 で新たに加わった機能の解説。
土台の処理系そのものは [`scheme13解説.md`](scheme13解説.md) にある。ここには差分だけを書く。

対象は `scheme14/scheme14.cpp`。`eval` と `system` と、`number->string` / `string->number` の基数は、このファイルに入っている。

---

## この文書の位置づけ

| 文書 | 何が書いてあるか | 読む人 |
| --- | --- | --- |
| **この文書** | **scheme14 で足したものがどう動くか。** 実装の解説。未実装の節は、その旨を見出しに書く | 使う人、読む人、直す人 |
| `scheme13解説.md` | scheme13 の時点の処理系全体 | 土台を知りたい人 |
| `dev_memo.md` | **なぜそう決めたか。** 設計憲章、凍結仕様、アーキテクチャ | 次に手を入れる人 |
| `micro_scheme8_notes.md` | 原典 `micro_Scheme8.lisp` の読解 | 由来を知りたい人 |

判断の根拠は `dev_memo.md` にある。`eval` は §4.5、`system` は §4.6、基数は §4.7。経緯は `log/decisions.md` の末尾「続報」。

振る舞いを変えたら、この文書も直す。

---

## 1. `eval`（2026-10-01 に実装）

R5RS 6.5 の4手続きである。どれも手続きで、`(procedure? eval)` は `TRUE`。特殊形式にはしていない。

```
(eval '(+ 1 2) (interaction-environment))   ; => 3
```

第1引数はすでにデータである式、第2引数は環境指定子である。フレーム（呼び出しの局所変数の並び）は値にしない。環境指定子は大域の表を指す別の値で、次の3つだけがある。同じ手続きを2回呼んだ結果は `eq?` で真。互いに比較すると偽。`read` では作れず、`write` すると次のように出る。

| 式 | 出力 |
| --- | --- |
| `(interaction-environment)` | `#<environment:interaction>` |
| `(scheme-report-environment 5)` | `#<environment:scheme-report>` |
| `(null-environment 5)` | `#<environment:null>` |

引数は整数 `5` だけを受け付ける。それ以外の整数は `argument out of range`、整数でないものは `wrong type of argument`。

### 1.1 三つの表

対話環境は、REPL と `load` が使っている大域の表そのものである。ここへの `define` と `set!` は、対話で束縛したのと同じセルを書く。

報告書の環境は、起動時ライブラリを読み終わった直後の写しである。セルは別物で、中の手続きオブジェクトは共有する。あとから対話環境で `define` したり、初期手続きを `set!` したりしても、写しの側は動かない。写しは起動の最後に1回だけ作る。最初に `scheme-report-environment` が呼ばれるまで遅らせると、その前にした利用者の定義が写しに混ざる。読み込み中にこの手続きを呼ぶと、今と同じ `unbound variable` になる。写しが終わったあとで、この手続き自身を対話環境と報告書の両方へ入れる。

空の環境には、組み込みの特殊形式と、シンボル `:undef` だけを写す。`+` も利用者の定義も無い。`:undef` を写すのは、`letrec` と `cond` の展開がこの大域を読むからである。無いと、空の環境での内部 `define` が `unbound variable: :undef` になる。

```
(eval '(+ 1 2) (scheme-report-environment 5))   ; => 3
(eval '(+ 1 2) (null-environment 5))            ; unbound variable: +
(eval '((lambda (x) x) 7) (null-environment 5)) ; => 7
(eval 'if (null-environment 5))                 ; 特殊形式 if
```

### 1.2 式は呼び出した機械の上で走る

`eval` は式を、いま動いているのと同じ仮想機械で実行する。別の機械は立てない。

コンパイルは空のコンパイル環境で行う。だから式は、`eval` を呼んだ手続きの局所変数を見ない。

```
(define x 2)
(let ((x 1))
  (eval 'x (interaction-environment)))   ; => 2
```

`x` は大域の `2` である。`let` の `1` は見えない。

組み込みの特殊形式は、どの環境でも、コンパイラが名前を見て先に判定する。`(let ((if list)) (if 1))` は `if` 式のままである。利用者のマクロは、その評価に渡した環境の表だけを見て展開する。対話環境で定義したマクロは、対話環境の `eval` では展開され、空の環境では展開されない。組み込みの `let` や `cond` の展開は、表を見ない。

本体の命令列は `RTN` で終わる。`load` や REPL が使う `STOP` は、機械の実行全体を戻してしまうので、ここには使わない。

通常のプリミティブは値を返してから呼んだ側へ戻る。`eval` はそうしない。引数を確かめて式をコンパイルし、クロージャを呼ぶときと同じ栈で、その命令列へ跳ぶ。末尾でなければ、戻り先をダンプに積み、スタックを引数の位置まで縮め、フレームを空にしてから跳ぶ。末尾ならダンプは積まず、いまの呼び出しの床まで縮める。`RTN` が結果を1つ残す。この位置がずれると、呼び出し元のスタックが壊れる。

登録上はプリミティブだが、機械は `eval` を見つけると、普通のプリミティブ呼び出しには入れない。値を返してから跳ぶ実装に戻すと、上の栈が合わなくなる。

コンパイルが失敗したときは、まだ跳んでいない。エラーはそのまま出る。対話環境では、失敗するまでに作った未束縛のセルが表に残ることがある。`load` や REPL も同じなので、`eval` だけでは片付けない。

### 1.3 継続

式は呼び出し元と同じ機械で走るので、式の中の `call/cc` は `eval` の呼び出し元まで含む。

```
(call/cc (lambda (k)
           (eval (list k 9) (interaction-environment))))   ; => 9
```

`(list k 9)` のデータには、継続オブジェクトそのものが入っている。リーダは継続を作れない。コンパイラは、式の中に現れた原子を定数として積む。

```
(call/cc (lambda (kk)
           (eval '(kk 9) (interaction-environment))))
```

こちらはシンボル `kk` を対話環境で引く。その `lambda` の継続にはならない。

式の中で捕まえた継続を、`eval` が戻ったあとから起動すると、その式の続きへ戻り、結果は `eval` の呼び出し元へ届く。`dynamic-wind` の入れ子も、機械が1本のまま見る。`(eval '(exit 0) ...)` は、いまの `exit` と同じくプロセスを終える。

別の機械のままにしているものは二つある。マクロ変換子と `load` である。変換子の中の代入は、そのマクロを定義したときに焼き込まれたセルを書く。報告書の環境でマクロを展開しても、変換子をコンパイルし直さない。`load` が読む各式は、今どおりロード側の実行である。どちらも、`eval` に渡した式の規則ではない。

### 1.4 定義と未束縛

大域の `define`、`define-macro`、大域への `set!` を受け付けるのは対話環境だけである。報告書や空の環境でコンパイルすると `bad syntax` になり、`note` は `accepted only in the interaction environment` と出る。

`lambda` の本体の先頭にある内部 `define` は、コンパイルの前に `letrec` へ書き換わる。局所変数への `set!` も、大域の表を書かない。どちらも環境指定子を書き換えないので、空の環境でも動く。

```
(eval '(begin (define zz 4) zz) (interaction-environment))  ; => 4
(eval '(define zz 4) (null-environment 5))                  ; bad syntax
```

未束縛の名前は、実行がそこへ到達したときに `unbound variable` で止まる。到達しなければ止まらない。`(if #f 無い名前 1)` は `1` である。

対話環境では、参照をコンパイルした時点でセルを表へ作る。先に使う定義が、これで後から埋まる。

```
(eval '(define (f) later) (interaction-environment))
(eval '(define later 8) (interaction-environment))
(eval '(f) (interaction-environment))   ; => 8
```

ほかの環境では、名前を持ったセルを命令のオペランドにはするが、表には入れない。入れると、拒否した定義の入れ物になる。

### 1.5 エラー

第2引数が環境指定子でなければ `eval: wrong type of argument`、`expected: an environment`。引数が2個でなければ `wrong number of arguments`。

式の中で起きたエラーの見出しは、その式を直に評価したときと同じである。`eval:` では包まない。ソース位置を持つ式は、そこを指す。`cons` で組んだ式は位置を持たないので、機械が `eval` を呼んだ位置を貼る。

---

## 2. `system`（2026-10-02 に実装）

規則は `dev_memo.md` §4.6 と同じである。Windows での呼び出しは §2.6、Linux と Unix での呼び出しは §2.7。どちらでも共通の置き方は §2.5。

Windows でディレクトリの作成と表示、作業ディレクトリの移動、ファイルの読み書き、コピー、移動、削除、終了コード、空白を含む引数を一度に見るスクリプトが `tests/system_win_test.scm` である。リポジトリのルートで次を実行する。

```
scheme14/scheme14.exe --load scheme14/tests/system_win_test.scm
```

2026-10-02 に、この Windows でそのスクリプトが通った。子の表示（`type` や `copy` のメッセージ）は端末へ出る。スクリプト自身の結果は `*** ALL SYSTEM CHECKS PASSED ***` である。`cmd.exe` は引用符の外にある `/` をスイッチとして読むので、このスクリプトはコマンドへ渡す経路の区切りを `\` にしている。

2026-10-03 に、この Linux で §2.7 の式を実行し、通った。実行ファイルは `make -C scheme14` が作る `scheme14/scheme14` である。子の表示は端末へ出る。

原典の `system` は、プログラム名と引数のリストを Common Lisp の `run-program` に渡していた。呼び出しの形は `(system prog arg1 (list ...))` で、引数を一つと、残りのリストとに分けていた。これは `run-program` がリストを要求していたことの写しなので、Scheme では残りの引数をそのまま並べる。

```
(system "git" "status")
(system "git")
```

第1引数はプログラム名、第2引数以降はそのプログラムの引数である。すべて文字列で、第1引数は必須、以降は何個でもよい。

引数はデータである。`&&` や `|` や引用符を、この手続きはシェルの文法として解釈しない。実行されるプログラムは第1引数だけである。`(system "echo" "a && rm x")` は、`echo` にその文字列を1引数として渡す。

`(procedure? system)` は `TRUE`。特殊形式にはしない。

### 2.1 OS の差は、この手続きの中だけに置く

プログラム名と引数の列でプロセスを起動する関数は、C++17 の標準には無い。Windows のビルドと、Linux および Unix のビルドとで、起動処理はコンパイル時にどちらか一方だけが残る。Scheme のプログラムが OS の名前を見て分岐する手続きは足さない。

- Linux と Unix では `posix_spawnp` で PATH を探し、`waitpid` で待つ。`fork` は使わない。この処理系は Boehm GC を使っていて、`fork` した子が GC のロックを抱えたままになることがある。
- Windows では `CreateProcess` で起動し、終了を待つ。プログラム名は `open-input-file` と同じバイト列で渡す。この処理系の中でワイド文字列へ変換しない。ディレクトリ区切りの無い名前は PATH から探し、拡張子が無ければ `.exe` を補う。引数の列は、Windows がコマンドラインを引数へ戻すときの規則で、この手続きが引用符を付けてから渡す。空の引数と、空白かタブを含む引数は二重引用符で囲む。引用符の直前にあるバックスラッシュは、引用符と合わせて倍にする。利用者が OS ごとに引用符を書くことはない。

新しいライブラリは足さない。`posix_spawnp` は libc、`CreateProcess` は Windows のビルドが既にリンクしている範囲である。`char-ready?` が POSIX と Windows で本体を分けているのと同じ置き方にする。

### 2.2 入出力と待ち

子プロセスには、scheme14 自身が OS から受け取った標準入力・標準出力・標準エラーを継がせる。出力は端末へそのまま出る。

Scheme の `current-output-port` には従わない。次の式は、ファイル `out` に `hi` を書かない。

```
(with-output-to-file "out"
  (lambda () (system "echo" "hi")))
```

`system` は子が終わるまで戻らない。裏で走らせる引数は無い。

### 2.3 戻り値とエラー

戻り値は終了コードの整数である。`0` が成功。

POSIX でプロセスがシグナルで終わったときは、`128` にそのシグナル番号を足した値を返す。Windows の終了コードは、255 を超えていても切らずに整数のまま返す。

起動できなかったとき（プログラムが無い、など）は終了コードを返さない。`system: cannot run program` とし、`given:` にプログラム名を書く。見出しの形は `open-input-file` がファイルを開けなかったときと同じである。

引数が0個なら `system: wrong number of arguments`。文字列でない引数は `system: wrong type of argument`、`expected: a string`。

### 2.4 採らなかった形

標準 C の `system` にコマンドライン文字列を一つ渡す形は採らない。ソースに OS の名前は要らないが、Windows 向けにリンクした C ライブラリはその文字列を `cmd.exe` に、Unix 向けは `sh` に渡す。同じ式が、ビルド先で別の言語になる。

子の標準出力を `current-output-port` へ繋ぐ形も採らない。原典は出力先を端末にしていた。ポートへの接続は、この手続きの範囲に入れない。

### 2.5 どちらでも同じ置き方

第1引数は起動するプログラムの名前、第2引数以降はそのプログラムの引数である。引数は Scheme の文字列を1個ずつ渡す。空白を含む文字列は、その1個の中に空白を書く。OS に渡すための引用符を、文字列の中へ足すことはない。

```
(system "git" "status")
(system "git" "diff" "--" "my file.scm")
```

2行目の最後の引数は、空白を含む1個のパスである。

出力を文字列として返す引数は無い。子の標準出力と標準エラーは、scheme14 を起動した端末へそのまま出る。中身を Scheme で読むときは、シェルにファイルへ書かせてから `open-input-file` で開く。

```
(define read1
  (lambda (path)
    (let* ((p (open-input-file path))
           (line (read-line p)))
      (close-input-port p)
      line)))
```

`cd` や `>` や `&&` や `|` は、プログラムの引数にはならない。それらはシェルの文法である。使うときだけ、シェルを第1引数にし、スクリプト全体をその次の1文字列にする。

- Windows では `(system "cmd.exe" "/c" "スクリプト")`。`"/c"` は「この文字列を実行して終了する」という `cmd.exe` のスイッチである。
- Linux と Unix では `(system "sh" "-c" "スクリプト")`。`"-c"` は同じ役割の `sh` のスイッチである。

この1文字列の中では、`>` も `&&` もシェルが解釈する。`(system "echo" "a > note.txt")` は、`echo` というプログラムに `a > note.txt` という文字列を1引数で渡す。ファイルはできない。

子の中で作業ディレクトリを変えても、その子が終わると変更は残らない。scheme14 自身の作業ディレクトリは動かない。移動先のパスが欲しいときは、子にそのパスをファイルへ書かせ、上の `read1` で読む。

`>` は、そのリダイレクトが付いているコマンドを実行するときの作業ディレクトリから解決される。`cd` のあとの `>` は、移動した先からの相対パスになる。

終了コードは整数で、`0` が成功である。引数の列はリストにまとめてから渡せる。`apply` は特殊形式なので、最後の引数がリストである。

```
(apply system (list "git" "status"))
```

### 2.6 Windows で使う

第1引数は実行ファイルの名前である。`where.exe` や `findstr.exe` や `attrib.exe` や `git.exe` はディスク上のプログラムなので、名前をそのまま第1引数にする。`cmd.exe` はここには要らない。

```
(system "where.exe" "cmd")
(system "findstr.exe" "/C:hello from" "work\\note.txt")          ; 見つかれば 0
(system "attrib.exe" "work\\note.txt")
(system "git" "status")
```

`mkdir` や `dir`、`type`、`copy`、`move`、`del`、`echo`、`cd` は、ディスク上のプログラムではない。`C:\Windows\System32` に `mkdir.exe` は無く、これらの名前は `cmd.exe` が自分の中に持っているコマンドである。`system` が起動できる相手は `cmd.exe` のほうなので、第1引数は `"cmd.exe"`、第2引数は `"/c"` になる。`"/c"` は `cmd.exe` に「続くコマンドを実行して、終わったら終了する」と伝えるスイッチである。その後ろの `"mkdir"` と `"work"` は、`cmd.exe` への引数である。

```
(system "cmd.exe" "/c" "mkdir" "work")
```

これは「`mkdir` を `system` の特別な書き方で呼ぶ」という意味ではない。起動しているプログラムは `cmd.exe` だけである。

拡張子の無い名前は、ディレクトリ区切りが無ければ `.exe` を補って PATH から探す。`(system "where" "cmd")` は `where.exe` を探す。`mkdir` には補う先の `mkdir.exe` が無い。

この節の残りの操作は、2026-10-02 にこの Windows で `tests/system_win_test.scm` が通した形である。子のメッセージ（`copy` が何ファイル写したか、など）は端末へ出る。`system` の値は終了コードだけである。`cmd.exe` は、引用符の外にある `/` をスイッチとして読む。`cmd.exe` へ渡す経路の区切りは `\` にする。Scheme の `open-input-file` は、同じファイルを `/` 区切りでも開けた。

ディレクトリを作り、ファイルを書き、読み戻す。

```
(system "cmd.exe" "/c" "mkdir" "work")
(system "cmd.exe" "/c" "mkdir" "work\\sub")
(system "cmd.exe" "/c" "echo hello from system>work\\note.txt")
(read1 "work/note.txt")                                          ; => "hello from system"
(system "cmd.exe" "/c" "type" "work\\note.txt")                  ; 端末に中身が出て、値は 0
```

一覧をファイルに取り、Scheme で行を見る。

```
(system "cmd.exe" "/c" "dir /b work > work\\listing.txt")
```

`dir /b work > work\listing.txt` は1文字列である。`>` を `cmd` に解釈させるため、引数を `"dir"` `"/b"` `"work"` と分けない。

作業ディレクトリの移動は子の中だけである。`cd` のあとの `>` は移動先から見たパスなので、一つ上へ書く。

```
(system "cmd.exe" "/c" "cd /d work\\sub && cd > ..\\cwd.txt")
(read1 "work/cwd.txt")                                           ; 行末は "\sub"
```

コピー、移動、削除。削除したあとの `dir` は、ファイルが無いので 0 以外を返す。エラーにはならない。

```
(system "cmd.exe" "/c" "copy" "/Y" "work\\note.txt" "work\\note-copy.txt")
(system "cmd.exe" "/c" "move" "/Y" "work\\note-copy.txt" "work\\sub\\moved.txt")
(read1 "work/sub/moved.txt")                                     ; => "hello from system"
(system "cmd.exe" "/c" "del" "/q" "work\\note.txt")
(system "cmd.exe" "/c" "dir" "work\\note.txt")                   ; => 0 以外
```

空白を含むディレクトリ名は、それ自身を1引数にする。

```
(system "cmd.exe" "/c" "mkdir" "work\\my files")
(system "cmd.exe" "/c" "echo spaced>work\\inside.txt")
(system "cmd.exe" "/c" "move" "/Y" "work\\inside.txt" "work\\my files\\inside.txt")
(read1 "work/my files/inside.txt")                               ; => "spaced"
```

`cmd /c` に渡す1文字列の中へ、空白のあるパスを引用符付きで書くと、cmd が引用符を剥がす規則と、この手続きが引用符を付ける規則が重なる。空白のあるパスへ書くときは、上のように一度空白の無い名前で書いてから `move` する。

終了コードはそのまま値になる。プログラム名が見つからないときは終了コードを返さず、エラーになる。`cmd.exe` が起動できて、その先の `dir` が失敗したときは、0 以外の整数が返る。

```
(system "cmd.exe" "/c" "exit" "7")                               ; => 7
(system "scheme14-no-such-program")                              ; system: cannot run program
(system "cmd.exe" "/c" "dir" "no-such-dir")                      ; 0 以外の整数
```

### 2.7 Linux と Unix で使う

呼び出しの形は §2.5 と同じで、起動するのはその OS のプログラムである。この節の式は POSIX 側の処理に合わせた使い方であり、この Windows ではその分岐がコンパイルされない。2026-10-03 に、この Linux でこの節の式を実行し、下の結果になった。子の表示（`ls` や `cat` や `grep` の出力）は端末へ出る。`system` の値は終了コードだけである。

`ls`、`mkdir`、`cp`、`mv`、`rm`、`cat`、`grep` は実行ファイルなので、第1引数にその名前を書く。PATH から探す。`/bin/ls` のように区切りを含む名前は、そのパスをそのまま使う。

ディレクトリを作り、ファイルを書き、読み戻す。書き込みは `sh` の文法なので、スクリプト全体を `"-c"` の次の1文字列にする。

```
(system "mkdir" "work")
(system "mkdir" "work/sub")
(system "mkdir" "work/my files")
(system "sh" "-c" "echo hello from system > work/note.txt")
(read1 "work/note.txt")                                          ; => "hello from system"
(system "ls" "-l" "work")                                        ; 端末に一覧が出て、値は 0
(system "cat" "work/note.txt")                                   ; 端末に中身が出て、値は 0
(system "grep" "hello from" "work/note.txt")                     ; 見つかれば 0
```

`grep` の第2引数は空白を含む1個の検索文字列である。この実行では、その行が端末に出て、値は 0 だった。

作業ディレクトリの移動は子の中だけである。`cd` と `&&` も `sh` の文法なので、同じように1文字列にする。`cd` のあとの `>` は移動先から見たパスなので、一つ上へ書く。

```
(system "sh" "-c" "cd work/sub && pwd > ../cwd.txt")
(read1 "work/cwd.txt")                                           ; 行末は "/sub"
```

`../cwd.txt` は、`cd` したあとの `work/sub` から見て一つ上である。できたファイルは `work/cwd.txt` で、中身はその移動先の絶対パスになる。§2.5 の `read1` で読む。

コピー、移動、削除。

```
(system "cp" "work/note.txt" "work/note-copy.txt")
(system "mv" "work/note-copy.txt" "work/sub/moved.txt")
(read1 "work/sub/moved.txt")                                     ; => "hello from system"
(system "rm" "work/note.txt")
```

`sh` はスクリプトの中の引用符を自分で読む。空白のあるパスへ書くときは、その引用符をスクリプトの1文字列の中に置く。

```
(system "sh" "-c" "echo spaced > 'work/my files/inside.txt'")
(read1 "work/my files/inside.txt")                               ; => "spaced"
```

終了コードは整数である。`true` は 0、`sh -c` に渡した `exit` の値がそのまま戻る。プログラム名が見つからないときは `system: cannot run program` で、終了コードは返らない。シグナルで終わったプロセスは、`128` にそのシグナル番号を足した値を返す。`SIGTERM` の番号は 15 なので、この実行では 143 だった。起動できたあとにコマンドが失敗したときは、0 以外の整数が返る。この Linux の `ls` は、無いパスに対して 2 を返した。

```
(system "true")                                                  ; => 0
(system "sh" "-c" "exit 7")                                      ; => 7
(system "sh" "-c" "kill -TERM $$")                               ; => 143
(system "scheme14-no-such-program")                              ; system: cannot run program
(system "ls" "no-such-dir")                                      ; => 2
```

---

## 3. `number->string` と `string->number` の基数（2026-10-03 に実装）

規則は `dev_memo.md` §4.7 と同じである。2026-10-03 に、この Windows の `--selftest` で下の式を確認した。370 checks, 0 failed のうち、基数の分が入っている。

```
(number->string 255)          ; => "255"
(string->number "255")        ; => 255
(string->number "1.5")        ; => 1.5
(number->string 255 16)       ; => "ff"
```

ソースに直接書ける数は 10 進である。16進で欲しい値は、10進の整数として書くか、16進の文字列を `string->number` で読む。機械の中の値は正確な整数で、10進や16進という区別は、文字列に出すときと文字列から読むときにだけ付く。

```
(number->string 255 16)       ; => "ff"
(string->number "ff" 16)      ; => 255
```

### 3.1 引数が1個のときと、基数が 10 のとき

この二つは、今の10進の経路をそのまま使う。`number->string` は `write` と同じ表示、`string->number` はリーダと同じ読み取りである。実数、`+inf.0`、`+nan.0` も今どおり読む。10進の書式は一つだけにする。

```
(number->string 1.5)          ; => "1.5"
(number->string 1.5 10)       ; => "1.5"
(string->number "1.5" 10)     ; => 1.5
(string->number "+inf.0")     ; => +inf.0
```

第2引数を省略したときは、基数 10 とみなす。

### 3.2 2、8、16 は正確な整数だけ

基数は正確な整数で、2、8、10、16 のいずれかである。2、8、16 の対象は正確な整数だけである。

```
(number->string 255 16)        ; => "ff"
(number->string 255 8)         ; => "377"
(number->string 255 2)         ; => "11111111"
(number->string -255 16)       ; => "-ff"
(number->string 0 2)           ; => "0"
(string->number "ff" 16)       ; => 255
(string->number "FF" 16)       ; => 255
(string->number "377" 8)       ; => 255
(string->number "11111111" 2)  ; => 255
(string->number "+10" 16)      ; => 16
(string->number "-0" 16)       ; => 0
(string->number "00ff" 16)     ; => 255
```

出力に `#x` や `#b` は付けない。16進の `a` から `f` は小文字である。負なら先頭に `-` を付ける。正に `+` は付けない。余分な先頭の 0 は付けない。0 は `"0"` である。桁数の上限は置かない。2の100乗は16進で `1` のあとに `0` が25個であり、2026-10-03 の `--selftest` で確認した。

```
(number->string (string->number "1267650600228229401496703205376") 16)
                                  ; => "10000000000000000000000000"
```

読み取りは、文字列全体が「符号が任意で1つ、その後にその基数の数字が1つ以上」のときだけ正確な整数を返す。2進は `0` と `1`、8進は `0` から `7`、16進は `0` から `9` と `a` から `f` である。入力の大文字と小文字は同じ数字である。先頭の 0 は許す。`"-0"` の値は正確な 0 である。

空白、小数点、指数、`#` で始まる接頭辞は受けない。形が外れたらエラーにせず `false` を返す。

```
(string->number "1.5" 16)      ; => false
(string->number "#xff" 16)     ; => false
(string->number "ff" 2)        ; => false
(string->number "" 16)         ; => false
(string->number "+" 16)        ; => false
```

正確な整数 `n` と基数 `r`（2、8、10、16）について、次は真になる。

```
(eqv? n (string->number (number->string n r) r))
```

### 3.3 エラー

個数は 1 個または 2 個である。0 個や 3 個以上は `wrong number of arguments`、`expected: 1 to 2 arguments`。

基数の検査は、第1引数が手続きの求める型だと分かったあとで行う。数でないものを `number->string` に渡すと、基数より先に `expected: a number` で止まる。文字列でないものを `string->number` に渡すと、`expected: a string` で止まる。

```
(number->string "ff" 16)       ; number->string: wrong type of argument
                               ;   expected: a number
(string->number 255 16)        ; string->number: wrong type of argument
                               ;   expected: a string
```

基数そのものが正確な整数でなければ `wrong type of argument`、`expected: an integer`。`16.0` はここである。正確な整数だが 2、8、10、16 のどれでもなければ `argument out of range`、`expected: 2, 8, 10, or 16`。

```
(number->string 255 16.0)      ; wrong type of argument
                               ;   expected: an integer
(number->string 255 3)         ; argument out of range
                               ;   expected: 2, 8, 10, or 16
```

基数が 2、8、16 で、変換する数が正確な整数でなければ `wrong type of argument`、`expected: an exact integer`。`8.0` や `1.5` や `+inf.0` はここである。

```
(number->string 1.5 16)        ; wrong type of argument
                               ;   expected: an exact integer
(number->string 8.0 2)         ; wrong type of argument
                               ;   expected: an exact integer
```

### 3.4 リーダは変えない

ソースに書いた `#b` `#o` `#d` `#x` `#e` `#i` は、数の接頭辞にしない。`#xff` はシンボルとして読まれる。それを評価すると `unbound variable: #xff` になる。整数が欲しいときは `(string->number "xff" 16)` と書く。2、8、16 の変換は、その基数が渡されたときのこの2手続きの中だけに置く。

### 3.5 採らなかった形

2、8、16 で不正確な数も出す形は採らない。倍精度を、読み戻すと同じビットになる別の基数で書く仕事は、10進の表示とは別になる。

リーダに `#xff` や `#b101` を足す形も採らない。数のトークンの規則は凍結してある。

2、8、10、16 以外の基数を受ける形も採らない。出力を大文字にする形、`#x` を付ける形も採らない。往復で戻る文字列を一つに決めるためである。
