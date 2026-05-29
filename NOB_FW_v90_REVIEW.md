# NOB FW v90 — レビュー結果

**レビュー日**: 2026-05-24

---

## 指摘 1: T6 テスト手順の曖昧さ

### 問題

T6「v90 から v90 を再度 OTA」で `--application-version 91` と記載されているが、
これは v90 バイナリに対して bootloader 上のバージョンメタデータだけを 91 にするという意味であり、
実際の `APP_FW_VERSION_NUM` は 90 のまま。DF5 の movement_counter も 0x5A (90) のままになる。
テスト手順として誤解を招く。

### 対応

`NOB_FW_v90_RELEASE_NOTES.md` の T6 を以下の表現に書き直すべき:

> **T6: OTA 再適用 (ブリック検証)**
>
> 1. 同じ v90 バイナリ (`nrf52832_xxaa.hex`) を使用し、DFU パッケージの
>    `--application-version` のみ 91 に変更して再生成する:
>    ```bash
>    nrfutil pkg generate \
>      --hw-version 0xB0 \
>      --application src/targets/kaarle/armgcc/_build/nrf52832_xxaa.hex \
>      --application-version 91 \
>      --sd-req 0xB7 \
>      --key-file keys/ruuvi_open_private.pem \
>      nob_fw_v90_reapply.zip
>    ```
>    **注意**: バイナリはリビルド不要。`--application-version` は bootloader の
>    ダウングレード防止メタデータであり、ファームウェア内の `APP_FW_VERSION_NUM` とは独立。
> 2. nRF Connect で `nob_fw_v90_reapply.zip` を OTA インストール
> 3. **検証**: OTA 成功し、デバイスが正常起動すること
> 4. **検証**: DF5 の movement_counter = 0x5A (90) のままであること

**ステータス**: ドキュメント修正のみ。コード変更なし。

---

## 指摘 2: continuous_adv 周期のコンパイル時設定可能化

### 問題

`APP_CONTINUOUS_ADV_INTERVAL_MS` が `app_heartbeat.c` にハードコードされており、
検証で 500ms / 2000ms に調整する際にドライバ層のファイルを編集する必要があった。

### 対応: 実施済み

`app_config.h` に `#ifndef` ガード付きで定義を移動した。

**`src/application_config/app_config.h`** (新規追加箇所):
```c
// ** Continuous advertising interval (ms) ** //
#ifndef APP_CONTINUOUS_ADV_INTERVAL_MS
#   define APP_CONTINUOUS_ADV_INTERVAL_MS (1000U)
#endif
```

**`src/app_heartbeat.c`**: ローカル `#define` を削除。`app_config.h` 経由で参照。

これにより、`app_config.h` の 1 行変更のみで周期調整が可能。
Makefile の `-D` フラグでのオーバーライドにも対応。

**ステータス**: コード変更済み。ビルド確認済み。

---

## 指摘 3: TX パワーの確認

### 調査結果

**nRF52832 (S132 v7.x) がサポートする TX パワー値**:
```
-40, -20, -16, -12, -8, -4, 0, +3, +4 dBm
```
(`ble_gap.h:1939` のコメントより)

**+8dBm は非対応。** nRF52832 のハードウェア上限は +4dBm。
(+8dBm は nRF52840 のみ対応)

**kaarle ボードの設定**:
```c
// ruuvi_board_kaarle.h:55
#define RB_TX_POWER_7  (4)      // +4dBm = 最大
#define RB_TX_POWER_MAX  RB_TX_POWER_7
```

**NOB ブイの設置環境**: ブイ本体は海面上に浮いている。アンテナは海面上。
ただし、波しぶきや塩害でケース内の電波減衰は通常より大きい。

### 結論

+4dBm が nRF52832 のハードウェア上限であり、これ以上は不可能。
現在の設定 (`RB_TX_POWER_MAX = +4dBm`) で問題なし。

**ステータス**: 確認完了。コード変更不要。

---

## 指摘 4: ri_adv_send() のエラーハンドリング

### 問題

`continuous_adv_isr()` 内で `(void) rt_adv_send_data()` とエラーを完全に無視しており、
nrf_queue 満杯等の連続失敗を検知できない。

