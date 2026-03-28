# VDualGrid — Expert Advisor (MetaTrader 5)

**VDualGrid** là EA lưới dùng **chờ ảo** (không gửi lệnh chờ lên sàn): mỗi **mức giá lưới** duy trì **một Buy ảo + một Sell ảo**; khi giá chạm điều kiện kích hoạt, EA đặt **lệnh thị trường** kèm **TP (pip)**. Một **magic** cho toàn bộ lệnh do EA quản lý.

- **File mã nguồn:** `VDualGrid.mq5`  
- **Phiên bản:** xem `#property version` trong file (ví dụ **3.48** tại thời điểm cập nhật README)  
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

**WebRequest (MT5):** *Tools → Options → Expert Advisors → Allow WebRequest*

| URL | Khi nào cần |
|-----|-------------|
| `https://api.telegram.org` | `EnableTelegram` |
| `https://api.groq.com` | `EnableGroqTelegramAI` + `TelegramFunAIAnalysis` (gọi Groq) |

---

## Thông báo: MT5, Telegram, Groq

### Điện thoại / push MT5 (`SendNotification`)

- Gắn với `EnableResetNotification`: tin **ngắn** (≤255 ký tự) — symbol, lý do, giá, số dư, % P/L.  
- **Không** gửi khối thống kê nến dài hay ảnh chart qua kênh này.

### Telegram (`EnableTelegram`)

Khi reset phiên / dừng EA, luồng gửi bot được tách rõ:

1. **Tin 1 — chỉ báo EA**  
   Một lần `sendMessage`: lý do, giá, số dư lúc gắn, P/L giao dịch so với gốc gắn, drawdown, link đăng ký (nội dung trong code). **Không** kèm khối nến hay AI.

2. **Tin 2 — biểu đồ & AI** (chỉ khi bật ít nhất một trong: `TelegramFunAIAnalysis`, `EnableTelegramChartScreenshot`, hoặc có khối phân tích nến từ `EnableTelegramChartAnalysis`)

   - **Số liệu nến:** `EnableTelegramChartAnalysis` dùng `CopyRates` trên `ChartAnalysisTimeframe` / `ChartAnalysisBars` — mô tả thống kê tiếng Việt (không thay cho tư vấn đầu tư).  
   - **Groq:** nếu `TelegramFunAIAnalysis` + `EnableGroqTelegramAI` + API key hợp lệ:
     - Có **khối nến đủ dài** gửi lên Groq → **không** dùng rule-based thay thế (xem `GroqFallbackToLocalFunAI` chỉ áp khi *không* gửi biểu đồ).  
     - **`GroqStructuredChartAnalysis = true`** và đủ dữ liệu nến → prompt **báo cáo 4 mục** (xu hướng, hỗ trợ/kháng cự, chiến lược thận trọng, tâm lý). **Tắt** → giọng **chém gió** + vẫn bám số nến; đoạn AI có thể được rút gọn nhẹ cho Telegram.  
     - Phân tích có cấu trúc: `GroqMaxTokens` được nâng tối thiểu **2000**, tối đa **8192**; bản **chém gió** giới hạn tối đa **2048** token như cấu hình.  
   - **Ảnh chart:** `EnableTelegramChartScreenshot` — chụp GIF (`ChartScreenShot`), gửi `sendPhoto` với **caption ngắn** (symbol); **toàn bộ** text số nến + AI gửi **tin nhắn text riêng** ngay sau (nếu rất dài, Telegram có thể tách thêm `[Tiếp 2]`… — giới hạn ~4096 ký tự mỗi bubble).  
   - **Tắt ảnh:** một hoặc nhiều tin text, nội dung **đầy đủ** (chunk tự động), không cắt cứng một bubble 4096 như phiên bản cũ.

**Lưu ý:** Groq chỉ nhận **số liệu nến trong prompt**, không “đọc” pixel ảnh; ảnh chỉ để bạn xem nhanh chart trên Telegram.

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
| **5** | `EnableResetNotification` | Push MT5 khi reset / dừng EA. |
| **5.1 Telegram** | `EnableTelegram`, `TelegramBotToken`, `TelegramChatID` | Bot Telegram. |
| | `TelegramFunAIAnalysis` | Bật khối AI trên Telegram (có chart → ưu tiên Groq). |
| | `EnableTelegramChartAnalysis`, `ChartAnalysisTimeframe`, `ChartAnalysisBars` | Thống kê nến realtime trong tin 2. |
| | `EnableTelegramChartScreenshot`, `TelegramScreenshotWidth/Height` | Gửi ảnh GIF chart (chart phải mở trên MT5). |
| **5.2 Groq** | `EnableGroqTelegramAI`, `GroqApiKey`, `GroqModel` | API Groq cho tin 2. |
| | `GroqMaxTokens`, `GroqTimeoutMs` | Độ dài / thời gian chờ phản hồi. |
| | `GroqFallbackToLocalFunAI` | Chỉ khi *không* gửi khối biểu đồ: Groq lỗi → rule-based vui. |
| | `GroqStructuredChartAnalysis` | Bật: báo cáo 4 mục đầy đủ (đủ khối nến). Tắt: chém gió. |
| **6. CAPITAL** | `EnableCapitalBasedScaling`, `CapitalGainScalePercent`, `CapitalScaleMaxBoostPercent` | Scale lot & mục tiêu phiên theo số dư vs gốc gắn EA (xem comment trong code). |

Giá trị mặc định trong code có thể thay đổi theo phiên bản — luôn kiểm tra tab **Inputs** sau khi compile.

---

## Ghi chú rủi ro & giới hạn

- **Không phải tư vấn đầu tư.** Giao dịch có rủi ro; chỉ dùng vốn chấp nhận mất.  
- **Phân tích AI / thống kê nến trên Telegram** chỉ mang tính tham khảo từ dữ liệu EA cung cấp; **Groq** và **Telegram** phụ thuộc mạng, API key và cấu hình WebRequest — không lưu key trong file `.set` công khai.  
- **200 bậc mỗi phía** (mặc định trong code hiện tại) ⇒ rất nhiều chờ ảo trong bộ nhớ và tải CPU mỗi lần bảo trì lưới — cân nhắc giảm `MaxGridLevels` khi tối ưu.  
- **Spread, trượt giá, quy tắc sàn** ảnh hưởng trực tiếp tới kích hoạt và P/L.  
- **TP tổng** chỉ tích lũy khi có **sự kiện reset phiên** (mục 4); nếu tắt reset phiên thì không có “lần reset” để cộng dồn.  
- EA chỉ đóng/xóa lệnh **đúng magic** của mình; lệnh tay hoặc EA khác trên cùng symbol không bị đụng (trừ khi trùng magic).  
- **Ảnh chart:** `ChartScreenShot` có thể thất bại trong Strategy Tester hoặc khi chart không hiển thị đúng — xem log Experts.

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
