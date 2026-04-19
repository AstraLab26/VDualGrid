# VDualGrid — Hướng dẫn cách EA hoạt động



Tài liệu mô tả **luồng vận hành** và **ý nghĩa các nhóm input** của Expert Advisor **VDualGrid** (MetaTrader 5). Nội dung căn cứ mã nguồn trong `VDualGrid.mq5` (phiên bản `#property version`, hiện **4.11**).



---



## 1. EA làm gì (tóm tắt)



VDualGrid là EA **lưới hai phía** quanh một **đường gốc (base)** trên **symbol** của biểu đồ đang gắn EA:



- **Lệnh chờ ảo (virtual pending)** do EA quản lý trong bộ nhớ. Khi giá chạm mức, EA gửi **lệnh thật** (market) kèm TP theo cấu hình từng chân.

- Mỗi **bậc lưới** có **cả Buy và Sell** (bốn chân: Buy trên gốc, Sell dưới gốc, Sell trên gốc, Buy dưới gốc) — xem `ENUM_VGRID_LEG` trong mã.

- **Một magic** (`MagicNumber`) dùng chung để nhận diện lệnh/vị thế của EA trên symbol đó.

- **Bước lưới** giữa các mức là **đều theo D** (`GridDistancePips`); không còn chế độ bước cấp số cộng.

- **Lot và TP** luôn cấu hình **riêng theo từng chân** (nhóm **4a–4d**); không còn một bộ lot/TP chung cho cả bốn chân.

- Ngoài lưới, EA còn **gồng lãi tổng (6b)**, **cân bằng lệnh (6c)**, **lịch chạy (8 / 8b)** và **push MT5 (9)**.



---



## 2. Quy ước quan trọng: TEV, số dư, nạp/rút



Khối comment đầu file mô tả quy ước — nên đọc trước khi hiểu scale và %:



| Khái niệm | Ý nghĩa |

|-----------|---------|

| **`attachBalance`** | `ACCOUNT_BALANCE` tại **OnInit** (một lần). **Không** cập nhật khi nạp/rút sau đó. |

| **`initialCapitalBaselineUSD`** | **TEV** (Trading Equity View) tại OnInit: trong code là **số dư lúc gắn + P/L đóng lệnh magic tích lũy + treo magic** tại thời điểm chụp; dùng làm **mốc %** và (khi bật nhóm 5) **scale lot**. |

| **TEV hiện tại** | `attachBalance + eaCumulativeTradingPL + floating(magic+symbol)` — **không** “ăn” nạp/rút vào các biến mốc đã snapshot. |

| **Phạm vi lệnh** | Mọi đếm/quét vị thế, lệnh chờ, deal… chỉ lọc **`MagicNumber` + `_Symbol` biểu đồ** (không gộp magic khác). |



**Push MT5 (nhóm 9):** tin ngắn có thể hiển thị **số dư broker hiện tại** (đọc `ACCOUNT_BALANCE` lúc gửi). **% trong push** là **% TEV so mốc gắn EA** (`GetTradingEquityViewPctVsScaleBaseline`), không nhất thiết bằng % giữa hai số dư nếu có nạp/rút hoặc TEV ≠ số dư.



---



## 3. Vòng đời từ khi gắn EA



### 3.1. `OnInit`



- Gán `MagicAA`, `pnt`, `dgt`, snapshot **số dư / TEV mốc** (`attachBalance`, `initialCapitalBaselineUSD`, v.v.).

- Tạo handle **iMA** cho **2d** (vùng cấm Gốc–EMA) và **6c** (lọc EMA cân bằng) nếu các input tương ứng bật.

- Xác định **`g_runtimeSessionActive`** qua `IsSchedulingAllowedForNewSession` (khung giờ + ngày server).

  - **Trong lịch:** có thể đặt `basePrice` ngay bằng `GridBasePriceAtPlacement()`, `InitializeGridLevels()`, rồi `ManageGridOrders()`.

  - **Ngoài lịch:** xóa chờ ảo / mảng mức, in log chờ.



### 3.2. Phiên “được phép chạy” (`g_runtimeSessionActive`)



- **Ngoài lịch:** EA chờ tick tới khi `IsSchedulingAllowedForNewSession` = true → bật phiên, đặt gốc (Bid), khởi tạo lưới.

- **Trong lịch nhưng chưa có gốc:** khi `IsNowWithinRunWindow` (nếu bật khung giờ) cho phép → `GridBasePriceAtPlacement()`, `InitializeGridLevels()`, `ManageGridOrders()`.



### 3.3. `OnTick` — các bước chính



1. Nếu **`!g_runtimeSessionActive`:** chỉ thử mở phiên mới khi vào lịch (như trên), rồi `return`.

