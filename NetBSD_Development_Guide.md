# NetBSD環境構築手順書
## Pentium-M旧型ノートPCにNetBSD-8.2を載せ、Python2.7 + pygame + PyOpenGL 環境を構築する

---

## はじめに

本手順書は、Pentium-M搭載の旧型ノートPCにNetBSD-8.2をインストールし、
pkgsrcのソースビルドによってPython2.7 + py27-pygame + py27-PyOpenGL 環境を
構築した実際の作業記録をもとにまとめたものです。

### 構築の目的

Python2製フライトシミュレータ（pygame + PyOpenGL使用）をNetBSD上で動作させること。

### なぜNetBSD-8.2か

- NetBSD-7.1では動作確認済み
- NetBSD-9.4ではi386向けOpenGLサポートが廃止されており使用不可
- NetBSD-8.2はi386 OpenGLが動作する最後の世代として選定

### なぜpkgsrc-2019Q3か

- NetBSD-8.2（2019年リリース）に対応するpkgsrcバージョンとして選定
- Python2.7、pygame、PyOpenGLが揃っている

---

## 環境

| 項目 | 内容 |
|------|------|
| CPU | Pentium-M（シングルコア） |
| OS | NetBSD-8.2 i386 |
| pkgsrc | pkgsrc-2019Q3 |
| Python | 2.7.16 |
| pygame | 1.9.6（py27-game） |
| PyOpenGL | 3.1.1a1（py27-OpenGL） |

---

## 第1章：インストール直後の確認とトラブル対応

### 1.1 XDMが原因のキーボード無反応問題

#### 症状

NetBSDインストール後、コンソール画面でキーボード入力はできるが
`ifconfig` などのコマンドが無反応。しかしSSHからは正常に動作する。

#### 原因分析

`/etc/rc.conf` に `xdm=YES` が設定されており、XDMが起動していた。
表示されていたコンソール画面は実際にはXターミナル（xterm等）であり、
そのXセッションの環境には `/sbin` がPATHに含まれていなかった。

SSHログインは完全にXと独立しているため正常なPATHで動作していた。

#### 対処

```sh
# /etc/rc.conf を編集
vi /etc/rc.conf

# xdm=YES を xdm=NO に変更
xdm=NO
```

リブート後、通常のコンソールが起動し問題解消。

---

### 1.2 PATH設定の問題

#### 症状

コンソールで `ifconfig` を打っても無反応（エラーメッセージも出ない）。
フルパス `/sbin/ifconfig` では正常に動作。

#### 原因分析

NetBSDでは `ifconfig` は `/sbin/ifconfig` に存在する。
ログインシェルのPATHに `/sbin` が含まれていなかった。
エラーメッセージが出ないのは「コマンドが見つからない」状態のため。

#### 対処

rootのログインシェルが `/bin/sh` であることを確認：

```sh
grep root /etc/passwd
# → root:*:0:0:Charlie &:/root:/bin/sh
```

`/root/.profile` にPATHを追記：

```sh
echo 'export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH' >> /root/.profile
. /root/.profile
```

---

## 第2章：pkgsrcツリーの取得

### 2.1 公式FTPサーバーからの取得を試みる

pkgsrc-2019Q3のtarballをNetBSD公式FTPから取得しようとしたが失敗。

```sh
# 試みたURL（404 Not Found）
ftp https://cdn.NetBSD.org/pub/pkgsrc/pkgsrc-2019Q3/pkgsrc.tar.gz
ftp ftp://ftp.NetBSD.org/pub/pkgsrc/pkgsrc-2019Q3.tar.gz
```

FTPサーバーのディレクトリを確認したところ、古いバージョンは削除されており
`pkgsrc-2025Q4` と `pkgsrc-2026Q1` のみが残っていた。

```sh
ftp ftp.NetBSD.org
ftp> cd /pub/pkgsrc
ftp> ls
# pkgsrc-2025Q4、pkgsrc-2026Q1のみ存在
```

