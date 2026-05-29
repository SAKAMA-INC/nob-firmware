# NOB Firmware v88/v89 — BLE 同期パフォーマンス監査

**対象**: nRF52832 + SoftDevice S132 v7.x (SDK 15.3.0)  
**ブランチ**: `v88-80sec-2.57adv` (FW_VERSION_NUM = 89)  
**ボード**: Kaarle (hw-version 0xB0, sd-req 0xB7)  
**実施日**: 2026-05-24  

---

## 1. 現状コンフィグ表

### 1.1 SoftDevice / SDK Config

| シンボル | 現在値 | 目標値 | ファイル:行 | 備考 |
|---|---|---|---|---|
| `NRF_SDH_BLE_GAP_DATA_LENGTH` | **27** | 251 | `sdk_config.h:11902` | DLE 未使用。1 PDU = 27B、MTU23 の範囲内 |
| `NRF_SDH_BLE_GATT_MAX_MTU_SIZE` | **23** | 247 | `sdk_config.h:11931` | デフォルト MTU。BLE_NUS_MAX_DATA_LEN = 20B |
| `NRF_SDH_BLE_HVN_TX_QUEUE_SIZE` | **未設定 (=1)** | 6 | SoftDevice デフォルト | 1 notification/CE。連射不可 |
| `NRF_SDH_BLE_GAP_EVENT_LENGTH` | **6** (= 7.5ms) | 320 (= 400ms) | `sdk_config.h:11926` | CE あたりの送信枠が極小 |
| `NRF_SDH_BLE_PERIPHERAL_LINK_COUNT` | **1** | 1 | `nrf5_sdk15_config.h:99` | OK (GATT 有効時に上書き) |
| `NRF_SDH_BLE_GATTS_ATTR_TAB_SIZE` | **1408** | 1408 | `sdk_config.h:11936` | 変更不要 |
| `NRF_SDH_BLE_VS_UUID_COUNT` | **3** (DFU+DIS+NUS) | 3 | `nrf5_sdk15_config.h:105` | OK |

### 1.2 接続パラメータ (PPCP)

| モード | Min Interval | Max Interval | Slave Latency | Supervision Timeout | 定義場所 |
|---|---|---|---|---|---|
| STANDARD (初期値) | **480ms** | **510ms** | **1** | 6000ms | `ruuvi_interface_communication_ble_gatt.h:30-31` |
| TURBO | 15ms | 30ms | 0 | 6000ms | `ruuvi_interface_communication_ble_gatt.h:28-29` |
| LOW_POWER | 1950ms | 1980ms | 0 | 6000ms | `ruuvi_interface_communication_ble_gatt.h:32-33` |

**問題点:**

1. **初期接続が STANDARD (480–510ms)** — 接続直後の応答が遅い
2. **TURBO 切替が 30 秒遅延** — `CONN_PARAM_UPDATE_DELAY_MS = 30000` (`app_comms.c:42`)
3. GATT データ応答完了後に **即座に LOW_POWER** に切り替え (`app_comms.c:317`)
4. `sd_ble_gap_ppcp_set()` で STANDARD を設定 → `gap_params_init()` (`ruuvi_nrf5_sdk15_communication_ble_gatt.c:167-183`)
5. ペリフェラル側からの `sd_ble_gap_conn_param_update()` は `ble_conn_params` モジュール経由で実行

### 1.3 PHY / DLE / MTU ネゴシエーション

