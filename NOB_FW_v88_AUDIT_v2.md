# NOB FW v88/v89 — BLE Advertising 構造 完全分析

**実施日**: 2026-05-24  
**対象ブランチ**: `v88-80sec-2.57adv` (APP_FW_VERSION_NUM = 89)  
**ボード**: Kaarle (hw 0xB0)

---

## 0. 結論: 前回の監査レポートの誤り

前回 `NOB_FW_v88_AUDIT.md` で「通常時は `NONCONNECTABLE_NONSCANNABLE`」と記載したが、
これは **誤り** である。

**真実**: `app_comms_init()` の実行順序により、起動完了後の定常状態は
**`CONNECTABLE_SCANNABLE`** である。

```
app_comms_init()
  ├─ adv_init()       → ri_adv_type_set(NONCONNECTABLE_NONSCANNABLE)  ← ①
  └─ gatt_init()      → rt_gatt_adv_enable()
                         → rt_adv_connectability_set(true, "Kaarle XXXX")
                           → ri_adv_type_set(CONNECTABLE_SCANNABLE)    ← ② ★最終状態
                           → ri_adv_scan_response_setup(name, true)
```

② が ① を上書きするため、定常状態は `CONNECTABLE_SCANNABLE` + scan response 付き。

---

## 1. 広告タイプ遷移の全契機

### 1.1 ri_adv_type_set() 経由の変更

| # | トリガー | コールチェーン | 最終 type | ファイル:行 |
|---|---|---|---|---|
| ① | 起動: `adv_init()` | `rt_adv_init()` → `ri_adv_type_set()` + `adv_init()` 自体 | NONCONNECTABLE_NONSCANNABLE | `app_comms.c:597` |
| ② | 起動: `gatt_init()` | `rt_gatt_adv_enable()` → `rt_adv_connectability_set(true, name)` → `ri_adv_type_set()` | **CONNECTABLE_SCANNABLE** | `ruuvi_task_advertisement.c:132` |
| ③ | GATT 接続時 | `handle_gatt_connected()` → `rt_gatt_adv_disable()` → `rt_adv_connectability_set(false, NULL)` → `ri_adv_type_set()` | NONCONNECTABLE_NONSCANNABLE | `ruuvi_task_advertisement.c:120` |
| ④ | GATT 接続時 (続) | `handle_gatt_connected()` → `app_comms_ble_adv_init()` → `adv_init()` → ① 再実行 | NONCONNECTABLE_NONSCANNABLE | `app_comms.c:597` |
| ⑤ | GATT 切断時 | `handle_gatt_disconnected()` → `config_cleanup_on_disconnect()` → `enable_config_on_next_conn(false)` → `app_comms_ble_uninit()` + `app_comms_ble_init()` → ① + ② 再実行 | **CONNECTABLE_SCANNABLE** | `app_comms.c:650` |
| ⑥ | config 有効化時 | `app_comms_configure_next_enable()` → `enable_config_on_next_conn(true)` → 同上再初期化 | **CONNECTABLE_SCANNABLE** | `app_comms.c:480` |

### 1.2 SoftDevice ISR 内の暗黙変更 (ri_adv_type_set を迂回)

**ファイル**: `ruuvi_nrf5_sdk15_communication_ble_advertising.c:158-176`

```c
case BLE_GAP_EVT_CONNECTED:
    nrf_queue_reset(&m_adv_queue);
    if (CONNECTABLE_SCANNABLE == m_type)
        m_type = NONCONNECTABLE_SCANNABLE;     // ★ m_scannable は変更しない
    if (CONNECTABLE_NONSCANNABLE == m_type)
        m_type = NONCONNECTABLE_NONSCANNABLE;
    notify_adv_stop(RI_COMM_ABORTED);
```

**重要**: この ISR ハンドラは `m_type` のみを変更し、`m_scannable` を変更しない。
そのため CONNECTABLE_SCANNABLE → NONCONNECTABLE_SCANNABLE に変更された場合、
**接続中でも scan response データは保持される**。

### 1.3 定常状態まとめ

