# VDualGrid — Hướng dẫn chi tiết EA (MetaTrader 5)

Tài liệu mô tả **luồng vận hành**, **quy ước TEV / số dư**, và **từng nhóm input** của Expert Advisor **VDualGrid**, căn cứ mã nguồn `VDualGrid.mq5` — phiên bản **`#property version` 4.17**.

---

## 1. EA làm gì (tóm tắt)

VDualGrid là EA **lưới hai phía** quanh một **đường gốc (base)** trên **symbol** của chart đang gắn EA:

- **Chờ ảo (virtual pending):** EA giữ mức giá trong bộ nhớ; khi giá chạm mức, gửi **lệnh thị trường (market)** kèm **TP** theo cấu hình từng **chân** (4a–4d).
- Mỗi **bậc lưới** có **cả Buy và Sell** (bốn chân: Buy trên gốc, Sell dưới gốc, Sell trên gốc, Buy dưới gốc) — enum `ENUM_VGRID_LEG` trong mã.
- **Một magic** (`MagicNumber`) + **symbol chart** để nhận diện mọi vị thế / chờ ảo / deal của EA.
- **Bước lưới** đều theo **D** (`GridDistancePips`); không còn bước cấp số cộng.
- **Lot và TP** luôn theo **từng chân** (4a–4d). **Lot không scale theo TEV** (nhóm scale vốn theo TEV đã **gỡ khỏi mã**).
- Ngoài lưới: **gồng lãi tổng (6b)**, **cân bằng lệnh (6c)**, **lịch (8 / 8b)**, **push MT5 (9)**.
- **Tùy chọn (2e):** có thể **chỉ đặt gốc** sau khi **EMA nhanh cắt EMA chậm** (xem mục 5); khi đã có gốc, EA **không** dùng cắt EMA để đổi gốc.

---

## 2. Quy ước: TEV, số dư, nạp/rút

Khối comment đầu `VDualGrid.mq5` mô tả quy ước — nên đọc cùng bảng sau:

| Khái niệm | Ý nghĩa |
|-----------|---------|
| **`attachBalance`** | `ACCOUNT_BALANCE` tại **OnInit** (một lần). **Không** cập nhật khi nạp/rút sau đó. |
| **`initialCapitalBaselineUSD`** | **TEV** tại OnInit: *số dư lúc gắn + P/L đóng lệnh magic (tích lũy) + treo magic* tại thời điểm chụp. Dùng làm **mốc %** trong thông báo (`GetTradingEquityViewPctVsScaleBaseline`). **Không** dùng để nhân lot. |
| **TEV hiện tại** | `attachBalance + eaCumulativeTradingPL + floating(magic+symbol)` — mốc snapshot **không** tự chỉnh vì nạp/rút. |
| **Phạm vi lệnh** | Mọi quét vị thế / deal / chờ ảo: **`MagicNumber` + `_Symbol` chart** (không gộp magic khác). |

**Push MT5 (nhóm 9):** có thể hiển thị **số dư broker hiện tại** (`ACCOUNT_BALANCE` lúc gửi). **% trong tin** là **% TEV so với mốc gắn EA**, không nhất thiết trùng % giữa hai số dư nếu có nạp/rút hoặc TEV ≠ số dư.

---

## 3. Vòng đời: OnInit → OnTick → OnDeinit

### 3.1. `OnInit`

- Gán `MagicAA`, `pnt`, `dgt`; snapshot **`attachBalance`**, **`initialCapitalBaselineUSD`** (TEV mốc), biến peak/min equity toàn cục / phiên.
- **`StartupEmaCrossInitHandles()`** — nếu bật **2e**: tạo hai **`iMA`** (EMA nhanh / EMA chậm, `PRICE_CLOSE`). Chu kỳ trong input được chuẩn hóa: **luôn period nhỏ hơn = EMA nhanh**, lớn hơn = **chậm**; nếu hai số bằng nhau thì chậm = nhanh + 1.
- Handle **2d** (`g_initBaseEmaVirtGapHandle`) nếu bật vùng cấm Gốc–EMA.
- Handle **6c** (`g_orderBalanceEmaHandle`) nếu bật lọc EMA cân bằng.
- `g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent())` (khung giờ 8 + ngày 8b).

