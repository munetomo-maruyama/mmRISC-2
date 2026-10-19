# mmRISC-2 で Debian を動かす: ボードの上でのコンパイル

[English](DEBIAN.md)

ボードはふつう、小さな BusyBox のルートで起動する(`software/boot/README_J.md`)。この文書では、それを SD カード上の
**Debian 13(trixie、riscv64)** に置き換え、**ボードの上に gcc、make、gdb、git** を用意する: C のプログラムを
mmRISC-2 そのものの上で書き、コンパイルして走らせ、`apt` で Debian のパッケージをインターネットから追加できる。
カーネル、OpenSBI、ビットストリームはそのままで、変わるのは SD カードの第 2 パーティションだけ。

こんな具合になる(Rev.02 のボード、50 MHz):

```
Debian GNU/Linux 13 mmrisc2 ttyLXU0

mmrisc2 login: root
root@mmrisc2:~# cat t.c
#include <stdio.h>
int main(void)
{
    printf("build on mmRISC-2\n");
    return 0;
}
root@mmrisc2:~# time gcc -O2 -o t t.c && ./t

real    0m20.712s
user    0m7.682s
sys     0m6.799s
build on mmRISC-2
```

## 1. 必要なもの

| | |
|---|---|
| ボード | mmRISC-2 のビットストリームを入れた Arty A7-100T。`software/boot/README_J.md` のとおり SD カードから Linux が起動すること |
| SD カード | 2 枚目のカード、4 GB 以上(8 GB 以上を推奨)。Debian のツリーが約 1 GB、そこに 512 MB のスワップファイルを作る |
| ネットワーク | ボードの Ethernet を、DHCP があってインターネットに出られる LAN に(時刻の NTP、`apt`) |
| ホスト | `mmdebstrap`、`qemu-user-static`、`binfmt-support`、`arch-test` のある Linux(Ubuntu 24.04 の x86_64 か arm64 で確かめた)、インターネット、空き約 2 GB |

Ubuntu では、最初に 1 回:

```bash
sudo apt install mmdebstrap qemu-user-static binfmt-support arch-test
```

`qemu-user-static` でホストが riscv64 のプログラムを動かせるようになる。ツリーを作る間、Debian のパッケージの
スクリプトがそれを必要とする。作ること自体に root は要らない。

## 2. Debian のツリーを作る

リポジトリの最上位で:

```bash
./LitexSystem/scripts/build_debian.sh
```

`~/mmlitex_build/debian-riscv64.tar`(約 1 GB。引数で別のファイル名)を作る。deb.debian.org からパッケージを
取ってきて、10〜20 分。最後にツリーの中で C のプログラムをコンパイルして走らせ(qemu で)、
`build_debian.sh: gcc in the tree compiles and runs` と出す。

Debian の署名の鍵: Ubuntu が持っている Debian の鍵束は、Debian 13 の鍵より古い。そのときスクリプトは、それを持つ
Debian 12 の鍵束を取ってくる。各段階を確かめながら(Ubuntu が持つ鍵で Debian 12 の署名付きの索引を、その中のハッシュで
パッケージの一覧を、一覧で鍵束のパッケージを)取るので、確かめていないものを信用することはない。

## 3. SD カードに書く

BusyBox のルートのときと同じように、カードを区切ってフォーマットし(`software/boot/README_J.md` の「新しいカードを
作る」: 第 1 パーティションは FAT16 512 MB の `LITEXBOOT`、第 2 パーティションは ext4 の `rootfs`)、`software/boot/` の
3 つのファイル(`Image`、`fw_jump.bin`、`boot.json`)を第 1 パーティションに置く。Debian でも同じもの。

次に第 2 パーティションを、マウントして(ここでは `/media/$USER/rootfs`):

```bash
sudo ./LitexSystem/scripts/sd_debian.sh /media/$USER/rootfs
```

第 2 パーティションを消す前に確認を求め、所有者と権限ごと tarball を展開し、`done` と出す。そのあと `sync` して
アンマウントし、カードを抜く。

Mac の上の仮想マシンの Ubuntu を使う場合、第 1 パーティションは Mac から書くこと(VM から書いた FAT は macOS に
書き戻されることがある: `software/boot/README_J.md` の「第 1 パーティションは Mac から書く」)。第 2 パーティション
(ext4)は VM から書く。

## 4. 起動

カードを挿し、Ethernet をつなぎ、RESET を押す。いつもの LiteX BIOS、OpenSBI、Linux の後に Debian の init が動き出す:

```
INIT: version 3.14 booting
Using makefile-style concurrent boot in runlevel S.
Checking root file system...rootfs: clean, 27442/1855952 files, 422107/7423744 blocks
...
Configuring network interfaces...
[  171.446968] random: crng init done
DHCPACK of 192.168.0.13 from 192.168.0.1
...
INIT: Entering runlevel: 2
Starting time daemon: chronyd.
Starting OpenBSD Secure Shell server: sshd.
[  189.733096] Adding 524284k swap on /swapfile.

Debian GNU/Linux 13 mmrisc2 ttyLXU0

mmrisc2 login:
```

**ログインは RESET から約 3 分後**。その大半は、DHCP がカーネルの乱数生成器を待つ時間(`crng init done`、約 170 秒:
ボードにはハードウェアの乱数源が無く、生成器は割り込みのタイミングからエントロピーを集める)。`root` でログインする。
シリアルコンソールではパスワードは無い。

