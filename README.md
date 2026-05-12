# SECD_Scheme
SECD_Scheme was developed after the development of SECD_Scheme8, incorporating the lessons learned from that project.
SECD_Scheme8 ended up with a dual design using both the SECD vm and the eval interpreter, a problem that could not be resolved until the end.
However, SECD_Scheme8 did have a unique mark-and-sweep type garbage collector design, which can be considered an achievement.
During the development of SECD_Scheme8, efforts were made to process multi-shot continuations as much as possible with the SECD vm, but ultimately it didn't work out.
It ended up being processed with the eval interpreter.

Therefore, with a fresh start, SECD_Scheme was developed with the focus on processing everything, including multi-shot continuations, with the SECD vm.
This time, we also devised a way to use AI: the AI ​​with limbs handled the implementation work, while the intelligent AI handled the basic design.
The actual actions taken are as follows:

- I consulted with Cursor's AI about writing a C++ version of a Scheme compiler that processes everything on the VM.

- I provided micro_Scheme8.lisp, mlib7.scm, and test-case6.scm as reference implementations.

- As a result, a C++ version of the Scheme compiler started working, which could process everything on the VM (although garbage collection was done using a reference counter method).

- At this point, there weren't many working primitives, but the fact that the continuation of multishots was entirely handled by the SECD VM was a significant advantage.

- Afterwards, I consulted with another AI (Claude 4.5 Sonnet) and had them switch the GC from a reference counter-based approach to using Boehm GC.

- I also consulted with him about infinite-precision integers, and he implemented infinite-precision integers using the Boost library.

- During this time, GitHub Copilot acted as an AI with limbs, responsible for the implementation, testing, and debugging of the C++ version.

- I asked Claude 4.5 Sonnet to implement file input/output functionality. He got it working perfectly with just one try.

- After that, We implemented string and vector manipulation. Once again, Claude 4.5 Sonnet played a crucial role.

- After that, We implemented Debugger in System. Once again, Claude 4.5 Sonnet played a crucial role.

- Then, we had GPT-5 Thinking create the system's instruction manual. It turned out he was incredibly clever.

- Implemented a red-black tree library and wrote test scripts. Author: Claude 4.5 Sonnet.  
  
- Also implemented a random number generation function in the system for stress testing of the red-black tree. Author: Claude 4.5 Sonnet.  
  
SECD_Scheme is not something I created; it's a C++ version of a Scheme compiler that uses the complete SECD VM method, developed through the collaboration of various AIs.  
  
I have built and tested this on clang++ on Ubuntu-24.04 and FreeBSD 15.0-RELEASE, and g++ on Windows 11.  
  
Compiler on Ubuntu:  
```
> clang++ -v  
Ubuntu clang version 18.1.3 (1ubuntu1)  
Target: x86_64-pc-linux-gnu  
Thread model: posix  
InstalledDir: /usr/bin  
Found candidate GCC installation: /usr/bin/../lib/gcc/x86_64-linux-gnu/13  
Found candidate GCC installation: /usr/bin/../lib/gcc/x86_64-linux-gnu/14  
Selected GCC installation: /usr/bin/../lib/gcc/x86_64-linux-gnu/14  
Candidate multilib: .;@m64  
Selected multilib: .;@m64  
```
Compiler on FreeBSD:  
```
> clang++ -v  
FreeBSD clang version 19.1.7 (https://github.com/llvm/llvm-project.git llvmorg-19.1.7-0-gcd708029e0b2)  
Target: x86_64-unknown-freebsd15.0  
Thread model: posix  
InstalledDir: /.bastille/usr/bin  
```
Compiler on Windows 11:  
```
> g++ -v  
Using built-in specs.  
COLLECT_GCC=C:\w64devkit\bin\g++.exe  
COLLECT_LTO_WRAPPER=C:/w64devkit/bin/../libexec/gcc/x86_64-w64-mingw32/15.2.0/lto-wrapper.exe  
Target: x86_64-w64-mingw32  
Configured with: /dl/gcc/configure --prefix=/w64devkit --with-sysroot=/w64devkit --with-native-system-header-dir=/include --target=x86_64-w64-mingw32 --host=x86_64-w64-mingw32 --enable-static --disable-shared --with-pic --with-gmp=/deps --with-mpc=/deps --with-mpfr=/deps --enable-languages=c,c++,fortran --enable-libgomp --enable-threads=posix --enable-version-specific-runtime-libs --disable-libstdcxx-verbose --disable-dependency-tracking --disable-lto --disable-multilib --disable-nls --disable-win32-registry --enable-mingw-wildcard CFLAGS_FOR_TARGET=-O2 CXXFLAGS_FOR_TARGET=-O2 LDFLAGS_FOR_TARGET=-s CFLAGS=-O2 CXXFLAGS=-O2 LDFLAGS=-s
Thread model: posix  
Supported LTO compression algorithms: zlib  
gcc version 15.2.0 (GCC)  
```
  