| 機能 | 状態 | ファイル:行 | 備考 |
|---|---|---|---|
| **PHY 初期設定** | `BLE_GAP_PHY_1MBPS` | `ruuvi_..._ble_gatt.c:128-130` | `m_phys` 初期値 |
| **PHY setup_phys()** | 2MBPS 設定 | `ruuvi_..._ble_gatt.c:625-626` | `APP_MODULATION = RI_RADIO_BLE_2MBPS` (kaarle 対応) |
| **接続時 PHY 自発要求** | **`#if 0` で無効** | `ruuvi_..._ble_gatt.c:304-311` | "Crashes on older iOS/Mac" コメント |
| **PHY_UPDATE_REQUEST 応答** | ✅ 応答あり | `ruuvi_..._ble_gatt.c:330-334` | リアクティブ (中央が要求した場合のみ) |
| **PHY_UPDATE ハンドラ** | ✅ ログのみ | `ruuvi_..._ble_gatt.c:337-357` | |
| **DLE 自発要求** | **❌ 未実装** | — | `sd_ble_gap_data_length_update()` 呼び出しなし |
| **DLE REQUEST ハンドラ** | **❌ 未実装** | — | `BLE_GAP_EVT_DATA_LENGTH_UPDATE_REQUEST` 未処理 |
| **MTU exchange 応答** | **❌ 「not supported」** | `ruuvi_..._ble_gatt.c:412-414` | `gatt_evt_handler` でログのみ |
| **MTU periph set** | 23 | `ruuvi_..._ble_gatt.c:717` | `NRF_SDH_BLE_GATT_MAX_MTU_SIZE = 23` |

**結論**: **1M PHY / MTU 23 / DLE OFF** のデフォルト動作に完全に落ちている。

---

## 2. データ転送プロトコル

### 2.1 BLE サービス構成

| Service | UUID | 用途 |
|---|---|---|
| NUS (Nordic UART Service) | `6E400001-...` | センサーデータ転送 (Notify) |
| DFU (Buttonless DFU) | `0xFE59` | OTA ファームウェア更新 |
| DIS (Device Information) | `0x180A` | デバイス情報 |

### 2.2 データ転送パターン

```
RE_STANDARD_MESSAGE_LENGTH = 3 (header) + 8 (payload) = 11 bytes/notification
BLE_NUS_MAX_DATA_LEN = MTU(23) - 3 (ATT overhead) = 20 bytes
```

**転送フロー** (`app_sensor.c` → `app_comms.c`):

1. `handle_comms()` が GATT コマンドを受信 (`app_comms.c:263`)
2. heartbeat 停止 (`app_comms.c:284`)
3. TURBO 接続パラメータ要求（**30 秒遅延！**）(`app_comms.c:286`)
4. `app_sensor_log_read()` がループでサンプル読み出し (`app_sensor.c:920`)
5. **1 フィールドごとに 1 notification** を `send_field()` で送信 (`app_sensor.c:760-778`)
6. `app_comms_blocking_send()` は TX バッファ空き待ちでリトライ（4 秒タイムアウト）(`app_comms.c:688-717`)
7. `heartbeat_overdue()` で 160 秒超過時にタイムアウトで中断 (`app_sensor.c:935`)
8. 完了後 LOW_POWER に切替 (`app_comms.c:317`)

**ボトルネック分析**:

- 各サンプルが temperature + acc_x + acc_y + acc_z = **4 フィールド → 4 notifications**
- 1 notification = 11 bytes + ATT header 3 bytes = 14 bytes / PDU
- HVN TX Queue = 1 → 1 notification 完了待ち → 次の notification
- Connection interval 480ms (STANDARD) × 4 notifications = **1920ms/sample**
- TURBO (15-30ms) でも GAP Event Length 7.5ms → CE あたり 1 packet のみ
- 8400 samples × 4 fields = 33,600 notifications → **推定 18+ 時間** (STANDARD) or **16-50 分** (TURBO, 1pkt/CE)

### 2.3 Heartbeat GATT 送信

```c
// app_heartbeat.c:109
msg.data_length = 18;   // ← DF5 広告データを 18B に切り詰め
msg.repeat_count = 1;
rt_gatt_send_asynchronous(&msg);
```

- 接続中の heartbeat は GATT notification でも送信
- 接続間隔 80 秒ごと

---

## 3. フラッシュストレージ

| 項目 | 値 | 根拠 |
|---|---|---|
| ストレージ方式 | **FDS** (Flash Data Storage) | `nrf5_sdk15_config.h:142` |
| APP_FLASH_PAGES | 44 | `app_config.h:324` |
| FDS 合計ページ | 45 (44 + 1 GC) | `nrf5_sdk15_config.h:144` |
| レコード数 | 42 (44 - 2) | `app_config.h:325` |
| 1 サンプル | 20 bytes | `app_log_element_t`: timestamp(4) + temp(4) + acc_xyz(12) |
| ブロックサイズ | 4000 bytes (4096 - 96 header) | `app_log.h:29` |
| サンプル/ブロック | 200 | 4000 / 20 |
| 総サンプル数 | **~8,400** (+RAM ブロック 200) | 42 × 200 |
| ロギング間隔 | 80 秒 | `app_config.h:350` |
| 保存期間 | **~7.8 日** | 8,600 × 80s |