## 5. 使う

```sh
date                         # 起動後数秒で chrony が NTP から合わせる
chronyc tracking | head -4   # どのサーバーか、ずれ
free -m                      # メモリ 237 MB、スワップ 511 MB
gcc --version; gdb --version # gcc 14.2、gdb 16.3
```

ボードの上でのコンパイル: 小さな C のファイルで `gcc -O2` が約 20 秒(コンパイラそのものを SD カードから読み、50 MHz で
走る)。大きなプログラムはそれに応じて長くなる。`make`、`gdb`(ユーザのプログラムにブレークポイント)、`git`、`strace`
もある。

パッケージを足す:

```sh
apt update                   # Debian のパッケージの一覧は、このボードには大きい
apt install -y tree          # update と小さなパッケージ 3 つで約 20 分
```

SSH: 先にパスワードを付ける(`passwd`)。それから LAN から `ssh root@<アドレス>`(アドレスは `ip addr show eth0`)。
または公開鍵を `/root/.ssh/authorized_keys` に置く。

電源を切る前に:

```sh
poweroff
```

`reboot: Power down` が出てから電源を切る(または RESET)。

BusyBox に戻すには、BusyBox のカードを挿す。または `scripts/sd_rootfs.sh --full` で第 2 パーティションに BusyBox の
ルートを書き直す(`software/boot/README_J.md`)。

## 6. 標準の Debian と違うところ

`build_debian.sh` は Debian の最小の基本(`mmdebstrap --variant=minbase`)から始め、ボードのために次を変える:

| | 理由 |
|---|---|
| systemd ではなく sysvinit | 256 MB、50 MHz には軽い方がよい。`software/boot/` のカーネルは sysvinit に要るものを持っている |
| LiteX の UART(`ttyLXU0`)にログイン、そこでは root にパスワード無し | シリアルコンソールがボードの端末。SSH はパスワードの無い root を拒むので、付けるまで LAN からは入れない |
| `eth0` は DHCP(`ifupdown`、`isc-dhcp-client`) | |
| chrony | 時計(RTC)が無い: 時刻は 1970 年から始まり、`apt` は「まだ有効でない」パッケージの一覧を拒む。chrony は起動時に正しい時刻へ一度で合わせる(Debian の `chrony.conf` の `makestep`) |
| 512 MB のスワップファイル(`/swapfile`)、初回起動時に `/etc/rc.local` が作る | 大きなファイルの gcc は、メモリの 237 MB を超える |
| `e2fsprogs` | Debian 13 は最小の基本から外しているが、ルートは起動時に検査する(`fsck.ext4`) |
| `busybox` | `software/bench/`(`tftp` など)が BusyBox のルートと同じように動くように |
| gcc、make、gdb、git、strace、OpenSSH、less、vim-tiny、nano、file、ca-certificates、全ロケール | 開発の道具 |

## 7. うまく動かないとき

| 症状 | 原因と対処 |
|---|---|
| `build_debian.sh`: `riscv64 programs do not run here` | ホストに `qemu-user-static` / `binfmt-support` が無い |
| `build_debian.sh`: `The repository ... is not signed` | 鍵束を取れなかったか確かめられなかった(ネットワーク、または Debian の鍵の変更)。その前のメッセージがどの段階かを示す |
| ボードが `Waiting for root device` や `VFS: Unable to mount` で止まる | 第 2 パーティションが ext4 でないか空。ホストで `ls` して `usr/sbin/init` があるか確かめる |
| `Checking root file system` の後で保守用シェルで止まる | `e2fsprogs` を加える前に作ったツリー(`fsck.ext4` が無い)。tarball を作り直し、第 2 パーティションを書き直す |
| `date` が 1970 年(や遠い未来) | chrony がまだサーバーに届いていない(インターネットや DNS が無い): `ip addr`、`ping 8.8.8.8` を確かめ、`/etc/init.d/chrony restart` |
| `apt update` が「not valid yet」や「expired」 | 時計が違う: 上と同じ |
| 何分もログインが出ない | `crng init done` を待つ(4 章)。Ethernet が無いと、DHCP はさらに 1 分ほどで諦める |
| `Cannot persist the following output on disc` というメッセージ | 害は無い: ルートが書けるようになってから起動のログを書く |

## 8. しくみ

- BusyBox と同じ `fw_jump.bin`(デバイスツリー入りの OpenSBI)と `Image`(Linux 7.2)が Debian を起動する: デバイス
  ツリーのカーネルのコマンドラインがすでに `root=/dev/mmcblk0p2` で、カーネルは Debian のユーザ空間に要るもの
  (devtmpfs、tmpfs、Unix ソケット、inotify、signalfd / timerfd / eventfd、ext4、スワップ)を持っている。
- `build_debian.sh` は `mmdebstrap` を unshare モード(root なし)で動かす: パッケージを取ってきて展開し、そのスクリプトを
  qemu-user で走らせ、6 章の変更を customize-hook として加え、gcc を確かめる。tarball は所有者(root)と権限を保ち、
  `sd_debian.sh` が `tar --numeric-owner` でそれを戻す。
- `/etc/inittab` は LiteX の UART ドライバのコンソール `ttyLXU0` に `getty` を起動する。ほかの `getty`(ボードに無い
  仮想端末用)は消してある。