### 2.2 CVSによるチェックアウト

NetBSDのpkgsrcはCVSで管理されており、アノニマスCVSが公開されている。
NetBSD-8.2には `/usr/bin/cvs` が標準インストールされていた。

```sh
which cvs
# → /usr/bin/cvs

cd /usr
cvs -q -z2 -d anoncvs@anoncvs.NetBSD.org:/cvsroot checkout -r pkgsrc-2019Q3 -P pkgsrc
```

Pentium-M + HDD環境のため、チェックアウトには1〜2時間程度かかる。
途中で中断した場合は同じコマンドを再実行すれば再開できる。

完了すると `/usr/pkgsrc` にツリーが展開される。

---

## 第3章：pkgsrcのbootstrap

### 3.1 bootstrap実行

```sh
cd /usr/pkgsrc/bootstrap
./bootstrap
```

約6分で完了。以下がインストールされる：
- `bmake`（BSD Make）
- `pkg_install`（pkg_add、pkg_delete、pkg_infoなど）
- `pkgtools`

### 3.2 PATHの設定

bootstrapで `/usr/pkg` 以下にツールが配置されるのでPATHに追加：

```sh
echo 'export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH' >> /root/.profile
. /root/.profile

# 確認
which bmake
# → /usr/pkg/bin/bmake
```

### 3.3 /etc/mk.conf の作成

pkgsrcのビルド設定ファイルを作成：

```sh
cat > /etc/mk.conf << 'EOF'
PYTHON_VERSION_DEFAULT=27
PKG_DBDIR=/usr/pkg/pkgdb
EOF
```

**注意：** `PYTHON_VERSION_DEFAULT` は `/etc/mk.conf` に書いても効かない場合がある。
その場合はコマンドラインで直接指定する（後述）。

### 3.4 pkg_infoが何も表示しない問題

#### 症状

`pkg_info` を実行しても何も表示されない。

#### 原因

bootstrapのデフォルトパッケージDBが `/usr/pkg/pkgdb` にあるが、
`PKG_DBDIR` 環境変数が設定されていないため参照できていなかった。

#### 対処

```sh
# -K オプションで明示的に指定
pkg_info -K /usr/pkg/pkgdb

# 永続化
echo 'export PKG_DBDIR=/usr/pkg/pkgdb' >> /root/.profile
. /root/.profile
```

---

## 第4章：bash と bmakeについて

### 4.1 bmakeとは

`bmake` はBSD Makeの略。NetBSD発祥のmakeツール。
pkgsrcはbmakeの文法を前提に書かれているため、GNU makeとは異なる。

**NetBSD上では `/usr/bin/make` 自体がBSD makeなので、
`make` と `bmake` は実質同じ。** pkgsrcのドキュメントが他OS移植性のために
`bmake` と明示しているだけ。

### 4.2 bashのインストール

コマンド補完を使いたい場合、bashをインストールする：

```sh
cd /usr/pkgsrc/shells/bash
bmake install clean
```

ログインシェルをbashに変更：

```sh
echo '/usr/pkg/bin/bash' >> /etc/shells
chsh -s /usr/pkg/bin/bash root
```

SSH再接続後にbashが起動する。

---

## 第5章：Python2.7のビルド

```sh
cd /usr/pkgsrc/lang/python27
bmake install clean
```

Pentium-Mでは数十分かかる。

---

## 第6章：pygameのビルドと各種トラブル対応

### 6.1 Python版の指定方法

`/etc/mk.conf` の `PYTHON_VERSION_DEFAULT=27` が効かない場合は、
コマンドラインで指定する：

```sh
bmake PYTHON_VERSION_DEFAULT=27 install clean
```

毎回打つのが面倒な場合はエイリアスを設定：

```sh
alias bmake27='bmake PYTHON_VERSION_DEFAULT=27'
echo "alias bmake27='bmake PYTHON_VERSION_DEFAULT=27'" >> /root/.profile
```