**Trong lịch (`g_runtimeSessionActive == true`):**

- **Bật 2e:** **không** đặt `basePrice` ngay; xóa chờ ảo / `gridLevels`; `sessionStartTime = 0`; log + push (nếu bật 9) báo **chờ cắt EMA** để đặt gốc.
- **Tắt 2e:** `basePrice = GridBasePriceAtPlacement()` (Bid), `InitializeGridLevels()`, push “EA đã khởi động” nếu bật.

**Ngoài lịch:** xóa chờ ảo / mảng mức, log chờ.

Cuối OnInit: nếu trong lịch, gọi `ManageGridOrders()` (khi chưa có gốc hàm này thoát sớm — không lỗi).

### 3.2. Phiên được phép chạy (`g_runtimeSessionActive`)

- **Ngoài lịch:** mỗi tick chỉ kiểm tra `IsSchedulingAllowedForNewSession`; khi true → `g_runtimeSessionActive = true`. Nếu **2e**: **không** đặt gốc ngay, chỉ log/push chờ EMA. Nếu **tắt 2e:** đặt gốc + `InitializeGridLevels()` + `ManageGridOrders()`.
- **Trong lịch, chưa có gốc (`basePrice <= 0`):** cần **`IsNowWithinRunWindow`** (nếu bật 8). Nếu **2e**: thêm điều kiện **`StartupEmaFastSlowCrossShift0vs1()`** — cắt EMA trên **shift 0 vs shift 1** (nến hiện tại so với nến đóng trước): cắt lên `f0>s0 && f1<=s1`, cắt xuống `f0<s0 && f1>=s1`. Khi đủ điều kiện → `basePrice = Bid`, `InitializeGridLevels()`, `ManageGridOrders()`.
- **Đã có gốc:** EA **không** gọi logic cắt 2e; lưới / 6b / 6c chạy bình thường.

### 3.3. `OnTick` — thứ tự chính

1. **`!g_runtimeSessionActive`:** như 3.2, rồi `return`.
2. **`basePrice <= 0`:** chờ khung giờ + (nếu có) cắt EMA → đặt gốc một lần → `return`.
3. **`basePrice > 0`** nhưng `gridLevels` thiếu so với `MaxGridLevels * 2`:** `InitializeGridLevels()` giữ nguyên gốc → `ManageGridOrders()` → `return`.
4. **Bình thường:** `ProcessVirtualPendingExecutions()` → `ProcessOrderBalanceMode()` (6c) → cộng profit+swap mở cho 6b → xử lý gồng (`ProcessCompound*`) → thống kê push → `TryArmCompoundTotalProfitMode` / `ProcessCompoundArming` → **`ManageGridOrdersThrottled()`** (tối đa ~1 lần/giây; khớp chờ ảo vẫn mỗi tick).

**Reset sau gồng — chạm SL chung (`CompoundResetAfterCommonSlHit`):** trong lịch, nếu **2e** bật → `basePrice = 0`, xóa mức lưới, **chờ cắt EMA** trước khi lưới mới (giống khởi động lại gốc). Nếu **tắt 2e:** đặt gốc Bid ngay như trước.

### 3.4. `OnDeinit`

- `IndicatorRelease` cho **6c**, **2d**, và **handle 2e** (`StartupEmaCrossReleaseHandles`).
- Xóa object chart `VPGrid_*`.
- Push “EA đã dừng” nếu bật nhóm 9.

---

## 4. Nhóm 1 — Lưới giá (GRID)

| Input | Ý nghĩa |
|-------|---------|
| `GridDistancePips` (D) | Khoảng cách **đều** giữa các mức (pip; quy ước point/pip theo symbol trong code). |
| `MaxGridLevels` | Số mức chờ ảo **mỗi phía** (trên và dưới gốc). |

