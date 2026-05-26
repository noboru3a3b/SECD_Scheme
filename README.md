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

- After that, We implemented string and vector manipulation. Author: Claude 4.5 Sonnet.

- After that, We implemented Debugger in System. Author: Claude 4.5 Sonnet.

- Then, we had GPT-5 Thinking create the system's instruction manual. It turned out he was incredibly clever.

- Implemented a red-black tree library and wrote test scripts. Author: Claude 4.5 Sonnet.  
  
- Also implemented a random number generation function in the system for stress testing of the red-black tree. Author: Claude 4.5 Sonnet.  
  
- Based on the red-black tree library, we implemented a hash table library. Author: Claude 4.5 Sonnet.  
  
- GPT-5 Thinking evaluated the current system. Based on the results, Claude 4.5 Sonnet modified the system as follows.  
  
- Modified the system to correctly handle lists containing circular references. Author: Claude 4.5 Sonnet.  
  
- Improved the hash table library so that values ​​are not overwritten unless the keys are identical. Author: Claude 4.5 Sonnet.  
  
- Speeded up LD/LSET instructions (reduced access time to O(1)) by vectorizing the environment frame. Author: Claude 4.5 Sonnet.  
  
- We've made several improvements, so We've updated the system manual. Author: Claude 4.5 Sonnet.
  
- We added NetBSD-9.4-i386 as a build and test environment. Author: Claude Sonnet 4.6.
  
SECD_Scheme is not something I created; it's a C++ version of a Scheme compiler that uses the complete SECD VM method, developed through the collaboration of various AIs.  
  
I have built and tested this on clang++ on Ubuntu-24.04 and FreeBSD-15.0-RELEASE, and g++ on Windows 11.  
  
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

Compiler on NetBSD:  
```
> /usr/pkg/gcc13/bin/g++ -v
Using built-in specs.
COLLECT_GCC=/usr/pkg/gcc13/bin/g++
COLLECT_LTO_WRAPPER=/usr/pkg/gcc13/libexec/gcc/i486--netbsdelf/13.3.0/lto-wrapper
Target: i486--netbsdelf
Configured with: ../gcc-13.3.0/configure --disable-libstdcxx-pch --enable-nls --with-libiconv-prefix=/usr --enable-__cxa_atexit --with-gxx-include-dir=/usr/pkg/gcc13/include/c++/ --enable-long-long --with-local-prefix=/usr/pkg/gcc13 --enable-threads=posix --with-boot-ldflags='-static-libstdc++ -static-libgcc -Wl,-R/usr/pkg/lib -Wl,-zrelro ' --without-zstd --with-arch=i486 --with-tune=i486 --with-system-zlib --disable-libssp --enable-languages='c obj-c++ objc fortran c++' --enable-shared --with-gnu-ld --with-ld=/usr/bin/ld --with-gnu-as --with-as=/usr/bin/as --prefix=/usr/pkg/gcc13 --build=i486--netbsdelf --host=i486--netbsdelf --infodir=/usr/pkg/gcc13/info --mandir=/usr/pkg/gcc13/man
Thread model: posix
Supported LTO compression algorithms: zlib
gcc version 13.3.0 (GCC)  
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
rm -f scheme12_debug scheme12_debug.exe libgc-1.dll libgccpp-1.dll
PS C:\Users\user\SECD_Scheme> make
g++ -std=c++17 -Wall -Wextra -O2 -Wno-unused-function -Igc-8.2.12/include -IC:/boost_1_91_0 -o scheme12_debug scheme12_bignum_boost_debug.cpp -Lgc-8.2.12/.libs -lgc -lgccpp
C:\Users\user\SECD_Scheme>scheme12_debug.exe
scheme12 debug REPL. Type (help) for commands.
scheme12> (let ((x 10) (y 20)) (+ x y))
30
scheme12> (compile '(let ((x 10) (y 20)) (+ x y)))

=== Compiled Code ===

[  0] LDC 10
[  1] LDC 20
[  2] ARGS 2
[  3] LDF (x y)
  Lambda body:
    [  0] LD (0 . 0)
    [  1] LD (0 . 1)
    [  2] ARGS 2
    [  3] LDG +
    [  4] TAPP
    [  5] RTN

[  4] APP
[  5] STOP
=====================
:compiled
scheme12> (trace-on)
Trace mode ON

==== Step 0 ====
PC: 3
Instruction: STOP
Stack:
  [0] TRUE
Environment: (empty)
Dump: 0 frame(s)
TRUE
scheme12> (let ((x 10) (y 20)) (+ x y))

==== Step 0 ====
PC: 0
Instruction: LDC 10
Stack: (empty)
Environment: (empty)
Dump: 0 frame(s)

==== Step 1 ====
PC: 1
Instruction: LDC 20
Stack:
  [0] 10
Environment: (empty)
Dump: 0 frame(s)

==== Step 2 ====
PC: 2
Instruction: ARGS 2
Stack:
  [0] 20
  [1] 10
Environment: (empty)
Dump: 0 frame(s)

==== Step 3 ====
PC: 3
Instruction: LDF (x y)
Stack:
  [0] (10 20)
Environment: (empty)
Dump: 0 frame(s)

==== Step 4 ====
PC: 4
Instruction: APP
Stack:
  [0] #<closure:(x y)>
  [1] (10 20)
Environment: (empty)
Dump: 0 frame(s)

==== Step 5 ====
PC: 0
Instruction: LD (0 . 0)
Stack: (empty)
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 6 ====
PC: 1
Instruction: LD (0 . 1)
Stack:
  [0] 10
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 7 ====
PC: 2
Instruction: ARGS 2
Stack:
  [0] 20
  [1] 10
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 8 ====
PC: 3
Instruction: LDG +
Stack:
  [0] (10 20)
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 9 ====
PC: 4
Instruction: TAPP
Stack:
  [0] (PRIMITIVE +)
  [1] (10 20)
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 10 ====
PC: 5
Instruction: RTN
Stack:
  [0] 30
Environment: 1 frame(s)
  Frame[0]: Vector(2 bindings)
Dump: 1 frame(s)

==== Step 11 ====
PC: 5
Instruction: STOP
Stack:
  [0] 30
Environment: (empty)
Dump: 0 frame(s)
30
scheme12> (trace-off)

==== Step 0 ====
PC: 0
Instruction: ARGS 0
Stack: (empty)
Environment: (empty)
Dump: 0 frame(s)

==== Step 1 ====
PC: 1
Instruction: LDG trace-off
Stack:
  [0] NIL
Environment: (empty)
Dump: 0 frame(s)

==== Step 2 ====
PC: 2
Instruction: APP
Stack:
  [0] (PRIMITIVE trace-off)
  [1] NIL
Environment: (empty)
Dump: 0 frame(s)
Trace mode OFF
FALSE
scheme12>
```

### Side note:
I used to be an OS enthusiast, installing and building new operating systems almost every week.  
As a result, I have many old PCs at home.  
For this project, I wanted to prepare multiple build and execution environments,   
so I dug out two old laptops and installed BSD-based operating systems.  
- FMV LIFEBOOK A8390 CPU: Core i5 RAM: 4GB HDD: 500GB ---> FreeBSD-15.0-RELEASE-amd64  
- FMV LIFEBOOK 820NAL CPU: Pentium-M RAM: 512MB HDD: 40GB ---> NetBSD-9.4-i386  
  
Both were configured as servers, and I found that NetBSD running on a Pentium-M is extremely efficient.  
With this combination, it consumes almost no power in standby mode, and the fan doesn't even run.  
  