### 6.2 pkgsrc-2019Q3とソース取得の問題

pkgsrc-2019Q3は2019年当時のURLとチェックサムを前提としている。
2026年現在では以下の問題が発生する：

- ソースのホスティング先が移転・削除されている
- GitHubリポジトリが移転し、tarballの内容が変わりチェックサムが不一致になる
- SourceForge等の古いURLが無効になっている

これらは個別に対処していく必要がある。

### 6.3 asciidocのチェックサムエラー（nasmの依存）

#### 症状

```
checksum: Checksum SHA1 mismatch for asciidoc-8.6.10.tar.gz
ERROR: ...
```

#### 原因分析

GitHubのasciidocリポジトリが `asciidoc-py` に移転。
tarballの内容が変わりチェックサム不一致。
さらに展開後のディレクトリ名も変わっているため `NO_CHECKSUM=yes` でも失敗する。

#### 対処

asciidocはnasmのドキュメント生成にしか使われない。
nasmのMakefileからasciidocへの依存をコメントアウトする：

```sh
vi /usr/pkgsrc/devel/nasm/Makefile
# 以下の行をコメントアウト
#BUILD_DEPENDS+=        asciidoc-[0-9]*:../../textproc/asciidoc
```

```sh
cd /usr/pkgsrc/devel/nasm
bmake install clean
```

### 6.4 smpegが入手不可の問題

#### 症状

```
=> Fetching smpeg-0.4.4.tar.gz
ftp: Error retrieving file `404 Not Found'
```

#### 原因

smpeg-0.4.4は非常に古く、公式サイト・ミラーともに消滅している。

#### 対処

smegはSDL_mixerおよびpy-gameのMP3再生機能のためだけに必要。
MP3再生を使わないなら依存を切ることができる。

SDL_mixerのMakefile：

```sh
vi /usr/pkgsrc/audio/SDL_mixer/Makefile
# 以下をコメントアウト
#.include "../../multimedia/smpeg/buildlink3.mk"
```

py-gameのMakefile：

```sh
vi /usr/pkgsrc/devel/py-game/Makefile
# 以下をコメントアウト
#.include "../../multimedia/smpeg/buildlink3.mk"
```

### 6.5 jpegsrcのチェックサムエラー

#### 症状

```
fetch: Size of the file jpeg-9c-v2/jpegsrc.v9c.tar.gz doesn't match.
checksum: Checksum SHA1 mismatch for jpeg-9c-v2/jpegsrc.v9c.tar.gz
```

#### 原因

配布元でファイルが更新されチェックサムが変わった。

#### 対処

```sh
cd /usr/pkgsrc/graphics/jpeg
bmake NO_CHECKSUM=yes install clean
```

### 6.6 giflibが入手不可の問題

#### 症状

```
=> Fetching giflib-5.1.4.tar.bz2
ftp: Error retrieving file `404 Not Found'
```

#### 原因

giflib-5.1.4はSourceForgeから削除されており入手不可。

#### 対処

giflibはlibwebpのGIF対応機能のためだけに必要。
libwebpのMakefileからgiflib依存をコメントアウトする：

```sh
vi /usr/pkgsrc/graphics/libwebp/Makefile
# 以下をコメントアウト
#.include "../../graphics/giflib/buildlink3.mk"
```

さらにPLISTからgif2webp関連エントリを削除：

```sh
grep -n gif2webp /usr/pkgsrc/graphics/libwebp/PLIST
# → 4:bin/gif2webp
# → 24:man/man1/gif2webp.1

vi /usr/pkgsrc/graphics/libwebp/PLIST
# 4行目と24行目を削除
```

```sh
cd /usr/pkgsrc/graphics/libwebp
bmake install clean
```

### 6.7 pygame（py-game）のPLIST問題

#### 症状

