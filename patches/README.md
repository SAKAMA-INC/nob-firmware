# サブモジュールに当てるパッチ

NOBのファームは、外部のリポジトリ（ruuvi.drivers.c、Sensirionのembedded-shtなど）をサブモジュールとして取り込んでいる。そのうち手を入れる必要があった箇所を、このディレクトリにパッチとして置く。サブモジュールの中を直接書き換えるだけだと、その変更はこのリポジトリに残らず、ほかの環境ではビルドし直せない。

## 当て方

```bash
git submodule update --init --recursive
./patches/apply.sh
```

`apply.sh`は`patches/<サブモジュールのパス>/*.patch`を、そのサブモジュールの中で`git apply`する。当て済みのパッチは飛ばすので、何度実行してもよい。`git submodule update`を実行するとサブモジュールの変更は消えるので、そのあとに毎回実行する。

当てられないと表示されたときは、サブモジュールの版がパッチを作ったときから変わっている。パッチを作り直す。

## パッチの一覧

### 0001-skip-sht-crc-check.patch

- 対象: `src/ruuvi.drivers.c/embedded-sht/embedded-common/sensirion_common.c`（embedded-common 1ac7c72）
- 内容: `sensirion_common_check_crc()`がCRCを確かめずに、いつも成功を返すようにする。
- 理由: ファイル内のコメントによると、v62で入れた変更である。I2Cの信号品質が悪く、温湿度センサー（SHT）の読み取りでCRCエラーが続いたため。
- 注意: 通信中に壊れた値も、そのまま測定値として受け取る。

この変更は、2026-11まで手元のサブモジュールの中にだけあった。リポジトリ直下の`nob_fw_v93.zip`などの配布済みのファームにこの変更が入っているかは、確かめていない。
