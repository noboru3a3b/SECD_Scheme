## (For Windows)
## Download and extract gc-8.2.12.tar.gz to this location.
### Setting up Boehm GC using the 64devkit shell
### Launching the w64devkit bash
```bash
1. Run w64devkit.exe (double-click)
Or
C:\w64devkit\w64devkit.exe

2. Once the bash shell starts, run the following:
cd c:/Users/user/SECD_Scheme/gc-8.2.12

3. Run configure
./configure --prefix=/c/w64devkit/x86_64-w64-mingw32 \
            --enable-threads=win32 \
            --enable-cplusplus

4. Build
make 
make install
```

## (For Linux)
### Execute the following.
```bash
sudo -s
apt install libgc-dev
exit
```

## (For FreeBSD)
### Execute the following.
```bash
su
pkg install devel/boehm-gc
exit
```

## (For NetBSD)
### Execute the following.
### NetBSD-8.2 is too old and application binaries are not available,
### so you need to prepare pkgsrc beforehand.
```bash
su
# Check out pkgsrc-2019Q3
cd /usr
cvs -q -z2 -d anoncvs@anoncvs.NetBSD.org:/cvsroot checkout -r pkgsrc-2019Q3 -P pkgsrc

# Execute bootstrap
cd /usr/pkgsrc/bootstrap
./bootstrap

# Add to PATH
echo 'export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH' >> /root/.profile
. /root/.profile
exit

su
cd /usr/pkgsrc/devel/boehm-gc
bmake install clean GCC_REQD=8 PKGSRC_COMPILER=gcc
exit
```
