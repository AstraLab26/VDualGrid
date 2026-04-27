# VDualGrid — README hiện tại (MT5)

Tài liệu này cập nhật theo mã nguồn `VDualGrid.mq5` đang dùng trong repo (nhánh chỉnh gần nhất), bao gồm các thay đổi mới về panel và thông báo Telegram.

---

## 1) Tổng quan nhanh

VDualGrid là EA grid 2 phía quanh `basePrice`:

- Chờ ảo (virtual pending) theo mức lưới, chạm mức thì vào lệnh market.
- Quản lý theo `MagicNumber + _Symbol`.
- Lot/TP theo từng chân A/B/C/D/E/F.
- Có các cụm chính: gồng 6b, cân bằng lệnh 6c, lịch chạy, panel tháng, thông báo MT5/Telegram.

---

## 2) Điểm đã thay đổi quan trọng

### Panel tháng

- Panel có kích thước và bố cục cố định theo code hiện tại.
- Có thêm card: **“LỢI NHUẬN TỪ LÚC GẮN EA”** (`eaCumulativeTradingPL`).
- Giá trị này **không reset theo tháng**.
- Khi sang tháng mới, panel tự quay về tháng hiện tại (server) để tổng tháng bắt đầu từ dữ liệu tháng mới.

### Đường gốc + mốc thời gian

- Gộp thành 1 công tắc duy nhất:
  - `EnableBaseLineAndEaStartMarker`
- `true`: hiện cả đường gốc + vạch dọc/nhãn thời gian đặt gốc.
- `false`: ẩn cả hai.

### Telegram

- Đã bỏ toàn bộ logic phân tích AI/chart cho Telegram.
- Luồng hiện tại: gửi **1 ảnh + caption** (không gửi text rời).
- Có thể chọn xóa tin cũ của bot trước khi gửi tin mới.

---

## 3) Input thông báo (đã rút gọn)

Hiện chỉ còn các input người dùng chỉnh trực tiếp:

- `EnableResetNotification`: bật/tắt push MT5.
- `EnableTelegram`: bật/tắt gửi Telegram.
- `TelegramDeletePreviousBotMessagesOnNotify`: bật/tắt xóa toàn bộ tin cũ của bot trước khi gửi tin mới.
- `TelegramBotToken`
- `TelegramChatID`

Các cấu hình Telegram khác giữ mặc định trong code, không còn input để chỉnh tay.

---

## 4) Telegram hiện gửi khi nào?

### Gửi ảnh khi attach EA

- Khi `OnInit` kết thúc: gọi `SendStartupTelegramScreenshot("EA vừa gắn vào biểu đồ")`.

### Gửi ảnh khi reset/dừng/các mốc có gọi notify

- Mọi chỗ gọi `SendResetNotification(...)` (ví dụ reset 6b/6d/6e, vào lịch, dừng EA...) nếu Telegram bật hợp lệ sẽ gửi 1 ảnh với caption.

### Cơ chế xóa tin cũ

- Nếu `TelegramDeletePreviousBotMessagesOnNotify = true`:
  - Bot xóa các `message_id` đã lưu từ những lần notify trước,
  - Sau đó gửi tin mới.

---

## 5) Carry trong 6c -> 6b (tóm tắt)

- Carry lưu ở `g_balanceCompoundCarryUsd`.
- Khi 6c đóng lệnh và có phần âm:
  - cộng vào carry theo trị tuyệt đối phần âm đã đóng.
- Ngưỡng gồng 6b thực tế:
  - `CompoundTotalProfitTriggerUSD + carryContribution`.
- Nếu bật trần carry theo phiên thì phần cộng vào ngưỡng bị giới hạn bởi `OrderBalanceCarryCapPerSessionUSD`.

---

## 6) Lưu ý build

- Nếu dùng Telegram, cần cho phép `WebRequest` tới:
  - `https://api.telegram.org`
- Sau các thay đổi input, nên compile lại `.ex5` và attach lại EA để tránh dùng cache input cũ.

---

## 7) Tệp chính

- `VDualGrid.mq5`: toàn bộ logic EA.
- `README.md`: tài liệu này.
