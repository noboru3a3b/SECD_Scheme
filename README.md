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

SECD_Scheme is not something I created; it's a C++ version of a Scheme compiler that uses the complete SECD VM method, developed through the collaboration of various AIs.

I have built and tested this on clang++ on Ubuntu-24.04 and FreeBSD 15.0-RELEASE, and g++ on Windows 11.

Compiler on Ubuntu:  
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

Compiler on FreeBSD:  
> clang++ -v  
FreeBSD clang version 19.1.7 (https://github.com/llvm/llvm-project.git llvmorg-19.1.7-0-gcd708029e0b2)  
Target: x86_64-unknown-freebsd15.0  
Thread model: posix  
InstalledDir: /.bastille/usr/bin  

Compiler on Windows 11:  
> g++ -v  
Using built-in specs.  
COLLECT_GCC=C:\w64devkit\bin\g++.exe  
COLLECT_LTO_WRAPPER=C:/w64devkit/bin/../libexec/gcc/x86_64-w64-mingw32/15.2.0/lto-wrapper.exe  
Target: x86_64-w64-mingw32  
Configured with: /dl/gcc/configure --prefix=/w64devkit --with-sysroot=/w64devkit --with-native-system-header-dir=/include --target=x86_64-w64-mingw32 --host=x86_64-w64-mingw32 --enable-static --disable-shared --with-pic --with-gmp=/deps --with-mpc=/deps --with-mpfr=/deps --enable-languages=c,c++,fortran --enable-libgomp --enable-threads=posix --enable-version-specific-runtime-libs --disable-libstdcxx-verbose --disable-dependency-tracking --disable-lto --disable-multilib --disable-nls --disable-win32-registry --enable-mingw-wildcard CFLAGS_FOR_TARGET=-O2 CXXFLAGS_FOR_TARGET=-O2 LDFLAGS_FOR_TARGET=-s CFLAGS=-O2 CXXFLAGS=-O2 LDFLAGS=-s
Thread model: posix  
Supported LTO compression algorithms: zlib  
gcc version 15.2.0 (GCC)  

Installing the compiler on Windows 11 was done using w64devkit.  


## Usage:  
PS C:\Users\user\SECD_Scheme8> make clean  
rm -f micro_scheme11 micro_scheme11.exe  
PS C:\Users\user\SECD_Scheme8> make  
g++ -std=c++17 -Wall -Wextra -O2 -o micro_scheme11 micro_scheme11.cpp  
PS C:\Users\user\SECD_Scheme8> .\micro_scheme11.exe  