```
pkg_create: can't stat `.../pygame/scrap.so'
ERROR: The following files are in the PLIST but not in destdir:
ERROR: .../pygame/scrap.so
```

#### 原因

smegへの依存をコメントアウトしたため、scrap.soがビルドされなかった。
しかしPLISTにはscrap.soが登録されたままになっている。

#### 対処

PLISTから該当行を削除：

```sh
grep -n scrap /usr/pkgsrc/devel/py-game/PLIST
# → 273:${PLIST.unix}${PYSITELIB}/pygame/scrap.so

vi /usr/pkgsrc/devel/py-game/PLIST
# 273行目を削除
```

### 6.8 pygameのビルド（最終）

```sh
cd /usr/pkgsrc/devel/py-game
bmake PYTHON_VERSION_DEFAULT=27 install clean
```

正常にインストールされると：

```
=> Installing binary package of py27-game-1.9.6
```

---

## 第7章：PyOpenGLのビルド

pygameと比べてトラブルなくビルドできた：

```sh
cd /usr/pkgsrc/graphics/py-OpenGL
bmake PYTHON_VERSION_DEFAULT=27 install clean
```

正常にインストールされると：

```
=> Installing binary package of py27-OpenGL-3.1.1a1nb1
```

---

## 第8章：インストール確認

```sh
pkg_info -K /usr/pkg/pkgdb | grep -E "game|OpenGL|python27"
```

以下が表示されれば成功：

```
python27-2.7.16     Interpreted, interactive, object-oriented programming language
py27-game-1.9.6     Set of Python modules designed for writing games
py27-OpenGL-3.1.1a1nb1 Python bindings for OpenGL
freeglut-3.0.0nb2   Alternative to the OpenGL Utility Toolkit (GLUT) library
```

---

## 第9章：アプリケーションの転送と起動

別PCからSCPでファイルを転送：

```sh
scp -r FlightSim/ user@<NetBSDのIP>:~/
```

NetBSD上で起動：

```sh
cd ~/FlightSim
python2.7 main.py
```

---

## トラブルシューティング早見表

| 症状 | 原因 | 対処 |
|------|------|------|
| コンソールでコマンドが無反応 | XDMが起動しXtermになっている | `/etc/rc.conf` で `xdm=NO` |
| ifconfig等が見つからない | PATHに `/sbin` がない | `/root/.profile` にPATH追記 |
| pkg_infoが何も表示しない | `PKG_DBDIR` 未設定 | `export PKG_DBDIR=/usr/pkg/pkgdb` |
| チェックサムエラー | 配布元ファイルが更新された | `bmake NO_CHECKSUM=yes install clean` |
| ファイル404エラー | 古いURLが無効 | 依存をMakefileでコメントアウト |
| PLISTエラー | ビルドされないファイルがPLISTに残る | PLISTから該当行を削除 |
| py37でビルドされる | PYTHON_VERSION_DEFAULT未設定 | `bmake PYTHON_VERSION_DEFAULT=27 install clean` |

---

## pkgsrc-2019Q3を2026年に使う際の注意事項

pkgsrc-2019Q3は2019年当時のURLとチェックサムを前提としているため、
2026年現在では以下の問題が頻発する：

1. **ソース消滅** → 依存をコメントアウトして回避
2. **チェックサム不一致** → `NO_CHECKSUM=yes` で回避
3. **ディレクトリ名変更** → Makefileのパッチが必要な場合がある

基本的な対処パターンは：

- Makefileの依存行をコメントアウト（`#.include "..."` ）
- PLISTから存在しないファイルのエントリを削除
- `NO_CHECKSUM=yes` でチェックサム検証をスキップ

これらを組み合わせることで多くの問題を解決できる。

---

*本手順書は2026年5月の実際の作業記録をもとに作成。*
*NetBSD-8.2 + pkgsrc-2019Q3の組み合わせで動作確認済み。*


---
(2026/5/28)

## 状況の整理（Boostライブラリビルド出来ない問題）

状況をまとめると、以下のような流れでした：