| 状態 | m_type | m_scannable | m_advertise_nus | Connectable | Scan Rsp |
|---|---|---|---|---|---|
| **起動完了後 (定常)** | CONNECTABLE_SCANNABLE | true | true | **Yes** | **Name + NUS UUID** |
| GATT 接続中 | NONCONNECTABLE_NONSCANNABLE | false | — | No | なし |
| GATT 切断後 (再初期化) | CONNECTABLE_SCANNABLE | true | true | **Yes** | **Name + NUS UUID** |

---

## 2. 広告パケット構造: CONNECTABLE_SCANNABLE モード (定常状態)

### 2.1 ADV_IND パケット (メイン広告)

**構築関数**: `format_adv()` @ `ruuvi_nrf5_sdk15_communication_ble_advertising.c:286-327`

```
┌────────────────────────────────────────────────────────────────┐
│  BLE ADV_IND パケット (最大 31 bytes)                          │
├────────────────────────────────────────────────────────────────┤
│  AD Structure 1: Flags (3 bytes)                               │
│    [02]  Length = 2                                             │
│    [01]  AD Type = Flags                                       │
│    [06]  Flags = LE_GENERAL_DISC_MODE | BR_EDR_NOT_SUPPORTED   │
├────────────────────────────────────────────────────────────────┤
│  AD Structure 2: Manufacturer Specific Data (27 bytes)         │
│    [1A]  Length = 26                                            │
│    [FF]  AD Type = Manufacturer Specific Data                  │
│    [99 04]  Company ID = 0x0499 (Ruuvi Innovations, LE)        │
│    [05]  DF5 Header                                            │
│    [TT TT]  温度 (int16, ×200)                                │
│    [HH HH]  湿度 (uint16, ×400)                               │
│    [PP PP]  気圧 (uint16, offset 50000)                        │
│    [AX AX]  加速度X (int16, ×1000, mG)                        │
│    [AY AY]  加速度Y                                            │
│    [AZ AZ]  加速度Z                                            │
│    [VV VV]  電圧(11bit) + TX電力(5bit)                         │
│    [59]     Movement counter = APP_FW_VERSION_NUM (89=0x59)    │
│    [SS SS]  Measurement sequence (uint16, rolling)             │
│    [MM MM MM MM MM MM]  MAC address (6 bytes, MSB first)       │
├────────────────────────────────────────────────────────────────┤
│  合計: 3 + 27 = 30 bytes                                      │
└────────────────────────────────────────────────────────────────┘
```

**根拠**:
- Company ID: `ruuvi_board_kaarle.h:47` → `RB_BLE_MANUFACTURER_ID = 0x0499`
- DF5 エンコード: `app_dataformats.c:91-135` → `re_5_encode()`
- `RE_5_DATA_LENGTH = 24` bytes (`ruuvi_endpoint_5.h:23`)
- Movement counter に FW version を代入: `app_dataformats.c:122`
- Flags 設定: `ruuvi_nrf5_sdk15_communication_ble_advertising.c:300-301`

### 2.2 SCAN_RSP パケット (スキャンレスポンス)

**構築関数**: `format_scan_rsp()` @ `ruuvi_nrf5_sdk15_communication_ble_advertising.c:329-362`

```
┌────────────────────────────────────────────────────────────────┐
│  SCAN_RSP パケット (最大 31 bytes)                              │
├────────────────────────────────────────────────────────────────┤
│  AD Structure 1: Complete Local Name (最大 13 bytes)            │
│    [0C]  Length = 12 (例: "Kaarle ABCD" = 11文字)              │
│    [09]  AD Type = Complete Local Name                         │
│    [4B 61 61 72 6C 65 20 41 42 43 44]  "Kaarle ABCD"          │
├────────────────────────────────────────────────────────────────┤
│  AD Structure 2: Complete List of 128-bit Service UUIDs        │
│  (m_advertise_nus == true の場合)                              │
│    [11]  Length = 17                                            │
│    [07]  AD Type = Complete List of 128-bit Service UUIDs      │
│    [9E CA DC 24 0E E5 A9 E0 93 F3 A3 B5 01 00 40 6E]         │
│     ↑ NUS UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E (LE)    │
├────────────────────────────────────────────────────────────────┤
│  合計: 13 + 18 = 31 bytes                                     │
└────────────────────────────────────────────────────────────────┘
```

