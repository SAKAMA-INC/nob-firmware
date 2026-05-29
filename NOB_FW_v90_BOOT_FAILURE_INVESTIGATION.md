# NOB FW v90 起動失敗調査報告

**日付**: 2026-05-24  
**症状**: v90 OTA 後、通常モードの広告が出ない。DFU モードでは bootloader が生きている。

---

## 0. 緊急ロールバック

### v89 ロールバック DFU パッケージ

```
ファイル: nob_fw_v89_rollback.zip
場所:    /Users/sojunshibata/Desktop/Git/SAKAMA/nob-firmware/nob_fw_v89_rollback.zip
SHA256:  787e328d1e337145ca6676c522eaadeb2f8329b7c8bd43df084e1a9c7cfbc8fb
```

- v89 コードそのまま (git stash で v90 変更を退避してビルド)
- `--application-version 91` (v90 の 90 より高い値でダウングレード防止を回避)
- `--hw-version 0xB0`, `--sd-req 0xB7`

### ロールバック手順

1. デバイスを DFU モードにする (ボタン長押し or 電池抜き差し後にDFUモード待ち)
2. nRF Connect で "Kaarle" (DFU 表示) に接続
3. `nob_fw_v89_rollback.zip` を選択して DFU 実行
4. 完了後、通常モードで広告が出ることを確認

---

## 1. ビルドログ再確認

### 1.1 コンパイル・リンク警告

```
v90 フルビルド出力を精査: 警告 0 件、エラー 0 件
-Werror フラグ有効のため、警告があればビルド失敗するはず
```

### 1.2 リンカ出力

```
リンカ region overflow: なし
ASSERT チェック (map ファイルより):
  ASSERT ((TotalFlashUsed <= LENGTH (FLASH)), region FLASH overflowed) → PASS
  ASSERT ((__StackLimit >= __HeapLimit), region RAM overflowed with stack) → PASS
```

### 1.3 メモリ配置 (.map ファイル)

```
Flash: 0x26000 - 0x77FFF (328 KB)
  使用: text=100,168 + data=1,320 = 101,488 bytes (30.2%)
  余裕: 230 KB

RAM: 0x20002450 - 0x2000FFFF (56.2 KB)
  .data 終端: 0x20002964 (1,300 bytes)
  .bss 終端:  0x20006084 (15,396 bytes = data + bss)
  Heap:       0x20006088 - 0x20008087 (8 KB)
  Stack:      0x2000E000 - 0x2000FFFF (8 KB)
  Gap:        0x20008088 - 0x2000DFFF (24 KB 未使用)

  → RAM overflow なし。余裕十分。
```

### 1.4 v90 新規変数のメモリ配置

| 変数 | アドレス | サイズ | ファイル |
|---|---|---|---|
| `m_cont_adv_timer` | 0x20003774 | 4 bytes | app_heartbeat.c |
| `m_adv_msg` | 0x20003750 | 26 bytes | app_heartbeat.c |
| `m_adv_msg_valid` | 0x2000376A | 1 byte | app_heartbeat.c |
| `m_cont_adv_fail_count` | 0x2000376C | 4 bytes | app_heartbeat.c |
| `m_cont_adv_running` | 0x20003770 | 1 byte | app_heartbeat.c |

全て .bss セクション内、正常範囲。

---

## 2. continuous_adv 関連の起動シーケンス検証

### 2.1 起動時の呼び出し順序

```
main() → setup():
  72: ri_timer_init()           ← タイマシステム初期化
  73: ri_scheduler_init()       ← スケジューラ初期化
  77: app_led_init()            ← LED タイマ作成 (timer 0-1)
  79: app_button_init()         ← ボタンタイマ作成 (timer 2)
  82: app_log_init()            ← ログ初期化、purge_logs()
  85: app_comms_init(true)      ← 通信初期化
        → ri_timer_create(m_comm_timer)   ← timer 3
        → adv_init()
            → rt_adv_init()     ← 広告初期化
            → ri_adv_type_set(NONCONNECTABLE_NONSCANNABLE)
            → timed_switch_to_normal()    ← 5秒タイマ開始
        → gatt_init()
            → rt_gatt_adv_enable() → CONNECTABLE_SCANNABLE
  87: app_heartbeat_init()
        → ri_timer_create(heart_timer)    ← timer 4
        → ri_timer_create(m_cont_adv_timer) ← timer 5  ★NEW
        → ri_timer_start(heart_timer, 80000ms)
  88: app_heartbeat_start()
        → heartbeat()  ← 即時実行、m_adv_msg 更新、m_adv_msg_valid = true
  ...
  (5秒後)
  comm_mode_change_isr()
        → app_heartbeat_continuous_adv_start()  ★NEW
            → ri_timer_start(m_cont_adv_timer, 1000ms)
```

### 2.2 タイマプール使用量