2. **Chưa có gốc** (`basePrice <= 0`): trong lịch + trong khung giờ (nếu bật) → đặt gốc, `InitializeGridLevels()`, `ManageGridOrders()`, `return`.

3. **Đã có gốc** nhưng `gridLevels` thiếu so với `MaxGridLevels * 2` → `InitializeGridLevels()` giữ nguyên gốc, `ManageGridOrders()`, `return`.

4. **Bình thường:**

   - `ProcessVirtualPendingExecutions()`

   - `ProcessOrderBalanceMode()` (6c)

   - Cộng **profit+swap** mở (magic+symbol) cho gồng 6b

   - Nếu đang gồng / chờ bước sau kích hoạt → các hàm `ProcessCompound*`

   - Cập nhật thống kê cho push (nếu bật)

   - **ARM gồng:** `TryArmCompoundTotalProfitMode()` khi đủ điều kiện

   - `ProcessCompoundArming(...)`

   - **`ManageGridOrdersThrottled()`** — tối đa một lần/giây (bảo trì lưới; khớp ảo vẫn xử lý mỗi tick).



### 3.4. `OnDeinit`



- `IndicatorRelease` cho handle 6c và 2d; xóa object chart tên `VPGrid_*`; push “EA đã dừng” nếu bật nhóm 9.



---



## 4. Nhóm 1 — Lưới giá (GRID)



- **`GridDistancePips` (D):** khoảng cách **đều** giữa các mức theo pip (quy ước pip/point theo symbol trong code).

- **`MaxGridLevels`:** số mức chờ ảo **mỗi phía** (trên và dưới gốc).



---



## 5. Nhóm 2 — Magic, comment; 2c replenish; 2d vùng cấm



- **`MagicNumber` / `CommentOrder`:** nhận diện lệnh EA; comment áp cho lệnh market theo mô tả input.

- **`EnableAutoReplenishVirtualOrders` (2c):** bật = sau khi khớp/đóng, EA **dựng lại** chờ ảo; tắt = chỉ dựng một lần khi có gốc (mỗi “phiên” lưới trong code có cờ `g_gridBuiltOnceThisSession`).

- **Nhóm 2d — Vùng cấm Gốc–EMA (phiên):**

  - Khi bật `EnableInitBaseEmaVirtGapBlock`, sau **khởi tạo lưới** EA chụp đoạn **[min(base, EMA) … max(base, EMA)]** theo EMA tại thời điểm chụp (`InitBaseEmaVirtGapEMAPeriod`, `InitBaseEmaVirtGapEMATimeframe`).

  - **Chỉ chụp lại** khi **gốc đổi** đáng kể hoặc chưa có vùng; **cùng gốc** thì **giữ vùng**.

  - Trong vùng: **chỉ chặn chờ ảo dạng Stop** (không chặn Limit): base > EMA → chặn **Sell Stop** dưới gốc trong zone; base < EMA → chặn **Buy Stop** trên gốc trong zone.



---



## 6. Nhóm 4 — Lot và TP chờ ảo (luôn 4a–4d)



- Nhóm **4** chỉ là tiêu đề; mọi tham số lot/TP nằm ở **4a, 4b, 4c, 4d** — mỗi chân một bộ (`ENUM_VGRID_LEG`).

- **`ENUM_LOT_SCALE`:** `LOT_FIXED` (0), `LOT_ARITHMETIC` (1), `LOT_GEOMETRIC` (2).

- **TP:** mỗi chân có `VGridTpNext*` (TP theo **mức lưới kế**) và `VGridTpPips*` (TP pip khi **tắt** TP theo mức kế).



**Giá trị mặc định trong repo (tham khảo):** `GridDistancePips = 1000`, `InitBaseEmaVirtGapEMAPeriod = 100`, `OrderBalanceEMAPeriod = 100`, `OrderBalanceEMAConfirmBars = 10`; các lot/TP 4a–4d như trong tab Inputs của bản build hiện tại.



---



## 7. Nhóm 5 — Scale theo TEV (lot)



- **`EnableCapitalBasedScaling`:** bật thì có **hệ số nhân** theo TEV so với mốc khởi động (xem comment input và `GetCapitalScaleMultiplier()`).

- **`CapitalGainScalePercent`**, **`CapitalScaleMaxBoostPercent`:** độ nhạy và trần mult.



*(Các tính năng “scale ngưỡng reset phiên / mục tiêu P/L theo vốn” đã được gỡ khỏi bản mã hiện tại.)*



---



## 8. Nhóm 6b — Gồng lãi tổng (Compound)