**根拠**:
- Name: `app_comms.c:427` → `"Kaarle %04X"` (MAC 下位 4 hex)
- NUS UUID 登録: `ruuvi_nrf5_sdk15_communication_ble_advertising.c:100-103`
  ```c
  static ble_uuid_t m_adv_uuids[] = {
      {BLE_UUID_NUS_SERVICE, BLE_UUID_TYPE_VENDOR_BEGIN}  // {0x0001, 0x02}
  };
  ```
- `BLE_UUID_NUS_SERVICE = 0x0001` (`ble_nus.h:97`)
- `NUS_BASE_UUID = {0x9E,0xCA,0xDC,0x24,0x0E,0xE5,0xA9,0xE0,0x93,0xF3,0xA3,0xB5,0x00,0x00,0x40,0x6E}` (`ble_nus.c:64`)
- `ble_advdata_encode()` が SoftDevice の VS UUID テーブルから 128-bit に展開
- `format_scan_rsp` 呼び出し条件: `m_scannable == true` (`ruuvi_nrf5_sdk15_communication_ble_advertising.c:381-384`)
- `m_advertise_nus` 設定: `ri_adv_scan_response_setup()` @ 行 742-743

### 2.3 SoftDevice パラメータ

**ファイル**: `set_phy_type()` @ `ruuvi_nrf5_sdk15_communication_ble_advertising.c:450-513`

```
m_type = CONNECTABLE_SCANNABLE の場合:
  → adv.params.properties.type = BLE_GAP_ADV_TYPE_CONNECTABLE_SCANNABLE_UNDIRECTED

primary_phy:
  APP_MODULATION = RI_RADIO_BLE_2MBPS の場合:
  → adv.params.primary_phy = BLE_GAP_PHY_1MBPS (広告は常に 1MBPS)
  → secondary_phy は data_length <= 24 なので不要 (sec_phy_required = false)
```

---

## 3. 広告パケット構造: NONCONNECTABLE_NONSCANNABLE モード (GATT 接続中)

GATT 接続中は `handle_gatt_connected()` が呼ばれ:

```
handle_gatt_connected()                               // app_comms.c:359-368
  → rt_gatt_adv_disable()                             // NONCONNECTABLE_NONSCANNABLE に変更
  → app_comms_ble_adv_init()                          // 広告を再初期化
    → rt_adv_uninit() + adv_init()                    // app_comms.c:671-678
      → ri_adv_type_set(NONCONNECTABLE_NONSCANNABLE)  // m_scannable = false に
```

```
┌────────────────────────────────────────────────────────────────┐
│  BLE ADV_NONCONN_IND パケット (31 bytes max)                   │
├────────────────────────────────────────────────────────────────┤
│  AD Structure 1: Flags (3 bytes) — 上記と同一                  │
│  AD Structure 2: Manufacturer Specific Data (27 bytes) — 同一  │
├────────────────────────────────────────────────────────────────┤
│  SCAN_RSP: なし (m_scannable = false)                          │
│  Service UUID: なし                                            │
└────────────────────────────────────────────────────────────────┘
```

---

## 4. 0xFC98 の出所

### 4.1 ファームウェア内の検索結果

```bash
grep -rn "0xFC98\|0x98FC\|FC98\|fc98" . → 該当なし (0件)
```

**`0xFC98` はファームウェアのどこにも存在しない。**

### 4.2 ファームウェアが広告する全 UUID / ID

| 識別子 | 値 | 場所 | 広告パケット内の位置 |
|---|---|---|---|
| Manufacturer ID | `0x0499` (Ruuvi Innovations) | `ruuvi_board_kaarle.h:47` | ADV_IND: AD Type `0xFF` の Company ID |
| NUS Service UUID | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | `ble_nus.c:64` + `ble_nus.h:97` | SCAN_RSP: AD Type `0x07` (128-bit UUID) |
| DFU Service UUID | `0xFE59` (SIG registered) | Nordic SDK | GATT テーブルのみ (広告には含まれない) |
| DIS Service UUID | `0x180A` (SIG standard) | Nordic SDK | GATT テーブルのみ |

### 4.3 iOS が NOB を発見できる理由

iOS の `scanForPeripherals(withServices:)` の挙動:

| iOS のフィルタ設定 | NOB を発見できるか | 理由 |
|---|---|---|
| `withServices: nil` | ✅ Yes | 全 BLE デバイスをスキャン |
| `withServices: [CBUUID("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")]` | ✅ Yes | SCAN_RSP に NUS UUID が含まれる |
| `withServices: [CBUUID("FC98")]` | ❌ **No** | FC98 はどこにも広告されていない |

### 4.4 矛盾の解消: 考えられるシナリオ

**シナリオ A: iOS アプリが `nil` でスキャンしている**
→ `scanForPeripherals(withServices: nil)` で全デバイスを発見し、
  `didDiscoverPeripheral` コールバック内で manufacturer data (0x0499) や
  デバイス名 ("Kaarle") で二次フィルタしている可能性。

**シナリオ B: iOS アプリが NUS UUID でスキャンしている**
→ `CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")` で
  フィルタしており、FC98 は別の目的 (例: GATT 接続後のサービスディスカバリ) で使用。

**シナリオ C: FC98 は iOS アプリ側で定義されたカスタム UUID**
→ ファームウェアとは無関係に、iOS アプリのコード内で定義されている可能性。
  ファームウェア v88/v89 には該当する UUID を登録する仕組みが存在しない。

**シナリオ D: CoreBluetooth のキャッシュ**
→ iOS は過去に接続したデバイスの GATT サービステーブルをキャッシュする。
  もし過去のファームウェア版（別のサービス構成）で接続済みなら、
  キャッシュされた UUID でデバイスがマッチする可能性がある。
  → Settings > Bluetooth でデバイスを「忘れる」か、Bluetooth をオフ→オンで検証可能。

**推奨**: iOS アプリのソースで `FC98` の定義箇所を確認すること。

---

## 5. adv_set_configure の直接呼び出し

アプリ層 (`src/app_*.c`) から `sd_ble_gap_adv_set_configure` を直接呼んでいる箇所は **ない**。

全呼び出しは単一箇所:
```
prepare_tx() @ ruuvi_nrf5_sdk15_communication_ble_advertising.c:123
  → sd_ble_gap_adv_set_configure(&m_adv_handle, &adv.data, &adv.params)
```

呼び出しチェーン:
```
heartbeat() → send_adv() → rt_adv_send_data() → m_channel.send (= ri_adv_send)
  → nrf_queue_push() → prepare_tx() → sd_ble_gap_adv_set_configure()
```

---

## 6. Heartbeat 80 秒サイクルの完全な動作シーケンス

### 6.1 タイマー設定

```
APP_HEARTBEAT_INTERVAL_MS = 80,000ms (80 秒)    // app_config.h:6
APP_BLE_INTERVAL_MS       = 1,285ms             // application_mode_default.h:30
APP_NUM_REPEATS           = 2                    // app_config.h:5
```

### 6.2 1 サイクルの詳細タイムライン

