# Download and extract gc-8.2.12.tar.gz to this location.
## Setting up Boehm GC using the 64devkit shell
### Launching the w64devkit bash
```bash
1. Run w64devkit.exe (double-click)
Or
C:\w64devkit\w64devkit.exe

2. Once the bash shell starts, run the following:
cd /c/Users/user/SECD_Scheme/gc-8.2.12

3. Run configure
./configure --prefix=/c/w64devkit/x86_64-w64-mingw32 \
            --enable-threads=win32 \
            --enable-cplusplus

4. Build
make 
make install
```
