# NOB FW v90 — リリースノート & OTA テスト手順

## 変更サマリ

| ファイル | 変更内容 |
|---|---|
| `src/app_heartbeat.c` | 継続広告タイマ (1000ms 周期) 実装、共有バッファ `m_adv_msg` 追加 |
| `src/app_heartbeat.h` | `app_heartbeat_continuous_adv_start/stop()` API 追加 |
| `src/app_comms.c` | TURBO 即時化 (30s→0)、GATT 接続/切断時の継続広告制御、起動時タイマ開始 |
| `src/application_config/app_config.h` | `APP_FW_VERSION_NUM` 89→90 |

## バイナリサイズ比較

| | text | data | bss | total |
|---|---|---|---|---|
| v89 (変更前) | 99,960 | 1,320 | 14,052 | 115,332 |
| **v90 (変更後)** | **100,152** | **1,320** | **14,084** | **115,556** |
| **差分** | **+192** | **0** | **+32** | **+224** |

- Flash 増分: +192 bytes (継続広告タイマの関数コード)
- RAM 増分: +32 bytes (`m_adv_msg` 24B + `m_cont_adv_timer` 4B + flags 2B + padding)
- 余裕: Flash 328KB 中 ~98KB 使用 (30%), RAM 56KB 中 ~14KB 使用 (25%)

---

## 1. 電池消費試算 (CR2477 1000mAh)

### 1.1 広告時の電流

nRF52832 + S132 の典型値 (1MBPS, 0dBm, 3ch):
- 1 回の広告イベント: ~15μA·s (平均電荷)
- 内訳: RF TX ~7mA × ~600μs × 3ch + CPU ~3mA × ~200μs

### 1.2 v89 (変更前)

```
heartbeat 80秒、1285ms 間隔 × 2 回 = 約 1.3 秒間のみ広告
→ 2 events / 80s = 0.025 events/s
→ 15μA·s × 0.025/s = 0.375 μA 平均
```

### 1.3 v90 (変更後)

```
継続広告: 1000ms 間隔 × 1 回/タイマ = 1 event/s
heartbeat 広告: 2 events / 80s = 0.025 events/s (変更なし)
合計: 1.025 events/s
→ 15μA·s × 1.025/s = 15.4 μA 平均
```

### 1.4 全体電流と電池寿命

| 項目 | v89 | v90 |
|---|---|---|
| 広告 | 0.4 μA | **15.4 μA** |
| センサー (LIS2DH12 10Hz + SHTCX + TMP117) | ~15 μA | ~15 μA |
| SoftDevice + MCU sleep | ~5 μA | ~5 μA |
| **合計** | **~20 μA** | **~35 μA** |
| **CR2477 寿命** | **~5.7 年** | **~3.3 年** |

七尾湾のデプロイ寿命 (~1 年想定) に対して十分なマージンあり。

### 1.5 TX パワーの影響

現在 +4dBm (RB_TX_POWER_MAX) で送信。0dBm に下げると:
- 1 event あたり ~12μA·s に改善
- 合計 ~32 μA → 寿命 ~3.6 年
- 海中デプロイでは電波減衰が大きいため +4dBm を推奨

---

## 2. タイマ優先度・競合分析

### 2.1 タイマ構成

| タイマ | 周期 | モード | ISR 内容 | 優先度 |
|---|---|---|---|---|
| `heart_timer` | 80,000 ms | REPEATED | `schedule_heartbeat_isr()` → scheduler | APP_TIMER (IRQ priority 7) |
| `m_cont_adv_timer` | 1,000 ms | REPEATED | `continuous_adv_isr()` → `rt_adv_send_data()` | APP_TIMER (IRQ priority 7) |
| `m_comm_timer` | one-shot | SINGLE_SHOT | `comm_mode_change_isr()` | APP_TIMER (IRQ priority 7) |

### 2.2 競合シナリオ

**Q: heartbeat と continuous_adv が同時に広告を発行したら？**
→ `ri_adv_send()` は `nrf_queue_push()` でキューイングする (`RUUVI_NRF5_SDK15_ADV_QUEUE_LENGTH = 3`)。
  `prepare_tx()` がキューから順次取り出して SoftDevice に渡す。
  heartbeat の `send_adv()` は `repeat_count=2`、continuous_adv は `repeat_count=1`。
  キュー深さ 3 で十分収容可能。SoftDevice が `BLE_GAP_EVT_ADV_SET_TERMINATED` を発火するまで次の広告は wait される。

**Q: continuous_adv_isr がキュー満杯時にどうなるか？**
→ `nrf_queue_push()` が `NRF_ERROR_NO_MEM` を返し、`rt_adv_send_data()` がエラーを返す。
  `(void)` でエラーを無視しているため、次の 1000ms で再試行される。データ損失は広告の 1 回スキップのみ。

**Q: GATT 接続中は？**
→ `handle_gatt_connected()` で `app_heartbeat_continuous_adv_stop()` が呼ばれ、タイマ停止。
  接続中の heartbeat 広告は `NONCONNECTABLE_NONSCANNABLE` で送信 (既存挙動)。
  `handle_gatt_disconnected()` で再開。

**Q: continuous_adv_isr は ISR コンテキストか？**
→ はい。APP_TIMER ISR (SWI1, priority 7) 内で実行。
  `rt_adv_send_data()` → `ri_adv_send()` → `nrf_queue_push()` + `prepare_tx()` は
  すべて SD API 呼び出しで ISR-safe (`sd_ble_gap_adv_*` は SVC call)。
  `memcpy()` も 24 bytes のみで高速。問題なし。