```
t=0.000s  schedule_heartbeat_isr() → ri_scheduler_event_put(heartbeat)
          // app_heartbeat.c:148-151

t=0.001s  heartbeat() 実行開始
          // app_heartbeat.c:83

          ① app_sensor_get(&data)
             - 全センサーから最新データ読み取り
             - LIS2DH12 (SPI), SHTCX/TMP117 (I2C)
             // app_sensor.c:501-514

          ② app_dataformat_next() → 常に DF_5
             // app_dataformats.c:55-60

          ③ app_dataformat_encode() → encode_to_5()
             - 24 bytes の DF5 ペイロード生成
             // app_dataformats.c:91-135
             // movement_count = 89 (FW version)

          ④ send_adv(&msg)
             - msg.repeat_count = APP_NUM_REPEATS = 2
             - rt_adv_send_data() → ri_adv_send()
             // app_heartbeat.c:49-73

          ⑤ ri_adv_send() 内部処理:
             - format_adv(): Flags + Manufacturer Data を BLE advdata にエンコード
             - format_scan_rsp(): Name + NUS UUID をスキャンレスポンスにエンコード
               (m_scannable == true の場合のみ)
             - set_phy_type(): ADV type を CONNECTABLE_SCANNABLE_UNDIRECTED に設定
             - adv.params.max_adv_evts = 2
             - adv.params.interval = MSEC_TO_UNITS(1285, UNIT_0_625_MS) = 2056
             - nrf_queue_push() → prepare_tx()
             // ruuvi_nrf5_sdk15_communication_ble_advertising.c:530-570

          ⑥ prepare_tx()
             - sd_ble_gap_adv_set_configure()
             - sd_ble_gap_adv_start()
             // 行 106-144

t≈0.003s  SoftDevice: 1回目の広告イベント
          - ch37, ch38, ch39 で ADV_IND 送信 (30 bytes)
          - スキャナがいれば SCAN_REQ → SCAN_RSP (31 bytes) 応答
          - CONNECT_REQ を受け付け可能

t≈1.288s  SoftDevice: 2回目の広告イベント (1285ms + 0~10ms random delay)
          - 同一データで再送信

t≈1.290s  BLE_GAP_EVT_ADV_SET_TERMINATED
          - m_advertising = false
          - notify_adv_stop(RI_COMM_SENT)
          - prepare_tx() → キューが空なら何もしない

          ⑦ rt_gatt_send_asynchronous(&msg)
             - msg.data_length = 18 (DF5 データの先頭 18 bytes に切り詰め)
             - NUS 接続中なら BLE notification で送信
             - 未接続なら RD_ERROR_INVALID_STATE (無視)
             // app_heartbeat.c:109-113

          ⑧ rt_nfc_send(&msg)  // NFC 送信 (本機は NFC 非搭載)

          ⑨ app_log_process(&data)
             - 80 秒間隔でフラッシュにサンプル記録
             // app_heartbeat.c:137

t≈1.300s  heartbeat() 完了

t=1.3s ~ 80.0s  ★★★ 沈黙期間 (約 78.7 秒) ★★★
                 - BLE 広告なし
                 - デバイスは発見不可能

t=80.0s   次の heartbeat サイクル開始
```

### 6.3 起動直後の高速広告期間

```
起動時 adv_init():
  - adv_interval_ms = 100ms
  - repeat_count = min(80000/100, 254) = 254 回
  - 5 秒後に comm_mode_change_isr() が通常モードに切替
    → repeat_count = 2, interval = 1285ms
```

起動後 5 秒間は 100ms 間隔で高速広告が行われる。
ただしこの期間中に `gatt_init()` → `rt_gatt_adv_enable()` が実行されるため、
広告タイプは `CONNECTABLE_SCANNABLE` に切り替わる。

---

## 7. PHY の注意点

```
set_phy_type() @ ruuvi_nrf5_sdk15_communication_ble_advertising.c:438-447:

  case RI_RADIO_BLE_2MBPS:
      p_adv->params.primary_phy = BLE_GAP_PHY_1MBPS;  // ★ Primary PHY は常に 1MBPS
      if (sec_phy_required)
          p_adv->params.secondary_phy = BLE_GAP_PHY_2MBPS;  // Extended ADV のみ 2MBPS
```

**BLE 仕様上の制約**: Legacy ADV (非 Extended) の Primary PHY は必ず 1MBPS。
DF5 は 24 bytes ≤ `NONEXTENDED_ADV_MAX_LEN` (24) なので Extended 不要。
→ **広告パケットは常に 1MBPS で送信される。** `APP_MODULATION = RI_RADIO_BLE_2MBPS` は
  GATT 接続時の PHY にのみ影響する（ただし PHY 自発要求が `#if 0` で無効なため実質 1MBPS）。

---

## 8. 全ファイル:行 根拠一覧

