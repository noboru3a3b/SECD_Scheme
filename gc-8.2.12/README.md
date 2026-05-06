## Setting up Boehm GC using the 64devkit shell
### Start the w64devkit bash
```bash
# 1. Run w64devkit.exe (double-click)
# Or
C:\w64devkit\w64devkit.exe
# 2. Once the bash shell starts, run the following:
cd /c/Users/okadan-cts/SECD_Scheme/gc-8.2.12/gc-8.2.4
# 3. Run configure
./configure --prefix=/c/w64devkit/x86_64-w64-mingw32 \
--enable-threads=win32 \
--enable-cplusplus
# 4. Build
make -j4
make install
```