**問題点:**

1. **「最後に送信成功したオフセット」が persistent でない** — ログは全サンプル送信後も残存、再接続で全量再送
2. **起動時にログ全消去** — `app_log_init()` が `purge_logs()` を呼ぶ (`app_log.c:199`)
3. GPREGRET 未使用 — resume state なし
4. フラッシュ消去は `ri_yield()` でブロッキング待機 — センサータスクとの衝突はなし（heartbeat 停止中のため）
5. `store_block()` はリトライロジックあり (`app_log.c:60-120`)

---

## 4. アドバタイジング

| 項目 | 値 | 根拠 |
|---|---|---|
| 初期間隔 | 100ms (5 秒間) | `app_comms.c:591`, `APP_FAST_ADV_TIME_MS` |
| 通常間隔 | **1285ms** | `application_mode_default.h:30` |
| 繰り返し | 2 回/heartbeat | `APP_NUM_REPEATS = 2` |
| heartbeat 間隔 | **80,000ms (80 秒)** | `app_config.h:6` |
| 広告タイプ | NONCONNECTABLE_NONSCANNABLE | `app_comms.c:597` |
| TX Power | +4 dBm (最大) | `adv_settings.adv_pwr_dbm = RB_TX_POWER_MAX` |
| チャンネル | 37, 38, 39 | `app_comms.c:587-589` |
| 変調 | 2MBPS (kaarle 対応) | `app_config.h:278`, `RB_BLE_2MBPS_SUPPORTED=1` |

**注意**: 広告は 2MBPS で送信されるが、GATT 接続は 1MBPS のまま。

**Wake-on-motion**: 
- `RB_INT_LEVEL_PIN` = `RB_PIN_UNUSED` (kaarle defaults) → **未対応**
- `RB_INT_ACC1_PIN` は定義済み (pin 30) だが FIFO 用
- `app_sensor_acc_thr_set()` は存在するが kaarle では `RB_INT_LEVEL_PIN` が未定義のため動作しない

---

## 5. ログ・診断

| 項目 | 状態 |
|---|---|
| `RI_LOG_ENABLED` | **0** (無効) |
| RTT/UART ログ | 無効 |
| Connection Event 統計 | 未実装 |
| スループット計測 | 未実装 |
| 診断用フィールド | SPI/I2C WHO_AM_I, bus_err, sensor_err を保持 (GATT 非公開) |

---

## 6. ボトルネック一覧（影響度順）

| # | ボトルネック | 影響度 | 根拠 |
|---|---|---|---|
| **B1** | MTU = 23, DLE OFF | **致命的** | 1 notification = 20B max。11B ペイロードに対しても ATT+L2CAP+LL オーバーヘッドが支配的。PDU あたり有効バイト率 ~40% |
| **B2** | GAP Event Length = 7.5ms | **致命的** | 1 CE あたり 1-2 packet しか送信できない。MTU を上げても GAP Event Length が短いと効果半減 |
| **B3** | HVN TX Queue = 1 | **重大** | Notification を 1 つずつしかキューできない。CE 内での連射が不可能 |
| **B4** | 1 フィールド = 1 notification | **重大** | 4 フィールド/sample → 4 notification。チャンク化なし。プロトコルオーバーヘッド 4 倍 |
| **B5** | 初期接続 CI = 480ms | **重大** | 接続後 30 秒間は CI 480ms のまま。TURBO 切替に 30 秒遅延あり |
| **B6** | PHY 1MBPS (自発要求無効) | **中** | 2MBPS 対応だが `#if 0` で無効。iOS が PHY 更新を要求しない場合 1MBPS 固定 |
| **B7** | ログ全消去 on boot | **中** | 電源喪失やリセットで全データ消失。七尾湾デプロイでは致命的 |
| **B8** | 送信完了ポインタ非永続化 | **中** | 再接続で全サンプル再送。帯域の無駄 |

### 推定スループット

