# VDualGrid — Hướng dẫn cách EA hoạt động

Tài liệu mô tả **luồng vận hành** và **ý nghĩa các nhóm input** của Expert Advisor **VDualGrid** (MetaTrader 5). Phiên bản tài liệu căn cứ mã nguồn kèm `#property version` trong file `VDualGrid.mq5`.

---

## 1. EA làm gì (tóm tắt)

VDualGrid là EA **lưới hai phía** quanh một **đường gốc (base)** trên cùng **symbol** của biểu đồ đang gắn EA:

- **Lệnh chờ ảo (virtual pending)** được quản lý trong bộ nhớ EA (không phải toàn bộ lệnh chờ trên server). Khi giá chạm mức, EA có thể gửi **lệnh thật** (market/limit/stop tuỳ thiết kế từng nhánh trong code).
- Mỗi **bậc lưới** (trên/dưới gốc) có thể có **cả Buy và Sell** (bốn “chân”: Buy trên gốc, Sell dưới gốc, Sell trên gốc, Buy dưới gốc) — xem enum `ENUM_VGRID_LEG` trong mã.
- **Một magic** (`MagicNumber`) dùng chung để nhận diện lệnh/vị thế của EA trên symbol đó.
- **Phiên (session)**: có cơ chế **reset phiên** theo P/L, **lỗ tối đa phiên**, **gồng lãi tổng (6b)**, **cân bằng lệnh (6c)**, **TP tổng (7)**, và **lịch chạy (8/8b)**.

---

## 2. Quy ước quan trọng: TEV, số dư, nạp/rút

Trong phần đầu file có khối comment quy ước — **rất nên đọc** trước khi hiểu scale và %:

| Khái niệm | Ý nghĩa |
|-----------|---------|
| **`attachBalance`** | `ACCOUNT_BALANCE` tại **OnInit** (một lần). **Không** cập nhật khi nạp/rút sau đó. |
| **`initialCapitalBaselineUSD`** | **TEV** (Trading Equity View) tại OnInit: công thức trong code là **số dư lúc gắn + P/L đóng lệnh magic tích lũy + treo magic** tại thời điểm chụp; dùng làm **mốc %** và (khi bật) **scale lot**. **Reset phiên không làm mới mốc này.** |
| **TEV hiện tại** | `attachBalance + eaCumulativeTradingPL + floating(magic+symbol)` — **không** “ăn” nạp/rút vào các biến mốc đã snapshot. |
| **Phạm vi lệnh** | Mọi đếm/quét vị thế, lệnh chờ, deal… chỉ lọc **`MagicNumber` + `_Symbol` biểu đồ** (không gộp magic khác). |

**Push MT5 (nhóm 9):** tin ngắn có thể hiển thị **số dư broker hiện tại** (đọc `ACCOUNT_BALANCE` lúc gửi) để tiện xem; **% trong push** là **% TEV so mốc gắn EA** (`GetTradingEquityViewPctVsScaleBaseline`), không nhất thiết bằng % giữa hai số dư nếu có nạp/rút hoặc TEV ≠ số dư.

---

## 3. Vòng đời từ khi gắn EA

### 3.1. `OnInit`

- Lưu snapshot **số dư / TEV mốc**, khởi tạo handle chỉ báo (RSI, EMA đặt gốc, ADX, EMA nhóm 2d, EMA nhóm 6c nếu dùng), cờ lịch phiên `g_runtimeSessionActive`, v.v.
- Có thể gửi thông báo khởi động nếu bật push (tuỳ nhánh compile).

### 3.2. Phiên “được phép chạy” (`g_runtimeSessionActive`)

- Nếu **chưa** trong lịch cho phép (`IsSchedulingAllowedForNewSession` = false): EA **chờ**; không coi là đang chạy phiên giao dịch đầy đủ.
- Khi **vào lịch**: nếu thỏa bộ lọc đặt gốc (`GridStartTimeAndRSIOk`) → đặt `basePrice`, `InitializeGridLevels()`, dựng chờ ảo / quản lý; nếu chưa thỏa → **chờ tín hiệu** (RSI/EMA/ADX nếu bật), chưa có gốc.

### 3.3. `OnTick` — các giai đoạn chính

