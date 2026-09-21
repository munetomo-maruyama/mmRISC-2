# SD カードに置くもの

FAT16 の第 1 パーティションのルートに 3 つ。

| ファイル | 出どころ | ロード先 |
|---|---|---|
| `fw_jump.bin` | `scripts/build_opensbi.sh` が**ここに**作る | 0x8000_0000 |
| `Image` | Linux カーネル。Rocket 構成のものをそのまま使う | 0x8020_0000 |
| `boot.json` | 同上 | ― |

`Image` と `boot.json` は CPU に依存しないので、Rocket 構成で作ったもの
(`LitexRocket/software/boot/`)をそのままコピーすればよい。

ルートファイルシステムは第 2 パーティション(ext4、ラベル `rootfs`)。
これも作り直す必要は無い。

## デバイスツリーは別ファイルではない

`fw_jump.bin` に**埋め込んである**(`FW_FDT_PATH`)。だから
`software/mmrisc_arty.dts` を触ったら、SD カードに DTB を置くのではなく
`scripts/build_opensbi.sh` を実行し直して `fw_jump.bin` を差し替える。

## 起動

シリアル 115200bps。`litex>` プロンプトで:

```
sdcardboot
```

LiteX BIOS → OpenSBI → Linux → BusyBox と進めば成功。
詰まったときの見どころは `docs/BRINGUP.md`。