Installing the compiler on Windows 11 was done using w64devkit.  
C:\w64devkit  
  
Download and extract boost_1_91_0.zip and place it directly under the directory c:\ .  
C:\boost_1_91_0  
  
## Usage:  
```
PS C:\Users\user\SECD_Scheme> make clean  
rm -f scheme12_bignum scheme12_bignum.exe libgc-1.dll libgccpp-1.dll  
PS C:\Users\user\SECD_Scheme> make  
g++ -std=c++17 -Wall -Wextra -O2 -Wno-unused-function -Igc-8.2.12/include -IC:/boost_1_91_0 -o scheme12_bignum scheme12_bignum_boost.cpp -Lgc-8.2.12/.libs -lgc -lgccpp  
PS C:\Users\user\SECD_Scheme> .\scheme12_debug.exe
scheme12 debug REPL. Type (help) for commands.
scheme12> primes
#<closure:(queue x xmax)>
scheme12> make-queue
#<closure:(x)>
scheme12> (primes (make-queue 2) 3 10000)
(2 3 5 7 11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71 73 79 83 89 97 101 103 107 109 113 127 131 137 139 149 151 157 163 167 173 179 181 191 193 197 199 211 223 227 229 233 239 241 251 257 263 269 271 277 281 283 293 307 311 313 317 331 337 347 349 353 359 367 373 379 383 389 397 401 409 419 421 431 433 439 443 449 457 461 463 467 479 487 491 499 503 509 521 523 541 547 557 563 569 571 577 587 593 599 601 607 613 617 619 631 641 643 647 653 659 661 673 677 683 691 701 709 719 727 733 739 743 751 757 761 769 773 787 797 809 811 821 823 827 829 839 853 857 859 863 877 881 883 887 907 911 919 929 937 941 947 953 967 971 977 983 991 997 1009 1013 1019 1021 1031 1033 1039 1049 1051 1061 1063 1069 1087 1091 1093 1097 1103 1109 1117 1123 1129 1151 1153 1163 1171 1181 1187 1193 1201 1213 1217 1223 1229 1231 1237 1249 1259 1277 1279 1283 1289 1291 1297 1301 1303 1307 1319 1321 1327 1361 1367 1373 1381 1399 1409 1423 1427 1429 1433 1439 1447 1451 1453 1459 1471 1481 1483 1487 1489 1493 1499 1511 1523 1531 1543 1549 1553 1559 1567 1571 1579 1583 1597 1601 1607 1609 1613 1619 1621 1627 1637 1657 1663 1667 1669 1693 1697 1699 1709 1721 1723 1733 1741 1747 1753 1759 1777 1783 1787 1789 1801 1811 1823 1831 1847 1861 1867 1871 1873 1877 1879 1889 1901 1907 1913 1931 1933 1949 1951 1973 1979 1987 1993 1997 1999 2003 2011 2017 2027 2029 2039 2053 2063 2069 2081 2083 2087 2089 2099 2111 2113 2129 2131 2137 2141 2143 2153 2161 2179 2203 2207 2213 2221 2237 2239 2243 2251 2267 2269 2273 2281 2287 2293 2297 2309 2311 2333 2339 2341 2347 2351 2357 2371 2377 2381 2383 2389 2393 2399 2411 2417 2423 2437 2441 2447 2459 2467 2473 2477 2503 2521 2531 2539 2543 2549 2551 2557 2579 2591 2593 2609 2617 2621 2633 2647 2657 2659 2663 2671 2677 2683 2687 2689 2693 2699 2707 2711 2713 2719 2729 2731 2741 2749 2753 2767 2777 2789 2791 2797 2801 2803 2819 2833 2837 2843 2851 2857 2861 2879 2887 2897 2903 2909 2917 2927 2939 2953 2957 2963 2969 2971 2999 3001 3011 3019 3023 3037 3041 3049 3061 3067 3079 3083 3089 3109 3119 3121 3137 3163 3167 3169 3181 3187 3191 3203 3209 3217 3221 3229 3251 3253 3257 3259 3271 3299 3301 3307 3313 3319 3323 3329 3331 3343 3347 3359 3361 3371 3373 3389 3391 3407 3413 3433 3449 3457 3461 3463 3467 3469 3491 3499 3511 3517 3527 3529 3533 3539 3541 3547 3557 3559 3571 3581 3583 3593 3607 3613 3617 3623 3631 3637 3643 3659 3671 3673 3677 3691 3697 3701 3709 3719 3727 3733 3739 3761 3767 3769 3779 3793 3797 3803 3821 3823 3833 3847 3851 3853 3863 3877 3881 3889 3907 3911 3917 3919 3923 3929 3931 3943 3947 3967 3989 4001 4003 4007 4013 4019 4021 4027 4049 4051 4057 4073 4079 4091 4093 4099 4111 4127 4129 4133 4139 4153 4157 4159 4177 4201 4211 4217 4219 4229 4231 4241 4243 4253 4259 4261 4271 4273 4283 4289 4297 4327 4337 4339 4349 4357 4363 4373 4391 4397 4409 4421 4423 4441 4447 4451 4457 4463 4481 4483 4493 4507 4513 4517 4519 4523 4547 4549 4561 4567 4583 4591 4597 4603 4621 4637 4639 4643 4649 4651 4657 4663 4673 4679 4691 4703 4721 4723 4729 4733 4751 4759 4783 4787 4789 4793 4799 4801 4813 4817 4831 4861 4871 4877 4889 4903 4909 4919 4931 4933 4937 4943 4951 4957 4967 4969 4973 4987 4993 4999 5003 5009 5011 5021 5023 5039 5051 5059 5077 5081 5087 5099 5101 5107 5113 5119 5147 5153 5167 5171 5179 5189 5197 5209 5227 5231 5233 5237 5261 5273 5279 5281 5297 5303 5309 5323 5333 5347 5351 5381 5387 5393 5399 5407 5413 5417 5419 5431 5437 5441 5443 5449 5471 5477 5479 5483 5501 5503 5507 5519 5521 5527 5531 5557 5563 5569 5573 5581 5591 5623 5639 5641 5647 5651 5653 5657 5659 5669 5683 5689 5693 5701 5711 5717 5737 5741 5743 5749 5779 5783 5791 5801 5807 5813 5821 5827 5839 5843 5849 5851 5857 5861 5867 5869 5879 5881 5897 5903 5923 5927 5939 5953 5981 5987 6007 6011 6029 6037 6043 6047 6053 6067 6073 6079 6089 6091 6101 6113 6121 6131 6133 6143 6151 6163 6173 6197 6199 6203 6211 6217 6221 6229 6247 6257 6263 6269 6271 6277 6287 6299 6301 6311 6317 6323 6329 6337 6343 6353 6359 6361 6367 6373 6379 6389 6397 6421 6427 6449 6451 6469 6473 6481 6491 6521 6529 6547 6551 6553 6563 6569 6571 6577 6581 6599 6607 6619 6637 6653 6659 6661 6673 6679 6689 6691 6701 6703 6709 6719 6733 6737 6761 6763 6779 6781 6791 6793 6803 6823 6827 6829 6833 6841 6857 6863 6869 6871 6883 6899 6907 6911 6917 6947 6949 6959 6961 6967 6971 6977 6983 6991 6997 7001 7013 7019 7027 7039 7043 7057 7069 7079 7103 7109 7121 7127 7129 7151 7159 7177 7187 7193 7207 7211 7213 7219 7229 7237 7243 7247 7253 7283 7297 7307 7309 7321 7331 7333 7349 7351 7369 7393 7411 7417 7433 7451 7457 7459 7477 7481 7487 7489 7499 7507 7517 7523 7529 7537 7541 7547 7549 7559 7561 7573 7577 7583 7589 7591 7603 7607 7621 7639 7643 7649 7669 7673 7681 7687 7691 7699 7703 7717 7723 7727 7741 7753 7757 7759 7789 7793 7817 7823 7829 7841 7853 7867 7873 7877 7879 7883 7901 7907 7919 7927 7933 7937 7949 7951 7963 7993 8009 8011 8017 8039 8053 8059 8069 8081 8087 8089 8093 8101 8111 8117 8123 8147 8161 8167 8171 8179 8191 8209 8219 8221 8231 8233 8237 8243 8263 8269 8273 8287 8291 8293 8297 8311 8317 8329 8353 8363 8369 8377 8387 8389 8419 8423 8429 8431 8443 8447 8461 8467 8501 8513 8521 8527 8537 8539 8543 8563 8573 8581 8597 8599 8609 8623 8627 8629 8641 8647 8663 8669 8677 8681 8689 8693 8699 8707 8713 8719 8731 8737 8741 8747 8753 8761 8779 8783 8803 8807 8819 8821 8831 8837 8839 8849 8861 8863 8867 8887 8893 8923 8929 8933 8941 8951 8963 8969 8971 8999 9001 9007 9011 9013 9029 9041 9043 9049 9059 9067 9091 9103 9109 9127 9133 9137 9151 9157 9161 9173 9181 9187 9199 9203 9209 9221 9227 9239 9241 9257 9277 9281 9283 9293 9311 9319 9323 9337 9341 9343 9349 9371 9377 9391 9397 9403 9413 9419 9421 9431 9433 9437 9439 9461 9463 9467 9473 9479 9491 9497 9511 9521 9533 9539 9547 9551 9587 9601 9613 9619 9623 9629 9631 9643 9649 9661 9677 9679 9689 9697 9719 9721 9733 9739 9743 9749 9767 9769 9781 9787 9791 9803 9811 9817 9829 9833 9839 9851 9857 9859 9871 9883 9887 9901 9907 9923 9929 9931 9941 9949 9967 9973)
scheme12> fact
#<closure:(n a)>
scheme12> (fact 50 1)
30414093201713378043612608166064768844377641568960512000000000000
scheme12> (disassemble fact)

=== Disassembly ===
Parameters: (n a)
Body:
  [  0] LD (0 . 0)
  [  1] LDC 0
  [  2] ARGS 2
  [  3] LDG =
  [  4] APP
  [  5] SEL
    THEN:
      [  0] LD (0 . 1)
      [  1] JOIN

    ELSE:
      [  0] LD (0 . 0)
      [  1] LDC 1
      [  2] ARGS 2
      [  3] LDG -
      [  4] APP
      [  5] LD (0 . 1)
      [  6] LD (0 . 0)
      [  7] ARGS 2
      [  8] LDG *
      [  9] APP
      [ 10] ARGS 2
      [ 11] LDG fact
      [ 12] TAPP
      [ 13] JOIN

  [  6] RTN
Environment: 0 frame(s)
===================
:disassembled
scheme12> (load "list_test1.scm")
(a b c d e f)
((a b) (c d) e f g)
(e d c b a)
((d e) c (a b))
(a b c d e)
(c d e)
FALSE
(a 1)
(e 5)
FALSE
(a b c d e)
((1) (2) (3) (4) (5))
((a . a) (b . b) (c . c) (d . d) (e . e))
(b c b c b c)
(((((NIL . a) . b) . c) . d) . e)
(a b c d e)
NIL
scheme12> (string? "Hello")
TRUE
scheme12> (string-length "Hello")
5
scheme12> (string-ref "Hello" 1)
"e"
scheme12> (vector? #(1 2 3))
TRUE
scheme12> (vector-length #(1 2 3))
3
scheme12> (vector-ref #(a b c) 1)
b
scheme12> (load "rbtree_stress_test_safe.scm")

Red-Black Tree Library (Improved) loaded.
Commands:
  (rb-test)      - Run comprehensive tests
  (rb-example)   - Run simple example

Red-Black Tree Stress Test Library (Safe) loaded.
Commands:
  (rb-quick-test)             - Quick 100 insertions test
  (rb-small-scale-test)       - 500 insertions, 250 deletions
  (rb-medium-scale-test)      - 2000 insertions, 1000 deletions
  (rb-large-scale-test-safe)  - Safe large-scale test
  (gc-info)                   - Show GC information
  (gc-collect)                - Force garbage collection
NIL
scheme12> (rb-test)

=== Red-Black Tree Test ===

Inserting: 10, 5, 20, 15, 30, 25, 35, 3, 7, 40, 45, 11, 12

Keys in order: (3 5 7 10 11 12 15 20 25 30 35 40 45)

Tree is valid (black height: 4)

Searching for key 15: ddd

Deleting key 10
Keys in order: (3 5 7 11 12 15 20 25 30 35 40 45)
Tree is valid (black height: 4)

Deleting key 20
Keys in order: (3 5 7 11 12 15 25 30 35 40 45)
Tree is valid (black height: 4)

Tree structure:
Tree structure (key:color):
    45:B
  40:B
    35:B
      30:R
25:B
    15:B
      12:R
  11:B
      7:B
    5:R
      3:B


=== Stress Test ===
Inserting 0-49...
Node count: 50
Tree is valid (black height: 6)

Deleting even numbers...
Node count: 25
Remaining keys: (1 3 5 7 9 11 13 15 17 19 21 23 25 27 29 31 33 35 37 39 41 43 45 47 49)
Tree is valid (black height: 5)

=== Test Complete ===
#(#(#(#(#(":nil" ":nil" 0 1 1) #(":nil" ":nil" 0 5 5) 0 3 3) #(#(":nil" ":nil" 0 9 9) #(":nil" ":nil" 0 13 13) 0 11 11) 0 7 7) #(#(#(":nil" ":nil" 0 17 17) #(":nil" ":nil" 0 21 21) 0 19 19) #(#(":nil" ":nil" 0 25 25) #(":nil" ":nil" 0 29 29) 0 27 27) 0 23 23) 1 15 15) #(#(#(":nil" ":nil" 0 33 33) #(":nil" ":nil" 0 37 37) 0 35 35) #(#(#(":nil" ":nil" 0 41 41) #(":nil" ":nil" 0 45 45) 1 43 43) #(":nil" ":nil" 0 49 49) 0 47 47) 0 39 39) 0 31 31)
scheme12> (rb-example)

=== Simple Example ===
Search 50: fifty
All keys: (25 50 75 100 150)
Tree is valid (black height: 3)

Tree structure (key:color):
  150:B
100:B
    75:B
  50:R
    25:B

#(#(#(":nil" ":nil" 0 25 "twenty-five") #(":nil" ":nil" 0 75 "seventy-five") 1 50 "fifty") #(":nil" ":nil" 0 150 "one-fifty") 0 100 "hundred")
scheme12> (gc-info)
Heap size: 4718592 bytes, Free: 16384 bytes
NIL
scheme12> (rb-large-scale-test-safe)

=== Large-Scale Stress Test (Safe) ===
Test 1: 1000 insertions, 500 deletions
=== Mixed Random Operations Test (Safe) ===
Phase 1: Insert 1000 keys

=== Random Insertion Test (with GC) ===
Inserting 1000 random keys (range: 0-9999)
Generated keys (sample): (7831 7469 6578 977 5671 2824 9013 8894 109 5757 7157 5261 8119 6895 8229 4175 6529 5248 7654 1088 . ..)
Heap size: 5218304 bytes, Free: 462848 bytes

[Forcing GC...] Heap size: 5218304 bytes, Free: 479232 bytes
Progress: 100/1000 Heap size: 4792320 bytes, Free: 8192 bytes
Progress: 200/1000 Heap size: 4788224 bytes, Free: 0 bytes
Progress: 300/1000 Heap size: 4780032 bytes, Free: 0 bytes
Progress: 400/1000 Heap size: 4775936 bytes, Free: 0 bytes
Progress: 500/1000 Heap size: 4780032 bytes, Free: 0 bytes
Progress: 600/1000 Heap size: 4788224 bytes, Free: 0 bytes
Progress: 700/1000 Heap size: 4784128 bytes, Free: 0 bytes
Progress: 800/1000 Heap size: 4784128 bytes, Free: 0 bytes
Progress: 900/1000 Heap size: 4780032 bytes, Free: 0 bytes

Final node count: 962
Heap size: 4861952 bytes, Free: 0 bytes
Tree is valid (black height: 9)
Phase 2: Delete 500 keys

=== Random Deletion Test (with GC) ===
Deleting 500 random keys
Heap size: 4874240 bytes, Free: 24576 bytes

[Forcing GC...] Heap size: 4874240 bytes, Free: 57344 bytes
Progress: 100/500 Heap size: 16146432 bytes, Free: 2097152 bytes
Progress: 200/500 Heap size: 26472448 bytes, Free: 2949120 bytes
Progress: 300/500 Heap size: 33095680 bytes, Free: 2924544 bytes
Progress: 400/500 Heap size: 41373696 bytes, Free: 3616768 bytes

Final node count: 462
Heap size: 53956608 bytes, Free: 11919360 bytes
Tree is valid (black height: 8)

Test 2: 3000 insertions, 1500 deletions
=== Mixed Random Operations Test (Safe) ===
Phase 1: Insert 3000 keys

=== Random Insertion Test (with GC) ===
Inserting 3000 random keys (range: 0-29999)
Generated keys (sample): (7742 13787 13355 7260 27388 27116 24018 5971 19474 29389 28330 22515 3653 13057 23764 26128 22807 23154 3348 10015 . ..)
Heap size: 53956608 bytes, Free: 11595776 bytes

[Forcing GC...] Heap size: 53956608 bytes, Free: 36073472 bytes
Progress: 100/3000 Heap size: 17424384 bytes, Free: 81920 bytes
Progress: 200/3000 Heap size: 17223680 bytes, Free: 0 bytes
Progress: 300/3000 Heap size: 17219584 bytes, Free: 4096 bytes
Progress: 400/3000 Heap size: 17178624 bytes, Free: 12288 bytes
Progress: 500/3000 Heap size: 17154048 bytes, Free: 0 bytes
Progress: 600/3000 Heap size: 17133568 bytes, Free: 0 bytes
Progress: 700/3000 Heap size: 17080320 bytes, Free: 0 bytes
Progress: 800/3000 Heap size: 16961536 bytes, Free: 0 bytes
Progress: 900/3000 Heap size: 16936960 bytes, Free: 36864 bytes
Progress: 1000/3000 Heap size: 16785408 bytes, Free: 0 bytes
[Forcing GC...] Heap size: 16785408 bytes, Free: 0 bytes
Progress: 1100/3000 Heap size: 16785408 bytes, Free: 20480 bytes
Progress: 1200/3000 Heap size: 16764928 bytes, Free: 0 bytes
Progress: 1300/3000 Heap size: 16764928 bytes, Free: 0 bytes
Progress: 1400/3000 Heap size: 16764928 bytes, Free: 0 bytes
Progress: 1500/3000 Heap size: 16764928 bytes, Free: 0 bytes
Progress: 1600/3000 Heap size: 16764928 bytes, Free: 0 bytes
Progress: 1700/3000 Heap size: 16764928 bytes, Free: 0 bytes
Progress: 1800/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 1900/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2000/3000 Heap size: 16760832 bytes, Free: 0 bytes
[Forcing GC...] Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2100/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2200/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2300/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2400/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2500/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2600/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2700/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2800/3000 Heap size: 16760832 bytes, Free: 0 bytes
Progress: 2900/3000 Heap size: 16760832 bytes, Free: 0 bytes

Final node count: 2842
Heap size: 16723968 bytes, Free: 0 bytes
Tree is valid (black height: 10)
Phase 2: Delete 1500 keys

=== Random Deletion Test (with GC) ===
Deleting 1500 random keys
Heap size: 16764928 bytes, Free: 45056 bytes

[Forcing GC...] Heap size: 16764928 bytes, Free: 53248 bytes
Progress: 100/1500 Heap size: 35852288 bytes, Free: 24576 bytes
Progress: 200/1500 Heap size: 79122432 bytes, Free: 7188480 bytes
Progress: 300/1500 Heap size: 104312832 bytes, Free: 8294400 bytes
Progress: 400/1500 Heap size: 121065472 bytes, Free: 4599808 bytes
Progress: 500/1500 Heap size: 146231296 bytes, Free: 1347584 bytes
Progress: 600/1500 Heap size: 196562944 bytes, Free: 28913664 bytes
Progress: 700/1500 Heap size: 204951552 bytes, Free: 8421376 bytes
Progress: 800/1500 Heap size: 230117376 bytes, Free: 13520896 bytes
Progress: 900/1500 Heap size: 246894592 bytes, Free: 15917056 bytes
Progress: 1000/1500 Heap size: 263671808 bytes, Free: 10244096 bytes
[Forcing GC...] Heap size: 263671808 bytes, Free: 14692352 bytes
Progress: 1100/1500 Heap size: 280449024 bytes, Free: 11653120 bytes
Progress: 1200/1500 Heap size: 297226240 bytes, Free: 3899392 bytes
Progress: 1300/1500 Heap size: 322392064 bytes, Free: 8916992 bytes
Progress: 1400/1500 Heap size: 330780672 bytes, Free: 9584640 bytes

Final node count: 1342
Heap size: 347557888 bytes, Free: 4698112 bytes
Tree is valid (black height: 9)

=== All tests completed ===
NIL
scheme12>
```