1. **Ngoài lịch** (khi `g_runtimeSessionActive` false): chỉ kiểm tra có vào khung giờ/ngày không; có thể bật phiên mới và khởi tạo như trên.
2. **Chưa có gốc** (`basePrice <= 0`): cập nhật latch RSI/EMA, kiểm tra `GridStartTimeAndRSIOk`; đủ → `GridBasePriceAtPlacement()`, `InitializeGridLevels()`, `ManageGridOrders()`.
3. **Đã có gốc** nhưng mảng mức lưới thiếu so với kỳ vọng: `InitializeGridLevels()` nạp lại (giữ nguyên gốc).
4. **Bình thường**:
   - `ProcessVirtualPendingExecutions()` — xử lý khớp chờ ảo.
   - `ProcessOrderBalanceMode()` — nhóm **6c** nếu bật.
   - Tính **floating**, **lot mở**, **tổng profit+swap mở** phục vụ gồng 6b.
   - Nếu đang **gồng hoạt động** → `ProcessCompoundTotalProfitTrailing()`; nếu đang **chờ +1 bước sau kích hoạt** → `ProcessCompoundPostActivationGridStepWait()`; ngược lại có thể áp **SL khóa lãi theo bậc (4e)** qua `ApplyGridProfitLockStops()`.
   - Thống kê cho thông báo (nếu bật).
   - **ARM gồng**: điều kiện ngưỡng Σ(profit+swap) mở + chưa ở trạng thái gồng/chờ bước → `TryArmCompoundTotalProfitMode()`.
   - `ProcessCompoundArming()` — xử lý giai đoạn “vũ trang” trước khi xóa chờ ảo.
   - **Reset phiên / lỗ tối đa** (mục 6 dưới đây).
   - `ManageGridOrders()` và các bước kế (bảo trì lưới, đặt lại chờ ảo, v.v.).

### 3.4. `OnDeinit`

- Giải phóng handle, có thể gửi push “EA đã dừng” nếu bật.

---

## 4. Nhóm 1 — Lưới giá (GRID)

- **`GridDistancePips` (D):** khoảng cách giữa các mức theo **pip** (trong code pip thường gắn với `point * 10` cho symbol 5 chữ số — theo quy ước file).
- **`EnableGridArithmeticSpacing`:** tắt = khoảng đều theo D (với quy ước ±1 bậc so với gốc trong comment input); bật = khoảng bậc **n** theo công thức cấp số cộng (xem comment trong input).
- **`GridArithmeticAddPips` (A):** dùng khi bật cấp số cộng.
- **`MaxGridLevels`:** số mức chờ ảo **mỗi phía** (trên và dưới gốc).

---

## 5. Nhóm 2 — Magic, comment, chế độ gốc, replenish, 2d

- **`MagicNumber` / `CommentOrder`:** nhận diện lệnh EA; comment áp cho lệnh market theo mô tả input.
- **`EnableBaseDirectionalMode` (2b):** khi bật, chỉ Buy một phía / Sell một phía theo quy tắc “theo đường gốc”; đóng hết một bậc thì có logic chờ giá lùi (xem comment input và code).
- **`EnableAutoReplenishVirtualOrders` (2c):** bật = sau khi khớp/đóng, EA **dựng lại** chờ ảo; tắt = chỉ dựng một lần khi có gốc.
- **Nhóm 2d — Vùng cấm Gốc–EMA (phiên):**
  - Khi bật `EnableInitBaseEmaVirtGapBlock`, sau **Init lưới** EA chụp một đoạn **[min(base, EMA) … max(base, EMA)]** theo EMA tại thời điểm chụp (chu kỳ + khung input).
  - **Chỉ chụp lại** khi **gốc đổi** (lệch quá dung sai) hoặc chưa có vùng; **cùng gốc** trong phiên thì **giữ vùng** dù Init lưới lại.
  - Trong vùng: **chỉ chặn chờ ảo dạng Stop** (không chặn Limit): base > EMA → chặn **Sell Stop** dưới gốc trong zone; base < EMA → chặn **Buy Stop** trên gốc trong zone.
  - Reset EA / đóng hết / tắt input → xóa vùng.

---

## 6. Nhóm 3 / 3b / 3c — Chỉ áp khi **chưa có gốc** (đặt gốc lần đầu)

Các bộ lọc này **không kéo lại đường gốc** khi lưới đã chạy (trừ luồng reset/chờ gốc mới theo thiết kế từng tính năng).

- **RSI (3):** khi bật, chỉ khi RSI vào “vùng” giữa `RSIZoneLow` và `RSIZoneHigh` trên khung `RSITimeframe` (có cơ chế latch theo nến — xem comment input).
- **EMA cắt (3b):** khi bật, lần đầu giá cắt EMA trên khung cấu hình thì khóa Bid làm gốc (latch).
- **ADX (3c):** khi bật và có ngưỡng hợp lệ, ADX đường chính phải nằm trong vùng min/max (0 = không kiểm tra phía đó).

Hàm tổng hợp điều kiện đặt gốc được gọi dưới tên gợi ý **`GridStartTimeAndRSIOk`** (gom cả giờ chạy + các latch/filter).

---

## 7. Nhóm 4 / 4a–4d — Lot và TP chờ ảo

- **`VirtualGridUsePerLegLotTpParams`:**
  - **false:** một bộ tham số nhóm **4** cho cả bốn chân.
  - **true:** dùng riêng **4a–4d** cho từng chân (`ENUM_VGRID_LEG`).