| Index | タイマ | 作成元 |
|---|---|---|
| 0 | RTC counter_timer | ri_rtc_init() |
| 1 | yield wakeup_timer | ri_yield_init() |
| 2 | LED m_timer | app_led_init() |
| 3 | button m_button_timer | app_button_init() |
| 4 | comm m_comm_timer | app_comms_init() |
| 5 | heart_timer | app_heartbeat_init() |
| 6 | **m_cont_adv_timer** | **app_heartbeat_init() ★NEW** |
| 7-9 | 未使用 | — |

**RI_TIMER_MAX_INSTANCES = 10、使用 7 個。** タイマ枯渇なし。

### 2.3 ISR-safety

`continuous_adv_isr()` は APP_TIMER ISR (SWI1, priority 7) 内で実行。
呼び出す関数チェーン:
```
continuous_adv_isr()
  → memcpy() : ISR-safe
  → rt_adv_send_data()
    → ri_adv_send()
      → format_msg() : スタック上のみ操作、ISR-safe
      → set_phy_type() : 同上
      → nrf_queue_push() : ISR-safe (nrf_queue は atomic 操作)
      → prepare_tx()
        → sd_ble_gap_adv_set_configure() : SVC call、ISR-safe
        → sd_ble_gap_adv_start() : SVC call、ISR-safe
```

**全関数が ISR-safe。問題なし。**

### 2.4 エラー伝搬の問題

```c
// app_heartbeat_init():
err_code |= ri_timer_create(&heart_timer, ...);
err_code |= ri_timer_create(&m_cont_adv_timer, ...);  // ★失敗すると↓
if (RD_SUCCESS == err_code) {                           // ★ここがスキップ
    err_code |= ri_timer_start(heart_timer, ...);       // ★heart_timer 未開始
}
```

もし `m_cont_adv_timer` の作成が失敗すると **heart_timer も start されない**。
ただし、タイマプール (10個中7個) に余裕があるため、作成失敗自体は考えにくい。

---

## 3. ハードフォルトの可能性

### 3.1 HardFault_Handler

```c
// sdk_config.h:7452
#define HARDFAULT_HANDLER_ENABLED 0
```

**ハードフォルトハンドラは無効。** ハードフォルト時は SoftDevice の
デフォルトハンドラが呼ばれ、**無限ループまたはリセット**する。

### 3.2 スタックオーバーフロー

- スタック: 8 KB (0x2000E000 - 0x2000FFFF)
- `continuous_adv_isr` のスタック消費: `ri_comm_message_t` (26 bytes) + `rd_status_t` (4 bytes) + リターンアドレス等 ≈ 40 bytes
- `heartbeat()` のスタック消費: `ri_comm_message_t` (26 bytes) + `rd_sensor_data_t` + `float[]` + `size_t` ≈ 100 bytes
- 8 KB は十分。**スタックオーバーフローの可能性は低い。**

### 3.3 新規変数のメモリ配置

`m_adv_msg` (26 bytes) は .bss セクション、0x20003750。
.bss 全体終端は 0x20006084。Heap 開始は 0x20006088。
**オーバーラップなし。**

---

## 4. APP_LOG_INTERVAL_S = 600 変更の影響

### 4.1 heartbeat_overdue() への影響

```c
#define APP_HEARTBEAT_OVERDUE_INTERVAL_MS (160U * 1000U)  // 160秒
```

`APP_HEARTBEAT_INTERVAL_MS = 80000` (変更なし) の 2 倍で 160 秒。
`APP_LOG_INTERVAL_S` とは独立。**影響なし。**

### 4.2 WDT への影響

```c
#define APP_WDT_INTERVAL_MS (160000 + 60000) = 220000  // 220秒
```

heartbeat は 80 秒間隔で watchdog を feed する。220 秒以内に必ず feed される。
**影響なし。**

### 4.3 app_log_init() の purge_logs()

`app_log_init()` は起動時に `purge_logs()` を呼ぶ。これは `APP_LOG_INTERVAL_S` に
関係なく実行される。600 に変更しても `purge_logs()` の動作に影響なし。

### 4.4 app_log_process() の動作

```c
uint64_t next_sample_ms = m_last_sample_ms + (m_log_config.interval_s * 1000U);
```

`interval_s = 600` → `next_sample_ms` が 600,000ms (10分) 先に設定される。
heartbeat 80 秒ごとに `app_log_process()` が呼ばれるが、10 分経過するまで
サンプルは保存されない。**動作に問題なし。**

---

## 5. 最有力仮説と修正案

### 5.1 仮説: v90 のコードは正常に起動しているが、広告が見えない

**v90 の起動シーケンスにコード上の致命的バグは見つからなかった。**

考えられるシナリオ:

#### 仮説 A: DFU 直後の FDS 状態問題

`app_log_init()` → `purge_logs()` が起動時に全ログを消去する。
v89 から v90 への OTA 後、FDS のレイアウトが変わらないため問題ないはずだが、
FDS の GC (ガベージコレクション) がタイムアウトする可能性:

```c
// purge_logs() 内:
while (rt_flash_busy()) { ri_yield(); }
```

FDS GC 中に SoftDevice がフラッシュ操作をブロックすると、
`ri_yield()` のループが WDT タイムアウト (220秒) まで継続する可能性。
ただしこれは v89 でも同じ動作なので v90 固有ではない。

#### 仮説 B: 実は起動しているが heartbeat の 80 秒待ち

v90 の `continuous_adv_start` は **起動 5 秒後** の `comm_mode_change_isr` で
呼ばれる。ただし **最初の heartbeat が m_adv_msg_valid = true にするまで**
継続広告は空振り (m_adv_msg_valid = false のため)。

`app_heartbeat_start()` は `heartbeat()` を即時実行するので、
`m_adv_msg_valid = true` は起動直後に設定される。
さらに `send_adv()` が heartbeat 内で実行されるため、
heartbeat の最初の 2 回の広告 (1285ms × 2 = ~2.5s) は送信される。

**→ 起動直後に少なくとも数秒は広告が出るはず。出ないなら起動自体が失敗。**

#### 仮説 C: アプリケーション有効フラグの問題

DFU 完了後、bootloader が新アプリケーションを検証する。
CRC/署名チェックが通っても、`GPREGRET` レジスタの状態によっては
bootloader がアプリケーションを起動せず DFU モードに留まる可能性。

**確認方法**: DFU 完了後にデバイスが自動リセットされ、
nRF Connect で「DfuTarg」ではなく「Kaarle XXXX」が見えるか。
もし「DfuTarg」のまなら、bootloader がアプリを起動していない。

#### 仮説 D: OTA パッケージの署名/CRC 不一致 (最有力)

nrfutil が生成したパッケージの署名鍵が bootloader の公開鍵と一致していない場合、
DFU は「Success」と表示されても **bootloader がアプリ起動を拒否する**。

v89 ロールバックパッケージも同じ鍵 (`ruuvi_open_private.pem`) で生成しているので、
ロールバックが成功するなら鍵の問題ではない。

### 5.2 推奨される切り分け手順

```
Step 1: v89 ロールバックを実行
  → 成功: DFU パイプラインと鍵は正常。v90 コードに問題あり。
  → 失敗: DFU パイプラインまたは鍵に問題。

Step 2: (Step 1 成功の場合) v90 を最小変更で再テスト

  v90.1 案: continuous_adv のみ無効化して再テスト
    → app_config.h で APP_FW_VERSION_NUM = 90 のまま
    → app_comms.c の 3 箇所の continuous_adv 呼び出しをコメントアウト
    → CONN_PARAM_UPDATE_DELAY_MS = 0 は維持
    → APP_LOG_INTERVAL_S = 600 は維持
    → ビルド → DFU → 広告が出るか確認

  v90.2 案: APP_LOG_INTERVAL_S のみ変更して再テスト
    → continuous_adv を有効に戻す
    → APP_LOG_INTERVAL_S を 80 に戻す
    → ビルド → DFU → 広告が出るか確認

  この 2 段階で原因が continuous_adv か APP_LOG_INTERVAL_S か特定可能。

Step 3: RTT ログ有効化ビルドでデバッグ
  → application_mode_debug.h を使い、RI_LOG_ENABLED=1 でビルド
  → J-Link 接続で RTT ログ確認
```

### 5.3 最小変更 v90.1 案 (continuous_adv 無効化)

```diff
# app_comms.c:570
-        app_heartbeat_continuous_adv_start ();
+        // app_heartbeat_continuous_adv_start ();

# app_comms.c:362
-    err_code |= app_heartbeat_continuous_adv_stop ();
+    // err_code |= app_heartbeat_continuous_adv_stop ();

# app_comms.c:388
-    err_code |= app_heartbeat_continuous_adv_start ();
+    // err_code |= app_heartbeat_continuous_adv_start ();
```

これにより v89 + TURBO 即時化 + APP_LOG_INTERVAL_S=600 のみの状態で
起動確認できる。

---

## 6. 調査結論

**v90 のコードにはハードフォルトを引き起こす明確なバグは検出されなかった。**

- ビルド: 警告 0、リンカ overflow なし
- RAM: 余裕 24 KB 以上
- タイマ: 10 個中 7 個使用、枯渇なし
- ISR-safety: 全関数チェック済み、問題なし
- スタック: 8 KB、追加消費 ~40 bytes、問題なし
- APP_LOG_INTERVAL_S = 600: heartbeat/WDT に影響なし

**最有力仮説は「DFU は成功したが bootloader がアプリを起動していない」(仮説 C/D)。**
nRF Connect で DFU 後の広告名が「DfuTarg」なのか「Kaarle XXXX」なのかが
切り分けの鍵。

**次の一手**: v89 ロールバックを実行し、DFU パイプラインの正常性を確認する。