| 構成 | 有効スループット | 8,400 samples (4 fields) の推定転送時間 |
|---|---|---|
| **現状** (MTU23, 1M, CI 480ms, GAP 7.5ms, Q1) | ~23 B/s | **~18 時間** |
| TURBO のみ (CI 15ms) | ~366 B/s | **~70 分** |
| TURBO + MTU247 + DLE + GAP320 + Q6 | ~8,000 B/s | **~3 分** |
| 上記 + チャンク化 (20 samples/pkt) | ~20,000 B/s | **~1 分** |

---

## 7. v89 最小パッチセット (Tier 1)

SoftDevice 領域・bootloader を一切触らない、SDK config + アプリコード変更のみ。

### 7.1 SDK Config 変更

**ファイル**: `src/ruuvi.drivers.c/src/nrf5_sdk15_platform/sdk_config.h`

```diff
-#define NRF_SDH_BLE_GAP_DATA_LENGTH 27
+#define NRF_SDH_BLE_GAP_DATA_LENGTH 251

-#define NRF_SDH_BLE_GAP_EVENT_LENGTH 6
+#define NRF_SDH_BLE_GAP_EVENT_LENGTH 6
 // ↑ sdk_config.h のデフォルト値は #ifndef ガード内なので、
 //   nrf5_sdk15_config.h で上書きする（下記参照）

-#define NRF_SDH_BLE_GATT_MAX_MTU_SIZE 23
+#define NRF_SDH_BLE_GATT_MAX_MTU_SIZE 247
```

**ファイル**: `src/ruuvi.drivers.c/src/nrf5_sdk15_platform/nrf5_sdk15_config.h`  
(GATT 有効ブロック内に追加)

```diff
 #if RUUVI_NRF5_SDK15_GATT_ENABLED
 #   define NRF_BLE_GATT_ENABLED (1U)
+#   define NRF_SDH_BLE_GAP_DATA_LENGTH (251U)
+#   define NRF_SDH_BLE_GATT_MAX_MTU_SIZE (247U)
+#   define NRF_SDH_BLE_GAP_EVENT_LENGTH (320U)
+#   define NRF_SDH_BLE_GATTS_ATTR_TAB_SIZE (1408U)
```

**注意**: `NRF_SDH_BLE_HVN_TX_QUEUE_SIZE` は sdk_config.h にシンボルがない。
SoftDevice の `ble_gatts_conn_cfg_t.hvn_tx_queue_size` を BLE stack 初期化時に設定する必要がある。
→ `nrf_sdh_ble_default_cfg_set()` 後に `ble_cfg_t` で上書きするか、
  もしくはランタイムで設定する実装が ruuvi.drivers.c に必要。

### 7.2 PHY 2MBPS 自発要求の有効化

**ファイル**: `src/ruuvi.drivers.c/src/nrf5_sdk15_platform/communication/ruuvi_nrf5_sdk15_communication_ble_gatt.c`

```diff
         case BLE_GAP_EVT_CONNECTED:
             m_conn_handle = p_ble_evt->evt.gap_evt.conn_handle;
             err_code = nrf_ble_qwr_conn_handle_assign (&m_qwr, m_conn_handle);
             LOG ("BLE Connected \r\n");
-            char msg[128];
-            sprintf (msg, "PHY: %s.\r\n", phy_str (m_phys));
             RD_ERROR_CHECK (ruuvi_nrf5_sdk15_to_ruuvi_error (err_code),
                             RD_SUCCESS);
-#           if 0
-            // Request preferred PHY on connection -
-            // Crashes connection on older iOS devices and Macs.
-            err_code = sd_ble_gap_phy_update (p_ble_evt->evt.gap_evt.conn_handle, &m_phys);
-            char msg[128];
-            snprintf (msg, sizeof (msg), "Request PHY update to %s.\r\n", phy_str (m_phys));
-            LOG (msg);
-#           endif
+            // Request 2M PHY after connection
+            err_code = sd_ble_gap_phy_update (p_ble_evt->evt.gap_evt.conn_handle, &m_phys);
+            {
+                char phy_msg[128];
+                snprintf (phy_msg, sizeof (phy_msg), "Request PHY update to %s.\r\n", phy_str (m_phys));
+                LOG (phy_msg);
+            }
             break;
```