- **`ENUM_LOT_SCALE`:** `LOT_FIXED` (0), `LOT_ARITHMETIC` (1), `LOT_GEOMETRIC` (2).
- **TP:** có thể **theo mức lưới kế** (`VirtualGridTakeProfitAtNextLevel` / các `VGridTpNext*`) hoặc **theo pip** khi tắt TP mức kế.
- **4e:** SL khóa lãi theo số bậc lời (tắt mặc định trừ khi bật `EnableGridProfitLockStop`).

---

## 8. Nhóm 5 — Scale theo TEV

- **`EnableCapitalBasedScaling`:** bật thì có **hệ số nhân** theo TEV so với mốc khởi động (chi tiết công thức trong comment input và hàm `GetCapitalScaleMultiplier()`).
- **`ScaleSessionProfitTargetsWithCapital`:** bật thì các **ngưỡng USD nhóm 6** (reset phiên) có thể được nhân cùng mult (khi scale bật và logic áp dụng — xem hàm `GetSessionProfit*Effective` trong code).

---

## 9. Nhóm 6 — Reset phiên theo mục tiêu / lỗ tối đa

### 9.1. Điều kiện chung

- Chỉ xét khi **`EnableSessionProfitReset`** (lãi) hoặc **`EnableSessionMaxLossReset`** (lỗ) bật tương ứng.
- **Gồng 6b có thể tạm tắt reset “mục tiêu lãi phiên”** khi đã có **SL chung** và đang trong pha gồng/chờ bước — hàm `CompoundSuppressesSessionProfitTargetReset()`:
  - Chỉ suppress khi **`EnableCompoundTotalFloatingProfit`** bật **và** `g_compoundCommonSlLine > 0` **và** (`g_compoundTotalProfitActive` hoặc `g_compoundAfterClearWaitGrid`).

### 9.2. Thứ tự ưu tiên **mục tiêu lãi** (khi `EnableSessionProfitReset` và không bị suppress)

Trong `OnTick`, thứ tự là:

1. **`SessionProfitEnable_TP_Open`:** P/L hiệu dụng = **`sessionClosedProfit` + floating** (TP trong phiên legacy + treo), so với `SessionProfitTargetUSD` (hiệu lực có thể nhân mult nếu bật scale + nhân ngưỡng phiên). Có thể kèm điều kiện **lot mở đúng** `SessionProfitRequiredOpenLots_TP_Open`.
2. **`SessionProfitUseOpenOnly`:** chỉ **floating**, so `SessionProfitTargetOpenOnlyUSD`; kèm lot `SessionProfitRequiredOpenLots_OpenOnly`.
3. **`SessionProfitIncludeClosedTPandSL`:** **`sessionClosedProfitTpSl` + floating**, so `SessionProfitTargetClosedTP_SL_OpenUSD`; kèm lot `SessionProfitRequiredOpenLots_TP_SL_Open`.

**Lưu ý cấu hình:** Nếu **cả ba cờ trên đều tắt**, nhánh (1)–(3) **không bao giờ** đạt điều kiện — khi đó **không có reset phiên theo lãi** từ nhóm 6 trừ khi bạn bật ít nhất một chế độ hoặc dùng **lỗ tối đa** (mục dưới).

### 9.3. Lỗ tối đa phiên

- Khi **`EnableSessionMaxLossReset`** bật và `SessionMaxLossUSD > 0`: so **`sessionClosedProfitTpSl + floating`** với **-ngưỡng**, kèm điều kiện lot nếu cấu hình.

### 9.4. Sau khi reset

- Đóng vị thế / xóa lệnh chờ / xóa chờ ảo theo `CloseAllPositionsAndOrders()` (và logic kèm).
- Nếu **ngoài lịch**: EA tắt phiên runtime, chờ giờ/ngày.
- Nếu **trong lịch**: có thể đặt gốc ngay hoặc chờ latch RSI/EMA/ADX tuỳ điều kiện; có thể gửi **push** (nhóm 9).

---

## 10. Nhóm 6b — Gồng lãi tổng (Compound)

- Bật **`EnableCompoundTotalFloatingProfit`** và `CompoundTotalProfitTriggerUsd > 0`.
- Ngưỡng kích hoạt dựa trên **Σ(profit+swap) các lệnh đang mở** (magic+symbol), có thể **cộng thêm** phần điều chỉnh từ **6c** (xem `GetCompoundFloatingTriggerThresholdUsd()` trong code).
- Luồng tóm tắt (theo comment biến toàn cục và các hàm `Compound*`):
  - **ARM:** đạt ngưỡng treo nhưng có thể hủy nếu giá đi ngược điều kiện tham chiếu (theo hướng rổ Buy/Sell so với gốc).
  - Sau kích hoạt: **xóa chờ ảo**, **chờ thêm một bước lưới có lợi**, gán **SL chung** tại mức tham chiếu, đóng một phía theo giá vs gốc, **SL trượt**…
