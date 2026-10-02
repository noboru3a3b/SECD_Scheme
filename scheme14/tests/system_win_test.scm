;;; Windows で system が実際のコマンドを走らせられるかの確認。
;;; ゴールデンには入れない。scheme14 のディレクトリからではなく、
;;; リポジトリのルートで --load する。

(define fails 0)
(define root "scheme14/system_try")

;;; cmd は引用符の外の / をスイッチとして読む。コマンドに渡す経路は \ にする。
(define slash (string-ref "/" 0))
(define backslash (string-ref "\\" 0))
(define win
  (lambda (path)
    (list->string
     (map (lambda (c) (if (char=? c slash) backslash c))
          (string->list path)))))

(define note
  (lambda (name ok)
    (display (if ok "[PASS] " "[FAIL] "))
    (display name)
    (newline)
    (if (not ok) (set! fails (+ fails 1)))))

(define read1
  (lambda (path)
    (let* ((p (open-input-file path))
           (line (read-line p)))
      (close-input-port p)
      line)))

(define run
  (lambda (name expected . args)
    (note name (= (apply system args) expected))))

(display "=== system on Windows ===")
(newline)

(system "cmd.exe" "/c" "rmdir" "/s" "/q" (win root))
(run "mkdir work tree" 0 "cmd.exe" "/c" "mkdir" (win root))
(run "mkdir subdir" 0 "cmd.exe" "/c" "mkdir" (win (string-append root "/sub")))
(run "mkdir name with space" 0 "cmd.exe" "/c" "mkdir" (win (string-append root "/my files")))

(run "write a file" 0 "cmd.exe" "/c"
     (string-append "echo hello from system>" (win (string-append root "/note.txt"))))
(note "read the file back" (equal? (read1 (string-append root "/note.txt"))
                                    "hello from system"))
(run "type (file read)" 0 "cmd.exe" "/c" "type" (win (string-append root "/note.txt")))

(run "dir /b into a file" 0 "cmd.exe" "/c"
     (string-append "dir /b " (win root) " > " (win (string-append root "/listing.txt"))))
(note "listing contains note.txt"
      (let ((p (open-input-file (string-append root "/listing.txt"))))
        (let loop ((line (read-line p)) (saw false))
          (if (eof-object? line)
              (begin (close-input-port p) saw)
              (loop (read-line p) (or saw (equal? line "note.txt")))))))

;;; cd の後の > は、移動先からの相対パスになる。
(run "cd into sub and record cwd" 0 "cmd.exe" "/c"
     (string-append "cd /d " (win (string-append root "/sub"))
                    " && cd > ..\\cwd.txt"))
(note "cwd ends in sub"
      (let* ((line (read1 (string-append root "/cwd.txt")))
             (n (string-length line))
             (m (string-length "\\sub")))
        (and (>= n m)
             (string=? (substring line (- n m) n) "\\sub"))))

(run "copy" 0 "cmd.exe" "/c" "copy" "/Y"
     (win (string-append root "/note.txt"))
     (win (string-append root "/note-copy.txt")))
(note "copy has the same text"
      (equal? (read1 (string-append root "/note-copy.txt")) "hello from system"))

(run "move" 0 "cmd.exe" "/c" "move" "/Y"
     (win (string-append root "/note-copy.txt"))
     (win (string-append root "/sub/moved.txt")))
(note "moved file is readable"
      (equal? (read1 (string-append root "/sub/moved.txt")) "hello from system"))

(run "write a file to move" 0 "cmd.exe" "/c"
     (string-append "echo spaced>" (win (string-append root "/inside.txt"))))
(run "move into a spaced directory" 0 "cmd.exe" "/c" "move" "/Y"
     (win (string-append root "/inside.txt"))
     (win (string-append root "/my files/inside.txt")))
(note "spaced path reads back"
      (equal? (read1 (string-append root "/my files/inside.txt")) "spaced"))

(run "findstr keeps a spaced argument as one" 0
     "findstr.exe" "/C:hello from" (win (string-append root "/note.txt")))
(run "where cmd" 0 "where.exe" "cmd")
(run "attrib" 0 "attrib.exe" (win (string-append root "/note.txt")))
(run "exit status 7 is a value" 7 "cmd.exe" "/c" "exit" "7")
(note "missing directory is a status, not an error"
      (let ((code (system "cmd.exe" "/c" "dir" "scheme14-no-such-dir")))
        (and (number? code) (not (= code 0)))))
(run "delete a file" 0 "cmd.exe" "/c" "del" "/q" (win (string-append root "/note.txt")))
(run "removed file is gone" 1 "cmd.exe" "/c" "dir" (win (string-append root "/note.txt")))

(system "cmd.exe" "/c" "rmdir" "/s" "/q" (win root))

(newline)
(if (= fails 0)
    (begin (display "*** ALL SYSTEM CHECKS PASSED ***") (newline) (exit 0))
    (begin (display "*** ") (display fails) (display " FAILED ***") (newline) (exit 1)))