### 対応: 実施済み

連続失敗カウンタ `m_cont_adv_fail_count` を追加した。

**`src/app_heartbeat.c`**:
```c
static uint32_t m_cont_adv_fail_count = 0;

static void continuous_adv_isr (void * const p_context)
{
    if (m_adv_msg_valid)
    {
        ri_comm_message_t msg;
        memcpy (&msg, &m_adv_msg, sizeof (ri_comm_message_t));
        msg.repeat_count = 1;
        rd_status_t err_code = rt_adv_send_data (&msg);

        if (RD_SUCCESS != err_code)
        {
            m_cont_adv_fail_count++;
        }
        else
        {
            m_cont_adv_fail_count = 0;
        }
    }
}

uint32_t app_heartbeat_continuous_adv_fail_count (void)
{
    return m_cont_adv_fail_count;
}
```

**`src/app_heartbeat.h`**:
```c
uint32_t app_heartbeat_continuous_adv_fail_count (void);
```

**設計判断**:
- 成功で 0 リセット (連続失敗数のみ追跡)
- ISR コンテキストなので LOG 出力は行わない (RI_LOG が ISR-safe でない可能性)
- 将来的に GATT 経由の診断レスポンスに含められる
- `RI_LOG_ENABLED = 0` (プロダクション) のため、ログ出力よりカウンタが実用的

**ステータス**: コード変更済み。ビルド確認済み。

---

## 指摘 5: APP_FW_VERSION_NUM → movement_counter 反映の確認

### コードトレース

```
app_config.h:514
  #define APP_FW_VERSION_NUM (90U)

      ↓ app_dataformats.c:122 で参照

  ep_data.movement_count = APP_FW_VERSION_NUM;  // = 90

      ↓ re_5_encode() (ruuvi_endpoint_5.c) で DF5 バッファに書き込み

  buffer[RE_5_OFFSET_MVTCTR] = movement_count & 0xFF;
  // RE_5_OFFSET_MVTCTR = 15 (ruuvi_endpoint_5.h:57)

      ↓ ADV_IND パケット内の位置

  Manufacturer Data (AD Type 0xFF):
    [99 04] Company ID
    [05]    DF5 header (offset 0)
    ...
    [5A]    offset 15 = movement_counter = 90 = 0x5A  ← ★ここ
    ...
```

### 検証

`APP_FW_VERSION_NUM = 90` → `0x5A` が DF5 ペイロードの offset 15 (Manufacturer Data
先頭から offset 18) に正しく格納される。

**確認ポイント**: nRF Connect のスキャン結果で Manufacturer Specific Data の
raw bytes を確認し、18 バイト目 (0-indexed) が `0x5A` であることを検証できる。

v89 では `0x59` (89)、v90 では `0x5A` (90)。OTA 前後で値が変化することで
ファームウェア更新成功の即座の確認が可能。

**ステータス**: 確認完了。コードは正しい。

---

## 修正後のバイナリサイズ

| | text | data | bss | total |
|---|---|---|---|---|
| v89 (変更前) | 99,960 | 1,320 | 14,052 | 115,332 |
| v90 (レビュー前) | 100,152 | 1,320 | 14,084 | 115,556 |
| **v90 (レビュー後)** | **100,168** | **1,320** | **14,092** | **115,580** |
| **差分 (v89 比)** | **+208** | **0** | **+40** | **+248** |

レビュー修正による増分: text +16 bytes (fail_count アクセサ), bss +4 bytes (カウンタ変数), 
app_config.h の define 移動はコンパイル結果に影響なし。

---

## 修正ファイル一覧 (レビュー対応分)

| ファイル | 変更内容 |
|---|---|
| `src/application_config/app_config.h` | `APP_CONTINUOUS_ADV_INTERVAL_MS` 定義を追加 |
| `src/app_heartbeat.c` | ローカル define 削除、`m_cont_adv_fail_count` 追加、ISR 内エラー追跡、アクセサ追加 |
| `src/app_heartbeat.h` | `app_heartbeat_continuous_adv_fail_count()` API 追加 |