**Mặc định trong repo:** `1000.0` pip, `50` mức mỗi phía.

---

## 5. Nhóm 2, 2c, 2d, 2e — Magic, replenish, vùng cấm, khởi động theo EMA

| Nhóm | Input chính | Ý nghĩa |
|------|-------------|---------|
| **2** | `MagicNumber`, `CommentOrder` | Magic chung; comment lệnh market. |
| **2c** | `EnableAutoReplenishVirtualOrders` | Bật = khớp/đóng xong **dựng lại** chờ ảo; tắt = một lần sau khi có gốc (cờ `g_gridBuiltOnceThisSession`). |
| **2d** | `EnableInitBaseEmaVirtGapBlock`, period, timeframe | Sau **khởi tạo lưới**, chụp đoạn giữa **gốc và EMA**; **chỉ cấm chờ ảo dạng Stop** trong zone (Limit không cấm). Chi tiết trong comment input. |
| **2e** | `EnableStartupEmaFastSlowCross`, `StartupEmaFastPeriod`, `StartupEmaSlowPeriod`, `StartupEmaCrossTimeframe` | Khi bật: **chỉ khi `basePrice <= 0`** mới chờ **cắt EMA (shift 0 vs 1)** rồi mới `basePrice = Bid`. Đã có gốc → **bỏ qua** mọi cắt sau. `PERIOD_CURRENT` = khung chart. |

**Mặc định trong repo (2e):** bật `true`, EMA nhanh **1**, chậm **100**, khung **M5**.

---

## 6. Nhóm 4 — Lot & TP theo chân (4a–4d)

- Nhóm **4** chỉ là tiêu đề; mọi lot/TP nằm ở **4a–4d** (`ENUM_VGRID_LEG`).
- **`ENUM_LOT_SCALE`:** `LOT_FIXED`, `LOT_ARITHMETIC`, `LOT_GEOMETRIC` — tăng lot theo **bậc lưới**, không liên quan TEV.
- **TP:** `VGridTpNext*` (TP theo mức lưới kế) và `VGridTpPips*` (khi không dùng TP theo mức kế).

**Mặc định lot/TP trong repo (tóm tắt):**

| Chân | L1 | Scale | Add | Mult | Max | TP next | TP pips |
|------|-----|-------|-----|------|-----|---------|---------|
| 4a Buy trên | 0.01 | ARITHMETIC | 0.02 | 1.5 | 3.0 | false | 0 |
| 4b Sell dưới | 0.01 | ARITHMETIC | 0.02 | 1.5 | 3.0 | false | 0 |
| 4c Sell trên | 0.01 | FIXED | 0.05 | 1.5 | 3.0 | true | 0 |
| 4d Buy dưới | 0.01 | FIXED | 0.05 | 1.5 | 3.0 | true | 0 |

*(Giá trị mặc định luôn lấy đúng dòng `input` trong `VDualGrid.mq5` nếu sau này đổi.)*

---

## 7. Nhóm 6b — Gồng lãi tổng (Compound)

- Bật `EnableCompoundTotalFloatingProfit` và `CompoundTotalProfitTriggerUSD > 0`.
- Ngưỡng: **Σ(profit+swap)** lệnh **đang mở** (magic+symbol), có thể **+ carry từ 6c** (`GetCompoundFloatingTriggerThresholdUsd`).
- Luồng tóm tắt: **ARM** (có nhánh hủy ARM) → kích hoạt → xóa chờ ảo, chờ bước lưới, SL chung, đóng một phía, SL trượt… — đọc các hàm `Compound*` trong mã.
- `CompoundResetOnCommonSlHit`: chạm SL chung → đóng / xóa lưới → chờ lịch hoặc đặt gốc lại (và **2e** nếu bật).

**Mặc định:** 6b bật, ngưỡng **20** USD, reset khi SL chung **bật**.

---

## 8. Nhóm 6c — Cân bằng lệnh