- **`CompoundResetOnCommonSlHit`:** khi bật, chạm SL chung có thể dẫn tới **đóng hết, xóa lưới, chờ tín hiệu đặt gốc** (hoặc đặt ngay nếu đủ điều kiện).

Chi tiết từng nhánh (Bid/Ask, ref, tol) nên đọc trực tiếp các hàm `Compound*` trong `VDualGrid.mq5`.

---

## 11. Nhóm 6c — Cân bằng lệnh (Order balance)

- Khi **`EnableOrderBalanceMode`** bật: nếu giá xa gốc đủ **bậc**, đủ **phút** cùng phía gốc, và **lệch số lệnh** hai phía → đóng **cả phía yếu**.
- P/L đóng (profit+swap) có thể **cộng vào ngưỡng Σ mở** của 6b (carry — xem biến/hàm `g_balanceCompoundCarryUsd` / `GetCompoundFloatingTriggerThresholdUsd` trong code).
- **`EnableOrderBalanceEMAFilter`:** lọc thêm bằng **N nến đã đóng** liên tiếp so với EMA (`OrderBalanceEMAConfirmBars`, chu kỳ + khung).

---

## 12. Nhóm 7 — TP tổng (dừng hẳn EA)

- Khi **`TotalProfitStopUSD` > 0**: mỗi lần **reset phiên do đạt mục tiêu lãi nhóm 6** (không tính reset do vượt lỗ tối đa), EA **cộng dồn** P/L hiệu dụng của lần reset đó vào biến tích lũy.
- Khi tổng tích lũy **≥ ngưỡng** → **đóng hết**, ghi **GlobalVariable** khóa, **`ExpertRemove()`** — cần xóa GV theo hướng dẫn trong log để gắn EA lại.

---

## 13. Nhóm 8 / 8b — Lịch chạy

- **8:** `EnableRunTimeWindow` — chỉ trong khung **`RunStartHour:RunStartMinute` → `RunEndHour:RunEndMinute`** (giờ **server MT5**).
- **8b:** `EnableRunDayFilter` — chỉ các ngày `RunOnMonday` … `RunOnSunday` được bật.
- Khi **đang có lưới (đã có gốc)** mà sang ngày tắt: theo comment trong code, EA vẫn có thể chạy cho đến khi **reset phiên**; sau reset nếu trùng ngày/giờ cấm thì **chờ** (xem `Print` quy ước trong OnInit).

---

## 14. Nhóm 9 — Thông báo MT5 (push)

- **`EnableResetNotification`:** gọi `SendNotification` với nội dung rút gọn (giới hạn **255 ký tự** của MT5): symbol, lý do, **số vốn lúc đầu** (mốc scale/TEV), **số dư hiện tại**, **% TEV vs mốc gắn EA**.
- Cần cấu hình **MetaQuotes ID** trong MT5 và app di động để nhận push.

---

## 15. Biên dịch Telegram / phân tích chart

Trong mã có khối:

```text
// If you ever need Telegram back, define VDUALGRID_ENABLE_TELEGRAM before compiling.
#ifdef VDUALGRID_ENABLE_TELEGRAM
```

Bản **mặc định không định nghĩa** macro này thì chỉ có nhánh **push MT5 rút gọn** (và không gửi Telegram). Nếu bạn tự build với macro, sẽ có thêm `SendResetNotification` đầy đủ + Telegram (xem code trong `#ifdef`).

---

## 16. Khuyến nghị vận hành

- Luôn **strategy tester** / **demo** trước khi dùng tiền thật.
- Kiểm tra **pip/point** của symbol (JPY, crypto, CFD) vì quy đổi bước lưới và TP pip gắn với thuộc tính symbol.
- Sau khi chỉnh input nhóm 6, xác nhận **ít nhất một chế độ đếm P/L lãi** đang bật nếu bạn **cần reset theo lãi**; nếu không bật mode nào thì chỉ còn **lỗ tối đa** (nếu bật) hoặc các thoát khác (6b, 7, thủ công).

---

## 17. Tệp trong repo

| Tệp | Vai trò |
|-----|---------|
| `VDualGrid.mq5` | Toàn bộ logic EA |

Nếu bạn dùng wrapper `#define VDUALGRID_SKIP_PROPERTIES`, có thể ghi đè metadata build — ngoài phạm vi README này.

---

*Tài liệu được tạo để mô tả kiến trúc và luồng; mọi số liệu ngưỡng cụ thể luôn lấy theo **input** trên terminal và theo **phiên bản mã** bạn đang biên dịch.*