**問題1: ダウンロード失敗**
- pkgsrcが `boost_1_71_0.tar.bz2` を自動取得しようとしたが、配布元（bintray.com）やNetBSDのミラーすべてで `404 Not Found`
- bintray.comは2021年にサービス終了しているため、古いpkgsrcのURLが無効になっているのが根本原因

**問題2: チェックサム不一致**
- `https://www.boost.org/releases/1.71.0/` から手動ダウンロードしたファイル（100,120,229 bytes）を置いたが、pkgsrcの `distinfo` に記録されているSHA1と一致しなかった
- ファイルサイズが微妙に違う（pkgsrcが期待するのは **100,124,647 bytes**）

**解決**
- `https://www.nektar.info/thirdparty/` から取得したファイル（100,124,647 bytes）はサイズが一致し、チェックサムも通ってビルドが進んだ

---

## 補足・今後のために

チェックサム不一致が起きた理由として考えられるのは、boost.org側が配布ファイルを差し替えた可能性です。pkgsrcの `distinfo` はある時点のファイルのハッシュを記録しているため、後から差し替えられると一致しなくなります。

もし同様の状況が再発した場合は：

```sh
# distinfo に記録されているチェックサムを確認
cat /usr/pkgsrc/meta-pkgs/boost/distinfo

# 手元のファイルのハッシュを確認して比較
sha1 /usr/pkgsrc/distfiles/boost_1_71_0.tar.bz2
```

または `NO_CHECKSUM=yes` オプションで強制的に進めることもできますが、ファイルの正当性が保証されないためご注意ください。

---

## 問題が起きたのでちょっと相談

私はc++でSchemeコンパイラを書くプロジェクトを持っていて、
そのSchemeをビルドするときだけ、gcc8.3とそれに対応したBoostとBoehmGCを使いたいのです。

実はBoehmGCはすでにビルド済み（gcc5.5でコンパイル）。
この状況で、今Boostライブラリをビルドしようとしています。
Boostライブラリは、すでにgcc5.5でビルしたものが登録済みです。
いま、以下のような状況。
  
boehm-gc-8.0.4      Garbage collection and memory leak detection for C and C++  
gcc8-8.3.0nb1       The GNU Compiler Collection (GCC) - 8.0 Release Series  
gcc8-libs-8.3.0nb1  The GNU Compiler Collection (GCC) support shared libraries  
boost-build-1.71.0  Free, peer-reviewed portable C++ source libraries (Boost.Build framework)  
boost-docs-1.71.0   Free, peer-reviewed portable C++ source libraries (documentation)  
boost-jam-1.71.0nb1 Free, peer-reviewed portable C++ source libraries (Boost.Jam utility)  
boost-headers-1.71.0nb1 Free, peer-reviewed portable C++ source libraries (build-time headers)  
  
Boostは、任意精度整数を実装するために使っています。
この状況でどうするのがベストか、教えて頂けますか？

-----
(AI Ans)

## 重要な発見：Boostの使い方

```cpp
#include <boost/multiprecision/cpp_int.hpp>
using BigIntType = boost::multiprecision::cpp_int;
```

**`boost::multiprecision::cpp_int` は完全にヘッダオンリーです！**

つまり、**Boost のバイナリライブラリは一切不要**です。

---

## 結論：何をすべきか

| ライブラリ | 状況 | 必要な対処 |
|---|---|---|
| boost-headers | gcc5.5でビルド済み | **そのままでOK**（ヘッダのみ） |
| boehm-gc | gcc5.5でビルド済み | **要ビルドし直し** ❗ |

Boostについては再ビルド不要です。**問題はboehm-gcだけ**です。

## Boostライブラリの現状

| パッケージ | 必要？ | 理由 |
|---|---|---|
| boost-headers-1.71.0 | ✅ 必須 | `cpp_int.hpp` がここに入っている |
| boost-build, boost-jam | ✅ あってOK | ビルドツール、害なし |
| boost-docs | ✅ あってOK | ドキュメント、害なし |
| boost-libs（未インストール） | **不要** | バイナリ不要なので問題なし |