---

## 3. GATT 接続中の制御フロー

```
GATT 接続:
  on_gatt_connected_isr (ISR context)
    → ri_scheduler_event_put(handle_gatt_connected)  // メインループへ
      → app_heartbeat_continuous_adv_stop()           // ★ 継続広告停止
      → rt_gatt_adv_disable()                         // NONCONNECTABLE に変更
      → app_comms_ble_adv_init()                      // 広告再初期化

GATT データ受信:
  handle_comms()
    → app_heartbeat_stop()                            // heartbeat 停止
    → ri_gatt_params_request(RI_GATT_TURBO, 0)       // ★ 即座に TURBO
    → ログ送信...
    → ri_gatt_params_request(RI_GATT_LOW_POWER, 0)
    → app_heartbeat_start()                           // heartbeat 再開

GATT 切断:
  on_gatt_disconnected_isr (ISR context)
    → ri_scheduler_event_put(handle_gatt_disconnected)
      → config_cleanup_on_disconnect()                // 再初期化
      → app_heartbeat_continuous_adv_start()          // ★ 継続広告再開
```

---

## 4. SoftDevice 領域の不変性確認

| 領域 | アドレス | v90 で変更 |
|---|---|---|
| MBR | 0x00000000 - 0x00000FFF | ❌ 不変 |
| SoftDevice S132 v7.0.1 | 0x00001000 - 0x00025FFF | ❌ 不変 |
| Application | 0x00026000 - 0x00077FFF | ✅ コード変更 |
| Bootloader | 0x00078000 - 0x0007DFFF | ❌ 不変 |
| RAM origin | 0x20002450 | ❌ 不変 (SDK config 変更なし) |

---

## 5. 陸上 OTA テスト手順

### 5.1 前提条件

- テスト用 kaarle ボード 1 台 (デプロイ済み 12 台とは別)
- iOS デバイス + nRF Connect (または Ruuvi Station)
- DFU パッケージ生成ツール (`nrfutil`)
- Python 3.10 venv 環境 (`.venv310`)

### 5.2 DFU パッケージ生成

```bash
source .venv310/bin/activate

nrfutil pkg generate \
  --hw-version 0xB0 \
  --application src/targets/kaarle/armgcc/_build/nrf52832_xxaa.hex \
  --application-version 90 \
  --sd-req 0xB7 \
  --key-file keys/ruuvi_open_private.pem \
  nob_fw_v90.zip
```

**注意**:
- `--application-version 90` は現行 (89) より高いこと (ダウングレード防止)
- `--hw-version 0xB0` (0xCA は誤り)
- SoftDevice は含めない (アプリケーションのみ)

### 5.3 テスト項目

#### T1: 継続広告の動作確認

1. v90 を OTA でインストール
2. nRF Connect でスキャン開始
3. **検証**: "Kaarle XXXX" が 1 秒間隔で RSSI 更新されること
4. **検証**: DF5 ペイロードの movement_counter = 0x5A (90)
5. 60 秒以上観察し、広告が途切れないことを確認

#### T2: 起動シーケンス

1. デバイスをリセット (電池抜き差し)
2. nRF Connect でスキャン
3. **検証**: 起動直後 5 秒間は 100ms 高速広告
4. **検証**: 5 秒後に 1000ms 間隔の継続広告に遷移
5. **検証**: 広告タイプが CONNECTABLE_SCANNABLE であること

#### T3: GATT 接続/切断

1. nRF Connect でデバイスに接続
2. **検証**: 接続中は NONCONNECTABLE_NONSCANNABLE に切り替わること
3. NUS サービスが見えること確認
4. 切断
5. **検証**: 切断後 1 秒以内に CONNECTABLE_SCANNABLE 広告が再開すること

#### T4: TURBO 即時化

1. nRF Connect でデバイスに接続
2. NUS Characteristic に RE_ENV_ALL ログ読み出しコマンドを送信
3. **検証**: 接続パラメータが即座に 15-30ms に変更されること
   (nRF Connect の "Connection Parameters" タブで確認)
4. ログデータが送信されることを確認
5. 送信完了後に LOW_POWER パラメータに戻ることを確認

#### T5: Watchdog 正常動作

1. v90 で 5 分以上放置
2. **検証**: デバイスがリセットされないこと (heartbeat 80 秒、WDT 220 秒)
3. **検証**: 継続広告が止まらないこと

#### T6: OTA 再実行 (ブリック検証)

1. v90 から v90 を再度 OTA インストール
   (`--application-version 91` に変更して実行)
2. **検証**: OTA 成功、デバイスが正常起動すること
3. **検証**: 継続広告が動作すること

#### T7: 電池電圧確認

1. DF5 パケットの電圧フィールドを 24 時間モニタリング
2. **検証**: 電圧降下が想定内 (CR2477: ~3.0V → 2.9V/月 程度)

### 5.4 デプロイ判定基準

| 項目 | 基準 |
|---|---|
| T1-T3 | 全 PASS |
| T4 | PASS (接続パラメータ変更を確認) |
| T5 | 5 分以上安定 |
| T6 | OTA 成功 |
| T7 | 24h で異常降下なし |

全項目 PASS で七尾湾デプロイ用 OTA パッケージとして承認。