- `EnableOrderBalanceMode`: đủ **bậc** xa gốc, **phút** cùng phía, **lệch số lệnh** → đóng cả **phía yếu**.
- P/L đóng có thể **cộng vào ngưỡng Σ mở** của 6b.
- `EnableOrderBalanceEMAFilter` + `OrderBalanceEMAConfirmBars` / period / timeframe: lọc theo **N nến đã đóng** vs EMA.

**Mặc định:** bật; 4 bậc, 30 phút, cooldown 60s; lọc EMA bật, period **100**, **M5**, N = **10**.

---

## 9. Nhóm 8 / 8b — Lịch chạy

- **8:** `EnableRunTimeWindow` — khung **`RunStartHour:RunStartMinute` → `RunEndHour:RunEndMinute`** (giờ **server** MT5). `start == end` → coi như 24h (xem `IsNowWithinRunWindow` trong mã).
- **8b:** `EnableRunDayFilter` + `RunOnMonday` … `RunOnSunday`.
- Đang có lưới (đã có gốc) mà sang ngày tắt: EA có thể **chạy tiếp** đến khi reset; sau reset nếu ngoài lịch thì **chờ**.

**Mặc định:** khung giờ **tắt**; nếu bật thì **01:00 → 16:00** server. Lọc ngày **tắt**; mọi ngày **bật**.

---

## 10. Nhóm 9 — Push MT5

- `EnableResetNotification`: `SendNotification` (tối đa **255** ký tự) — symbol, lý do, **vốn mốc** (`GetScaleCapitalReferenceUSD`), **số dư hiện tại**, **% TEV vs mốc**.
- Cần **MetaQuotes ID** trên MT5 và app điện thoại để nhận push.

**Mặc định:** bật.

---

## 11. Telegram / phân tích chart (tùy biên dịch)

Trong mã có:

```text
#ifdef VDUALGRID_ENABLE_TELEGRAM
```

Bản **mặc định không định nghĩa** macro này thì chủ yếu dùng **push MT5**. Khi build có macro, xem thêm code trong `#ifdef`.

---

## 12. Khuyến nghị vận hành

- Chạy **Strategy Tester** / **demo** trước khi dùng tiền thật.
- Kiểm tra **pip/point** và quy mô lot theo symbol (JPY, crypto, CFD).
- Nếu tab Inputs vẫn hiện **nhóm “5. Vốn — scale TEV”** nhưng source **không còn** nhóm đó → bạn đang dùng **`.ex5` cũ** hoặc preset cũ; **compile lại** `VDualGrid.mq5` và gắn lại EA.

---

## 13. Tệp trong repo

| Tệp | Vai trò |
|-----|---------|
| `VDualGrid.mq5` | Toàn bộ logic EA |
| `README.md` | Tài liệu này |

Wrapper `#define VDUALGRID_SKIP_PROPERTIES` có thể ghi đè metadata — ngoài phạm vi README.

---

## 14. Tính năng / nhóm đã gỡ hoặc không còn trong mã

Để tránh nhầm với tài liệu hoặc preset cũ:

- **Nhóm 5 — scale lot theo TEV** (`EnableCapitalBasedScaling`, …): **đã xóa**; lot chỉ từ **4a–4d**.
- Bộ lọc **RSI / EMA đặt gốc / ADX** (nhóm 3 cũ), **chế độ một phía 2b** (nếu từng có).
- **Bước lưới cấp số cộng**; chỉ còn **D đều**.
- **Một bộ lot/TP chung** cho cả bốn chân — thay bằng **4a–4d**.
- **Reset phiên theo mục tiêu P/L**, **lỗ tối đa phiên kiểu 6 cũ**, **TP tổng (7)**, **SL khóa lãi theo bậc (4e)** — theo mục lịch sử trong comment mã / README cũ.

---

*Tài liệu mô tả kiến trúc và luồng theo mã; mọi ngưỡng cụ thể luôn lấy theo **input** trên terminal và **phiên bản** bạn đang biên dịch (`#property version`).*