### 7.3 DLE 自発要求の追加

**ファイル**: `src/ruuvi.drivers.c/src/nrf5_sdk15_platform/communication/ruuvi_nrf5_sdk15_communication_ble_gatt.c`

BLE_GAP_EVT_CONNECTED ハンドラ内、PHY 要求の後に追加:

```c
// Request DLE after connection
{
    ble_gap_data_length_params_t dl_params = {0};
    dl_params.max_tx_octets = NRF_SDH_BLE_GAP_DATA_LENGTH;
    dl_params.max_rx_octets = NRF_SDH_BLE_GAP_DATA_LENGTH;
    sd_ble_gap_data_length_update(p_ble_evt->evt.gap_evt.conn_handle,
                                   &dl_params, NULL);
    LOG("DLE update requested\r\n");
}
```

`BLE_GAP_EVT_DATA_LENGTH_UPDATE_REQUEST` ハンドラを `ble_evt_handler()` に追加:

```c
case BLE_GAP_EVT_DATA_LENGTH_UPDATE_REQUEST:
    sd_ble_gap_data_length_update(p_ble_evt->evt.gap_evt.conn_handle,
                                   NULL, NULL); // Accept peer's parameters
    LOG("DLE request accepted\r\n");
    break;

case BLE_GAP_EVT_DATA_LENGTH_UPDATE:
    LOG("DLE update complete\r\n");
    break;
```

### 7.4 MTU exchange 応答の修正

**ファイル**: `src/ruuvi.drivers.c/src/nrf5_sdk15_platform/communication/ruuvi_nrf5_sdk15_communication_ble_gatt.c`

`gatt_evt_handler()` を修正:

```diff
 static void gatt_evt_handler (nrf_ble_gatt_t * p_gatt, nrf_ble_gatt_evt_t const * p_evt)
 {
     if ( (m_conn_handle == p_evt->conn_handle)
             && (p_evt->evt_id == NRF_BLE_GATT_EVT_ATT_MTU_UPDATED))
     {
-        //m_ble_nus_max_data_len = p_evt->params.att_mtu_effective - OPCODE_LENGTH - HANDLE_LENGTH;
-        LOGD ("Changing MTU size is not supported\r\n");
+        char msg[128];
+        snprintf(msg, sizeof(msg), "MTU updated to %d\r\n", p_evt->params.att_mtu_effective);
+        LOG(msg);
     }
 }
```

**注意**: `nrf_ble_gatt` モジュールが `BLE_GATTS_EVT_EXCHANGE_MTU_REQUEST` を自動処理する。
`NRF_SDH_BLE_GATT_MAX_MTU_SIZE` を 247 に設定すれば、`nrf_ble_gatt_att_mtu_periph_set()` 呼び出しで自動応答される。

### 7.5 PPCP / TURBO 遅延の短縮

**ファイル**: `src/app_comms.c`

```diff
-#define CONN_PARAM_UPDATE_DELAY_MS (30U * 1000U)
+#define CONN_PARAM_UPDATE_DELAY_MS (0U)  // 即座に TURBO に切替
```

**ファイル**: `src/ruuvi.drivers.c/src/interfaces/communication/ruuvi_interface_communication_ble_gatt.h`

```diff
-#define RI_GATT_MIN_INTERVAL_STANDARD_MS  (480U)
-#define RI_GATT_MAX_INTERVAL_STANDARD_MS  (510U)
+#define RI_GATT_MIN_INTERVAL_STANDARD_MS  (15U)
+#define RI_GATT_MAX_INTERVAL_STANDARD_MS  (30U)
```

→ PPCP 初期値を TURBO 相当にする（Apple ガイドライン準拠: min ≥ 15ms）

### 7.6 RAM 計算

**リンカスクリプト**: `src/targets/kaarle/armgcc/kaarle.ld`

```
現状:  RAM ORIGIN = 0x20002450, LENGTH = 0xDBB0
       → 終端 0x20010000 (nRF52832 全 64KB)
       → SD が使用: 0x20000000 ~ 0x20002450 = 9,296 bytes
```