| ファイル | 行 | 内容 |
|---|---|---|
| `src/app_comms.c` | 597 | `ri_adv_type_set(NONCONNECTABLE_NONSCANNABLE)` |
| `src/app_comms.c` | 626 | `rt_gatt_adv_enable()` — 最終的に CONNECTABLE_SCANNABLE |
| `src/app_comms.c` | 631-654 | `app_comms_init()` — adv_init() → gatt_init() の実行順序 |
| `src/app_comms.c` | 42 | `CONN_PARAM_UPDATE_DELAY_MS = 30s` |
| `src/app_comms.c` | 359-368 | `handle_gatt_connected()` — 接続時の広告再初期化 |
| `src/app_comms.c` | 560-568 | `comm_mode_change_isr()` — 通常モード切替 |
| `src/app_comms.c` | 591-594 | 初期広告設定: 100ms, +4dBm, 0x0499 |
| `src/app_heartbeat.c` | 49-73 | `send_adv()` — repeat_count 設定 |
| `src/app_heartbeat.c` | 83-138 | `heartbeat()` — 完全なデータ処理+送信フロー |
| `src/app_heartbeat.c` | 109 | GATT 送信時の `data_length = 18` 切り詰め |
| `src/app_dataformats.c` | 55-60 | `app_dataformat_next()` — 常に DF_5 |
| `src/app_dataformats.c` | 91-135 | `encode_to_5()` — DF5 エンコード |
| `src/app_dataformats.c` | 122 | `movement_count = APP_FW_VERSION_NUM` (89) |
| `src/app_dataformats.c` | 111-118 | 加速度 NaN 時の診断エンコード |
| `src/application_config/app_config.h` | 5-6 | `APP_NUM_REPEATS=2`, `HEARTBEAT=80s` |
| `src/application_config/application_mode_default.h` | 30 | `APP_BLE_INTERVAL_MS=1285` |
| `src/ruuvi.boards.c/ruuvi_board_kaarle.h` | 47 | `RB_BLE_MANUFACTURER_ID = 0x0499` |
| `src/ruuvi.boards.c/ruuvi_board_kaarle.h` | 44 | `RB_BLE_NAME_STRING = "Kaarle"` |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 81 | `m_scannable` 変数宣言 |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 86 | `m_advertise_nus` 変数宣言 |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 87 | `m_type` 変数宣言 |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 100-103 | `m_adv_uuids[]` — NUS UUID 定義 |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 106-144 | `prepare_tx()` — SD API 呼び出し |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 158-176 | ISR: BLE_GAP_EVT_CONNECTED 時の m_type 暗黙変更 |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 286-327 | `format_adv()` — ADV_IND 構築 |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 329-362 | `format_scan_rsp()` — SCAN_RSP 構築 |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 438-448 | PHY 設定: 2MBPS 選択時も primary = 1MBPS |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 478-492 | `m_type = CONNECTABLE_SCANNABLE` 時の ADV type 設定 |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 530-570 | `ri_adv_send()` — 送信処理全体 |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 732-744 | `ri_adv_scan_response_setup()` |
| `ruuvi_nrf5_sdk15_communication_ble_advertising.c` | 747-763 | `ri_adv_type_set()` |
| `ruuvi_task_advertisement.c` | 110-137 | `rt_adv_connectability_set()` |
| `ruuvi_task_advertisement.c` | 132-133 | `ri_adv_type_set(CONNECTABLE_SCANNABLE)` + scan rsp setup |
| `ruuvi_task_gatt.c` | 261-275 | `rt_gatt_adv_enable()` → `rt_adv_connectability_set(true, name)` |
| `ruuvi_task_gatt.c` | 277-291 | `rt_gatt_adv_disable()` → `rt_adv_connectability_set(false, NULL)` |
| `ruuvi_interface_communication_ble_gatt.h` | 28-33 | PPCP 定数 (TURBO/STANDARD/LOW_POWER) |
| `nRF5_SDK_15.3.0_59ac345/.../ble_nus.h` | 97 | `BLE_UUID_NUS_SERVICE = 0x0001` |
| `nRF5_SDK_15.3.0_59ac345/.../ble_nus.c` | 64 | `NUS_BASE_UUID` 定義 |
| `ruuvi_endpoint_5.h` | 23 | `RE_5_DATA_LENGTH = 24` |

---

## 9. 前回監査レポートへの正誤表

| 項目 | v1 での記載 | 修正 |
|---|---|---|
| 定常広告タイプ | NONCONNECTABLE_NONSCANNABLE | **CONNECTABLE_SCANNABLE** |
| Scan Response | 言及なし | **Name + NUS 128-bit UUID が含まれる** |
| 発見可能性 | 暗黙的に「発見しにくい」 | **CONNECTABLE_SCANNABLE のため iOS のサービスフィルタでも発見可能 (NUS UUID で)** |
| 80 秒サイクル中の広告時間 | 言及なし | **約 1.3 秒のみ広告、残り 78.7 秒は沈黙** |
| PHY | 「広告は 2MBPS」 | **広告は常に 1MBPS** (BLE 仕様上、Legacy ADV の Primary PHY は 1MBPS 固定) |
