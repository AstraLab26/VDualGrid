# VDualGrid — Expert Advisor (MetaTrader 5)

**VDualGrid** là EA lưới dùng **chờ ảo** (không gửi pending order lên sàn): mỗi mức lưới duy trì một Buy ảo + một Sell ảo; khi chạm điều kiện, EA vào **lệnh market** và gắn TP theo pip.

- **File mã nguồn:** `VDualGrid.mq5`
- **Phiên bản:** theo `#property version` (hiện tại: **3.51**)
- **Nền tảng:** MT5

---

## Ý tưởng chính

1. **Giá gốc (`basePrice`)** được đặt khi khởi động hoặc sau mỗi lần reset phiên.
2. **Bậc lưới:** bậc ±1 là nửa bước, các bậc xa hơn cách nhau 1 bước đầy đủ.
3. **Chờ ảo thông minh theo vị trí giá** (Buy Stop/Sell Limit hoặc Buy Limit/Sell Stop).
4. **Trigger chờ ảo -> lệnh market** có TP theo `VirtualGridTakeProfitPips`.
5. **Reset phiên** khi đạt `SessionProfitTargetUSD` theo công thức P/L phiên của EA.
6. **TP tổng** (`TotalProfitStopUSD`) đạt ngưỡng thì đóng hết, ghi Global Variable khóa, và tự gỡ EA.

---

## Cài đặt & biên dịch

1. Chép `VDualGrid.mq5` vào `MQL5/Experts/`.
2. Mở MetaEditor, Compile (`F7`).
3. Gắn EA lên chart và bật Algo Trading.

**WebRequest cần bật trong MT5:**  
`Tools -> Options -> Expert Advisors -> Allow WebRequest`  
thêm URL: `https://api.telegram.org`

---

## Thông báo: MT5 & Telegram (local-only)

### Push MT5 (`SendNotification`)
- Dùng `EnableResetNotification`.
- Tin ngắn (<=255 ký tự): symbol, lý do, giá, số dư, % P/L.

### Telegram (`EnableTelegram`)

Khi reset/dừng EA:

1. **Tin 1 — trạng thái EA**  
   `sendMessage` với thông tin đầy đủ về lý do, giá, số dư, P/L, drawdown, link.

2. **Tin 2 — chart + phân tích local**  
   - Nếu bật `EnableTelegramChartAnalysis`: gửi thống kê nến realtime từ `CopyRates` (theo `ChartAnalysisTimeframe`, `ChartAnalysisBars`).
   - Nếu bật `TelegramFunAIAnalysis`: thêm đoạn “chém gió” local từ hàm nội bộ (không gọi AI cloud).
   - Nếu bật `EnableTelegramChartScreenshot`: gửi ảnh chart (GIF) + caption ngắn, rồi gửi text tin 2.
   - Tin dài sẽ tự tách nhiều phần `[Tiếp N]` theo giới hạn Telegram.

> Bản hiện tại **đã bỏ toàn bộ Groq** khỏi input và luồng gửi tin.

---

## Inputs chính

| Nhóm | Tham số |
|------|---------|
| `1. GRID` | `GridDistancePips`, `MaxGridLevels` |
| `2. ORDERS` | `MagicNumber`, `CommentOrder` |
| `3. ORDERS (chờ ảo)` | `VirtualGridLotSize`, `VirtualGridLotScale`, `VirtualGridLotMult`, `VirtualGridMaxLot`, `VirtualGridTakeProfitPips` |
| `4. SESSION` | `EnableSessionProfitReset`, `SessionProfitTargetUSD` |
| `4.1 SESSION` | `TotalProfitStopUSD` |
| `5. NOTIFICATIONS` | `EnableResetNotification` |
| `5.1 Telegram` | `EnableTelegram`, `TelegramBotToken`, `TelegramChatID`, `TelegramFunAIAnalysis`, `EnableTelegramChartAnalysis`, `ChartAnalysisTimeframe`, `ChartAnalysisBars`, `EnableTelegramChartScreenshot`, `TelegramScreenshotWidth`, `TelegramScreenshotHeight` |
| `6. CAPITAL` | `EnableCapitalBasedScaling`, `CapitalGainScalePercent`, `CapitalScaleMaxBoostPercent` |

---

## Ghi chú rủi ro

- Không phải tư vấn đầu tư.
- EA grid có thể tăng rủi ro khi thị trường chạy một chiều mạnh.
- Spread/slippage/quy tắc sàn ảnh hưởng trực tiếp tới kết quả.
- `ChartScreenShot` có thể lỗi trong Strategy Tester hoặc khi chart không hiển thị đúng.

---

## Tệp trong repo

| Tệp | Mô tả |
|-----|------|
| `VDualGrid.mq5` | Mã nguồn EA |
| `README.md` | Tài liệu |