MTU 247 + GAP Event Length 320 + HVN TX Queue 6 に変更した場合:
- MTU 増加分: (247 - 23) × 2 (TX+RX) = 448 bytes
- GAP Event Length: 主に SoftDevice 内部バッファ、RAM 直接増加は小 (~100 bytes)
- HVN TX Queue: (6 - 1) × ~40 bytes = 200 bytes
- **推定追加 RAM**: ~800 bytes → 新 ORIGIN ≈ 0x20002780

```diff
-  RAM (rwx) :  ORIGIN = 0x20002450, LENGTH = 0xDBB0
+  RAM (rwx) :  ORIGIN = 0x20002780, LENGTH = 0xD880
```

**注意**: 正確な値は `nrf_sdh_ble_default_cfg_set()` の戻り値 (必要 RAM 開始アドレス) で確認すること。
ビルド時に `NRF_LOG_INFO("RAM start: 0x%x", ram_start)` で取得可能。

---

## 8. v90 リファクタ範囲 (Tier 2)

### 8.1 チャンクプロトコル導入

対象関数:

| 関数 | ファイル | 変更内容 |
|---|---|---|
| `app_sensor_log_read()` | `app_sensor.c:876-963` | 複数サンプルをバッファに詰めて 1 notification で送信 |
| `app_sensor_send_data()` | `app_sensor.c:796-821` | 全フィールドを 1 メッセージに pack |
| `send_field()` | `app_sensor.c:760-778` | 廃止、チャンク送信に統合 |
| `app_sensor_encode_log()` | `app_sensor.c:731-751` | チャンク対応エンコーダに変更 |
| `app_comms_blocking_send()` | `app_comms.c:688-717` | BLE_GATTS_EVT_HVN_TX_COMPLETE で次チャンク発射に変更 |

**新プロトコル概要**:
- MTU 247 → NUS payload 244 bytes
- 1 sample = 20 bytes (timestamp_s + temp + acc_xyz)
- 1 notification = **12 samples** (240 bytes ≤ 244)
- 8,400 samples → **700 notifications** (現行 33,600 から 98% 削減)
- HVN TX Queue 6 → CE あたり最大 6 notifications
- CI 15ms → ~400 notifications/sec → **全データ ~2 秒**

### 8.2 送信済みポインタの永続化

| 関数/構造体 | ファイル | 変更内容 |
|---|---|---|
| `app_log_config_t` | `app_log.h:31-40` | `last_sent_timestamp_s` フィールド追加 |
| `app_log_init()` | `app_log.c:167-203` | `purge_logs()` 削除、代わりに last_sent から送信 |
| `app_sensor_log_read()` | `app_sensor.c:876` | 送信完了後に `last_sent_timestamp_s` を FDS に書き戻し |

### 8.3 iOS 互換 PHY フォールバック

`BLE_GAP_EVT_PHY_UPDATE` ハンドラで PHY 更新が rejected された場合に 1MBPS にフォールバック:

```c
case BLE_GAP_EVT_PHY_UPDATE:
    if (p_phy_evt->status != BLE_HCI_STATUS_CODE_SUCCESS) {
        m_phys.tx_phys = BLE_GAP_PHY_1MBPS;
        m_phys.rx_phys = BLE_GAP_PHY_1MBPS;
    }
    break;
```

---

## 9. 互換性メモ

### 9.1 iOS アプリとの互換性

| 変更 | 旧 iOS アプリへの影響 | 対策 |
|---|---|---|
| MTU 247 | ✅ 互換 | MTU exchange は中央主導。旧アプリが MTU exchange しなければ 23 のまま |
| DLE 251 | ✅ 互換 | DLE も negotiate-down する。旧端末は 27 のまま |
| PHY 2MBPS | ⚠️ 要検証 | 旧 iOS (iPhone 7 以前) は 2MBPS 非対応。SoftDevice が自動 fallback するが、一部端末で接続失敗の報告あり (コメント参照) |
| PPCP 15-30ms | ⚠️ 要検証 | Apple ガイドライン準拠だが、省電力端末で rejection される可能性 |
| Service UUID | ✅ 変更なし | NUS/DFU/DIS UUID は不変 |
| メッセージ長 | ✅ 互換 (Tier 1) | Tier 1 ではメッセージ構造変更なし |
| チャンクプロトコル (Tier 2) | ❌ **非互換** | iOS アプリ側の解析ロジック変更が必須 |

