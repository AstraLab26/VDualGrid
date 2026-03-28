# VDualGrid — Expert Advisor (MetaTrader 5)

**VDualGrid** là EA lưới dùng **chờ ảo** (không gửi lệnh chờ lên sàn): mỗi **mức giá lưới** duy trì **một Buy ảo + một Sell ảo**; khi giá chạm điều kiện kích hoạt, EA đặt **lệnh thị trường** kèm **TP (pip)**. Một **magic** cho toàn bộ lệnh do EA quản lý.

- **File mã nguồn:** `VDualGrid.mq5`  
- **Phiên bản:** xem `#property version` trong file  
- **Nền tảng:** MT5 (hedging/netting — logic dựa trên vị thế & deal chuẩn MT5)

---

## Ý tưởng chính

1. **Giá gốc (`basePrice`)**  
   Được gắn khi khởi động EA hoặc sau **reset phiên** (mục 4). Lưới được tính quanh mức này.

2. **Bố cục lưới**  
   - **Bậc ±1** cách gốc **½ bước** (`GridDistancePips` quy ra `gridStep`).  
   - **Các bậc xa hơn** cách nhau **đúng một bước** đầy đủ.  
   - Có **MaxGridLevels** bậc phía trên và **MaxGridLevels** bậc phía dưới → **2 × MaxGridLevels** mức giá (và tối đa từng ấy cặp Buy/Sell ảo).

3. **Loại chờ ảo theo vị trí giá**  
   Tùy giá hiện tại so với mức lưới, EA dùng cặp **Buy Stop + Sell Limit** hoặc **Buy Limit + Sell Stop** để mô phỏng hành vi chờ hợp lệ; khi giá đổi phía so với mức, loại chờ được **làm mới** (xóa sai loại, bổ sung đúng loại).

4. **Khớp chờ → market**  
   Khi trigger, EA gọi `Buy` / `Sell`, gắn **TP** theo `VirtualGridTakeProfitPips` (0 = tắt TP).

5. **Không tạo lại chờ ảo ngay sau khi vừa khớp**  
   Có **cooldown ngắn** sau khi khớp thành công để tránh tái tạo chờ ảo cùng phía trong lúc terminal chưa kịp hiển thị vị thế. Khi **đóng vị thế** (bất kỳ lý do), `OnTradeTransaction` gọi `ManageGridOrders()` để **bổ sung chờ ảo** tương ứng (và bảo trì lưới tối đa ~1 lần/giây trên tick).

6. **Reset phiên (mục 4)**  
   Khi **P/L phiên** = *(lãi đóng bằng **TP** trong phiên)* + *(float các vị thế mở trong phiên, đúng magic+symbol)* ≥ `SessionProfitTargetUSD`:  
   đóng hết lệnh EA, xóa chờ ảo, đặt lại `basePrice` và **khởi tạo lại lưới**.

7. **TP tổng / dừng hẳn EA (mục 4.1)**  
   Nếu `TotalProfitStopUSD > 0`: **mỗi lần** đủ điều kiện **reset phiên** như trên, EA **cộng dồn** giá trị `effectiveSession` (cùng công thức ngưỡng reset) vào một biến tích lũy.  
   Khi **tổng dồn ≥ TotalProfitStopUSD**: đóng hết, ghi **Global Variable** khóa, **`ExpertRemove()`** — EA biến mất khỏi chart.  
   Lần gắn EA sau: **`INIT_FAILED`** cho đến khi bạn **xóa GV** trong *Tools → Global Variables* (tên khóa in trong log, dạng `VDualGridTotalStop_<ChartID>_<Symbol>_<Magic>`).

---

## Cài đặt & biên dịch

1. Sao chép `VDualGrid.mq5` vào thư mục `MQL5/Experts/` (hoặc thư mục con của bạn).  
2. Mở **MetaEditor** → mở file → **Compile (F7)**.  
3. Trên chart: **Navigator → Expert Advisors** → kéo **VDualGrid** lên chart, bật **Algo Trading**.

**Telegram:** bật `EnableTelegram` thì trong MT5 cần thêm `https://api.telegram.org` vào *Tools → Options → Expert Advisors → Allow WebRequest*.

---

## Tham số (Inputs) — tóm tắt

| Nhóm | Tham số | Ý nghĩa ngắn gọn |
|------|---------|------------------|
| **1. GRID** | `GridDistancePips` | Một bước lưới (pip). |
| | `MaxGridLevels` | Số bậc mỗi phía (trên/dưới gốc). |
| **2. Chung** | `MagicNumber`, `CommentOrder` | Magic & comment lệnh market. |
| **3. Chờ ảo** | `VirtualGridLotSize`, `VirtualGridLotScale`, `VirtualGridLotMult`, `VirtualGridMaxLot` | Lot theo bậc (cố định / hình học), trần lot. |
| | `VirtualGridTakeProfitPips` | TP pip cho lệnh sau khi chờ khớp (0 = tắt). |
| **4. SESSION** | `EnableSessionProfitReset`, `SessionProfitTargetUSD` | Bật reset phiên & ngưỡng USD. |
| **4.1** | `TotalProfitStopUSD` | 0 = tắt; >0 = cộng dồn theo mỗi lần đạt reset phiên, đủ thì gỡ EA. |
| **5 / 5.1** | Thông báo MT5, Telegram | Push / bot. |

Giá trị mặc định trong code có thể thay đổi theo phiên bản — luôn kiểm tra tab **Inputs** sau khi compile.

---

## Ghi chú rủi ro & giới hạn

- **Không phải tư vấn đầu tư.** Giao dịch có rủi ro; chỉ dùng vốn chấp nhận mất.  
- **200 bậc mỗi phía** (mặc định trong code hiện tại) ⇒ rất nhiều chờ ảo trong bộ nhớ và tải CPU mỗi lần bảo trì lưới — cân nhắc giảm `MaxGridLevels` khi tối ưu.  
- **Spread, trượt giá, quy tắc sàn** ảnh hưởng trực tiếp tới kích hoạt và P/L.  
- **TP tổng** chỉ tích lũy khi có **sự kiện reset phiên** (mục 4); nếu tắt reset phiên thì không có “lần reset” để cộng dồn.  
- EA chỉ đóng/xóa lệnh **đúng magic** của mình; lệnh tay hoặc EA khác trên cùng symbol không bị đụng (trừ khi trùng magic).

---

## Tùy chỉnh cho bản “wrapper”

Trong `VDualGrid.mq5` có:

```cpp
#ifndef VDUALGRID_SKIP_PROPERTIES
#property copyright "..."
#property version "..."
#property description "..."
#endif
```

File khác có thể `#define VDUALGRID_SKIP_PROPERTIES` trước khi `#include` để ghi đè `#property`.

---

## Tệp trong repo

| Tệp | Mô tả |
|-----|--------|
| `VDualGrid.mq5` | Mã nguồn EA |
| `README.md` | Tài liệu này |

---

*Nếu bạn sửa logic trong code, hãy cập nhật README cho khớp.*