---

## boehm-gc を gcc8.3 でビルドし直す手順

```sh
# 1. 既存の boehm-gc を削除
pkg_delete boehm-gc

# 2. gcc8.3 でビルドし直す
cd /usr/pkgsrc/devel/boehm-gc
bmake install clean GCC_REQD=8 PKGSRC_COMPILER=gcc

# 3. インストール確認
pkg_info | grep boehm
```

---

## 自分のプロジェクトのコンパイル時

```sh
/usr/pkg/gcc8/bin/g++ -std=c++17 \
  -I/usr/pkg/include \
  -L/usr/pkg/lib \
  -lgc -lgc_cpp -lstdc++fs \
  scheme12_bignum_boost_debug.cpp -o scheme12
```

---
(2026/5/28)

## startx で日本語キーにならない場合の設定

/etc/X11/xorg.conf に以下を追加（ファイルがなければ作成）：
```sh
Section "ServerLayout"
    Identifier     "Default Layout"
    InputDevice    "Japanese Keyboard" "CoreKeyboard"
EndSection

Section "InputDevice"
    Identifier     "Japanese Keyboard"
    Driver         "kbd"
    Option         "XkbLayout"  "jp"
    Option         "XkbModel"   "jp106"
EndSection

Section "InputClass"
    Identifier     "Keyboard Defaults"
    MatchIsKeyboard "yes"
    Option         "XkbLayout" "jp"
    Option         "XkbModel"  "jp106"
EndSection
```

---

(2026/5/30)

このPCはサーバとして使うので、IPアドレスが時々変わるのは不便でした。固定アドレスにする方法教えてください。

----- 
(AI Ans)

## NetBSD-8.2 固定IPアドレスの設定

### 現在のネットワーク状態を確認

まず現在の設定を確認します：

```sh
/sbin/ifconfig -a
```

NICのインターフェース名（`wm0`、`re0`、`vr0` など）を確認してください。以下では `wm0` を例として使います。

---

### `/etc/rc.conf` に固定IPを設定

```sh
vi /etc/rc.conf
```

以下の行を追加または編集します：

```sh
# DHCPを使っている場合は以下をコメントアウトまたは削除
#dhclient=YES

# 固定IPの設定（インターフェース名と値は環境に合わせて変更）
ifconfig_wm0="inet 192.168.1.100 netmask 255.255.255.0"
defaultroute="192.168.1.1"
```

---

### `/etc/resolv.conf` にDNSを設定

```sh
vi /etc/resolv.conf
```

```
nameserver 192.168.1.1
nameserver 8.8.8.8
```

---

### 設定を即時反映（再起動なし）

```sh
# 既存のDHCPクライアントを停止（動いている場合）
/sbin/ifconfig wm0 down

# 固定IPを設定
/sbin/ifconfig wm0 inet 192.168.1.100 netmask 255.255.255.0

# デフォルトゲートウェイを設定
/sbin/route add default 192.168.1.1

# インターフェースを起動
/sbin/ifconfig wm0 up
```

---

### 確認

```sh
/sbin/ifconfig wm0
/sbin/netstat -rn    # ルーティングテーブルの確認
ping 192.168.1.1     # ゲートウェイへの疎通確認
```

---

### ポイント

| 項目 | 説明 |
|------|------|
| インターフェース名 | `ifconfig -a` で確認（`wm0`、`re0` など環境により異なる） |
| `rc.conf` の変更 | 再起動後も有効になる永続設定 |
| `ifconfig` コマンド | 即時反映だが再起動で消える（`rc.conf` との併用が必要） |
| SCPでのファイル転送 | 固定IP後は `scp ... user@192.168.1.100:~/` と直接指定できる |

再起動後も設定が維持されるか、一度 `reboot` して `ifconfig wm0` で確認されることをお勧めします。