### 9.2 旧 FW + 新アプリ

- 旧 FW は MTU 23 / DLE 27 を応答する → 新アプリは negotiate-down して動作
- チャンクプロトコル (Tier 2) は FW バージョン番号で分岐

---

## 10. OTA リスク評価

| パッチ | SoftDevice 変更 | ブリック リスク | 備考 |
|---|---|---|---|
| SDK Config 変更 | ❌ 不要 | **低** | RAM 開始アドレスのみ変更。SoftDevice バイナリは不変 |
| PHY/DLE/MTU 自発要求 | ❌ 不要 | **低** | SoftDevice API 呼び出しのみ。失敗しても接続断で復帰 |
| PPCP 変更 | ❌ 不要 | **低** | 接続パラメータの変更。失敗時は disconnect |
| リンカ RAM 調整 | ❌ 不要 | **中** | RAM 開始アドレスが正確でないと起動時にハードフォルト。ビルド時に検証必須 |
| チャンクプロトコル (Tier 2) | ❌ 不要 | **低** | アプリ層のみ。GATT サービス構造は不変 |

### OTA 安全策

1. **`--application-version`** を現行より必ず高く設定（ダウングレード防止）
2. **`--hw-version 0xB0`** を指定（0xCA は誤り、実機検証済み）
3. **`--sd-req 0xB7`** (S132 v7.0.1) — SoftDevice は変更しないため同一 req
4. DFU パッケージに **SoftDevice を含めない** — アプリケーションのみ更新
5. DFU 失敗時は bootloader が旧 FW を保持 — 再試行可能
6. 12 台すべてが陸上回収が必要な海上デプロイのため、**テスト機で OTA 検証後に展開**

---

## 11. 変更対象ファイル一覧

### Tier 1 (v89 パッチ)

| ファイル | 変更種別 |
|---|---|
| `src/ruuvi.drivers.c/src/nrf5_sdk15_platform/sdk_config.h` | SDK config 値変更 |
| `src/ruuvi.drivers.c/src/nrf5_sdk15_platform/nrf5_sdk15_config.h` | GAP/MTU/DLE 定義追加 |
| `src/ruuvi.drivers.c/src/nrf5_sdk15_platform/communication/ruuvi_nrf5_sdk15_communication_ble_gatt.c` | PHY/DLE 自発要求、MTU 応答修正 |
| `src/ruuvi.drivers.c/src/interfaces/communication/ruuvi_interface_communication_ble_gatt.h` | PPCP 定数変更 |
| `src/app_comms.c` | TURBO 遅延削除 |
| `src/targets/kaarle/armgcc/kaarle.ld` | RAM origin 調整 |

### Tier 2 (v90 リファクタ)

| ファイル | 変更種別 |
|---|---|
| `src/app_sensor.c` | チャンクプロトコル実装 |
| `src/app_log.c` | 送信済みポインタ永続化 |
| `src/app_log.h` | 構造体変更 |
| `src/app_comms.c` | HVN_TX_COMPLETE 駆動の連射送信 |

---

## 付録: リンカメモリマップ

```
nRF52832 メモリマップ (kaarle):

FLASH:
  0x00000000 - 0x00000FFF  MBR (4 KB)
  0x00001000 - 0x00025FFF  SoftDevice S132 v7.0.1 (148 KB)
  0x00026000 - 0x00077FFF  Application (328 KB)
    0x00060000 - 0x00074FFF  FDS storage (84 KB = 21 pages × 4KB)
  0x00078000 - 0x0007DFFF  Bootloader (24 KB)
  0x0007E000 - 0x0007EFFF  MBR params page
  0x0007F000 - 0x0007FFFF  Bootloader settings page

RAM:
  0x20000000 - 0x2000244F  SoftDevice RAM (~9.3 KB)
  0x20002450 - 0x2000FFFF  Application RAM (~56.2 KB)

storage_flash セクション: 0x60000 - 0x74FFF (84 KB)
  → APP_FLASH_PAGES = 44 + 1 GC = 45 pages = 180 KB 要求
  → リンカスクリプトでは 0x15000 (84 KB) のみ確保
  → 実際の FDS ページ割り当ては FDS 内部で管理
```