- Bật **`EnableCompoundTotalFloatingProfit`** và **`CompoundTotalProfitTriggerUSD` > 0**.

- Ngưỡng kích hoạt dựa trên **Σ(profit+swap) các lệnh đang mở** (magic+symbol), có thể **cộng carry** từ **6c** (`GetCompoundFloatingTriggerThresholdUsd()`).

- Luồng tóm tắt: **ARM** (có thể hủy nếu giá đi ngược điều kiện tham chiếu) → kích hoạt → xóa chờ ảo, chờ bước lưới, SL chung, đóng một phía, SL trượt…

- **`CompoundResetOnCommonSlHit`:** khi bật, chạm SL chung có thể **đóng hết, xóa lưới**, rồi chờ lịch / đặt gốc mới tùy điều kiện.



Chi tiết nhánh Bid/Ask/ref nên đọc các hàm `Compound*` trong `VDualGrid.mq5`.



---



## 9. Nhóm 6c — Cân bằng lệnh (Order balance)



- Khi **`EnableOrderBalanceMode`** bật: nếu giá xa gốc đủ **bậc**, đủ **phút** cùng phía gốc, và **lệch số lệnh** hai phía → đóng **cả phía yếu**.

- P/L đóng (profit+swap) có thể **cộng vào ngưỡng Σ mở** của 6b (carry).

- **`EnableOrderBalanceEMAFilter`:** lọc bằng **N nến đã đóng** liên tiếp so với EMA (`OrderBalanceEMAConfirmBars`, `OrderBalanceEMAPeriod`, `OrderBalanceEMATimeframe`).



---



## 10. Nhóm 8 / 8b — Lịch chạy



- **8:** `EnableRunTimeWindow` — chỉ trong khung **`RunStartHour:RunStartMinute` → `RunEndHour:RunEndMinute`** (giờ **server MT5**).

- **8b:** `EnableRunDayFilter` — chỉ các ngày `RunOnMonday` … `RunOnSunday` được bật.

- Khi **đang có lưới (đã có gốc)** mà sang ngày tắt: theo log OnInit, EA vẫn có thể chạy cho đến khi **đóng/reset lưới** (ví dụ qua 6b); sau đó nếu trùng ngày/giờ cấm thì **chờ**.



---



## 11. Nhóm 9 — Thông báo MT5 (push)



- **`EnableResetNotification`:** `SendNotification` (giới hạn **255 ký tự**): symbol, lý do, **số vốn lúc đầu** (mốc scale/TEV), **số dư hiện tại**, **% TEV vs mốc gắn EA**.

- Cần cấu hình **MetaQuotes ID** trong MT5 và app di động để nhận push.



---



## 12. Biên dịch Telegram / phân tích chart



Trong mã có khối:



```text

// If you ever need Telegram back, define VDUALGRID_ENABLE_TELEGRAM before compiling.

#ifdef VDUALGRID_ENABLE_TELEGRAM

```



Bản **mặc định không định nghĩa** macro này thì chỉ có nhánh **push MT5 rút gọn**. Nếu build với macro, xem thêm code trong `#ifdef`.



---



## 13. Khuyến nghị vận hành



- Luôn **Strategy Tester** / **demo** trước khi dùng tiền thật.

- Kiểm tra **pip/point** của symbol (JPY, crypto, CFD) vì bước lưới và TP pip gắn với thuộc tính symbol.



---



## 14. Tệp trong repo



| Tệp | Vai trò |

|-----|---------|

| `VDualGrid.mq5` | Toàn bộ logic EA |



Nếu dùng wrapper `#define VDUALGRID_SKIP_PROPERTIES`, có thể ghi đè metadata build — ngoài phạm vi README này.



---



## 15. Các tính năng không còn trong bản mã hiện tại



Để tránh nhầm với tài liệu cũ hoặc preset cũ:



- Bộ lọc **RSI / EMA đặt gốc / ADX** (nhóm 3) và **chế độ một phía theo gốc (2b)**.

- **Bước lưới cấp số cộng**; spacing chỉ còn **D đều**.

- **Một bộ lot/TP chung** + cờ tách chân; hiện chỉ còn **4a–4d**.

- **Reset phiên theo mục tiêu P/L**, **lỗ tối đa phiên kiểu nhóm 6 cũ**, **TP tổng (nhóm 7)**, **SL khóa lãi theo bậc (4e)**.

- **Nhân ngưỡng reset phiên theo scale vốn** (cùng gói với các reset trên).



---



*Tài liệu mô tả kiến trúc và luồng; mọi ngưỡng cụ thể luôn lấy theo **input** trên terminal và theo **phiên bản mã** bạn đang biên dịch.*

