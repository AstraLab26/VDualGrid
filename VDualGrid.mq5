//+------------------------------------------------------------------+
//|                                                VDualGrid.mq5      |
//|     VDualGrid — chờ ảo full lưới, mỗi bậc Buy+Sell (1 magic)       |
//+------------------------------------------------------------------+
// Allow wrapper versions to reuse this file while overriding #property fields.
#ifndef VDUALGRID_SKIP_PROPERTIES
#property copyright "VDualGrid"
#property version   "4.05"
#property description "VDualGrid: lưới chờ ảo, reset phiên, TP tổng. Nạp/rút không đổi mốc TEV/lot trong code (tin có thể hiện số dư)."
#endif
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Quy ước NẠP/RÚT (các nhóm input bên dưới — nạp/rút không đổi logic EA): |
//| — EA không đọc ACCOUNT_BALANCE sau khi gắn (trừ dòng hiện số dư thông báo nếu bật). |
//| — attachBalance = số dư ledger snapshot một lần lúc OnInit; nạp/rút không cập nhật. |
//| — initialCapitalBaselineUSD = TEV snapshot một lần lúc OnInit — mốc % P/L & scale lot (reset phiên không đổi mốc). |
//| — P/L tích lũy chỉ từ deal BUY/SELL OUT cùng magic+symbol biểu đồ (bỏ deal balance). |
//| — Mọi quét vị thế/lệnh chờ/lịch sử: chỉ magic MagicNumber + _Symbol chart (không gộp magic khác). |
//| — Lưới/lot/TP: theo input; ngưỡng phiên USD + lỗ tối đa phiên: input × mult nếu bật scale vốn + “nhân ngưỡng phiên”; TP tổng: dồn P/L phiên (chỉ khi reset do đạt lãi nhóm 6). |
//| — Thông báo/lịch: không đổi lưới/lot/ngưỡng.                      |
//| — Scale vốn (nếu bật): mult theo TEV → nhân L1 lot, Add (cấp số cộng), tuỳ chọn nhân ngưỡng USD phiên; TEV không đổi chỉ vì nạp/rút. |
//+------------------------------------------------------------------+

//--- Kiểu tăng lot theo bậc lưới: 0=Cố định mọi bậc; 1=Cộng thêm mỗi bậc; 2=Nhân mỗi bậc (khác scale vốn nhóm 5).
enum ENUM_LOT_SCALE { LOT_FIXED = 0, LOT_ARITHMETIC = 1, LOT_GEOMETRIC = 2 };

// Bốn “chân” chờ ảo theo vị trí bậc so với gốc (+ trên / - dưới) và phía Buy/Sell.
enum ENUM_VGRID_LEG
{
   VGRID_LEG_BUY_ABOVE = 0,   // Bậc dương + Buy (BUY STOP / BUY LIMIT tại mức trên gốc)
   VGRID_LEG_SELL_BELOW = 1,  // Bậc âm + Sell (SELL STOP)
   VGRID_LEG_SELL_ABOVE = 2,  // Bậc dương + Sell (SELL LIMIT)
   VGRID_LEG_BUY_BELOW = 3    // Bậc âm + Buy (BUY LIMIT)
};

//+------------------------------------------------------------------+
//| Tab Inputs — [1–2] lưới+lệnh → [3] RSI + EMA + ADX đặt gốc (tuỳ chọn) → [4–5] lot+scale |
//| → [6–7] phiên+TP tổng → [8–9] lịch, MT5.                         |
//+------------------------------------------------------------------+

//——— Giao dịch: lưới, lệnh, lot, rồi scale lot (cùng cụm) ———
input group "━━ 1. Lưới giá (GRID) ━━"
input double GridDistancePips = 2000.0;         // Bước D giữa các mức (pip). Tắt cấp số cộng: bậc ±1 cách gốc nửa bước; bật: ±1 đúng D
input bool   EnableGridArithmeticSpacing = false; // Bật: khoảng bậc ±n theo công thức n*D+n(n-1)/2*A; mỗi bước lên bậc +D+k*A
input double GridArithmeticAddPips = 200.0;         // A (pip) khi bật cấp số cộng: mỗi bước xa gốc thêm A (1→2 +A, 2→3 +2A…)
input int MaxGridLevels = 50;                  // Số mức chờ ảo mỗi phía (trên và dưới giá gốc)

input group "━━ 2. Lệnh chung (magic / comment) ━━"
input int MagicNumber = 123456;                // Magic dùng chung cho chờ ảo và lệnh khớp (nhận diện lệnh EA)
input string CommentOrder = "VPGrid";           // Ghi chú (comment) gắn lệnh market

input group "━━ 2b. Chế độ theo đường gốc ━━"
input bool EnableBaseDirectionalMode = false;   // Bật: chỉ BUY phía bậc dương, SELL phía âm; đóng hết một bậc thì chờ giá lùi đủ bậc mới dựng lại

input group "━━ 2c. Bổ sung lệnh (replenish) ━━"
input bool EnableAutoReplenishVirtualOrders = true; // Bật: khớp/đóng lệnh thì tự dựng lại chờ ảo; Tắt: chỉ dựng một lần khi có gốc

input group "━━ 2d. Vùng cấm chờ ảo theo Gốc–EMA lúc khởi tạo lưới (phiên) ━━"
input bool   EnableInitBaseEmaVirtGapBlock = true; // Bật: chỉ chụp vùng Gốc–EMA lần đầu khi vừa đặt gốc; cùng gốc cả phiên thì giữ vùng. Chỉ cấm chờ ảo Stop (không cấm Limit). base>EMA → [EMA..base] cấm Sell Stop dưới gốc; base<EMA → [base..EMA] cấm Buy Stop trên gốc
input int    InitBaseEmaVirtGapEMAPeriod = 50;       // Chu kỳ EMA (PRICE_CLOSE), ≥1
input ENUM_TIMEFRAMES InitBaseEmaVirtGapEMATimeframe = PERIOD_M5; // Khung EMA lúc chụp (PERIOD_CURRENT = khung chart)

input group "━━ 3. RSI — chỉ đặt gốc lưới & chờ ảo khi trong vùng ━━"
input bool   EnableRSIFilterForGridStart = false; // Bật: chỉ khi RSI vào vùng lần đầu trên nến khung RSI mới khóa Bid làm gốc (ra vào vùng không đổi latch)
input int    RSIPeriod = 14;                     // Chu kỳ chỉ báo RSI
input ENUM_TIMEFRAMES RSITimeframe = PERIOD_M5; // Khung nến tính RSI
input double RSIZoneLow  = 45.0;                 // Cận dưới vùng: RSI phải lớn hơn giá trị này (ví dụ 45 < RSI)
input double RSIZoneHigh = 55.0;                 // Cận trên vùng: RSI phải nhỏ hơn giá trị này (ví dụ RSI < 55)

input group "━━ 3b. EMA — chỉ đặt gốc khi nến hiện tại cắt EMA ━━"
input bool   EnableEMAFilterForGridStart = false; // Bật: lần đầu giá cắt EMA trên nến khung EMA thì khóa Bid làm gốc (cắt lại không đổi latch)
input int    EMAPeriod = 50;                      // Chu kỳ đường EMA (giá đóng)
input ENUM_TIMEFRAMES EMATimeframe = PERIOD_M5; // Khung nến tính EMA (PERIOD_CURRENT = khung chart)

input group "━━ 3c. ADX — chỉ đặt gốc khi ADX trong vùng (đường ADX chính) ━━"
input bool   EnableADXFilterForGridStart = false;  // Bật: kiểm tra ADX mỗi tick khi chưa có gốc; đã chạy lưới thì không đổi đường gốc
input int    ADXPeriodForGridStart = 14;           // Chu kỳ chỉ báo ADX
input ENUM_TIMEFRAMES ADXTimeframeForGridStart = PERIOD_M5; // Khung nến tính ADX
input double ADXMinForGridStart = 0.0;             // ADX đường chính phải lớn hơn mức này; 0 = không kiểm tra phía dưới
input double ADXMaxForGridStart = 25.0;            // ADX đường chính phải nhỏ hơn mức này; 0 = không kiểm tra phía trên (cả hai >0: vùng min < ADX < max)

input group "━━ 4. Chờ ảo — lot / TP pip (full lưới) ━━"
input double VirtualGridLotSize = 0.1;         // Lot mức ±1 (sau đó nhóm 5 có thể nhân thêm hệ số theo TEV nếu bật scale vốn)
input ENUM_LOT_SCALE VirtualGridLotScale = LOT_GEOMETRIC; // 0=Cố định mọi bậc | 1=Cộng thêm VirtualGridLotAdd mỗi bậc | 2=Nhân VirtualGridLotMult mỗi bậc
input double VirtualGridLotAdd = 0.05;            // Khi chọn cấp số cộng: mỗi bậc cộng thêm Add (bậc k = L1+(k-1)*Add); Add cũng nhân mult khi bật scale vốn nhóm 5
input double VirtualGridLotMult = 1.1;           // Khi chọn hình học: lot bậc k = lot bậc 1 * Mult^(k-1)
input double VirtualGridMaxLot = 3.0;             // Trần lot mỗi lệnh (0 = chỉ giới hạn theo sàn)
input bool   VirtualGridTakeProfitAtNextLevel = false; // Bật: chốt lời theo giá mức lưới kế; tắt mới dùng TP pip bên dưới
input double VirtualGridTakeProfitPips = 0.0;  // TP theo pip (chỉ khi tắt TP theo mức lưới kế); 0 = không đặt TP pip
input bool   VirtualGridUsePerLegLotTpParams = true; // Tắt=false: MỘT bộ lot/TP (nhóm 4) cho cả 4 chân — không tách. Bật=true: TÁCH riêng — mỗi chân một bộ (nhóm 4a–4d: Buy+ / Sell- / Sell+ / Buy-)

input group "━━ 4a. Buy trên gốc (+) — lot / TP ━━"
input double VGridL1BuyAbove = 0.01;
input ENUM_LOT_SCALE VGridScaleBuyAbove = LOT_ARITHMETIC;
input double VGridLotAddBuyAbove = 0.01;
input double VGridLotMultBuyAbove = 1.5;
input double VGridMaxLotBuyAbove = 3.0;
input bool   VGridTpNextBuyAbove = false;
input double VGridTpPipsBuyAbove = 0.0;

input group "━━ 4b. Sell dưới gốc (-) — lot / TP ━━"
input double VGridL1SellBelow = 0.01;
input ENUM_LOT_SCALE VGridScaleSellBelow = LOT_ARITHMETIC;
input double VGridLotAddSellBelow = 0.01;
input double VGridLotMultSellBelow = 1.5;
input double VGridMaxLotSellBelow = 3.0;
input bool   VGridTpNextSellBelow = false;
input double VGridTpPipsSellBelow = 0.0;

input group "━━ 4c. Sell trên gốc (+) — lot / TP ━━"
input double VGridL1SellAbove = 0.01;
input ENUM_LOT_SCALE VGridScaleSellAbove = LOT_FIXED;
input double VGridLotAddSellAbove = 0.05;
input double VGridLotMultSellAbove = 1.5;
input double VGridMaxLotSellAbove = 3.0;
input bool   VGridTpNextSellAbove = true;
input double VGridTpPipsSellAbove = 0.0;

input group "━━ 4d. Buy dưới gốc (-) — lot / TP ━━"
input double VGridL1BuyBelow = 0.01;
input ENUM_LOT_SCALE VGridScaleBuyBelow = LOT_FIXED;
input double VGridLotAddBuyBelow = 0.05;
input double VGridLotMultBuyBelow = 1.5;
input double VGridMaxLotBuyBelow = 3.0;
input bool   VGridTpNextBuyBelow = true;
input double VGridTpPipsBuyBelow = 0.0;

input group "━━ 4e. SL khóa lãi theo bậc lưới ━━"
input bool EnableGridProfitLockStop = false;      // Bật: khi lời đủ số bậc thì đặt SL khóa một phần lãi theo cấu hình
input int  GridProfitLockTriggerLevels = 2;       // Số bậc lời tối thiểu (so với gốc) để bắt đầu áp SL khóa lãi
input int  GridProfitLockLockLevels = 1;          // Khóa lãi tương đương bao nhiêu “bậc” lưới (mặc định 1)

input group "━━ 5. Vốn — scale theo TEV (lot + tuỳ chọn ngưỡng phiên) ━━"
input bool   EnableCapitalBasedScaling = false;  // Bật: dùng mult theo TEV. TEV = số dư lúc gắn + P/L đóng + treo (magic), không đổi vì nạp/rút
input double CapitalGainScalePercent   = 70.0;  // X% độ nhạy 0–100: mult=1+(TEV/mốc−1)*(X/100). Ví dụ TEV +100% vs mốc, X=70 → phần nhân vào mult chỉ 70% độ lệch (tới trần). mốc=TEV lúc khởi động
input double CapitalScaleMaxBoostPercent = 100.0; // Trần mult: tối đa = 1 + giá_trị/100 (100→×2). Giới hạn cả lot và (nếu bật) ngưỡng USD phiên
input bool   ScaleSessionProfitTargetsWithCapital = false; // Bật: các ngưỡng USD nhóm 6 (reset phiên) nhân cùng mult; Tắt = giữ số input (hành vi cũ)

//——— Mục tiêu & thoát ———
input group "━━ 6. Phiên — reset theo mục tiêu lãi ━━"
input bool     EnableSessionProfitReset   = true;   // Bật: đủ điều kiện P/L phiên → đóng hết lệnh EA symbol, lưới mới. Gồng lãi 6b: chỉ tạm tắt reset mục tiêu lãi phiên khi ĐÃ đặt SL chung (sau +1 bước lưới); giai đoạn ARM / chờ bước (chưa SL chung) reset phiên vẫn hoạt động; hết gồng / reset sau SL chung → như cũ
input bool     SessionProfitEnable_TP_Open = false;  // Bật: một chế độ đếm P/L = TP trong phiên + treo (xem code ưu tiên với các mode khác)
input double   SessionProfitTargetUSD     = 30.0;   // Ngưỡng USD gốc (legacy); hiệu lực = gốc × mult nếu bật scale vốn + nhân ngưỡng phiên
input double   SessionProfitRequiredOpenLots_TP_Open = 0.0; // Điều kiện kèm: tổng lot đang mở phải đúng X (0=tắt)
input bool     SessionProfitUseOpenOnly   = false;   // Bật: P/L phiên chỉ = floating lệnh đang mở (magic), so với ngưỡng OpenOnly bên dưới
input double   SessionProfitTargetOpenOnlyUSD = 30.0; // Ngưỡng USD gốc (chỉ treo); hiệu lực = gốc × mult nếu bật nhân ngưỡng
input double   SessionProfitRequiredOpenLots_OpenOnly = 0; // Điều kiện kèm lot mở cho mode OpenOnly (0=tắt)
input bool     SessionProfitIncludeClosedTPandSL = false; // Bật: P/L phiên = (đóng TP+SL trong phiên) + treo, so ngưỡng TP_SL_Open
input double   SessionProfitTargetClosedTP_SL_OpenUSD = 20.0; // Ngưỡng USD gốc (TP+SL+treo); hiệu lực = gốc × mult nếu bật nhân ngưỡng
input double   SessionProfitRequiredOpenLots_TP_SL_Open = 1; // Điều kiện kèm lot mở cho mode TP+SL+treo (0=tắt)
input bool     EnableSessionMaxLossReset = false;   // Bật: (đóng TP+SL trong phiên + P/L treo lệnh mở phiên) <= -ngưỡng lỗ → reset phiên (đóng hết, lưới mới / chờ gốc)
input double   SessionMaxLossUSD = 2000.0;            // Lỗ tối đa cho phép mỗi phiên (USD gốc, nhập số dương, ví dụ 100); hiệu lực = gốc × mult nếu bật scale + nhân ngưỡng; 0=tắt
input double   SessionMaxLossRequiredOpenLots = 2; // Điều kiện kèm lot mở (0=tắt); cùng quy tắc khớp lot như nhóm 6

input group "━━ 6b. Gồng lãi tổng — kích hoạt: xóa chờ ảo; chờ +1 bước lưới; SL chung tại ref; đóng SELL/BUY theo giá vs gốc; SL trượt ━━"
input bool   EnableCompoundTotalFloatingProfit = true; // ARM/chờ bước: hết ngưỡng VÀ (Bid<tham chiếu nếu rổ trên gốc | Ask>tham chiếu nếu rổ dưới gốc) → hủy, coi như chưa gồng; chờ bước thì ManageGridOrders. Còn lại: >1 pip+ngưỡng→kích hoạt xóa chờ; +1 bước→SL@ref→đóng SELL/BUY theo Bid vs gốc; SL trượt. Max loss vẫn xét nếu bật
input double CompoundTotalProfitTriggerUSD = 20.0; // Ngưỡng (USD): CHỈ Σ(profit+swap) các lệnh ĐANG MỞ (magic+symbol chart), không TP/SL đóng trong phiên, không commission; ≤0=tắt. Cộng thêm phần điều chỉnh từ nhóm 6c (nếu bật)
input bool   CompoundResetOnCommonSlHit = true; // Bật: giá quay đầu chạm mức SL chung → đóng hết, xóa lưới, chờ tín hiệu đặt gốc (RSI/EMA/ADX theo input) hoặc đặt gốc ngay nếu đủ điều kiện

input group "━━ 6c. Cân bằng lệnh — đóng một phía + nâng ngưỡng gồng 6b ━━"
input bool   EnableOrderBalanceMode = true;        // Bật: khi giá xa gốc đủ bậc + đủ phút cùng phía gốc + lệch số lệnh hai phía → đóng hết lệnh phía yếu; P/L đóng (profit+swap) cộng vào ngưỡng Σ mở của 6b
input int    OrderBalanceMinGridStepsFromBase = 4; // Tối thiểu: Bid cách đường gốc theo số bậc lưới (trên hoặc dưới), ≥1
input int    OrderBalanceMinMinutesOnSideOfBase = 30; // Tối thiểu phút: Bid liên tục cùng phía đường gốc (chưa cắt qua vùng cấm quanh gốc), ≥1
input int    OrderBalanceCooldownSeconds = 60;     // Sau mỗi lần cân bằng: chờ N giây mới xét lại (0 = không chờ)
input bool   EnableOrderBalanceEMAFilter = true;  // Bật: N nến ĐÃ ĐÓNG gần nhất, liên tiếp theo thời gian (shift 1 = nến đóng mới nhất, 2,3… kế trước, không nhảy nến). Cả N đều close>EMA → chỉ nhánh đóng dưới gốc (+ Bid 6c); cả N close<EMA → chỉ đóng trên; lẫn hoặc có nến chạm EMA → không đóng
input int    OrderBalanceEMAPeriod = 50;         // Chu kỳ EMA (PRICE_CLOSE) cho lọc 6c, ≥1 (ví dụ: 100)
input ENUM_TIMEFRAMES OrderBalanceEMATimeframe = PERIOD_M5; // Khung nến so close vs EMA (PERIOD_CURRENT = khung chart)
input int    OrderBalanceEMAConfirmBars = 7;     // N = số nến đóng gần nhất, liên tiếp. Mỗi nến: close vs EMA cùng thời điểm; clamp 1..50

input group "━━ 7. TP tổng — dừng hẳn EA ━━"
input double TotalProfitStopUSD = 0.0;           // 0=tắt. >0: cộng dồn P/L mỗi lần reset phiên đạt mục nhóm 6; đủ thì đóng hết và gỡ EA (xóa GV để chạy lại)

//——— Vận hành & thông báo ———
input group "━━ 8. Lịch chạy — khung giờ (server MT5) ━━"
input bool   EnableRunTimeWindow = false;      // Bật: chỉ trong khung giờ mới được đặt gốc/chạy lưới; ngoài giờ EA chờ
input int    RunStartHour = 1;                 // Giờ bắt đầu khung (0..23), giờ server MT5
input int    RunStartMinute = 0;               // Phút bắt đầu (0..59)
input int    RunEndHour = 16;                  // Giờ kết thúc khung (0..23)
input int    RunEndMinute = 0;                 // Phút kết thúc (0..59)

input group "━━ 8b. Ngày chạy trong tuần (server MT5) ━━"
input bool EnableRunDayFilter = false;         // Bật: chỉ được mở/reset phiên mới vào các ngày bật bên dưới
input bool RunOnMonday    = true;              // Thứ 2
input bool RunOnTuesday   = true;              // Thứ 3
input bool RunOnWednesday = true;              // Thứ 4
input bool RunOnThursday  = true;              // Thứ 5
input bool RunOnFriday    = true;              // Thứ 6
input bool RunOnSaturday  = true;              // Thứ 7
input bool RunOnSunday    = true;              // Chủ nhật

input group "━━ 9. Thông báo — MT5 (push) ━━"
input bool EnableResetNotification = true;     // Bật: push MT5 khi reset/dừng — symbol, lý do, số vốn lúc đầu, số dư hiện tại • % (TEV vs mốc gắn EA)

//--- Global variables
CTrade trade;
double pnt;
int dgt;
double basePrice;                               // Base price (base line)
double gridLevels[];                            // Giá từng mức (đều hoặc cấp số cộng theo input)
double gridStep;                                // Bước tham chiếu (price): dung sai / khớp mức; khởi tạo trong InitializeGridLevels
double lastTickBid = 0.0;
double lastTickAsk = 0.0;
// Session TP-net — chỉ đóng TP, không pool cân bằng.
double sessionClosedProfit = 0.0;               // Session: TP profit in session. Reset on EA reset.
double sessionClosedProfitTpSl = 0.0;           // Session: profit from closes by TP or SL in session. Reset on EA reset.
datetime lastResetTime = 0;                     // Last reset time (avoid double-count from orders just closed on reset)
double attachBalance = 0.0;                    // Số dư ledger lúc gắn EA — không cập nhật khi nạp/rút; thành phần trong TEV
double initialCapitalBaselineUSD = 0.0;        // TEV một lần lúc OnInit — mốc % và mult scale lot (không đổi mỗi reset phiên)
datetime eaAttachTime = 0;                     // OnInit time: chỉ cộng deal OUT vào eaCumulativeTradingPL khi deal >= thời điểm này
double eaCumulativeTradingPL = 0.0;            // Tổng (profit+swap+comm) deal OUT cùng magic symbol từ lúc gắn EA — không nạp/rút
double sessionPeakTradingEquityView = 0.0;   // Cao nhất (attachBalance + eaCumulativeTradingPL + float magic) trong phiên lưới
double sessionMinTradingEquityView = 0.0;     // Thấp nhất — cùng công thức; không tính nạp/rút
double globalPeakTradingEquityView = 0.0;    // Cao nhất kể từ gắn EA
double globalMinTradingEquityView = 0.0;       // Thấp nhất kể từ gắn EA
double sessionMaxSingleLot = 0.0;              // Largest single position lot in session
double sessionTotalLotAtMaxLot = 0.0;         // Total open lot when that max single lot occurred
double globalMaxSingleLot = 0.0;              // Largest single lot since EA attach (not reset)
double globalTotalLotAtMaxLot = 0.0;          // Total open lot at that time since EA attach (not reset)
datetime sessionStartTime = 0;                // Current session: starts when EA attached or EA reset. Only P/L and orders from this time.
double sessionStartBalance = 0.0;             // TEV (vốn giao dịch quan sát) lúc bắt đầu phiên lưới — không phản ánh nạp/rút đơn thuần
int MagicAA = 0;                              // Strategy magic (= MagicNumber in OnInit)
bool g_runtimeSessionActive = true;           // true: trong lịch chạy (giờ/ngày); false: chờ tới khi lịch cho phép phiên mới
double g_accumResetSessionPL = 0.0;           // TP tổng: cộng dồn effectiveSession mỗi lần đạt mục phiên
bool g_gridBuiltOnceThisSession = false;      // Khi tắt auto replenish: chỉ dựng chờ ảo 1 lần mỗi phiên (sau khi đặt base)
bool g_compoundTotalProfitActive = false;     // Chế độ gồng lãi tổng (nhóm 6b): sau khi có SL chung → tắt reset mục tiêu lãi phiên; không nạp chờ ảo, SL trượt
bool g_compoundBuyBasketMode = false;         // true = giá Bid≥gốc: giữ BUY, SL chung buy; false = dưới gốc: giữ SELL
double g_compoundCommonSlLine = 0.0;          // Giá SL chung (0 = chưa đặt bước đầu); Buy: SL dưới giá; Sell: SL trên giá
bool g_compoundAfterClearWaitGrid = false;    // Sau kích hoạt: chờ thêm 1 bước lưới có lợi rồi SL tại ref + đóng phía ngược
double g_compoundFrozenRefPx = 0.0;           // Tham chiếu khóa lúc kích hoạt (xóa chờ ảo)
bool g_compoundActivationBuyBasket = false;   // Hướng bước lưới có lợi khi chờ (Bid≥gốc = buy basket)
bool g_compoundArmed = false;                 // Đạt ngưỡng treo, chờ giá xác nhận (chưa đóng lệnh / chưa xóa chờ ảo)
bool g_compoundArmBuyBasket = false;          // Hướng chờ khi armed (đồng nghĩa buyBasket khi xác nhận)
double g_balanceCompoundCarryUsd = 0.0;       // 6c: cộng vào ngưỡng Σ(profit+swap) mở cho ARM/chờ bước gồng 6b; xóa khi kích hoạt gồng / hết gồng / đóng hết EA
datetime g_orderBalAboveSideSince = 0;        // 6c: Bid liên tục phía trên gốc (chưa xuống vùng cấm)
datetime g_orderBalBelowSideSince = 0;        // 6c: Bid liên tục phía dưới gốc
datetime g_orderBalLastExecTime = 0;          // 6c: cooldown sau lần đóng cân bằng
int    g_orderBalanceEmaHandle = INVALID_HANDLE; // iMA EMA khi bật lọc EMA cân bằng (6c)
int    g_initBaseEmaVirtGapHandle = INVALID_HANDLE; // iMA nhóm 2d: vùng cấm chờ ảo theo khoảng gốc−EMA lúc Init lưới
bool   g_initBaseEmaVirtGapActive = false;    // 2d: vùng cấm theo gốc đã chụp; giữ cố định tới đổi gốc hoặc reset EA
double g_initBaseEmaVirtSnapBase = 0.0;       // 2d: gốc tại lúc chụp (đoạn gốc–EMA)
double g_initBaseEmaVirtSnapEma = 0.0;        // 2d: giá EMA tại lúc chụp (buffer shift 0)
bool   g_initBaseEmaVirtBaseAboveEma = false; // 2d: snapBase > snapEma
double g_initBaseEmaVirtGapPips = 0.0;        // 2d: |gốc−EMA| theo pip (10×point)
int    g_rsiHandle = INVALID_HANDLE;          // iRSI khi bật lọc RSI đặt gốc
bool   g_rsiInZonePrevTick = false;           // RSI trong vùng tick trước (chờ gốc)
bool   g_rsiLatchActive = false;              // đã vào vùng RSI lần đầu trên nến hiện tại → khóa Bid
double g_rsiLatchBid = 0.0;
datetime g_rsiLastBarOpenForLatch = 0;        // nến RSITimeframe — đổi nến thì xóa latch nếu chưa đặt gốc
int    g_emaHandle = INVALID_HANDLE;          // iMA EMA khi bật lọc EMA đặt gốc
bool   g_emaCrossPrevTick = false;            // trạng thái cắt EMA tick trước (chờ gốc)
bool   g_emaLatchActive = false;              // đã bắt lần cắt EMA đầu trên nến hiện tại → giá gốc = g_emaLatchBid
double g_emaLatchBid = 0.0;                   // Bid tại đúng tick cắt EMA lần đầu (mỗi nến / mỗi chu kỳ chờ)
datetime g_emaLastBarOpenForLatch = 0;        // time mở nến EMATimeframe — đổi nến thì xóa latch nếu chưa đặt gốc
int    g_adxHandle = INVALID_HANDLE;          // iADX khi bật lọc ADX đặt gốc
//--- Sau khi chờ ảo khớp market: chặn bổ sung lại chờ ảo cùng phía/mức cho tới khi vị thế hiện hoặc hết hạn
#define VPGRID_VIRTUAL_EXEC_COOLDOWN_SEC 5
struct VirtualExecCooldownEntry
{
   double   priceLevel;
   bool     isBuy;
   datetime expireUtc;
};
VirtualExecCooldownEntry g_virtualExecCooldown[];

struct VirtualRearmGateEntry
{
   double priceLevel;
   bool   isBuy;
};
VirtualRearmGateEntry g_virtualRearmGates[];

//--- Virtual pending: do not place broker pending orders; when price touches level -> Market + TP
struct VirtualPendingEntry
{
   long              magic;
   ENUM_ORDER_TYPE   orderType;
   double            priceLevel;
   int               levelNum;
   double            tpPrice;
   double            lot;
};
VirtualPendingEntry g_virtualPending[];

void VirtualPendingClear();
void ManageGridOrders();
void CompoundResetAfterCommonSlHit();
double GridPriceTolerance();
void OrderBalanceResetSideDwellState();
double GetCompoundFloatingTriggerThresholdUsd();
bool OrderBalanceLastClosedVsEma(int &biasOut);
bool ProcessOrderBalanceMode();
void InitBaseEmaVirtGapClearZone();
void InitBaseEmaVirtGapSnapshotFromGridInit();
bool InitBaseEmaVirtGapSuppressesVirtual(const ENUM_ORDER_TYPE orderType, const double priceLevel, const int signedLevelNum);
void InitBaseEmaVirtGapPurgeVirtualViolations();

//+------------------------------------------------------------------+
//| Khóa GlobalVariable: EA đã dừng vì TP tổng (mỗi chart+symbol+magic) |
//+------------------------------------------------------------------+
string VDualGridTotalStopGvKey()
{
   return "VDualGridTotalStop_" + IntegerToString(ChartID()) + "_" + _Symbol + "_" + IntegerToString(MagicAA);
}

//+------------------------------------------------------------------+
//| True if magic belongs to this EA                                   |
//+------------------------------------------------------------------+
bool IsOurMagic(long magic)
{
   return (magic == MagicAA);
}

//+------------------------------------------------------------------+
//| Vị thế / lệnh chờ: đúng magic EA (MagicAA) + symbol chart này     |
//+------------------------------------------------------------------+
bool PositionIsOurSymbolAndMagic(const ulong ticket)
{
   if(ticket == 0) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   return IsOurMagic(PositionGetInteger(POSITION_MAGIC)) && PositionGetString(POSITION_SYMBOL) == _Symbol;
}

bool OrderIsOurSymbolAndMagic(const ulong ticket)
{
   if(ticket == 0) return false;
   if(!OrderSelect(ticket)) return false;
   return IsOurMagic(OrderGetInteger(ORDER_MAGIC)) && OrderGetString(ORDER_SYMBOL) == _Symbol;
}

//+------------------------------------------------------------------+
//| Swap helpers for sort by distance                                |
//+------------------------------------------------------------------+
void SwapDouble(double &a, double &b) { double t = a; a = b; b = t; }
void SwapULong(ulong &a, ulong &b) { ulong t = a; a = b; b = t; }

string BuildOrderCommentWithLevel(int levelNum)
{
   return "VDualGrid|L" + (levelNum > 0 ? "+" : "") + IntegerToString(levelNum);
}

//+------------------------------------------------------------------+
//| Directional-by-base filter: allow buy only above base, sell only below base |
//+------------------------------------------------------------------+
bool IsOrderSideAllowedByBase(int levelNum, ENUM_ORDER_TYPE orderType)
{
   if(!EnableBaseDirectionalMode)
      return true;
   bool isBuy = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
   if(levelNum > 0)
      return isBuy;      // above base: buy only
   if(levelNum < 0)
      return !isBuy;     // below base: sell only
   return false;         // no trades on base
}

//+------------------------------------------------------------------+
//| In base-directional mode, require market to be at least 1 level  |
//| away from trigger level:                                          |
//| - Buy above base only when Ask is strictly below the nearer level |
//|   (for +1, nearer level is base -> must go below base first)      |
//| - Sell below base only when Bid is strictly above the nearer level|
//|   (for -1, nearer level is base -> must go above base first)      |
//+------------------------------------------------------------------+
bool IsDirectionalDistanceSatisfied(int levelNum, bool isBuySide, double bid, double ask)
{
   if(!EnableBaseDirectionalMode || basePrice <= 0.0 || levelNum == 0)
      return true;

   if(isBuySide && levelNum < 0)  return false;
   if(!isBuySide && levelNum > 0) return false;

   int n = MathAbs(levelNum);
   int nearerLevelAbs = n - 1; // level closer to base
   double nearerPrice = basePrice;
   if(nearerLevelAbs > 0)
   {
      int nearerSigned = (levelNum > 0) ? nearerLevelAbs : -nearerLevelAbs;
      nearerPrice = NormalizeDouble(basePrice + GridOffsetFromBaseForSignedLevel(nearerSigned), dgt);
   }

   double tol = GridPriceTolerance();
   if(isBuySide)
      return (ask < nearerPrice - tol); // must be clearly below nearer level
   return (bid > nearerPrice + tol);    // must be clearly above nearer level
}

bool GetPositionEntryByPositionId(ulong positionId, double &entryPrice, bool &isBuy)
{
   entryPrice = 0.0;
   isBuy = false;
   if(positionId == 0)
      return false;
   if(!HistorySelect(0, TimeCurrent()))
      return false;

   int total = HistoryDealsTotal();
   long firstInTime = LONG_MAX;
   bool found = false;
   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if((ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) != positionId) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
      if(!IsOurMagic(HistoryDealGetInteger(dealTicket, DEAL_MAGIC))) continue;
      long dt = (long)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(dt >= firstInTime) continue;
      long dType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      if(dType != DEAL_TYPE_BUY && dType != DEAL_TYPE_SELL) continue;
      firstInTime = dt;
      entryPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      isBuy = (dType == DEAL_TYPE_BUY);
      found = true;
   }
   return found;
}

//+------------------------------------------------------------------+
//| Remove virtual pendings at a level for a side (buy/sell)          |
//+------------------------------------------------------------------+
void RemoveVirtualPendingsAtLevelSide(double priceLevel, bool isBuy, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return;
   double tolerance = GridPriceTolerance();
   for(int i = ArraySize(g_virtualPending) - 1; i >= 0; i--)
   {
      if(g_virtualPending[i].magic != whichMagic) continue;
      if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) >= tolerance) continue;
      ENUM_ORDER_TYPE ot = g_virtualPending[i].orderType;
      bool entryBuy = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT);
      if(entryBuy == isBuy)
         VirtualPendingRemoveAt(i);
   }
}

//+------------------------------------------------------------------+
//| Find signed grid level number (+/-1..+/-Max) for a price (by tolerance) |
//+------------------------------------------------------------------+
bool FindSignedLevelNumForPrice(double price, int &signedLevelNum)
{
   signedLevelNum = 0;
   if(basePrice <= 0.0 || ArraySize(gridLevels) < 1)
      return false;
   double tol = GridPriceTolerance();
   for(int i = 0; i < ArraySize(gridLevels); i++)
   {
      if(MathAbs(gridLevels[i] - price) < tol)
      {
         signedLevelNum = GridSignedLevelNumFromIndex(i);
         return (signedLevelNum != 0);
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Modify SL/TP for a specific position ticket (hedging-safe)        |
//+------------------------------------------------------------------+
bool ModifyPositionSLTP(ulong positionTicket, double newSL, double keepTP)
{
   if(positionTicket == 0)
      return false;
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.position = (ulong)positionTicket;
   req.symbol   = _Symbol;
   req.sl       = newSL;
   req.tp       = keepTP;
   bool ok = OrderSend(req, res);
   if(!ok)
      Print("VDualGrid: SLTP send fail ticket ", positionTicket, " err ", GetLastError());
   return ok;
}

//+------------------------------------------------------------------+
//| Grid profit-lock stop: if profit >= N levels, set SL to lock M levels |
//+------------------------------------------------------------------+
void ApplyGridProfitLockStops()
{
   if(!EnableGridProfitLockStop)
      return;
   if(basePrice <= 0.0 || ArraySize(gridLevels) < MaxGridLevels + 1)
      return;

   int triggerN = GridProfitLockTriggerLevels;
   int lockN    = GridProfitLockLockLevels;
   if(triggerN < 1) triggerN = 1;
   if(lockN < 1) lockN = 1;
   if(lockN >= triggerN) lockN = triggerN - 1;
   if(lockN < 1) lockN = 1;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);   // points
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL); // points
   double minDist = (double)MathMax(stopsLevel, freezeLevel) * pt;
   double eps = pt * 2.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC)) || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(sessionStartTime > 0 && (datetime)PositionGetInteger(POSITION_TIME) < sessionStartTime) continue;

      ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool isBuy = (ptp == POSITION_TYPE_BUY);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int entryLvl = 0;
      if(!FindSignedLevelNumForPrice(openPrice, entryLvl))
         continue;

      int trigLvl = entryLvl + (isBuy ? triggerN : -triggerN);
      int lockLvl = entryLvl + (isBuy ? lockN : -lockN);
      if(MathAbs(trigLvl) > MaxGridLevels || MathAbs(lockLvl) > MaxGridLevels)
         continue;

      double trigPrice = NormalizeDouble(basePrice + GridOffsetFromBaseForSignedLevel(trigLvl), dgt);
      double lockSL    = NormalizeDouble(basePrice + GridOffsetFromBaseForSignedLevel(lockLvl), dgt);

      bool reached = false;
      if(isBuy)
         reached = (bid + eps >= trigPrice);
      else
         reached = (ask - eps <= trigPrice);
      if(!reached)
         continue;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      // Must be on the correct side and respect stops/freeze distance.
      if(isBuy)
      {
         if(lockSL >= bid - minDist)
            continue;
         if(curSL > 0.0 && curSL + eps >= lockSL)
            continue; // already locked equal/better
      }
      else
      {
         if(lockSL <= ask + minDist)
            continue;
         if(curSL > 0.0 && curSL - eps <= lockSL)
            continue; // already locked equal/better (lower SL for sell)
      }

      if(ModifyPositionSLTP(ticket, lockSL, curTP))
         Print("VDualGrid: GridProfitLock SL ticket ", ticket, " entryL=", entryLvl, " trigL=", trigLvl, " lockL=", lockLvl, " SL=", DoubleToString(lockSL, dgt));
   }
}

//+------------------------------------------------------------------+
//| Bước giá một mức lưới (dùng gridStep; nếu 0 thì từ D pip).         |
//+------------------------------------------------------------------+
double CompoundModeGridStepPrice()
{
   if(gridStep > 0.0)
      return gridStep;
   return MathMax(pnt * 10.0 * GridDistancePips, pnt);
}

//+------------------------------------------------------------------+
//| 1 pip giá (cùng quy ước bước pip lưới: 10 × point).                 |
//+------------------------------------------------------------------+
double OnePipPrice()
{
   return pnt * 10.0;
}

//+------------------------------------------------------------------+
//| Vị thế mở trong phiên lưới (cùng quy tắc đếm P/L phiên).           |
//+------------------------------------------------------------------+
bool CompoundPositionPassesSessionFilter(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;
   if(sessionStartTime <= 0)
      return true;
   return ((datetime)PositionGetInteger(POSITION_TIME) >= sessionStartTime);
}

void CompoundModeClearState()
{
   g_compoundTotalProfitActive = false;
   g_compoundBuyBasketMode = false;
   g_compoundCommonSlLine = 0.0;
   g_compoundAfterClearWaitGrid = false;
   g_compoundFrozenRefPx = 0.0;
   g_compoundArmed = false;
   g_compoundArmBuyBasket = false;
   g_balanceCompoundCarryUsd = 0.0;
   OrderBalanceResetSideDwellState();
}

//+------------------------------------------------------------------+
//| Ngưỡng Σ(profit+swap) mở cho logic gồng 6b (ARM + chờ bước hủy).   |
//+------------------------------------------------------------------+
double GetCompoundFloatingTriggerThresholdUsd()
{
   return CompoundTotalProfitTriggerUSD + g_balanceCompoundCarryUsd;
}

//+------------------------------------------------------------------+
//| Reset đồng hồ “cùng phía gốc” cho chế độ cân bằng lệnh (6c).      |
//+------------------------------------------------------------------+
void OrderBalanceResetSideDwellState()
{
   g_orderBalAboveSideSince = 0;
   g_orderBalBelowSideSince = 0;
}

//+------------------------------------------------------------------+
//| true = tạm tắt reset MỤC TIÊU LÃI nhóm 6 chỉ khi gồng 6b đã có SL chung (đang chờ bước nhưng đã ghi mức SL / hoặc đang trượt SL). |
//| false = ARM, chờ +1 bước lưới trước khi gán SL chung → reset phiên vẫn chạy. |
//+------------------------------------------------------------------+
bool CompoundSuppressesSessionProfitTargetReset()
{
   if(!EnableCompoundTotalFloatingProfit)
      return false;
   if(g_compoundCommonSlLine <= 0.0)
      return false;
   return (g_compoundTotalProfitActive || g_compoundAfterClearWaitGrid);
}

//+------------------------------------------------------------------+
//| Trên gốc (BUY): Bid vượt TRÊN ref → xóa chờ ảo.                    |
//| Dưới gốc (SELL): Bid vượt XUỐNG DƯỚI ref → xóa chờ ảo.             |
//+------------------------------------------------------------------+
void CompoundClearVirtualPendingsIfPriceAboveReference(const bool buyBasket, const double refPx)
{
   if(refPx <= 0.0 || !MathIsValidNumber(refPx))
      return;
   if(ArraySize(g_virtualPending) < 1)
      return;
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double tol = MathMax(GridPriceTolerance(), pt * 2.0);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool doClear = false;
   if(buyBasket)
   {
      if(bid > refPx + tol)
         doClear = true;
   }
   else
   {
      if(bid < refPx - tol)
         doClear = true;
   }
   if(!doClear)
      return;
   VirtualPendingClear();
   if(buyBasket)
      Print("VDualGrid: Gồng lãi — Bid trên tham chiếu ", DoubleToString(refPx, dgt), " → xóa chờ ảo.");
   else
      Print("VDualGrid: Gồng lãi — Bid dưới tham chiếu ", DoubleToString(refPx, dgt), " → xóa chờ ảo.");
}

//+------------------------------------------------------------------+
//| Tham chiếu như sau khi đã đóng phía ngược + lệnh âm (mô phỏng): bỏ qua lỗ & ngược. |
//+------------------------------------------------------------------+
bool CompoundEvaluateDeferredBasket(const bool buyBasket, double &refPxOut)
{
   refPxOut = 0.0;
   bool haveRef = false;
   for(int k = 0; k < PositionsTotal(); k++)
   {
      ulong ticket = PositionGetTicket(k);
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      const bool isLoser = (pl < 0.0);
      const bool isOpposite = (buyBasket && ptp == POSITION_TYPE_SELL) || (!buyBasket && ptp == POSITION_TYPE_BUY);
      if(isLoser || isOpposite)
         continue;
      if(buyBasket && ptp != POSITION_TYPE_BUY)
         continue;
      if(!buyBasket && ptp != POSITION_TYPE_SELL)
         continue;
      const double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(buyBasket && op <= basePrice)
         continue;
      if(!buyBasket && op >= basePrice)
         continue;
      if(!haveRef || (buyBasket && op > refPxOut) || (!buyBasket && op < refPxOut))
      {
         refPxOut = op;
         haveRef = true;
      }
   }
   return haveRef;
}

//+------------------------------------------------------------------+
//| Đặt SL theo mức line chung (ref) cho mọi vị thế phiên BUY+SELL.   |
//+------------------------------------------------------------------+
void CompoundApplyCommonSlLineToAllSessionPositions(const double lineNorm, const double minDist)
{
   trade.SetExpertMagicNumber(MagicAA);
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int p = 0; p < PositionsTotal(); p++)
   {
      ulong ticket = PositionGetTicket(p);
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double curSL = PositionGetDouble(POSITION_SL);
      const double curTP = PositionGetDouble(POSITION_TP);
      double newSL = 0.0;

      if(ptp == POSITION_TYPE_BUY)
      {
         newSL = MathMin(lineNorm, openPrice - minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL >= openPrice || newSL >= bid)
            continue;
         if(curSL > 0.0 && newSL <= curSL + pt)
            continue;
      }
      else
      {
         newSL = MathMax(lineNorm, openPrice + minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL <= openPrice || newSL <= ask)
            continue;
         if(curSL > 0.0 && newSL >= curSL - pt)
            continue;
      }

      if(ModifyPositionSLTP(ticket, newSL, curTP))
         Print("VDualGrid: Gồng lãi — SL tại tham chiếu ticket ", ticket, " SL=", DoubleToString(newSL, dgt));
   }
}

//+------------------------------------------------------------------+
//| Đủ giá + đủ ngưỡng: xóa hết chờ ảo; chờ thêm 1 bước lưới có lợi.   |
//+------------------------------------------------------------------+
void CompoundOnActivationConfirmed(const bool buyBasket, const double refPx)
{
   g_balanceCompoundCarryUsd = 0.0;
   VirtualPendingClear();
   g_compoundFrozenRefPx = refPx;
   g_compoundActivationBuyBasket = buyBasket;
   g_compoundAfterClearWaitGrid = true;
   g_compoundArmed = false;
   g_compoundTotalProfitActive = false;
   g_compoundCommonSlLine = 0.0;
   Print("VDualGrid: Gồng lãi — KÍCH HOẠT: đã xóa hết chờ ảo. Tham chiếu=", DoubleToString(refPx, dgt),
         " | Chờ +1 bước lưới có lợi → SL chung tại ref → đóng toàn bộ SELL nếu Bid≥gốc, toàn bộ BUY nếu Bid<gốc.",
         " | Reset mục tiêu lãi phiên (nhóm 6): vẫn BẬT cho đến khi đặt SL chung; sau đó tạm tắt.");
}

//+------------------------------------------------------------------+
//| Sau kích hoạt: giá đi thêm 1 bước lưới có lợi → SL tại ref → đóng phía. |
//| Hết ngưỡng + giá xấu vs ref → hủy chờ, coi như chưa gồng (ManageGridOrders bổ sung chờ ảo). |
//+------------------------------------------------------------------+
void ProcessCompoundPostActivationGridStepWait(const double totalOpenProfitSwapUsd)
{
   if(!g_compoundAfterClearWaitGrid)
      return;

   const double step = CompoundModeGridStepPrice();
   if(step <= 0.0 || g_compoundFrozenRefPx <= 0.0 || !MathIsValidNumber(g_compoundFrozenRefPx))
   {
      g_compoundAfterClearWaitGrid = false;
      g_compoundFrozenRefPx = 0.0;
      return;
   }

   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double refTol = MathMax(GridPriceTolerance(), pt * 2.0);
   if(CompoundTotalProfitTriggerUSD > 0.0 && totalOpenProfitSwapUsd < GetCompoundFloatingTriggerThresholdUsd())
   {
      if(g_compoundActivationBuyBasket && bid < g_compoundFrozenRefPx - refTol)
      {
         g_compoundAfterClearWaitGrid = false;
         g_compoundFrozenRefPx = 0.0;
         Print("VDualGrid: Gồng lãi — HỦY chờ bước: ngưỡng không còn & Bid dưới tham chiếu (trên gốc) — khôi phục như chưa đạt ngưỡng gồng.");
         ManageGridOrders();
         return;
      }
      if(!g_compoundActivationBuyBasket && ask > g_compoundFrozenRefPx + refTol)
      {
         g_compoundAfterClearWaitGrid = false;
         g_compoundFrozenRefPx = 0.0;
         Print("VDualGrid: Gồng lãi — HỦY chờ bước: ngưỡng không còn & Ask trên tham chiếu (dưới gốc) — khôi phục như chưa đạt ngưỡng gồng.");
         ManageGridOrders();
         return;
      }
   }

   bool stepOk = false;
   if(g_compoundActivationBuyBasket)
      stepOk = ((bid - g_compoundFrozenRefPx) >= step - pt * 0.5);
   else
      stepOk = ((g_compoundFrozenRefPx - ask) >= step - pt * 0.5);

   if(!stepOk)
      return;

   if(basePrice <= 0.0)
   {
      g_compoundAfterClearWaitGrid = false;
      g_compoundFrozenRefPx = 0.0;
      Print("VDualGrid: Gồng lãi — chờ bước lưới: base=0, hủy pha chờ.");
      return;
   }

   const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (double)MathMax(stopsLevel, freezeLevel) * pt;
   if(minDist < pt * 2.0)
      minDist = pt * 2.0;

   const double lineNorm = NormalizeDouble(g_compoundFrozenRefPx, dgt);
   g_compoundCommonSlLine = lineNorm;
   CompoundApplyCommonSlLineToAllSessionPositions(lineNorm, minDist);

   trade.SetExpertMagicNumber(MagicAA);
   if(bid >= basePrice)
   {
      for(int j = PositionsTotal() - 1; j >= 0; j--)
      {
         ulong ticket = PositionGetTicket(j);
         if(!PositionIsOurSymbolAndMagic(ticket))
            continue;
         if(!CompoundPositionPassesSessionFilter(ticket))
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
            continue;
         trade.PositionClose(ticket);
      }
      Print("VDualGrid: Gồng lãi — Bid≥gốc: đã đóng toàn bộ SELL (phiên).");
   }
   else
   {
      for(int j = PositionsTotal() - 1; j >= 0; j--)
      {
         ulong ticket = PositionGetTicket(j);
         if(!PositionIsOurSymbolAndMagic(ticket))
            continue;
         if(!CompoundPositionPassesSessionFilter(ticket))
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
            continue;
         trade.PositionClose(ticket);
      }
      Print("VDualGrid: Gồng lãi — Bid<gốc: đã đóng toàn bộ BUY (phiên).");
   }

   g_compoundBuyBasketMode = (bid >= basePrice);
   g_compoundAfterClearWaitGrid = false;
   g_compoundFrozenRefPx = 0.0;
   g_compoundTotalProfitActive = true;

   Print("VDualGrid: Gồng lãi tổng — SL chung tại tham chiếu, đóng phía xong → bật trượt SL theo bậc. Rổ ",
         (g_compoundBuyBasketMode ? "BUY" : "SELL"), ".");
}

//+------------------------------------------------------------------+
//| Đạt ngưỡng Σ(profit+swap) lệnh mở: chỉ ARM — chưa đóng lệnh / chưa xóa chờ ảo. |
//+------------------------------------------------------------------+
void TryArmCompoundTotalProfitMode()
{
   if(g_compoundTotalProfitActive || g_compoundArmed || g_compoundAfterClearWaitGrid)
      return;
   if(!EnableCompoundTotalFloatingProfit || CompoundTotalProfitTriggerUSD <= 0.0)
      return;
   if(basePrice <= 0.0)
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const bool buyBasket = (bid >= basePrice);
   double refPx = 0.0;
   if(!CompoundEvaluateDeferredBasket(buyBasket, refPx))
   {
      Print("VDualGrid: Gồng lãi tổng — sau dọn (mô phỏng) không còn ", (buyBasket ? "BUY" : "SELL"), " trên/dưới gốc — không ARM.");
      return;
   }

   g_compoundArmed = true;
   g_compoundArmBuyBasket = buyBasket;
   const double step = CompoundModeGridStepPrice();
   const double onePip = OnePipPrice();
   Print("VDualGrid: Gồng lãi tổng — ARM (chờ đủ giá + đủ ngưỡng). Tham chiếu=", DoubleToString(refPx, dgt),
         " | 1 pip=", DoubleToString(onePip, dgt),
         (step > 0.0 ? (" | bước lưới=" + DoubleToString(step, dgt)) : ""),
         " | ngưỡng=", DoubleToString(GetCompoundFloatingTriggerThresholdUsd(), 2), " USD (Σ profit+swap lệnh mở",
         (MathAbs(g_balanceCompoundCarryUsd) > 1e-8 ? "; gốc input " + DoubleToString(CompoundTotalProfitTriggerUSD, 2) + " +6c " + DoubleToString(g_balanceCompoundCarryUsd, 2) : ""),
         ")",
         (buyBasket ? " | Đủ giá: (Bid−ref)>1 pip; HỦY: Bid≤ref−1 pip." : " | Đủ giá: (ref−Ask)>1 pip; HỦY: Ask≥ref+1 pip."));
}

//+------------------------------------------------------------------+
//| Đang ARM: đủ giá = Bid/Ask lệch tham chiếu > 1 pip; + Σ profit+swap mở ≥ ngưỡng → execute. |
//| totalOpenProfitSwapUsd = chỉ lệnh mở magic+symbol (không lọc theo sessionStartTime). |
//+------------------------------------------------------------------+
void ProcessCompoundArming(const double totalOpenProfitSwapUsd)
{
   if(!g_compoundArmed)
      return;

   const bool buyBasket = g_compoundArmBuyBasket;
   double refPx = 0.0;
   if(!CompoundEvaluateDeferredBasket(buyBasket, refPx))
   {
      g_compoundArmed = false;
      Print("VDualGrid: Gồng lãi tổng — mất tham chiếu khi chờ — HỦY ARM (không đóng lệnh).");
      return;
   }

   const double onePip = OnePipPrice();
   if(onePip <= 0.0)
      return;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double compoundFloatThr = GetCompoundFloatingTriggerThresholdUsd();
   const bool floatOk = (CompoundTotalProfitTriggerUSD > 0.0
                           && totalOpenProfitSwapUsd >= compoundFloatThr);
   const double refTol = MathMax(GridPriceTolerance(), SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 2.0);
   if(CompoundTotalProfitTriggerUSD > 0.0 && totalOpenProfitSwapUsd < compoundFloatThr)
   {
      if(buyBasket && bid < refPx - refTol)
      {
         g_compoundArmed = false;
         Print("VDualGrid: Gồng lãi tổng — HỦY ARM: ngưỡng không còn & Bid dưới tham chiếu (trên gốc) — coi như chưa đạt ngưỡng gồng.");
         return;
      }
      if(!buyBasket && ask > refPx + refTol)
      {
         g_compoundArmed = false;
         Print("VDualGrid: Gồng lãi tổng — HỦY ARM: ngưỡng không còn & Ask trên tham chiếu (dưới gốc) — coi như chưa đạt ngưỡng gồng.");
         return;
      }
   }

   if(buyBasket)
   {
      // Đủ giá: (Bid − tham chiếu) > 1 pip.
      if((bid - refPx) > onePip)
      {
         if(!floatOk)
            return;
         g_compoundArmed = false;
         CompoundOnActivationConfirmed(true, refPx);
         return;
      }
      // Hủy đối xứng: Bid nằm từ tham chiếu trở xuống quá 1 pip.
      if(bid <= refPx - onePip)
      {
         g_compoundArmed = false;
         Print("VDualGrid: Gồng lãi tổng — HỦY ARM: Bid ≤ tham chiếu − 1 pip — không đóng lệnh, không xóa chờ ảo.");
         return;
      }
   }
   else
   {
      // Rổ SELL: đủ giá = (tham chiếu − Ask) > 1 pip.
      if((refPx - ask) > onePip)
      {
         if(!floatOk)
            return;
         g_compoundArmed = false;
         CompoundOnActivationConfirmed(false, refPx);
         return;
      }
      if(ask >= refPx + onePip)
      {
         g_compoundArmed = false;
         Print("VDualGrid: Gồng lãi tổng — HỦY ARM: Ask ≥ tham chiếu + 1 pip — không đóng lệnh, không xóa chờ ảo.");
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Chạm SL chung (gồng lãi): reset như hết phiên — chờ / đặt gốc theo input. |
//+------------------------------------------------------------------+
void CompoundResetAfterCommonSlHit()
{
   CloseAllPositionsAndOrders();
   lastResetTime = TimeCurrent();
   sessionClosedProfit = 0.0;
   sessionClosedProfitTpSl = 0.0;

   if(!IsSchedulingAllowedForNewSession(TimeCurrent()))
   {
      g_runtimeSessionActive = false;
      VirtualPendingClear();
      ArrayResize(gridLevels, 0);
      sessionStartTime = 0;
      basePrice = 0.0;
      Print("VDualGrid: Gồng lãi — chạm SL chung, reset ngoài lịch chạy — EA chờ giờ/ngày.");
      if(EnableResetNotification)
         SendResetNotification("Gồng lãi: chạm SL chung — ngoài lịch chạy");
      return;
   }

   ResetAllGridStartLatches();
   UpdateAllGridStartLatchesWhileWaiting();
   if(GridStartTimeAndRSIOk(TimeCurrent()))
   {
      basePrice = GridBasePriceAtPlacement();
      InitializeGridLevels();
      ResetAllGridStartLatches();
      Print("VDualGrid: Gồng lãi — chạm SL chung — đặt gốc mới ngay, base=", DoubleToString(basePrice, dgt));
      if(EnableResetNotification)
         SendResetNotification("Gồng lãi: chạm SL chung — lưới mới");
      ManageGridOrders();
   }
   else
   {
      basePrice = 0.0;
      VirtualPendingClear();
      ArrayResize(gridLevels, 0);
      sessionStartTime = 0;
      {
         string rs = "VDualGrid: Gồng lãi — chạm SL chung — chờ điều kiện đặt gốc mới";
         if(EnableRSIFilterForGridStart)
            rs += " | RSI lần đầu vào vùng " + DoubleToString(RSIZoneLow, 1) + " < RSI < " + DoubleToString(RSIZoneHigh, 1);
         if(EnableEMAFilterForGridStart)
            rs += " | EMA: lần cắt đầu trên nến (khóa giá)";
         if(EnableADXFilterForGridStart && ADXStartGateUsesThresholds())
            rs += " | ADX trong vùng (theo input)";
         Print(rs + ".");
      }
      if(EnableResetNotification)
         SendResetNotification("Gồng lãi: chạm SL chung — chờ tín hiệu đặt gốc");
   }
}

//+------------------------------------------------------------------+
//| SL chung BUY: mức = maxBuy + (k-1)*bước với k=floor((Bid-maxBuy)/step), k≥1. |
//| Ví dụ maxBuy=1300, step=100: Bid≥1400 → SL=1300; Bid≥1500 → SL=1400 (không nhảy 2 bậc trong 1 tick). |
//+------------------------------------------------------------------+
void ProcessCompoundTotalProfitTrailing()
{
   if(!g_compoundTotalProfitActive)
      return;

   const double step = CompoundModeGridStepPrice();
   if(step <= 0.0)
      return;

   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (double)MathMax(stopsLevel, freezeLevel) * pt;
   if(minDist < pt * 2.0)
      minDist = pt * 2.0;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double touchTol = MathMax(GridPriceTolerance(), pt * 3.0);

   double extOpen = 0.0;
   bool haveExt = false;
   int managed = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(g_compoundBuyBasketMode)
      {
         if(ptp != POSITION_TYPE_BUY)
            continue;
         if(op <= basePrice)
            continue;
         managed++;
         if(!haveExt || op > extOpen)
         {
            extOpen = op;
            haveExt = true;
         }
      }
      else
      {
         if(ptp != POSITION_TYPE_SELL)
            continue;
         if(op >= basePrice)
            continue;
         managed++;
         if(!haveExt || op < extOpen)
         {
            extOpen = op;
            haveExt = true;
         }
      }
   }

   if(managed == 0 || !haveExt)
   {
      CompoundModeClearState();
      Print("VDualGrid: Gồng lãi tổng — hết vị thế quản lý, TẮT chế độ. Reset lãi phiên (nhóm 6) hoạt động lại.");
      ManageGridOrders();
      return;
   }

   CompoundClearVirtualPendingsIfPriceAboveReference(g_compoundBuyBasketMode, extOpen);

   if(CompoundResetOnCommonSlHit && g_compoundCommonSlLine > 0.0)
   {
      if(g_compoundBuyBasketMode)
      {
         if(bid <= g_compoundCommonSlLine + touchTol)
         {
            Print("VDualGrid: Gồng lãi — Bid chạm SL chung ", DoubleToString(g_compoundCommonSlLine, dgt), " → reset EA, chờ đặt gốc.");
            CompoundResetAfterCommonSlHit();
            return;
         }
      }
      else
      {
         if(ask >= g_compoundCommonSlLine - touchTol)
         {
            Print("VDualGrid: Gồng lãi — Ask chạm SL chung ", DoubleToString(g_compoundCommonSlLine, dgt), " → reset EA, chờ đặt gốc.");
            CompoundResetAfterCommonSlHit();
            return;
         }
      }
   }

   if(g_compoundBuyBasketMode)
   {
      if(bid >= extOpen + step - pt * 0.5)
      {
         const int k = (int)MathFloor((bid - extOpen) / step + 1e-8);
         if(k >= 1)
         {
            const double candidate = NormalizeDouble(extOpen + (double)(k - 1) * step, dgt);
            if(candidate > 0.0)
            {
               if(g_compoundCommonSlLine <= 0.0)
                  g_compoundCommonSlLine = candidate;
               else
                  g_compoundCommonSlLine = MathMax(g_compoundCommonSlLine, candidate);
            }
         }
      }
   }
   else
   {
      if(ask <= extOpen - step + pt * 0.5)
      {
         const int k = (int)MathFloor((extOpen - ask) / step + 1e-8);
         if(k >= 1)
         {
            const double candidate = NormalizeDouble(extOpen - (double)(k - 1) * step, dgt);
            if(candidate > 0.0)
            {
               if(g_compoundCommonSlLine <= 0.0)
                  g_compoundCommonSlLine = candidate;
               else
                  g_compoundCommonSlLine = MathMin(g_compoundCommonSlLine, candidate);
            }
         }
      }
   }

   if(g_compoundCommonSlLine <= 0.0)
      return;

   for(int p = 0; p < PositionsTotal(); p++)
   {
      ulong ticket = PositionGetTicket(p);
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(g_compoundBuyBasketMode && ptp != POSITION_TYPE_BUY)
         continue;
      if(!g_compoundBuyBasketMode && ptp != POSITION_TYPE_SELL)
         continue;

      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(g_compoundBuyBasketMode && openPrice <= basePrice)
         continue;
      if(!g_compoundBuyBasketMode && openPrice >= basePrice)
         continue;

      const double curSL = PositionGetDouble(POSITION_SL);
      const double curTP = PositionGetDouble(POSITION_TP);
      double newSL = 0.0;

      if(g_compoundBuyBasketMode)
      {
         newSL = MathMin(g_compoundCommonSlLine, openPrice - minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL >= openPrice)
            continue;
         if(curSL > 0.0 && newSL <= curSL + pt)
            continue;
      }
      else
      {
         newSL = MathMax(g_compoundCommonSlLine, openPrice + minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL <= openPrice)
            continue;
         if(curSL > 0.0 && newSL >= curSL - pt)
            continue;
      }

      if(ModifyPositionSLTP(ticket, newSL, curTP))
         Print("VDualGrid: Gồng lãi — SL chung ticket ", ticket, " SL=", DoubleToString(newSL, dgt));
   }
}

//+------------------------------------------------------------------+
//| Virtual pending: clear all                                        |
//+------------------------------------------------------------------+
void VirtualPendingClear()
{
   ArrayResize(g_virtualPending, 0);
   ArrayResize(g_virtualExecCooldown, 0);
   ArrayResize(g_virtualRearmGates, 0);
}

int VirtualRearmGateFindIndex(double priceLevel, bool isBuy)
{
   double tol = GridPriceTolerance();
   for(int i = 0; i < ArraySize(g_virtualRearmGates); i++)
   {
      if(g_virtualRearmGates[i].isBuy != isBuy) continue;
      if(MathAbs(g_virtualRearmGates[i].priceLevel - priceLevel) < tol)
         return i;
   }
   return -1;
}

void VirtualRearmGateSet(double priceLevel, bool isBuy)
{
   double p = NormalizeDouble(priceLevel, dgt);
   if(VirtualRearmGateFindIndex(p, isBuy) >= 0)
      return;
   int n = ArraySize(g_virtualRearmGates);
   ArrayResize(g_virtualRearmGates, n + 1);
   g_virtualRearmGates[n].priceLevel = p;
   g_virtualRearmGates[n].isBuy = isBuy;
}

void VirtualRearmGateClear(double priceLevel, bool isBuy)
{
   int idx = VirtualRearmGateFindIndex(priceLevel, isBuy);
   int n = ArraySize(g_virtualRearmGates);
   if(idx < 0 || idx >= n) return;
   if(n == 1) { ArrayResize(g_virtualRearmGates, 0); return; }
   g_virtualRearmGates[idx] = g_virtualRearmGates[n - 1];
   ArrayResize(g_virtualRearmGates, n - 1);
}

bool VirtualRearmGateIsActive(double priceLevel, bool isBuy)
{
   return (VirtualRearmGateFindIndex(priceLevel, isBuy) >= 0);
}

//+------------------------------------------------------------------+
//| Same order side (buy vs sell) for virtual entry                   |
//+------------------------------------------------------------------+
bool VirtualPendingSameSide(ENUM_ORDER_TYPE a, ENUM_ORDER_TYPE b)
{
   bool ba = (a == ORDER_TYPE_BUY_LIMIT || a == ORDER_TYPE_BUY_STOP);
   bool bb = (b == ORDER_TYPE_BUY_LIMIT || b == ORDER_TYPE_BUY_STOP);
   return (ba == bb);
}

//+------------------------------------------------------------------+
//| Find virtual pending index (-1 = none)                            |
//+------------------------------------------------------------------+
int VirtualPendingFindIndex(long magic, ENUM_ORDER_TYPE orderType, double priceLevel)
{
   if(!IsOurMagic(magic)) return -1;
   double tol = gridStep * 0.5;
   if(gridStep <= 0) tol = pnt * 10.0 * GridDistancePips * 0.5;
   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(g_virtualPending[i].magic != magic) continue;
      if(!VirtualPendingSameSide(g_virtualPending[i].orderType, orderType)) continue;
      if(g_virtualPending[i].orderType != orderType) continue;
      if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) < tol)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Add virtual pending if not duplicate at level                     |
//+------------------------------------------------------------------+
bool VirtualPendingAdd(long magic, ENUM_ORDER_TYPE orderType, double priceLevel, int levelNum, double tpPrice, double lot)
{
   if(!IsOurMagic(magic))
      return false;
   if(VirtualPendingFindIndex(magic, orderType, priceLevel) >= 0)
      return true;
   int n = ArraySize(g_virtualPending);
   ArrayResize(g_virtualPending, n + 1);
   g_virtualPending[n].magic = magic;
   g_virtualPending[n].orderType = orderType;
   g_virtualPending[n].priceLevel = NormalizeDouble(priceLevel, dgt);
   g_virtualPending[n].levelNum = levelNum;
   g_virtualPending[n].tpPrice = tpPrice;
   g_virtualPending[n].lot = lot;
   return true;
}

//+------------------------------------------------------------------+
//| Remove virtual pending at index (swap with last)                  |
//+------------------------------------------------------------------+
void VirtualPendingRemoveAt(int idx)
{
   int n = ArraySize(g_virtualPending);
   if(idx < 0 || idx >= n) return;
   if(n == 1) { ArrayResize(g_virtualPending, 0); return; }
   g_virtualPending[idx] = g_virtualPending[n - 1];
   ArrayResize(g_virtualPending, n - 1);
}

//+------------------------------------------------------------------+
//| Dung sai cho cùng một ô lưới (virtual / trùng lặp)                  |
//+------------------------------------------------------------------+
double GridPriceTolerance()
{
   double t = gridStep * 0.5;
   if(gridStep <= 0.0)
      t = pnt * 10.0 * GridDistancePips * 0.5;
   return t;
}

//+------------------------------------------------------------------+
//| 6c: N nến ĐÃ ĐÓNG gần nhất, liên tiếp (Copy* từ shift 1, count=N).   |
//| Mỗi nến: close vs EMA cùng shift. bias +1 / −1 / 0 như trước.        |
//+------------------------------------------------------------------+
bool OrderBalanceLastClosedVsEma(int &biasOut)
{
   biasOut = 0;
   if(!EnableOrderBalanceEMAFilter || g_orderBalanceEmaHandle == INVALID_HANDLE)
      return false;
   ENUM_TIMEFRAMES tf = OrderBalanceEMATimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;
   int nBar = OrderBalanceEMAConfirmBars;
   if(nBar < 1)
      nBar = 1;
   if(nBar > 50)
      nBar = 50;
   const int emaP = MathMax(1, OrderBalanceEMAPeriod);
   if(BarsCalculated(g_orderBalanceEmaHandle) < emaP + nBar + 2)
      return false;

   // shift 1 = nến đóng mới nhất; shift 2..N = các nến đóng liền trước đó (không bỏ sót).
   double emaVal[];
   ArrayResize(emaVal, nBar);
   if(CopyBuffer(g_orderBalanceEmaHandle, 0, 1, nBar, emaVal) != nBar)
      return false;

   MqlRates rr[];
   ArrayResize(rr, nBar);
   if(CopyRates(_Symbol, tf, 1, nBar, rr) != nBar)
      return false;

   bool allAbove = true;
   bool allBelow = true;
   for(int i = 0; i < nBar; i++)
   {
      const double cls = rr[i].close;
      const double ema = emaVal[i];
      if(cls <= ema)
         allAbove = false;
      if(cls >= ema)
         allBelow = false;
   }
   if(allAbove)
      biasOut = 1;
   else if(allBelow)
      biasOut = -1;
   else
      biasOut = 0;
   return true;
}

//+------------------------------------------------------------------+
//| 2d: giá nằm trong đoạn [min(base,EMA)..max(base,EMA)] lúc chụp.     |
//+------------------------------------------------------------------+
bool InitBaseEmaVirtGapPriceInZone(const double priceLevel)
{
   if(!g_initBaseEmaVirtGapActive)
      return false;
   const double lo = MathMin(g_initBaseEmaVirtSnapBase, g_initBaseEmaVirtSnapEma);
   const double hi = MathMax(g_initBaseEmaVirtSnapBase, g_initBaseEmaVirtSnapEma);
   const double tol = MathMax(GridPriceTolerance(), SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 2.0);
   return (priceLevel >= lo - tol && priceLevel <= hi + tol);
}

//+------------------------------------------------------------------+
//| 2d: chỉ chặn chờ ảo Stop (không chặn Limit).                       |
//| base>EMA → zone: chặn Sell Stop dưới gốc (bậc âm).                 |
//| base<EMA → zone: chặn Buy Stop trên gốc (bậc dương).              |
//+------------------------------------------------------------------+
bool InitBaseEmaVirtGapSuppressesVirtual(const ENUM_ORDER_TYPE orderType, const double priceLevel, const int signedLevelNum)
{
   if(!EnableInitBaseEmaVirtGapBlock || !g_initBaseEmaVirtGapActive)
      return false;
   if(!InitBaseEmaVirtGapPriceInZone(priceLevel))
      return false;
   const bool isSellStop = (orderType == ORDER_TYPE_SELL_STOP);
   const bool isBuyStop = (orderType == ORDER_TYPE_BUY_STOP);
   if(g_initBaseEmaVirtBaseAboveEma)
   {
      if(!isSellStop)
         return false;
      if(signedLevelNum >= 0)
         return false;
      return true;
   }
   if(!isBuyStop)
      return false;
   if(signedLevelNum <= 0)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| 2d: gỡ chờ ảo Stop vi phạm vùng (sau chụp / đổi gốc). Limit giữ.   |
//+------------------------------------------------------------------+
void InitBaseEmaVirtGapPurgeVirtualViolations()
{
   if(!g_initBaseEmaVirtGapActive)
      return;
   for(int i = ArraySize(g_virtualPending) - 1; i >= 0; i--)
   {
      if(!InitBaseEmaVirtGapSuppressesVirtual(g_virtualPending[i].orderType, g_virtualPending[i].priceLevel, g_virtualPending[i].levelNum))
         continue;
      VirtualPendingRemoveAt(i);
   }
}

//+------------------------------------------------------------------+
//| 2d: xóa vùng cấm (reset EA / trước khi init lưới mới).             |
//+------------------------------------------------------------------+
void InitBaseEmaVirtGapClearZone()
{
   g_initBaseEmaVirtGapActive = false;
   g_initBaseEmaVirtGapPips = 0.0;
   g_initBaseEmaVirtSnapBase = 0.0;
   g_initBaseEmaVirtSnapEma = 0.0;
   g_initBaseEmaVirtBaseAboveEma = false;
}

//+------------------------------------------------------------------+
//| 2d: cuối Init lưới — chỉ chụp khi gốc mới (hoặc đổi gốc); cùng gốc → giữ vùng. |
//+------------------------------------------------------------------+
void InitBaseEmaVirtGapSnapshotFromGridInit()
{
   if(!EnableInitBaseEmaVirtGapBlock)
   {
      InitBaseEmaVirtGapClearZone();
      return;
   }

   if(basePrice <= 0.0)
   {
      InitBaseEmaVirtGapClearZone();
      return;
   }

   const double baseSnapTol = MathMax(GridPriceTolerance(), SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 2.0);
   if(g_initBaseEmaVirtGapActive && MathAbs(basePrice - g_initBaseEmaVirtSnapBase) <= baseSnapTol)
      return;

   InitBaseEmaVirtGapClearZone();

   if(g_initBaseEmaVirtGapHandle == INVALID_HANDLE)
      return;
   const int emaP = MathMax(1, InitBaseEmaVirtGapEMAPeriod);
   if(BarsCalculated(g_initBaseEmaVirtGapHandle) < emaP + 1)
      return;
   double emaBuf[1];
   if(CopyBuffer(g_initBaseEmaVirtGapHandle, 0, 0, 1, emaBuf) != 1)
      return;
   const double emaPx = emaBuf[0];
   if(!MathIsValidNumber(emaPx) || emaPx <= 0.0)
      return;
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double pipPx = pnt * 10.0;
   if(pipPx <= 0.0)
      return;
   const double pxEps = MathMax(GridPriceTolerance(), pt * 2.0);
   if(MathAbs(basePrice - emaPx) <= pxEps)
      return;

   g_initBaseEmaVirtSnapBase = basePrice;
   g_initBaseEmaVirtSnapEma = emaPx;
   g_initBaseEmaVirtBaseAboveEma = (basePrice > emaPx);
   g_initBaseEmaVirtGapPips = MathAbs(basePrice - emaPx) / pipPx;
   g_initBaseEmaVirtGapActive = true;

   Print("VDualGrid: 2d — chụp vùng Gốc–EMA (mới đặt / đổi gốc) | base=", DoubleToString(g_initBaseEmaVirtSnapBase, dgt),
         " EMA=", DoubleToString(g_initBaseEmaVirtSnapEma, dgt),
         " khoảng=", DoubleToString(g_initBaseEmaVirtGapPips, 1), " pip | ",
         (g_initBaseEmaVirtBaseAboveEma ? "cấm Sell Stop ảo dưới gốc trong [EMA..base] (Limit không cấm)" : "cấm Buy Stop ảo trên gốc trong [base..EMA] (Limit không cấm)"));

   InitBaseEmaVirtGapPurgeVirtualViolations();
}

//+------------------------------------------------------------------+
//| 6c: cân bằng lệnh — đóng phía yếu, điều chỉnh ngưỡng gồng 6b.      |
//+------------------------------------------------------------------+
bool ProcessOrderBalanceMode()
{
   static double s_obAnchorBase = -1.0;

   if(!EnableOrderBalanceMode)
      return false;
   if(basePrice <= 0.0)
   {
      s_obAnchorBase = -1.0;
      OrderBalanceResetSideDwellState();
      return false;
   }
   const double baseTol = MathMax(GridPriceTolerance(), SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 3.0);
   if(s_obAnchorBase < 0.0)
      s_obAnchorBase = basePrice;
   else if(MathAbs(basePrice - s_obAnchorBase) > baseTol)
   {
      OrderBalanceResetSideDwellState();
      s_obAnchorBase = basePrice;
   }

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double baseEps = baseTol;

   if(bid < basePrice - baseEps)
      g_orderBalAboveSideSince = 0;
   else if(bid > basePrice + baseEps)
   {
      if(g_orderBalAboveSideSince == 0)
         g_orderBalAboveSideSince = TimeCurrent();
   }

   if(bid > basePrice + baseEps)
      g_orderBalBelowSideSince = 0;
   else if(bid < basePrice - baseEps)
   {
      if(g_orderBalBelowSideSince == 0)
         g_orderBalBelowSideSince = TimeCurrent();
   }

   if(g_compoundTotalProfitActive || g_compoundAfterClearWaitGrid || g_compoundArmed)
      return false;

   if(OrderBalanceCooldownSeconds > 0 && g_orderBalLastExecTime > 0
      && (TimeCurrent() - g_orderBalLastExecTime) < OrderBalanceCooldownSeconds)
      return false;

   const double stepPx = CompoundModeGridStepPrice();
   if(stepPx <= 0.0)
      return false;

   int minSteps = OrderBalanceMinGridStepsFromBase;
   if(minSteps < 1) minSteps = 1;
   int minMin = OrderBalanceMinMinutesOnSideOfBase;
   if(minMin < 1) minMin = 1;
   const int needSec = minMin * 60;
   const double needDist = (double)minSteps * stepPx;

   int cntAbove = 0;
   int cntBelow = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionIsOurSymbolAndMagic(ticket))
         continue;
      const double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(op > basePrice + baseEps)
         cntAbove++;
      else if(op < basePrice - baseEps)
         cntBelow++;
   }

   const datetime now = TimeCurrent();
   const bool distAboveOk = ((bid - basePrice) >= needDist);
   const bool distBelowOk = ((basePrice - bid) >= needDist);

   // Lọc EMA: N nến đóng gần nhất liên tiếp; +1 → nhánh đóng dưới gốc; −1 → đóng trên gốc.
   // Hai nhánh còn phải đủ Bid X bậc + phút + lệch số lệnh (điều kiện 6c gốc).
   int emaBias = 0;
   bool allowCloseBelowByEma = true;
   bool allowCloseAboveByEma = true;
   if(EnableOrderBalanceEMAFilter)
   {
      if(!OrderBalanceLastClosedVsEma(emaBias))
         return false;
      if(emaBias > 0)
         allowCloseAboveByEma = false;
      else if(emaBias < 0)
         allowCloseBelowByEma = false;
      else
      {
         allowCloseBelowByEma = false;
         allowCloseAboveByEma = false;
      }
   }

   bool wantCloseBelow = false;
   bool wantCloseAbove = false;
   if(allowCloseBelowByEma && distAboveOk && g_orderBalAboveSideSince > 0 && (now - g_orderBalAboveSideSince) >= needSec
      && cntAbove > cntBelow && cntBelow > 0)
      wantCloseBelow = true;
   if(allowCloseAboveByEma && distBelowOk && g_orderBalBelowSideSince > 0 && (now - g_orderBalBelowSideSince) >= needSec
      && cntBelow > cntAbove && cntAbove > 0)
      wantCloseAbove = true;

   if(!wantCloseBelow && !wantCloseAbove)
      return false;

   ulong toClose[];
   ArrayResize(toClose, 0);
   double batchPnL = 0.0;

   if(wantCloseBelow && !wantCloseAbove)
   {
      for(int j = 0; j < PositionsTotal(); j++)
      {
         ulong ticket = PositionGetTicket(j);
         if(ticket <= 0 || !PositionIsOurSymbolAndMagic(ticket))
            continue;
         const double op = PositionGetDouble(POSITION_PRICE_OPEN);
         if(op >= basePrice - baseEps)
            continue;
         batchPnL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         int n = ArraySize(toClose);
         ArrayResize(toClose, n + 1);
         toClose[n] = ticket;
      }
   }
   else if(wantCloseAbove)
   {
      for(int j = 0; j < PositionsTotal(); j++)
      {
         ulong ticket = PositionGetTicket(j);
         if(ticket <= 0 || !PositionIsOurSymbolAndMagic(ticket))
            continue;
         const double op = PositionGetDouble(POSITION_PRICE_OPEN);
         if(op <= basePrice + baseEps)
            continue;
         batchPnL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         int n = ArraySize(toClose);
         ArrayResize(toClose, n + 1);
         toClose[n] = ticket;
      }
   }

   if(ArraySize(toClose) < 1)
      return false;

   trade.SetExpertMagicNumber(MagicAA);
   int closed = 0;
   for(int k = ArraySize(toClose) - 1; k >= 0; k--)
   {
      if(trade.PositionClose(toClose[k]))
         closed++;
   }

   if(closed < 1)
      return false;

   g_balanceCompoundCarryUsd -= batchPnL;
   OrderBalanceResetSideDwellState();
   g_orderBalLastExecTime = TimeCurrent();

   string emaLog = "";
   if(EnableOrderBalanceEMAFilter)
   {
      int nLog = OrderBalanceEMAConfirmBars;
      if(nLog < 1) nLog = 1;
      if(nLog > 50) nLog = 50;
      emaLog = " | EMA " + IntegerToString(nLog) + " nến đóng gần nhất (liên tiếp): " + (emaBias > 0 ? "cả N close>EMA" : (emaBias < 0 ? "cả N close<EMA" : "không đồng nhất"));
   }
   Print("VDualGrid: Cân bằng lệnh (6c) — đóng ", closed, " vị thế ",
         (wantCloseBelow ? "dưới" : "trên"), " gốc | P/L đóng (profit+swap) ", DoubleToString(batchPnL, 2),
         " USD | điều chỉnh ngưỡng gồng Σ mở → ", DoubleToString(GetCompoundFloatingTriggerThresholdUsd(), 2), " USD",
         emaLog);

   ManageGridOrders();
   return true;
}

//+------------------------------------------------------------------+
//| Giá có trùng một mức đã đăng ký trong gridLevels                  |
//+------------------------------------------------------------------+
bool VirtualPriceMatchesRegisteredGrid(double price)
{
   double tol = GridPriceTolerance();
   for(int g = 0; g < ArraySize(gridLevels); g++)
      if(MathAbs(price - gridLevels[g]) < tol)
         return true;
   return false;
}

//+------------------------------------------------------------------+
//| Mức trên thị trường → cắt lên chạm: Buy Stop + Sell Limit.        |
//| Mức dưới thị trường → cắt xuống chạm: Buy Limit + Sell Stop.       |
//| Trong spread → chia theo mid.                                     |
//+------------------------------------------------------------------+
void GetVirtualPairForLevel(double levelPrice, double bid, double ask,
                            ENUM_ORDER_TYPE &buyType, ENUM_ORDER_TYPE &sellType)
{
   double eps = pnt * 2.0;
   if(levelPrice > ask + eps)
   {
      buyType  = ORDER_TYPE_BUY_STOP;
      sellType = ORDER_TYPE_SELL_LIMIT;
   }
   else if(levelPrice < bid - eps)
   {
      buyType  = ORDER_TYPE_BUY_LIMIT;
      sellType = ORDER_TYPE_SELL_STOP;
   }
   else
   {
      double mid = (bid + ask) * 0.5;
      if(levelPrice >= mid)
      {
         buyType  = ORDER_TYPE_BUY_STOP;
         sellType = ORDER_TYPE_SELL_LIMIT;
      }
      else
      {
         buyType  = ORDER_TYPE_BUY_LIMIT;
         sellType = ORDER_TYPE_SELL_STOP;
      }
   }
}

//+------------------------------------------------------------------+
//| Xóa chờ ảo sai loại (khi giá đổi phía so với mức)                 |
//+------------------------------------------------------------------+
void RemoveStaleVirtualTypesAtLevel(double priceLevel, ENUM_ORDER_TYPE wantBuy, ENUM_ORDER_TYPE wantSell, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return;
   double tolerance = GridPriceTolerance();
   for(int i = ArraySize(g_virtualPending) - 1; i >= 0; i--)
   {
      if(g_virtualPending[i].magic != whichMagic) continue;
      if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) >= tolerance) continue;
      ENUM_ORDER_TYPE ot = g_virtualPending[i].orderType;
      bool isBuy = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT);
      if(isBuy)
      {
         if(ot != wantBuy)
            VirtualPendingRemoveAt(i);
      }
      else
      {
         if(ot != wantSell)
            VirtualPendingRemoveAt(i);
      }
   }
}

//+------------------------------------------------------------------+
//| Có vị thế mở đúng magic+symbol tại mức giá và phía Buy/Sell        |
//+------------------------------------------------------------------+
bool OurMagicPositionAtLevelSide(double priceLevel, bool isBuyOrder, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return false;
   double tolerance = GridPriceTolerance();
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != whichMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(posPrice - priceLevel) >= tolerance) continue;
      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((pt == POSITION_TYPE_BUY) == isBuyOrder)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Ghi nhận chờ ảo vừa khớp market — không bổ sung lại chờ ảo cùng phía ngay. |
//+------------------------------------------------------------------+
void VirtualExecCooldownAdd(double priceLevel, bool isBuy)
{
   double p = NormalizeDouble(priceLevel, dgt);
   int n = ArraySize(g_virtualExecCooldown);
   ArrayResize(g_virtualExecCooldown, n + 1);
   g_virtualExecCooldown[n].priceLevel = p;
   g_virtualExecCooldown[n].isBuy = isBuy;
   g_virtualExecCooldown[n].expireUtc = TimeCurrent() + VPGRID_VIRTUAL_EXEC_COOLDOWN_SEC;
}

//+------------------------------------------------------------------+
void VirtualExecCooldownRemoveAt(int idx)
{
   int n = ArraySize(g_virtualExecCooldown);
   if(idx < 0 || idx >= n) return;
   if(n == 1) { ArrayResize(g_virtualExecCooldown, 0); return; }
   g_virtualExecCooldown[idx] = g_virtualExecCooldown[n - 1];
   ArrayResize(g_virtualExecCooldown, n - 1);
}

//+------------------------------------------------------------------+
//| true = chưa bổ sung chờ ảo (đợi vị thế hiện hoặc hết cooldown).    |
//+------------------------------------------------------------------+
bool VirtualReplenishBlockedAfterExecution(double priceLevel, ENUM_ORDER_TYPE orderType, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return false;
   bool isBuyOrder = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
   double tol = GridPriceTolerance();
   datetime now = TimeCurrent();
   double pl = NormalizeDouble(priceLevel, dgt);

   for(int i = ArraySize(g_virtualExecCooldown) - 1; i >= 0; i--)
   {
      if(now > g_virtualExecCooldown[i].expireUtc)
      {
         VirtualExecCooldownRemoveAt(i);
         continue;
      }
      if(MathAbs(g_virtualExecCooldown[i].priceLevel - pl) >= tol) continue;
      if(g_virtualExecCooldown[i].isBuy != isBuyOrder) continue;
      if(OurMagicPositionAtLevelSide(pl, isBuyOrder, whichMagic))
      {
         VirtualExecCooldownRemoveAt(i);
         return false;
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Execute virtual pendings when price touches trigger (same as broker pending) |
//+------------------------------------------------------------------+
void ProcessVirtualPendingExecutions()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tol = pnt * 2.0;
   // Directional trigger uses last tick prices (prevent "wrong direction" fills).
   // Initialize on first call (no triggers on the very first tick).
   if(lastTickBid <= 0.0 || lastTickAsk <= 0.0)
   {
      lastTickBid = bid;
      lastTickAsk = ask;
      return;
   }
   double prevBid = lastTickBid;
   double prevAsk = lastTickAsk;
   for(int i = ArraySize(g_virtualPending) - 1; i >= 0; i--)
   {
      VirtualPendingEntry e = g_virtualPending[i];
      if(!IsOurMagic(e.magic))
      {
         VirtualPendingRemoveAt(i);
         continue;
      }
      // Directional mode by base: only allow Buy above base levels, Sell below base levels.
      // Remove any disallowed virtual entries to prevent accidental execution.
      if(!IsOrderSideAllowedByBase(e.levelNum, e.orderType))
      {
         VirtualPendingRemoveAt(i);
         continue;
      }
      if(basePrice > 0.0 && ArraySize(gridLevels) >= MaxGridLevels + 1)
      {
         if(!VirtualPriceMatchesRegisteredGrid(e.priceLevel))
         {
            VirtualPendingRemoveAt(i);
            continue;
         }
      }
      bool trigger = false;
      // Trên thị trường: Buy Stop — Ask cắt lên; Sell Limit — Bid cắt lên (chuẩn MT5).
      if(e.orderType == ORDER_TYPE_BUY_STOP)
         trigger = (prevAsk < (e.priceLevel - tol) && ask >= (e.priceLevel - tol));
      else if(e.orderType == ORDER_TYPE_SELL_LIMIT)
         trigger = (prevBid < (e.priceLevel - tol) && bid >= (e.priceLevel - tol));
      // Dưới gốc (-1): Sell Stop — Bid cắt từ trên xuống.
      else if(e.orderType == ORDER_TYPE_SELL_STOP)
         trigger = (prevBid > (e.priceLevel + tol) && bid <= (e.priceLevel + tol));
      // Dưới gốc (-1): Buy Limit — Ask cắt từ trên xuống.
      else if(e.orderType == ORDER_TYPE_BUY_LIMIT)
         trigger = (prevAsk > (e.priceLevel + tol) && ask <= (e.priceLevel + tol));
      else
         continue;
      if(!trigger) continue;

      trade.SetExpertMagicNumber(e.magic);
      string cmt = BuildOrderCommentWithLevel(e.levelNum);
      bool ok = false;
      double sl = 0.0;
      double tp = e.tpPrice;
      if(e.orderType == ORDER_TYPE_BUY_STOP || e.orderType == ORDER_TYPE_BUY_LIMIT)
         ok = trade.Buy(e.lot, _Symbol, 0.0, sl, tp, cmt);
      else
         ok = trade.Sell(e.lot, _Symbol, 0.0, sl, tp, cmt);
      if(ok)
      {
         Print("VDualGrid -> market: ", EnumToString(e.orderType), " magic ", e.magic, " lot ", e.lot, " at level ", e.priceLevel, " (", cmt, ")");
         VirtualExecCooldownAdd(e.priceLevel, (e.orderType == ORDER_TYPE_BUY_STOP || e.orderType == ORDER_TYPE_BUY_LIMIT));
      }
      else
         Print("VDualGrid execute fail: ", EnumToString(e.orderType), " err ", GetLastError());
      VirtualPendingRemoveAt(i);
   }
   trade.SetExpertMagicNumber(MagicAA);
   // Update last tick prices after processing triggers.
   lastTickBid = bid;
   lastTickAsk = ask;
}

//+------------------------------------------------------------------+
//| Position P/L = profit + swap (overnight fee). Commission only when position closed (in DEAL). |
//+------------------------------------------------------------------+
double GetPositionPnL(ulong ticket)
{
   if(!PositionIsOurSymbolAndMagic(ticket)) return 0.0;
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
}

//+------------------------------------------------------------------+
//| Tổng float (profit+swap) mọi vị thế mở đúng magic + symbol.      |
//+------------------------------------------------------------------+
double GetOurMagicFloatingUSD()
{
   double f = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC)) || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      f += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return f;
}

//+------------------------------------------------------------------+
//| "Vốn giao dịch" quan sát được: số dư lúc gắn EA + P/L đóng lệnh   |
//| (deal OUT) + float — không chứa hiệu ứng nạp/rút sau attach.       |
//+------------------------------------------------------------------+
double GetTradingEquityViewUSD()
{
   return attachBalance + eaCumulativeTradingPL + GetOurMagicFloatingUSD();
}

//+------------------------------------------------------------------+
//| Mốc cho % P/L và mult: TEV tại khởi động EA (đóng+treo tại thời điểm đó). |
//| Khác số dư ledger nếu có treo — mult=1 khi TEV hiện tại = mốc. Reset phiên không làm mới mốc. |
//+------------------------------------------------------------------+
double GetScaleCapitalReferenceUSD()
{
   if(initialCapitalBaselineUSD > 0.0)
      return initialCapitalBaselineUSD;
   if(attachBalance > 0.0)
      return attachBalance;
   return 0.0;
}

//+------------------------------------------------------------------+
//| % thay đổi TEV so với mốc khởi động (không tính nạp/rút vào mốc).   |
//+------------------------------------------------------------------+
double GetTradingEquityViewPctVsScaleBaseline()
{
   const double r0 = GetScaleCapitalReferenceUSD();
   if(r0 <= 0.0)
      return 0.0;
   return (GetTradingEquityViewUSD() / r0 - 1.0) * 100.0;
}

//+------------------------------------------------------------------+
//| X% dùng thực tế: clamp [0, 100] (input > 100 không có hiệu lực thêm). |
//+------------------------------------------------------------------+
double CapitalGainScalePercentEffective()
{
   double x = CapitalGainScalePercent;
   if(x < 0.0) x = 0.0;
   if(x > 100.0) x = 100.0;
   return x;
}

//+------------------------------------------------------------------+
//| Trần % tăng tối đa: clamp [0, 1e6] (mult không vượt 1 + value/100). |
//+------------------------------------------------------------------+
double CapitalScaleMaxBoostPercentEffective()
{
   double m = CapitalScaleMaxBoostPercent;
   if(m < 0.0) m = 0.0;
   if(m > 1000000.0) m = 1000000.0;
   return m;
}

//+------------------------------------------------------------------+
//| Gốc R0 = GetScaleCapitalReferenceUSD() (TEV lúc khởi động EA; không đổi khi reset phiên). |
//| C = GetTradingEquityViewUSD (ledger gốc + P/L đóng + float magic; không cộng nạp/rút). |
//| mult = 1 + (C/R0 - 1) * (X/100), rồi min(..., 1 + trần%/100).     |
//+------------------------------------------------------------------+
double GetCapitalScaleMultiplier()
{
   if(!EnableCapitalBasedScaling)
      return 1.0;
   double xEff = CapitalGainScalePercentEffective();
   const double r0 = GetScaleCapitalReferenceUSD();
   if(r0 <= 0.0 || xEff <= 0.0)
      return 1.0;
   double C = GetTradingEquityViewUSD();
   if(C <= 0.0)
      return 1.0;
   double mult = 1.0 + (C / r0 - 1.0) * (xEff / 100.0);
   double multCap = 1.0 + CapitalScaleMaxBoostPercentEffective() / 100.0;
   if(multCap < 0.01)
      multCap = 0.01;
   if(mult > multCap)
      mult = multCap;
   if(mult < 0.01)
      mult = 0.01;
   return mult;
}

//+------------------------------------------------------------------+
//| Ngưỡng reset phiên: gốc input × mult khi bật scale vốn + ScaleSessionProfitTargetsWithCapital. |
//+------------------------------------------------------------------+
double GetSessionProfitTargetUSDEffective()
{
   if(SessionProfitTargetUSD <= 0.0)
      return 0.0;
   double t = SessionProfitTargetUSD;
   if(t < 0.01)
      t = 0.01;
   if(EnableCapitalBasedScaling && ScaleSessionProfitTargetsWithCapital)
      t *= GetCapitalScaleMultiplier();
   if(t < 0.01)
      t = 0.01;
   return t;
}

double GetSessionProfitTargetOpenOnlyUSDEffective()
{
   double t = SessionProfitTargetOpenOnlyUSD;
   if(t <= 0.0)
      return 0.0;
   if(t < 0.01)
      t = 0.01;
   if(EnableCapitalBasedScaling && ScaleSessionProfitTargetsWithCapital)
      t *= GetCapitalScaleMultiplier();
   if(t < 0.01)
      t = 0.01;
   return t;
}

double GetSessionProfitTargetClosedTpSlOpenUSDEffective()
{
   double t = SessionProfitTargetClosedTP_SL_OpenUSD;
   if(t <= 0.0)
      return 0.0;
   if(t < 0.01)
      t = 0.01;
   if(EnableCapitalBasedScaling && ScaleSessionProfitTargetsWithCapital)
      t *= GetCapitalScaleMultiplier();
   if(t < 0.01)
      t = 0.01;
   return t;
}

//+------------------------------------------------------------------+
//| Ngưỡng lỗ tối đa phiên (USD dương): so với -(ngưỡng hiệu lực).    |
//+------------------------------------------------------------------+
double GetSessionMaxLossUSDEffective()
{
   double t = SessionMaxLossUSD;
   if(t <= 0.0)
      return 0.0;
   if(t < 0.01)
      t = 0.01;
   if(EnableCapitalBasedScaling && ScaleSessionProfitTargetsWithCapital)
      t *= GetCapitalScaleMultiplier();
   if(t < 0.01)
      t = 0.01;
   return t;
}

bool SessionOpenLotsMatchesRequired(const double requiredLots, const double openLots)
{
   if(requiredLots <= 0.0)
      return true; // condition disabled
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   double tol = step * 0.5;
   return (MathAbs(openLots - requiredLots) <= tol);
}

//+------------------------------------------------------------------+
//| Khung giờ chạy (theo giờ server MT5).                             |
//| - Nếu start == end: coi như chạy 24h.                            |
//| - Hỗ trợ qua đêm (vd 22:00 -> 06:00).                             |
//+------------------------------------------------------------------+
int ClampHour(const int h)
{
   if(h < 0)  return 0;
   if(h > 23) return 23;
   return h;
}

int ClampMinute(const int m)
{
   if(m < 0)  return 0;
   if(m > 59) return 59;
   return m;
}

int MinuteOfDayServer(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour * 60 + dt.min;
}

bool IsNowWithinRunWindow(const datetime nowSrv)
{
   if(!EnableRunTimeWindow)
      return true;
   int sh = ClampHour(RunStartHour);
   int sm = ClampMinute(RunStartMinute);
   int eh = ClampHour(RunEndHour);
   int em = ClampMinute(RunEndMinute);

   int startMin = sh * 60 + sm;
   int endMin   = eh * 60 + em;
   int nowMin   = MinuteOfDayServer(nowSrv);

   if(startMin == endMin)
      return true; // chạy cả ngày
   if(startMin < endMin)
      return (nowMin >= startMin && nowMin < endMin);
   return (nowMin >= startMin || nowMin < endMin); // khung qua đêm
}

//+------------------------------------------------------------------+
//| Có ít nhất một ngày được chọn (khi bật lọc ngày).                 |
//+------------------------------------------------------------------+
bool RunDayFilterAnyDaySelected()
{
   return RunOnMonday || RunOnTuesday || RunOnWednesday || RunOnThursday
       || RunOnFriday || RunOnSaturday || RunOnSunday;
}

//+------------------------------------------------------------------+
//| Ngày server hiện tại có nằm trong các ngày được bật không.         |
//| Tắt lọc / không chọn ngày nào → luôn true (không khóa).            |
//+------------------------------------------------------------------+
bool IsRunDayAllowedNow(const datetime nowSrv)
{
   if(!EnableRunDayFilter)
      return true;
   if(!RunDayFilterAnyDaySelected())
      return true;
   MqlDateTime dt;
   TimeToStruct(nowSrv, dt);
   switch(dt.day_of_week)
   {
   case 0: return RunOnSunday;
   case 1: return RunOnMonday;
   case 2: return RunOnTuesday;
   case 3: return RunOnWednesday;
   case 4: return RunOnThursday;
   case 5: return RunOnFriday;
   case 6: return RunOnSaturday;
   default:
      return true;
   }
}

//+------------------------------------------------------------------+
//| Cho phép khởi động phiên mới từ trạng thái chờ (giờ + ngày).      |
//| Không dùng để ngắt lưới đang chạy (basePrice>0): phiên đó chạy    |
//| đến khi reset; sau reset nếu trùng ngày/giờ cấm → EA chờ.         |
//+------------------------------------------------------------------+
bool IsSchedulingAllowedForNewSession(const datetime nowSrv)
{
   if(EnableRunTimeWindow && !IsNowWithinRunWindow(nowSrv))
      return false;
   if(!IsRunDayAllowedNow(nowSrv))
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| RSI hiện tại: RSIZoneLow < RSI < RSIZoneHigh (bộ đệm nến hiện tại). |
//+------------------------------------------------------------------+
bool IsRSIInStartZoneNow()
{
   if(g_rsiHandle == INVALID_HANDLE)
      return false;
   const int rsiP = MathMax(2, RSIPeriod);
   int need = rsiP + 2;
   if(BarsCalculated(g_rsiHandle) < need)
      return false;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_rsiHandle, 0, 0, 1, buf) < 1)
      return false;
   double r = buf[0];
   if(!MathIsValidNumber(r))
      return false;
   double lo = RSIZoneLow;
   double hi = RSIZoneHigh;
   if(lo >= hi)
   {
      double t = lo;
      lo = hi;
      hi = t;
   }
   return (r > lo && r < hi);
}

//+------------------------------------------------------------------+
//| Xóa latch RSI — cùng chu kỳ với latch EMA.                         |
//+------------------------------------------------------------------+
void ResetRSIGridStartLatch()
{
   g_rsiInZonePrevTick = false;
   g_rsiLatchActive = false;
   g_rsiLatchBid = 0.0;
   g_rsiLastBarOpenForLatch = 0;
}

//+------------------------------------------------------------------+
//| Cập nhật latch RSI khi chưa có gốc: lần đầu vào vùng / nến → khóa Bid. |
//+------------------------------------------------------------------+
void UpdateRSIGridStartLatchWhileWaiting()
{
   if(!EnableRSIFilterForGridStart || g_rsiHandle == INVALID_HANDLE)
      return;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, RSITimeframe, 0, 1, rates) < 1)
      return;
   const datetime barOpen = rates[0].time;
   if(g_rsiLastBarOpenForLatch != barOpen)
   {
      if(g_rsiLastBarOpenForLatch != 0)
      {
         g_rsiLatchActive = false;
         g_rsiLatchBid = 0.0;
         g_rsiInZonePrevTick = false;
      }
      g_rsiLastBarOpenForLatch = barOpen;
   }
   bool inZoneNow = IsRSIInStartZoneNow();
   if(inZoneNow && !g_rsiInZonePrevTick && !g_rsiLatchActive)
   {
      g_rsiLatchActive = true;
      g_rsiLatchBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   g_rsiInZonePrevTick = inZoneNow;
}

//+------------------------------------------------------------------+
//| EMA: nến hiện tại (EMATimeframe) — Bid đã qua EMA so với open (đang cắt). |
//+------------------------------------------------------------------+
bool EMACurrentBarCrossingBidVsOpen()
{
   if(g_emaHandle == INVALID_HANDLE)
      return false;
   const int emaP = MathMax(1, EMAPeriod);
   if(BarsCalculated(g_emaHandle) < emaP + 2)
      return false;
   double emaBuf[];
   ArraySetAsSeries(emaBuf, true);
   if(CopyBuffer(g_emaHandle, 0, 0, 1, emaBuf) < 1)
      return false;
   double ema = emaBuf[0];
   if(!MathIsValidNumber(ema))
      return false;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, EMATimeframe, 0, 1, rates) < 1)
      return false;
   double op = rates[0].open;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double eps = MathMax(pnt * 3.0, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE));
   if(op < ema - eps && bid > ema + eps)
      return true;
   if(op > ema + eps && bid < ema - eps)
      return true;
   if(MathAbs(op - ema) <= eps && rates[0].low < ema - eps && rates[0].high > ema + eps)
   {
      if(bid > ema + eps || bid < ema - eps)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Xóa latch EMA — chu kỳ chờ gốc mới (gắn EA / vào khung giờ / reset phiên). |
//+------------------------------------------------------------------+
void ResetEMAGridStartLatch()
{
   g_emaCrossPrevTick = false;
   g_emaLatchActive = false;
   g_emaLatchBid = 0.0;
   g_emaLastBarOpenForLatch = 0;
}

//+------------------------------------------------------------------+
//| Khi chưa có gốc: tick cạnh lên “bắt đầu cắt” → khóa Bid một lần / nến; cắt lại không đổi khóa. |
//+------------------------------------------------------------------+
void UpdateEMAGridStartLatchWhileWaiting()
{
   if(!EnableEMAFilterForGridStart || g_emaHandle == INVALID_HANDLE)
      return;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, EMATimeframe, 0, 1, rates) < 1)
      return;
   const datetime barOpen = rates[0].time;
   if(g_emaLastBarOpenForLatch != barOpen)
   {
      if(g_emaLastBarOpenForLatch != 0)
      {
         g_emaLatchActive = false;
         g_emaLatchBid = 0.0;
         g_emaCrossPrevTick = false;
      }
      g_emaLastBarOpenForLatch = barOpen;
   }
   bool crossNow = EMACurrentBarCrossingBidVsOpen();
   if(crossNow && !g_emaCrossPrevTick && !g_emaLatchActive)
   {
      g_emaLatchActive = true;
      g_emaLatchBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
   g_emaCrossPrevTick = crossNow;
}

//+------------------------------------------------------------------+
void ResetAllGridStartLatches()
{
   ResetEMAGridStartLatch();
   ResetRSIGridStartLatch();
}

//+------------------------------------------------------------------+
void UpdateAllGridStartLatchesWhileWaiting()
{
   UpdateEMAGridStartLatchWhileWaiting();
   UpdateRSIGridStartLatchWhileWaiting();
}

//+------------------------------------------------------------------+
//| ADX: có ít nhất một ngưỡng (dưới hoặc trên) được bật.             |
//+------------------------------------------------------------------+
bool ADXStartGateUsesThresholds()
{
   return (ADXMinForGridStart > 0.0 || ADXMaxForGridStart > 0.0);
}

//+------------------------------------------------------------------+
//| Điều kiện ADX đường chính (buffer 0): ADX > min và ADX < max      |
//| (mỗi chiều 0 = không kiểm tra). Chỉ khi chưa có basePrice.         |
//+------------------------------------------------------------------+
bool IsADXGridStartConditionOk()
{
   if(!EnableADXFilterForGridStart)
      return true;
   if(!ADXStartGateUsesThresholds())
      return true;
   if(ADXMinForGridStart > 0.0 && ADXMaxForGridStart > 0.0 && ADXMinForGridStart >= ADXMaxForGridStart)
      return false;
   if(g_adxHandle == INVALID_HANDLE)
      return false;
   const int ap = MathMax(1, ADXPeriodForGridStart);
   if(BarsCalculated(g_adxHandle) < ap + 2)
      return false;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_adxHandle, 0, 0, 1, buf) < 1)
      return false;
   const double adx = buf[0];
   if(!MathIsValidNumber(adx) || adx < 0.0)
      return false;
   const double eps = 1e-6;
   if(ADXMinForGridStart > 0.0 && adx <= ADXMinForGridStart + eps)
      return false;
   if(ADXMaxForGridStart > 0.0 && adx >= ADXMaxForGridStart - eps)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Giá đặt gốc: ưu tiên Bid khóa lúc cắt EMA lần đầu, rồi Bid khóa lúc RSI vào vùng lần đầu. |
//+------------------------------------------------------------------+
double GridBasePriceAtPlacement()
{
   if(EnableEMAFilterForGridStart && g_emaLatchActive && g_emaLatchBid > 0.0 && MathIsValidNumber(g_emaLatchBid))
      return NormalizeDouble(g_emaLatchBid, dgt);
   if(EnableRSIFilterForGridStart && g_rsiLatchActive && g_rsiLatchBid > 0.0 && MathIsValidNumber(g_rsiLatchBid))
      return NormalizeDouble(g_rsiLatchBid, dgt);
   return SymbolInfoDouble(_Symbol, SYMBOL_BID);
}

//+------------------------------------------------------------------+
//| Đủ điều kiện đặt gốc lần đầu (chỉ khi basePrice==0).                |
//| Logic AND: khung giờ + (nếu bật RSI) latch RSI + (nếu bật EMA) latch EMA |
//| + (nếu bật ADX có ngưỡng) ADX > min và ADX < max — tất cả phải true cùng tick. |
//+------------------------------------------------------------------+
bool GridStartTimeAndRSIOk(const datetime nowSrv)
{
   if(!IsNowWithinRunWindow(nowSrv))
      return false;
   if(EnableRSIFilterForGridStart)
   {
      if(!g_rsiLatchActive || g_rsiLatchBid <= 0.0)
         return false;
   }
   if(EnableEMAFilterForGridStart)
   {
      if(!g_emaLatchActive || g_emaLatchBid <= 0.0)
         return false;
   }
   if(!IsADXGridStartConditionOk())
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   eaAttachTime = TimeCurrent();
   MagicAA = MagicNumber;
   trade.SetExpertMagicNumber(MagicAA);
   if(TotalProfitStopUSD > 0.0 && GlobalVariableCheck(VDualGridTotalStopGvKey()))
   {
      Print("VDualGrid: đã dừng trước đó (TP tổng). Xóa Global Variable \"", VDualGridTotalStopGvKey(), "\" (Tools → Global Variables) để gắn EA lại.");
      return(INIT_FAILED);
   }
   dgt = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pnt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_rsiHandle = INVALID_HANDLE;
   if(EnableRSIFilterForGridStart)
   {
      const int rsiP = MathMax(2, RSIPeriod);
      g_rsiHandle = iRSI(_Symbol, RSITimeframe, rsiP, PRICE_CLOSE);
      if(g_rsiHandle == INVALID_HANDLE)
         Print("VDualGrid: iRSI không khởi tạo được — không đặt gốc lưới khi bật lọc RSI.");
   }
   g_emaHandle = INVALID_HANDLE;
   if(EnableEMAFilterForGridStart)
   {
      const int emaP = MathMax(1, EMAPeriod);
      g_emaHandle = iMA(_Symbol, EMATimeframe, emaP, 0, MODE_EMA, PRICE_CLOSE);
      if(g_emaHandle == INVALID_HANDLE)
         Print("VDualGrid: iMA EMA không khởi tạo được — không đặt gốc lưới khi bật lọc EMA.");
   }
   g_orderBalanceEmaHandle = INVALID_HANDLE;
   if(EnableOrderBalanceEMAFilter)
   {
      ENUM_TIMEFRAMES obTf = OrderBalanceEMATimeframe;
      if(obTf == PERIOD_CURRENT)
         obTf = (ENUM_TIMEFRAMES)_Period;
      const int obP = MathMax(1, OrderBalanceEMAPeriod);
      g_orderBalanceEmaHandle = iMA(_Symbol, obTf, obP, 0, MODE_EMA, PRICE_CLOSE);
      if(g_orderBalanceEmaHandle == INVALID_HANDLE)
         Print("VDualGrid: 6c — không tạo iMA cho lọc EMA cân bằng lệnh.");
   }
   g_initBaseEmaVirtGapHandle = INVALID_HANDLE;
   if(EnableInitBaseEmaVirtGapBlock)
   {
      ENUM_TIMEFRAMES igTf = InitBaseEmaVirtGapEMATimeframe;
      if(igTf == PERIOD_CURRENT)
         igTf = (ENUM_TIMEFRAMES)_Period;
      const int igP = MathMax(1, InitBaseEmaVirtGapEMAPeriod);
      g_initBaseEmaVirtGapHandle = iMA(_Symbol, igTf, igP, 0, MODE_EMA, PRICE_CLOSE);
      if(g_initBaseEmaVirtGapHandle == INVALID_HANDLE)
         Print("VDualGrid: 2d — không tạo iMA (vùng cấm chờ ảo Gốc–EMA).");
   }
   g_adxHandle = INVALID_HANDLE;
   if(EnableADXFilterForGridStart)
   {
      const int ap = MathMax(1, ADXPeriodForGridStart);
      g_adxHandle = iADX(_Symbol, ADXTimeframeForGridStart, ap);
      if(g_adxHandle == INVALID_HANDLE)
         Print("VDualGrid: iADX không khởi tạo được — không đặt gốc lưới khi bật lọc ADX.");
      else if(!ADXStartGateUsesThresholds())
         Print("VDualGrid: lọc ADX bật — đặt ADXMinForGridStart > 0 hoặc ADXMaxForGridStart > 0 để có ngưỡng (hiện không áp cổng ADX).");
      else if(ADXMinForGridStart > 0.0 && ADXMaxForGridStart > 0.0 && ADXMinForGridStart >= ADXMaxForGridStart)
         Print("VDualGrid: ADXMinForGridStart phải < ADXMaxForGridStart khi cả hai > 0 — vùng ADX không hợp lệ.");
   }
   ResetAllGridStartLatches();
   basePrice = 0.0;
   lastTickBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   lastTickAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   eaCumulativeTradingPL = 0.0;
   sessionClosedProfit = 0.0;
   sessionClosedProfitTpSl = 0.0;
   lastResetTime = 0;

   // Gốc % P/L & TEV: chỉ snapshot một lần — nạp/rút sau đó không cập nhật biến này
   attachBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double tevInit = GetTradingEquityViewUSD();
   initialCapitalBaselineUSD = tevInit;
   if(initialCapitalBaselineUSD <= 0.0)
      initialCapitalBaselineUSD = attachBalance;
   sessionPeakTradingEquityView = tevInit;
   sessionMinTradingEquityView = tevInit;
   globalPeakTradingEquityView = tevInit;
   globalMinTradingEquityView = tevInit;
   sessionMaxSingleLot = 0.0;
   sessionTotalLotAtMaxLot = 0.0;
   g_accumResetSessionPL = 0.0;
   CompoundModeClearState();
   InitBaseEmaVirtGapClearZone();

   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(EnableRunDayFilter && !RunDayFilterAnyDaySelected())
      Print("VDualGrid: lọc ngày bật nhưng chưa chọn ngày nào — coi như không khóa theo ngày.");
   if(g_runtimeSessionActive)
   {
      UpdateAllGridStartLatchesWhileWaiting();
      if(GridStartTimeAndRSIOk(TimeCurrent()))
      {
         basePrice = GridBasePriceAtPlacement();
         InitializeGridLevels();
         ResetAllGridStartLatches();
         if(EnableResetNotification)
            SendResetNotification("EA đã khởi động");
      }
      else
      {
         basePrice = 0.0;
         VirtualPendingClear();
         ArrayResize(gridLevels, 0);
         sessionStartTime = 0;
         if(EnableRSIFilterForGridStart || EnableEMAFilterForGridStart || EnableADXFilterForGridStart)
         {
            string msg = "VDualGrid: chờ điều kiện đặt gốc";
            if(EnableRSIFilterForGridStart)
               msg += " — RSI lần đầu vào vùng (" + DoubleToString(RSIZoneLow, 1) + " < RSI < " + DoubleToString(RSIZoneHigh, 1) + ", khóa Bid)";
            if(EnableEMAFilterForGridStart)
               msg += (EnableRSIFilterForGridStart ? " và " : " — ") + "lần đầu cắt EMA trên nến (khóa Bid)";
            if(EnableADXFilterForGridStart && ADXStartGateUsesThresholds())
            {
               msg += (EnableRSIFilterForGridStart || EnableEMAFilterForGridStart ? " và " : " — ");
               msg += "ADX (" + EnumToString(ADXTimeframeForGridStart) + " p=" + IntegerToString(MathMax(1, ADXPeriodForGridStart)) + ")";
               if(ADXMinForGridStart > 0.0)
                  msg += " > " + DoubleToString(ADXMinForGridStart, 1);
               if(ADXMinForGridStart > 0.0 && ADXMaxForGridStart > 0.0)
                  msg += " và";
               if(ADXMaxForGridStart > 0.0)
                  msg += " < " + DoubleToString(ADXMaxForGridStart, 1);
            }
            msg += ".";
            Print(msg);
         }
      }
   }
   else
   {
      VirtualPendingClear();
      ArrayResize(gridLevels, 0);
      sessionStartTime = 0;
      Print("VDualGrid: ngoài lịch chạy (khung giờ và/hoặc ngày server) — EA tạm chờ. Khi đủ điều kiện sẽ tự khởi động phiên mới.");
   }
   Print("========================================");
   Print("VDualGrid đã chạy. Lãi phiên: 0 USD (từ đây: mở + đã đóng trong phiên)");
   Print("Symbol: ", _Symbol, " | Base: ", basePrice, " | Grid: ", GridDistancePips, " pips | Levels: ", ArraySize(gridLevels));
   Print("Chờ ảo: mỗi bậc lưới 1 Buy+1 Sell (Stop/Limit theo vị trí giá) | mức=", ArraySize(gridLevels), " | lot L1=", GetLotForLevel(ORDER_TYPE_BUY_STOP, 1));
   Print("VDualGrid: nạp/rút broker không đổi cấu hình EA — lưới/lot/mục tiêu theo input + P/L giao dịch (TEV), không theo số dư ledger.");
   if(EnableRunTimeWindow || EnableRunDayFilter)
   {
      string st = "ĐANG CHỜ LỊCH CHẠY";
      if(g_runtimeSessionActive)
         st = (basePrice > 0.0 ? "ĐANG CHẠY LƯỚI" : "TRONG LỊCH — CHỜ ĐẶT GỐC (RSI/EMA/ADX nếu bật)");
      if(EnableRunTimeWindow)
         Print("Khung giờ (server): ", IntegerToString(ClampHour(RunStartHour)), ":", StringFormat("%02d", ClampMinute(RunStartMinute)),
               " -> ", IntegerToString(ClampHour(RunEndHour)), ":", StringFormat("%02d", ClampMinute(RunEndMinute)));
      if(EnableRunDayFilter)
      {
         string days = "T2:" + (RunOnMonday ? "ON" : "off") + " T3:" + (RunOnTuesday ? "ON" : "off")
            + " T4:" + (RunOnWednesday ? "ON" : "off") + " T5:" + (RunOnThursday ? "ON" : "off")
            + " T6:" + (RunOnFriday ? "ON" : "off") + " T7:" + (RunOnSaturday ? "ON" : "off")
            + " CN:" + (RunOnSunday ? "ON" : "off");
         Print("Ngày chạy (server): ", days);
         Print("Quy ước: đang có lưới (base) thì sang ngày tắt vẫn chạy; sau reset phiên nếu trùng ngày/giờ cấm thì EA chờ, không mở lưới mới.");
      }
      Print("Lịch chạy — trạng thái hiện tại: ", st);
   }
   else if((EnableRSIFilterForGridStart || EnableEMAFilterForGridStart || EnableADXFilterForGridStart) && g_runtimeSessionActive && basePrice <= 0.0)
   {
      string w = "VDualGrid: lọc đặt gốc bật — chưa đặt gốc";
      if(EnableRSIFilterForGridStart)
         w += " | RSI chờ lần đầu vào vùng " + DoubleToString(RSIZoneLow, 1) + " < RSI < " + DoubleToString(RSIZoneHigh, 1);
      if(EnableEMAFilterForGridStart)
         w += " | EMA chờ lần cắt đầu trên nến để khóa giá gốc";
      if(EnableADXFilterForGridStart && ADXStartGateUsesThresholds())
         w += " | ADX chờ trong vùng (min/max theo input)";
      Print(w + ".");
   }
   if(EnableRSIFilterForGridStart)
      Print("Lọc RSI đặt gốc: BẬT | TF=", EnumToString(RSITimeframe), " period=", MathMax(2, RSIPeriod),
            " | vùng (", DoubleToString(RSIZoneLow, 1), ",", DoubleToString(RSIZoneHigh, 1), ") — lần đầu vào vùng trên nến khóa Bid; ra vào lại không đổi khóa.");
   if(EnableEMAFilterForGridStart)
      Print("Lọc EMA đặt gốc: BẬT | TF=", EnumToString(EMATimeframe), " period=", MathMax(1, EMAPeriod),
            " — lần đầu cắt EMA trên nến: khóa Bid làm gốc; cắt lại (cùng phiên) không đổi gốc; nến mới chưa có gốc thì chờ cắt lần đầu mới.");
   if(EnableADXFilterForGridStart)
   {
      if(ADXStartGateUsesThresholds())
         Print("Lọc ADX đặt gốc: BẬT | TF=", EnumToString(ADXTimeframeForGridStart), " period=", MathMax(1, ADXPeriodForGridStart),
               " | ADX đường chính: > ", DoubleToString(ADXMinForGridStart, 1), " (0=tắt); < ", DoubleToString(ADXMaxForGridStart, 1),
               " (0=tắt) — chỉ khi chưa có gốc; đã chạy lưới thì không đổi đường gốc.");
      else
         Print("Lọc ADX đặt gốc: BẬT nhưng chưa có ngưỡng — đặt ADXMin hoặc ADXMax > 0 để kích hoạt cổng ADX.");
   }
   {
      int activeGates = 0;
      if(EnableRSIFilterForGridStart)
         activeGates++;
      if(EnableEMAFilterForGridStart)
         activeGates++;
      if(EnableADXFilterForGridStart && ADXStartGateUsesThresholds())
         activeGates++;
      if(activeGates >= 2)
         Print("VDualGrid: Đặt gốc — logic AND: phải thỏa đồng thời cả ", activeGates, " lọc đang bật (RSI latch + EMA latch + ADX — chỉ những mục input đã bật).");
   }
   if(EnableCapitalBasedScaling)
   {
      double xEff = CapitalGainScalePercentEffective();
      double maxB = CapitalScaleMaxBoostPercentEffective();
      Print("Scale vốn: BẬT | mult=", DoubleToString(GetCapitalScaleMultiplier(), 4), " | TEV=", DoubleToString(GetTradingEquityViewUSD(), 2), " USD | mốc TEV khởi động=", DoubleToString(GetScaleCapitalReferenceUSD(), 2), " (số dư ledger lúc gắn=", DoubleToString(attachBalance, 2), ") | X%=", DoubleToString(xEff, 1), " trần%=", DoubleToString(maxB, 1));
      Print("Áp mult: lot L1 + bước Add (cấp số cộng)", (ScaleSessionProfitTargetsWithCapital ? " + ngưỡng USD nhóm 6 (reset phiên)" : ""), ".");
      Print("Ngưỡng phiên hiệu lực (USD): legacy TP+Open=", DoubleToString(GetSessionProfitTargetUSDEffective(), 2),
            " | OpenOnly=", DoubleToString(GetSessionProfitTargetOpenOnlyUSDEffective(), 2),
            " | TP+SL+Open=", DoubleToString(GetSessionProfitTargetClosedTpSlOpenUSDEffective(), 2),
            (EnableSessionMaxLossReset ? " | Lỗ tối đa phiên=" + DoubleToString(GetSessionMaxLossUSDEffective(), 2) : ""),
            (ScaleSessionProfitTargetsWithCapital ? " (đã ×mult)" : " (gốc input, không ×mult)"));
      if(CapitalGainScalePercent > 100.0)
         Print("VDualGrid: CapitalGainScalePercent > 100 → dùng 100.");
      if(CapitalScaleMaxBoostPercent < 0.0 || CapitalScaleMaxBoostPercent > 1000000.0)
         Print("VDualGrid: CapitalScaleMaxBoostPercent ngoài [0, 1e6] → clamp.");
   }
   if(EnableSessionMaxLossReset && SessionMaxLossUSD > 0.0)
      Print("VDualGrid: reset khi lỗ phiên — (P/L đóng TP+SL trong phiên + treo) <= -", DoubleToString(GetSessionMaxLossUSDEffective(), 2),
            " USD; không cộng dồn TP tổng (nhóm 7).");
   Print("========================================");
   if(g_runtimeSessionActive)
      ManageGridOrders();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_rsiHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_rsiHandle);
      g_rsiHandle = INVALID_HANDLE;
   }
   if(g_emaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_emaHandle);
      g_emaHandle = INVALID_HANDLE;
   }
   if(g_orderBalanceEmaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_orderBalanceEmaHandle);
      g_orderBalanceEmaHandle = INVALID_HANDLE;
   }
   if(g_initBaseEmaVirtGapHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_initBaseEmaVirtGapHandle);
      g_initBaseEmaVirtGapHandle = INVALID_HANDLE;
   }
   if(g_adxHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_adxHandle);
      g_adxHandle = INVALID_HANDLE;
   }
   // Gỡ object chart từ bản EA cũ (tên cố định)
   ObjectDelete(0, "VPGrid_BaseLine");
   ObjectDelete(0, "VPGrid_PoolGateAbove");
   ObjectDelete(0, "VPGrid_PoolGateBelow");
   ObjectDelete(0, "VPGrid_PoolGateZone");
   if(EnableResetNotification)
   {
      UpdateSessionStatsForNotification();
      SendResetNotification("EA đã dừng (mã lý do: " + IntegerToString(reason) + ")");
   }
   Print("VDualGrid đã dừng. Mã lý do: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Đang chờ lịch (giờ/ngày server): chỉ bật phiên mới khi IsSchedulingAllowedForNewSession.
   if(!g_runtimeSessionActive)
   {
      if(IsSchedulingAllowedForNewSession(TimeCurrent()))
      {
         g_runtimeSessionActive = true;
         sessionClosedProfit = 0.0;
         sessionClosedProfitTpSl = 0.0;
         ResetAllGridStartLatches();
         UpdateAllGridStartLatchesWhileWaiting();
         if(GridStartTimeAndRSIOk(TimeCurrent()))
         {
            basePrice = GridBasePriceAtPlacement();
            InitializeGridLevels();
            ResetAllGridStartLatches();
            Print("VDualGrid: vào lịch chạy — khởi động phiên mới, base=", DoubleToString(basePrice, dgt));
            if(EnableResetNotification)
               SendResetNotification("Vào lịch chạy — EA khởi động phiên mới");
            ManageGridOrders();
         }
         else
         {
            basePrice = 0.0;
            VirtualPendingClear();
            ArrayResize(gridLevels, 0);
            sessionStartTime = 0;
            Print("VDualGrid: vào lịch chạy — chờ điều kiện đặt gốc (RSI/EMA/ADX nếu bật).");
         }
      }
      return;
   }

   const int expectedGridLevelCount = MaxGridLevels * 2;

   // Chưa có đường gốc: lần đầu thỏa khung giờ + latch → đặt gốc một lần rồi khởi tạo lưới.
   if(g_runtimeSessionActive && basePrice <= 0.0)
   {
      UpdateAllGridStartLatchesWhileWaiting();
      if(!GridStartTimeAndRSIOk(TimeCurrent()))
         return;
      basePrice = GridBasePriceAtPlacement();
      ResetAllGridStartLatches();
      InitializeGridLevels();
      Print("VDualGrid: đủ điều kiện đặt gốc — base=", DoubleToString(basePrice, dgt), " (khung giờ + RSI/EMA/ADX nếu bật)");
      if(EnableResetNotification)
         SendResetNotification("Đủ điều kiện — bắt đầu lưới chờ ảo");
      ManageGridOrders();
      return;
   }

   // Đã có gốc, EA chưa reset: không đổi basePrice — chỉ nạp lại mức lưới nếu mảng lệch (hiếm).
   if(g_runtimeSessionActive && basePrice > 0.0 && ArraySize(gridLevels) < expectedGridLevelCount)
   {
      InitializeGridLevels();
      Print("VDualGrid: nạp lại mức lưới theo base giữ nguyên base=", DoubleToString(basePrice, dgt));
      ManageGridOrders();
      return;
   }

   ProcessVirtualPendingExecutions();
   ProcessOrderBalanceMode();

   double floating = 0.0;
   double openLots = 0.0;
   double compoundOpenProfitSwapUsd = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !IsOurMagic(PositionGetInteger(POSITION_MAGIC)) || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      const double ps = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      compoundOpenProfitSwapUsd += ps;
      if(sessionStartTime > 0 && (datetime)PositionGetInteger(POSITION_TIME) < sessionStartTime)
         continue;
      floating += ps;
      openLots += PositionGetDouble(POSITION_VOLUME);
   }

   if(g_compoundTotalProfitActive)
      ProcessCompoundTotalProfitTrailing();
   else if(g_compoundAfterClearWaitGrid)
      ProcessCompoundPostActivationGridStepWait(compoundOpenProfitSwapUsd);
   else
      ApplyGridProfitLockStops();

   if(EnableResetNotification)
      UpdateSessionStatsForNotification();

   if(EnableCompoundTotalFloatingProfit && CompoundTotalProfitTriggerUSD > 0.0 && basePrice > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid
      && compoundOpenProfitSwapUsd >= GetCompoundFloatingTriggerThresholdUsd())
   {
      TryArmCompoundTotalProfitMode();
   }

   ProcessCompoundArming(compoundOpenProfitSwapUsd);

   if((EnableSessionProfitReset && !CompoundSuppressesSessionProfitTargetReset()) || EnableSessionMaxLossReset)
   {
      // Nếu loại nào đạt ngưỡng (và điều kiện lot đúng nếu đặt) thì reset ngay.
      bool   shouldReset = false;
      bool   sessionResetFromProfitMilestone = false;
      double effectiveSession = 0.0;
      double sessionTargetUsd = 0.0;
      string modeLabel = "";

      if(EnableSessionProfitReset && !CompoundSuppressesSessionProfitTargetReset())
      {
         // 1) TP+OPEN (legacy) — luôn hoạt động khi target > 0
         if(!shouldReset && SessionProfitEnable_TP_Open)
         {
            double t = GetSessionProfitTargetUSDEffective();
            if(t > 0.0)
            {
               double eff = sessionClosedProfit + floating;
               if(eff >= t && SessionOpenLotsMatchesRequired(SessionProfitRequiredOpenLots_TP_Open, openLots))
               {
                  shouldReset = true;
                  sessionResetFromProfitMilestone = true;
                  effectiveSession = eff;
                  sessionTargetUsd = t;
                  modeLabel = "TP+OPEN";
               }
            }
         }

         // 2) OPEN only
         if(!shouldReset && SessionProfitUseOpenOnly)
         {
            double t = GetSessionProfitTargetOpenOnlyUSDEffective();
            if(t > 0.0)
            {
               double eff = floating;
               if(eff >= t && SessionOpenLotsMatchesRequired(SessionProfitRequiredOpenLots_OpenOnly, openLots))
               {
                  shouldReset = true;
                  sessionResetFromProfitMilestone = true;
                  effectiveSession = eff;
                  sessionTargetUsd = t;
                  modeLabel = "OPEN";
               }
            }
         }

         // 3) TP+SL+OPEN
         if(!shouldReset && SessionProfitIncludeClosedTPandSL)
         {
            double t = GetSessionProfitTargetClosedTpSlOpenUSDEffective();
            if(t > 0.0)
            {
               double eff = sessionClosedProfitTpSl + floating;
               if(eff >= t && SessionOpenLotsMatchesRequired(SessionProfitRequiredOpenLots_TP_SL_Open, openLots))
               {
                  shouldReset = true;
                  sessionResetFromProfitMilestone = true;
                  effectiveSession = eff;
                  sessionTargetUsd = t;
                  modeLabel = "TP+SL+OPEN";
               }
            }
         }
      }

      // 4) Lỗ tối đa phiên: cùng thành phần TP+SL đóng + treo (lệnh mở trong phiên)
      if(!shouldReset && EnableSessionMaxLossReset)
      {
         const double maxLoss = GetSessionMaxLossUSDEffective();
         if(maxLoss > 0.0)
         {
            const double effLoss = sessionClosedProfitTpSl + floating;
            if(effLoss <= -maxLoss && SessionOpenLotsMatchesRequired(SessionMaxLossRequiredOpenLots, openLots))
            {
               shouldReset = true;
               effectiveSession = effLoss;
               sessionTargetUsd = maxLoss;
               modeLabel = "MAX_LOSS";
            }
         }
      }

      if(shouldReset)
      {
         double tpSnap = sessionClosedProfit;
         double tpSlSnap = sessionClosedProfitTpSl;
         double flSnap = floating;
         // TP tổng: chỉ cộng dồn khi reset do đạt mục lãi nhóm 6 (không tính reset do vượt lỗ tối đa)
         if(TotalProfitStopUSD > 0.0 && sessionResetFromProfitMilestone)
         {
            g_accumResetSessionPL += effectiveSession;
            if(g_accumResetSessionPL >= TotalProfitStopUSD)
            {
               CloseAllPositionsAndOrders();
               GlobalVariableSet(VDualGridTotalStopGvKey(), (double)TimeCurrent());
               Print("VDualGrid: TP tổng (cộng dồn các lần reset phiên) ", DoubleToString(g_accumResetSessionPL, 2), " >= ", DoubleToString(TotalProfitStopUSD, 2), " USD — đóng hết & gỡ EA. Xóa GV \"", VDualGridTotalStopGvKey(), "\" để chạy lại.");
               if(EnableResetNotification)
                  SendResetNotification("Dừng TP tổng — tổng lãi các lần reset phiên đạt mục tiêu");
               ExpertRemove();
               return;
            }
         }
         CloseAllPositionsAndOrders();
         lastResetTime = TimeCurrent();
         sessionClosedProfit = 0.0;
         sessionClosedProfitTpSl = 0.0;
         if(!IsSchedulingAllowedForNewSession(TimeCurrent()))
         {
            g_runtimeSessionActive = false;
            basePrice = 0.0;
            VirtualPendingClear();
            ArrayResize(gridLevels, 0);
            sessionStartTime = 0;
            Print("VDualGrid: reset xong nhưng ngoài lịch chạy (giờ và/hoặc ngày server) — EA tạm dừng, chờ lịch cho phép.");
            if(EnableResetNotification)
               SendResetNotification("Reset xong ngoài lịch chạy — EA chờ giờ/ngày");
            return;
         }
         ResetAllGridStartLatches();
         UpdateAllGridStartLatchesWhileWaiting();
         if(GridStartTimeAndRSIOk(TimeCurrent()))
         {
               basePrice = GridBasePriceAtPlacement();
               InitializeGridLevels();
               ResetAllGridStartLatches();
               {
                  double tevNow = GetTradingEquityViewUSD();
                  const double trdPct = GetTradingEquityViewPctVsScaleBaseline();
                  if(modeLabel == "MAX_LOSS")
                     Print("Vượt lỗ tối đa phiên: ", DoubleToString(effectiveSession, 2), " (TP+SL ", DoubleToString(tpSlSnap, 2), " + treo ", DoubleToString(flSnap, 2), ", lot mở ", DoubleToString(openLots, 2), ") <= -", DoubleToString(sessionTargetUsd, 2), " USD. Reset EA, giá gốc mới = ", basePrice);
                  else if(modeLabel == "TP+SL+OPEN")
                     Print("Đạt mục tiêu lãi phiên: ", DoubleToString(effectiveSession, 2), " (TP+SL ", DoubleToString(tpSlSnap, 2), " + treo ", DoubleToString(flSnap, 2), ", lot mở ", DoubleToString(openLots, 2), ") >= ", DoubleToString(sessionTargetUsd, 2), " USD (mode ", modeLabel, "). Reset EA, giá gốc mới = ", basePrice);
                  else if(modeLabel == "OPEN")
                     Print("Đạt mục tiêu lãi phiên: ", DoubleToString(effectiveSession, 2), " (treo ", DoubleToString(flSnap, 2), ", lot mở ", DoubleToString(openLots, 2), ") >= ", DoubleToString(sessionTargetUsd, 2), " USD (mode ", modeLabel, "). Reset EA, giá gốc mới = ", basePrice);
                  else
                     Print("Đạt mục tiêu lãi phiên: ", DoubleToString(effectiveSession, 2), " (TP ", DoubleToString(tpSnap, 2), " + treo ", DoubleToString(flSnap, 2), ", lot mở ", DoubleToString(openLots, 2), ") >= ", DoubleToString(sessionTargetUsd, 2), " USD (mode ", modeLabel, "). Reset EA, giá gốc mới = ", basePrice);
                  Print("VDualGrid: TEV vs mốc khởi động EA (reset phiên không đổi mốc; không nạp/rút vào mốc): ", (trdPct >= 0 ? "+" : ""), DoubleToString(trdPct, 2), "% (TEV ", DoubleToString(tevNow, 2), " / mốc ", DoubleToString(GetScaleCapitalReferenceUSD(), 2), " USD) | mult scale lot=", DoubleToString(GetCapitalScaleMultiplier(), 4));
               }
               if(TotalProfitStopUSD > 0.0)
                  Print("TP tổng (dồn): ", DoubleToString(g_accumResetSessionPL, 2), " / ", DoubleToString(TotalProfitStopUSD, 2), " USD");
               if(EnableResetNotification)
                  SendResetNotification(modeLabel == "MAX_LOSS" ? "Vượt lỗ tối đa phiên — reset lưới" : "Đạt mục tiêu lãi phiên — reset lưới");
               ManageGridOrders();
         }
         else
         {
            basePrice = 0.0;
            VirtualPendingClear();
            ArrayResize(gridLevels, 0);
            sessionStartTime = 0;
            {
               string rs = "VDualGrid: reset phiên xong — chờ điều kiện đặt gốc mới";
               if(EnableRSIFilterForGridStart)
                  rs += " | RSI lần đầu vào vùng " + DoubleToString(RSIZoneLow, 1) + " < RSI < " + DoubleToString(RSIZoneHigh, 1);
               if(EnableEMAFilterForGridStart)
                  rs += " | EMA: lần cắt đầu trên nến (khóa giá)";
               if(EnableADXFilterForGridStart && ADXStartGateUsesThresholds())
                  rs += " | ADX trong vùng (theo input)";
               Print(rs + ".");
            }
            if(EnableResetNotification)
               SendResetNotification(modeLabel == "MAX_LOSS" ? "Vượt lỗ tối đa phiên — chờ đặt gốc" : "Reset phiên — chờ điều kiện đặt gốc (RSI/EMA/ADX nếu bật)");
         }
         return;
      }
   }

   ManageGridOrdersThrottled();
}

//+------------------------------------------------------------------+
//| Throttle ManageGridOrders to reduce per-tick workload             |
//| - Virtual stop triggers still run every tick (ProcessVirtual...). |
//| - Grid maintenance: at most once/sec; + ngay khi đóng vị thế (OUT). |
//| - Không bổ sung chờ ngay sau chờ ảo -> market (cooldown + vị thế).  |
//+------------------------------------------------------------------+
void ManageGridOrdersThrottled()
{
   static datetime lastManageTime = 0;
   datetime now = TimeCurrent();
   if(lastManageTime == now)
      return;  // avoid multiple full scans in same second
   lastManageTime = now;
   ManageGridOrders();
}

//+------------------------------------------------------------------+
//| Update peak/min balance (session + global since EA attach) and max lot in session |
//+------------------------------------------------------------------+
void UpdateSessionStatsForNotification()
{
   double tev = GetTradingEquityViewUSD();
   if(tev > sessionPeakTradingEquityView) sessionPeakTradingEquityView = tev;
   if(tev < sessionMinTradingEquityView) sessionMinTradingEquityView = tev;
   if(tev > globalPeakTradingEquityView) globalPeakTradingEquityView = tev;
   if(tev < globalMinTradingEquityView) globalMinTradingEquityView = tev;
   double totalLot = 0, maxLot = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC)) || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      totalLot += vol;
      if(vol > maxLot) maxLot = vol;
   }
   if(maxLot > sessionMaxSingleLot)
   {
      sessionMaxSingleLot = maxLot;
      sessionTotalLotAtMaxLot = totalLot;
   }
   if(maxLot > globalMaxSingleLot)
   {
      globalMaxSingleLot = maxLot;
      globalTotalLotAtMaxLot = totalLot;
   }
}

// Telegram/WebRequest block removed to lighten code.
// If you ever need Telegram back, define VDUALGRID_ENABLE_TELEGRAM before compiling.
#ifdef VDUALGRID_ENABLE_TELEGRAM
//+------------------------------------------------------------------+
//| URL encode for Telegram text                                       |
//+------------------------------------------------------------------+
string UrlEncodeForTelegram(const string s)
{
   string result = "";
   for(int i = 0; i < StringLen(s); i++)
   {
      ushort c = StringGetCharacter(s, i);
      if(c == ' ')
         result += "+";
      else if(c == '\n')
         result += "%0A";
      else if(c == '\r')
         result += "%0D";
      else if(c == '&')
         result += "%26";
      else if(c == '=')
         result += "%3D";
      else if(c == '+')
         result += "%2B";
      else if(c == '%')
         result += "%25";
      else if(c >= 32 && c < 127)
         result += CharToString((uchar)c);
      else
      {
         // UTF-8 rồi %HH từng byte (Telegram yêu cầu; %02X từ code unit 16-bit trước đây gây HTTP 400 với tiếng Việt)
         string oneChar = StringSubstr(s, i, 1);
         uchar bytes[];
         int nb = StringToCharArray(oneChar, bytes, 0, WHOLE_ARRAY, CP_UTF8);
         if(nb <= 0)
            continue;
         int useLen = nb;
         if(useLen > 0 && bytes[useLen - 1] == 0)
            useLen--;
         for(int k = 0; k < useLen; k++)
            result += "%" + StringFormat("%02X", (uint)bytes[k]);
      }
   }
   return result;
}

//+------------------------------------------------------------------+
//| Lấy message_id từ JSON phản hồi Telegram (sendMessage/sendPhoto). |
//+------------------------------------------------------------------+
long TelegramExtractMessageIdFromJson(const string json)
{
   int p = StringFind(json, "\"message_id\"");
   if(p < 0)
      return 0;
   int c = StringFind(json, ":", p);
   if(c < 0)
      return 0;
   int i = c + 1;
   int len = StringLen(json);
   while(i < len)
   {
      ushort w = StringGetCharacter(json, i);
      if(w == ' ' || w == '\t' || w == '\n' || w == '\r')
      {
         i++;
         continue;
      }
      break;
   }
   if(i >= len)
      return 0;
   long val = 0;
   bool neg = false;
   if(StringGetCharacter(json, i) == '-')
   {
      neg = true;
      i++;
   }
   while(i < len)
   {
      ushort ch = StringGetCharacter(json, i);
      if(ch < '0' || ch > '9')
         break;
      val = val * 10 + (long)(ch - '0');
      i++;
   }
   return neg ? -val : val;
}

//+------------------------------------------------------------------+
void TelegramNotifyIdsAppend(const long mid)
{
   if(mid <= 0)
      return;
   int n = ArraySize(g_telegramNotifyMsgIds);
   if(n >= 200)
      return;
   ArrayResize(g_telegramNotifyMsgIds, n + 1);
   g_telegramNotifyMsgIds[n] = mid;
}

//+------------------------------------------------------------------+
void TelegramApiDeleteMessage(const long messageId)
{
   if(!EnableTelegram || StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatID) < 5 || messageId <= 0)
      return;
   string url = "https://api.telegram.org/bot" + TelegramBotToken + "/deleteMessage";
   string body = "chat_id=" + TelegramChatID + "&message_id=" + IntegerToString(messageId);
   uchar ubody[];
   int nw = StringToCharArray(body, ubody, 0, WHOLE_ARRAY, CP_UTF8);
   if(nw <= 0)
      return;
   int blen = nw;
   if(blen > 0 && ubody[blen - 1] == 0)
      blen--;
   char post[];
   ArrayResize(post, blen);
   for(int b = 0; b < blen; b++)
      post[b] = (char)ubody[b];
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/x-www-form-urlencoded; charset=UTF-8\r\n";
   ResetLastError();
   int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
   if(res != 200 && res >= 0)
   {
      string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      if(StringFind(resp, "\"ok\":true") < 0)
         Print("Telegram deleteMessage id=", messageId, " HTTP ", res, " ", StringSubstr(resp, 0, 280));
   }
}

//+------------------------------------------------------------------+
//| Xóa toàn bộ tin bot đã lưu từ lần thông báo trước (deleteMessage). |
//+------------------------------------------------------------------+
void TelegramDeleteAllPreviousNotifyMessages()
{
   int n = ArraySize(g_telegramNotifyMsgIds);
   if(n <= 0)
      return;
   if(StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatID) < 5)
   {
      ArrayResize(g_telegramNotifyMsgIds, 0);
      return;
   }
   for(int i = 0; i < n; i++)
   {
      long mid = g_telegramNotifyMsgIds[i];
      if(mid > 0)
         TelegramApiDeleteMessage(mid);
      Sleep(50);
   }
   ArrayResize(g_telegramNotifyMsgIds, 0);
}

//+------------------------------------------------------------------+
//| Ghép chuỗi UTF-8 / byte nhị phân vào body POST (multipart).       |
//+------------------------------------------------------------------+
void TelegramPostAppendUtf8(char &post[], int &postLen, const string s)
{
   uchar u[];
   int n = StringToCharArray(s, u, 0, WHOLE_ARRAY, CP_UTF8);
   int L = n;
   if(L > 0 && u[L - 1] == 0)
      L--;
   int old = postLen;
   ArrayResize(post, old + L);
   for(int i = 0; i < L; i++)
      post[old + i] = (char)u[i];
   postLen = old + L;
}

void TelegramPostAppendBytes(char &post[], int &postLen, const uchar &data[], const int dataLen)
{
   int old = postLen;
   ArrayResize(post, old + dataLen);
   for(int i = 0; i < dataLen; i++)
      post[old + i] = (char)data[i];
   postLen = old + dataLen;
}

//+------------------------------------------------------------------+
//| Chụp chart hiện tại (GIF) + POST Telegram sendPhoto (multipart).  |
//+------------------------------------------------------------------+
void SendTelegramChartScreenshotIfEnabled(const string caption)
{
   if(!EnableTelegram || !EnableTelegramChartScreenshot)
      return;
   if(StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatID) < 5)
      return;

   int w = TelegramScreenshotWidth;
   int h = TelegramScreenshotHeight;
   if(w < 320)
      w = 320;
   if(w > 1920)
      w = 1920;
   if(h < 240)
      h = 240;
   if(h > 1080)
      h = 1080;

   const string shotName = "vdualgrid_chart_shot.gif";
   ResetLastError();
   if(!ChartScreenShot(0, shotName, w, h, ALIGN_RIGHT))
   {
      Print("VDualGrid ảnh chart: ChartScreenShot thất bại (err ", GetLastError(), ") — mở chart gắn EA hoặc thử ngoài Strategy Tester.");
      return;
   }

   int fh = FileOpen(shotName, FILE_READ | FILE_BIN);
   if(fh == INVALID_HANDLE)
   {
      Print("VDualGrid ảnh chart: không mở được ", shotName, " err ", GetLastError());
      return;
   }
   ulong sz64 = FileSize(fh);
   if(sz64 < 32 || sz64 > 10485760UL)
   {
      FileClose(fh);
      FileDelete(shotName);
      Print("VDualGrid ảnh chart: kích thước file không hợp lệ: ", sz64);
      return;
   }
   int sz = (int)sz64;
   uchar gif[];
   ArrayResize(gif, sz);
   uint nread = FileReadArray(fh, gif, 0, sz);
   FileClose(fh);
   FileDelete(shotName);
   if(nread != (uint)sz)
   {
      Print("VDualGrid ảnh chart: đọc file thiếu byte (", nread, "/", sz, ").");
      return;
   }

   string bnd = "VDG" + IntegerToString((long)TimeCurrent()) + IntegerToString(GetTickCount());
   string ctype = "multipart/form-data; boundary=" + bnd;

   char post[];
   int plen = 0;
   TelegramPostAppendUtf8(post, plen, "--" + bnd + "\r\n");
   TelegramPostAppendUtf8(post, plen, "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n");
   TelegramPostAppendUtf8(post, plen, TelegramChatID + "\r\n");

   string cap = caption;
   if(StringLen(cap) > 1024)
      cap = StringSubstr(cap, 0, 1021) + "...";
   if(StringLen(cap) > 0)
   {
      TelegramPostAppendUtf8(post, plen, "--" + bnd + "\r\n");
      TelegramPostAppendUtf8(post, plen, "Content-Disposition: form-data; name=\"caption\"\r\n\r\n");
      TelegramPostAppendUtf8(post, plen, cap + "\r\n");
   }

   TelegramPostAppendUtf8(post, plen, "--" + bnd + "\r\n");
   TelegramPostAppendUtf8(post, plen, "Content-Disposition: form-data; name=\"photo\"; filename=\"chart.gif\"\r\n");
   TelegramPostAppendUtf8(post, plen, "Content-Type: image/gif\r\n\r\n");
   TelegramPostAppendBytes(post, plen, gif, sz);
   TelegramPostAppendUtf8(post, plen, "\r\n--" + bnd + "--\r\n");

   string url = "https://api.telegram.org/bot" + TelegramBotToken + "/sendPhoto";
   string hdr = "Content-Type: " + ctype + "\r\nContent-Length: " + IntegerToString(plen) + "\r\n";

   char result[];
   string resultHeaders;
   ResetLastError();
   int res = WebRequest("POST", url, hdr, 45000, post, result, resultHeaders);
   if(res == 200 && TelegramDeletePreviousBotMessagesOnNotify)
   {
      string okBody = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      long mid = TelegramExtractMessageIdFromJson(okBody);
      if(mid > 0)
         TelegramNotifyIdsAppend(mid);
   }
   if(res != 200)
   {
      string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      Print("Telegram sendPhoto: HTTP ", res, " GetLastError=", GetLastError(), " | ", StringSubstr(resp, 0, 700));
   }
}



//+------------------------------------------------------------------+
//| Chọn 1 trong n chuỗi theo seed (phân tích "AI" vui, không gọi mạng). |
//+------------------------------------------------------------------+
string FunAI_Pick5(const int seed, const string s0, const string s1, const string s2, const string s3, const string s4)
{
   int i = seed % 5;
   if(i < 0) i += 5;
   if(i == 0) return s0;
   if(i == 1) return s1;
   if(i == 2) return s2;
   if(i == 3) return s3;
   return s4;
}

//+------------------------------------------------------------------+
//| Khối phân tích vui cho Telegram (if/else + RNG — không phải LLM).   |
//+------------------------------------------------------------------+
string BuildFunAIAnalysisTelegram(const string reason, const double pct, const double maxLossUSD,
                                  const string chartCompactVi)
{
   uint u = (uint)TimeCurrent() + (uint)(StringLen(reason) * 131U) + (uint)(MathAbs(pct) * 17.0);
   int s0 = (int)(u % 5);
   int s1 = (int)((u / 5U) % 5);
   int s2 = (int)((u / 25U) % 5);

   string out = "Phân tích AI\n\n";

   string ev = "";
   if(StringFind(reason, "mục tiêu lãi phiên") >= 0)
      ev = FunAI_Pick5(s0,
         "Ding ding! Đủ tiền mục tiêu phiên rồi — EA dọn bàn cũ, kê bàn mới, thị trường ơi cho xin tí drama tiếp theo!",
         "Ê hê, phiên này ăn đủ — reset lưới kiểu 'tính tiền xong nhảy quán khác', chúc vé may mắn vòng sau nha!",
         "Logic thắng cảm xúc hiếm lắm đó — đừng khoe Facebook quá, chart hay ghen tị lắm.",
         "Mục tiêu phiên chạm đích: như chạy bộ xong được chai nước — uống mát, nghỉ quéo rồi chạy tiếp.",
         "Telegram *ting* một cái là biến vui: TP phiên okela, đi ăn mừng chưa bạn hiền?");
   else if(StringFind(reason, "Dừng TP tổng") >= 0)
      ev = FunAI_Pick5(s0,
         "Boss cuối gục! Tổng lãi dồn đủ ngưỡng — cinematic ending, đóng máy, hết phim phần này!",
         "Combo TP tổng full — như hết season Netflix: đừng spoil cho thị trường nha.",
         "Mình tặng 10/10 cho độ kiên nhẫn dồn phiên — giờ đi chill hoặc code input mới cho máu.",
         "Bánh kem trong tủ đang gọi tên bạn — cớ hợp lý để ăn ngọt, không cần họp hành.",
         "Hệ thống: xong việc. Bạn: hehe. Chart: im thin thít. Telegram: hân hạnh phục vụ.");
   else if(StringFind(reason, "EA đã dừng") >= 0)
      ev = FunAI_Pick5(s0,
         "Tạm biệt nha — EA về tắm rửa, RAM đi ngủ sớm, tick history vẫn flex trong quá khứ.",
         "Hết show! Đèn tắt, khán giả vỗ tay (hoặc ngủ gật), cả làng đi ăn mì.",
         "OnDeinit = 'hẹn gặp lại sau khi bấm attach' — đừng buồn như chia tay người yêu, nó chỉ là code thôi.",
         "Coi log lý do dừng nha — đừng đổ tại Wi-Fi hàng xóm trừ khi thật sự lag.",
         "Độ ẩm phòng vô tội… trừ khi bạn đánh đổ nước lên máy, lúc đó sorry bro.");
   else if(StringFind(reason, "EA đã khởi động") >= 0)
      ev = FunAI_Pick5(s0,
         "Lên sóng rùi nè! Grid căng sẵn, thị trường đang make-up hậu trường — mình cầm popcorn chờ hạ cánh.",
         "Từ giờ drama là của giá + lot; nút nguồn chỉ để bật quạt thôi bạn hiền ơi.",
         "Margin theo dõi như trend TikTok — cười nhẹ thôi, đừng FOMO quá tay.",
         "Hệ thống online — cà phê tuỳ gu, kỷ luật thì pha nóng hổi mới ngon!",
         "Team tự động đã join party: chart chưa giàu ngay nhưng đã có đồng minh rồi đó.");
   else
      ev = FunAI_Pick5(s0,
         "Lý do hơi ngớ ngẩn? Không sa, meme cũng cần nguyên liệu — mình vẫn bắt trend cho đủ khung hình.",
         "Không gắn nhãn là để tự do nghệ thuật — EA xin một câu triết lý fake cho đẹp story.",
         "Phân tích đa chiều = nhìn một chiều mà tỏ vẻ sâu — có biến là đủ content.",
         "Không hiểu lý do thì uống nước, F5 chart, thở — survival kit của trader đó bạn ơi.",
         "AI trong đầu mình gật gù như hiểu hết — đừng tin, nó cũng đang Google dở.");

   string pl = "";
   if(pct >= 5.0)
      pl = "P/L TEV vs mốc khởi động: +" + DoubleToString(pct, 2) + "%. " + FunAI_Pick5(s1,
            "Woohoo xanh bụi! Thắt dây an toàn cảm xúc — tàu lượn lên dốc hét được nhưng đừng buông tay.",
            "Số đẹp phết — mai chart đổi kịch như đạo diễn uống quá caffeine, coi chừng plot twist.",
            "Đừng tưởng skill vĩnh viễn — đôi khi chỉ là sóng cho mượn, trả hồi còn lại.",
            "Kiêu nhẹ thôi nha — bot không khoe được, bạn cũng đừng khoe hộ nó quá.",
            "Chúc mừng! Giai đoạn dễ tự tin quá đà — bình tĩnh như ninja đi gác.");
   else if(pct > 0.05)
      pl = "P/L TEV vs mốc khởi động: +" + DoubleToString(pct, 2) + "%. " + FunAI_Pick5(s1,
            "Xanh nhạt matcha vibe — chill chill, chưa cần chạy vào phòng điều hành hò hét.",
            "Lãi tí cũng là lãi — lãi kép thích người không drama, drama để hội trưởng drama lo.",
            "Thắng nhẹ: đủ tự tin, chưa đủ màn hình cong — tiết kiệm ví, eco-friendly.",
            "Máy êm như xe đủ xăng — chưa nổ nhưng có ga là được.",
            "Vi mô ổn — vĩ mô thi riêng, coi như môn phụ kế bên.");
   else if(pct >= -0.05)
      pl = "P/L TEV vs mốc khởi động: " + DoubleToString(pct, 2) + "%. " + FunAI_Pick5(s1,
            "Mode Schrödinger: thắng hay thua tùy mood — chart không nói, chỉ nháy mắt.",
            "Hòa vốn cảm xúc: P/L im lặng nhưng tâm lý đang rap battle.",
            "Phẳng như ly soda quên nắp — không sai, chỉ hơi chán tí.",
            "Vùng F5 thiền: hoặc tĩnh tâm hoặc spam refresh như game idle.",
            "Không lên không xuống — ít nhất log có twist, đọc cho đỡ buồn ngủ.");
   else
      pl = "P/L TEV vs mốc khởi động: " + DoubleToString(pct, 2) + "%. " + FunAI_Pick5(s1,
            "Đỏ hơi chói — coi như gym free cho khả năng chịu đựng, không tính phí PT.",
            "Drawdown = học phí; không học được gì thì coi như Netflix buồn nhưng vẫn có phụ đề.",
            "Số âm không định nghĩa con người bạn — chỉ định nghĩa đoạn curve đang vẽ dở.",
            "Thở + check risk; đừng capslock cãi chart — chart không đọc comment đâu.",
            "Ôm ấm ảo: sóng qua hết drama, EA vẫn chạy input bạn gõ — team work đó!");

   string dd = "";
   if(maxLossUSD > 1.0)
      dd = "Biên độ sụt giảm (equity EA) ~ " + DoubleToString(maxLossUSD, 2) + " USD. " + FunAI_Pick5(s2,
            "Tàu lượn có đoạn lao — dây an toàn vốn siết chặt nha bạn hiền.",
            "Số này mà giật mình thì lot có thể đang biên kịch kinh dị — cân nhắc rating.",
            "Đỉnh đáy chỉ spoiler quá khứ — không leak tập sau.",
            "Drawdown bự = dataset; bình tĩnh = giảm học phí, panic = mua vé VIP.",
            "Thị trường: 'cầm hộ biến động'. Bạn: 'mình giữ risk như giữ crush.'");
   else
      dd = "Drawdown nhỏ xíu — EA mới tập đi hoặc bạn đi dạo trên ray tàu lượn cho vui.";

   string chartNote = "";
   if(StringLen(chartCompactVi) > 3)
      chartNote = "\n\nGợi nhanh chart: " + chartCompactVi + " — vibe nến cho đủ màu, không phải lệnh nha.";

   return out + ev + "\n\n" + pl + "\n" + dd + chartNote;
}


//+------------------------------------------------------------------+
//| Nhãn khung thời gian ngắn (VN context).                            |
//+------------------------------------------------------------------+
string PeriodToShortLabelVi(const ENUM_TIMEFRAMES tf)
{
   ENUM_TIMEFRAMES t = tf;
   if(t == PERIOD_CURRENT)
      t = (ENUM_TIMEFRAMES)Period();
   switch(t)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M2:  return "M2";
      case PERIOD_M3:  return "M3";
      case PERIOD_M4:  return "M4";
      case PERIOD_M5:  return "M5";
      case PERIOD_M6:  return "M6";
      case PERIOD_M10: return "M10";
      case PERIOD_M12: return "M12";
      case PERIOD_M15: return "M15";
      case PERIOD_M20: return "M20";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H2:  return "H2";
      case PERIOD_H3:  return "H3";
      case PERIOD_H4:  return "H4";
      case PERIOD_H6:  return "H6";
      case PERIOD_H8:  return "H8";
      case PERIOD_H12: return "H12";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default:         return "TF";
   }
}

//+------------------------------------------------------------------+
//| Mô tả độ dài một nến (khung hiện tại).                            |
//+------------------------------------------------------------------+
string CandleSpanLabelVi(const int secBar)
{
   if(secBar <= 0)
      return "?";
   if(secBar >= 86400)
      return IntegerToString(secBar / 86400) + " ngày/nến";
   if(secBar >= 3600)
      return IntegerToString(secBar / 3600) + " giờ/nến";
   if(secBar >= 60)
      return IntegerToString(secBar / 60) + " phút/nến";
   return IntegerToString(secBar) + " giây/nến";
}

//+------------------------------------------------------------------+
//| Thống kê nến realtime (CopyRates) — full block + dòng gọn (push/AI local). |
//+------------------------------------------------------------------+
void BuildRealtimeChartAnalysisVI(const string sym, const int symDigits, string &fullOut, string &compactOut)
{
   fullOut = "";
   compactOut = "";
   if(!EnableTelegramChartAnalysis)
      return;

   int barsReq = ChartAnalysisBars;
   if(barsReq < 10)
      barsReq = 10;
   if(barsReq > 500)
      barsReq = 500;

   ENUM_TIMEFRAMES tf = ChartAnalysisTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)Period();

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int n = CopyRates(sym, tf, 0, barsReq, rates);
   string tfLab = PeriodToShortLabelVi(ChartAnalysisTimeframe);

   if(n < 5)
   {
      fullOut = "--- BIỂU ĐỒ (thời gian thực) ---\n(Không đủ dữ liệu nến — kiểm tra symbol/khung hoặc history.)";
      compactOut = tfLab + ": không đủ nến";
      return;
   }

   double c0 = rates[0].close;
   double o0 = rates[0].open;
   int iOld = n - 1;
   double cOld = rates[iOld].close;
   double chgPct = (cOld > 0.0) ? ((c0 / cOld - 1.0) * 100.0) : 0.0;

   double rangeHigh = rates[0].high;
   double rangeLow = rates[0].low;
   for(int i = 1; i < n; i++)
   {
      if(rates[i].high > rangeHigh)
         rangeHigh = rates[i].high;
      if(rates[i].low < rangeLow)
         rangeLow = rates[i].low;
   }

   int bull = 0, bear = 0;
   int look = 12;
   if(look > n)
      look = n;
   for(int j = 0; j < look; j++)
   {
      if(rates[j].close >= rates[j].open)
         bull++;
      else
         bear++;
   }

   int k5 = 5;
   if(k5 > n)
      k5 = n;
   int k20 = 20;
   if(k20 > n)
      k20 = n;
   double sum5 = 0.0, sum20 = 0.0;
   for(int k = 0; k < k5; k++)
      sum5 += rates[k].close;
   for(int k = 0; k < k20; k++)
      sum20 += rates[k].close;
   double sma5 = sum5 / k5;
   double sma20 = sum20 / k20;

   int atrN = 14;
   if(atrN > n)
      atrN = n;
   double sumATR = 0.0;
   for(int a = 0; a < atrN; a++)
      sumATR += rates[a].high - rates[a].low;
   double atrAvg = (atrN > 0) ? sumATR / atrN : 0.0;

   string bias = "";
   if(c0 > sma5 && sma5 > sma20)
      bias = "nghiêng tăng ngắn hạn (giá > MA5 > MA20).";
   else if(c0 < sma5 && sma5 < sma20)
      bias = "nghiêng giảm ngắn hạn (giá < MA5 < MA20).";
   else
      bias = "đan xen / đi ngang nhanh — MA không xếp rõ xu hướng.";

   string lastBar = (c0 >= o0) ? "nến đang hình thành: tăng (đóng ≥ mở)." : "nến đang hình thành: giảm (đóng < mở).";

   fullOut = "--- BIỂU ĐỒ (thời gian thực, lúc báo) ---\n";
   fullOut += "Khung: " + tfLab + " | Số nến: " + IntegerToString(n) + "\n";
   fullOut += "Giá đóng mới nhất: " + DoubleToString(c0, symDigits) + " | " + lastBar + "\n";
   fullOut += "So với đóng nến cũ nhất trong cửa sổ (" + IntegerToString(n) + " nến): " + (chgPct >= 0.0 ? "+" : "") + DoubleToString(chgPct, 2) + "%\n";
   fullOut += "Đỉnh/đáy trong " + IntegerToString(n) + " nến: " + DoubleToString(rangeHigh, symDigits) + " / " + DoubleToString(rangeLow, symDigits) + "\n";
   fullOut += IntegerToString(look) + " nến gần nhất: " + IntegerToString(bull) + " tăng / " + IntegerToString(bear) + " giảm\n";
   fullOut += "MA đơn giản (5 vs 20): " + DoubleToString(sma5, symDigits) + " / " + DoubleToString(sma20, symDigits) + " → " + bias + "\n";
   fullOut += "Biên độ nến TB (high−low, " + IntegerToString(atrN) + " nến): " + DoubleToString(atrAvg, symDigits) + "\n";

   int secBar = PeriodSeconds(tf);
   if(secBar <= 0)
      secBar = 60;
   int n24want = (int)MathCeil(86400.0 / (double)secBar);
   if(n24want < 2)
      n24want = 2;
   int n24 = n24want;
   if(n24 > n - 1)
      n24 = n - 1;
   int n7want = (int)MathCeil(604800.0 / (double)secBar);
   if(n7want < 2)
      n7want = 2;
   int n7 = n7want;
   if(n7 > n - 1)
      n7 = n - 1;
   if(n7 < n24)
      n7 = n24;

   fullOut += "\n--- ĐA KHUNG (ước lượng từ độ dài nến × khung " + tfLab + ") ---\n";
   fullOut += "Một nến: " + CandleSpanLabelVi(secBar) + "\n";
   if(n24 < n24want)
      fullOut += "Lưu ý: ~24h cần khoảng " + IntegerToString(n24want) + " nến nhưng chỉ có " + IntegerToString(n) + " nến — số liệu 24h là tối đa có sẵn.\n";
   if(n7 < n7want)
      fullOut += "Lưu ý: ~7 ngày cần khoảng " + IntegerToString(n7want) + " nến — đang dùng " + IntegerToString(n7) + " nến.\n";

   double pct24 = 0.0, pct7 = 0.0;
   if(n24 >= 1 && n24 < n && rates[n24].close > 0.0)
      pct24 = (c0 / rates[n24].close - 1.0) * 100.0;
   if(n7 >= 1 && n7 < n && rates[n7].close > 0.0)
      pct7 = (c0 / rates[n7].close - 1.0) * 100.0;

   double hi24 = rates[0].high, lo24 = rates[0].low;
   for(int i = 1; i < n24 && i < n; i++)
   {
      if(rates[i].high > hi24)
         hi24 = rates[i].high;
      if(rates[i].low < lo24)
         lo24 = rates[i].low;
   }
   double hi7 = rates[0].high, lo7 = rates[0].low;
   for(int i = 1; i < n7 && i < n; i++)
   {
      if(rates[i].high > hi7)
         hi7 = rates[i].high;
      if(rates[i].low < lo7)
         lo7 = rates[i].low;
   }

   fullOut += "Cửa sổ ~24h: " + IntegerToString(n24) + " nến | % đổi đóng vs đóng cách " + IntegerToString(n24) + " nến: "
              + (pct24 >= 0.0 ? "+" : "") + DoubleToString(pct24, 2) + "%\n";
   fullOut += "Đỉnh/đáy trong " + IntegerToString(n24) + " nến gần nhất: " + DoubleToString(hi24, symDigits) + " / " + DoubleToString(lo24, symDigits) + "\n";
   fullOut += "Cửa sổ ~7 ngày: " + IntegerToString(n7) + " nến | % đổi đóng vs đóng cách " + IntegerToString(n7) + " nến: "
              + (pct7 >= 0.0 ? "+" : "") + DoubleToString(pct7, 2) + "%\n";
   fullOut += "Đỉnh/đáy trong " + IntegerToString(n7) + " nến gần nhất: " + DoubleToString(hi7, symDigits) + " / " + DoubleToString(lo7, symDigits) + "\n";
   fullOut += "Toàn cửa sổ " + IntegerToString(n) + " nến — đỉnh/đáy: " + DoubleToString(rangeHigh, symDigits) + " / " + DoubleToString(rangeLow, symDigits) + "\n";
   fullOut += "(Chỉ mô tả số liệu nến; AI chỉ được diễn giải từ các mức trên — không bịa giá.)";

   compactOut = tfLab + " " + (chgPct >= 0.0 ? "+" : "") + DoubleToString(chgPct, 1) + "%/" + IntegerToString(n) + "n";
   if(c0 > sma5 && sma5 > sma20)
      compactOut += " ↑MA";
   else if(c0 < sma5 && sma5 < sma20)
      compactOut += " ↓MA";
   else
      compactOut += " ~MA";
}


//+------------------------------------------------------------------+
//| Cắt chuỗi cho giới hạn Telegram (caption 1024, text 4096).         |
//+------------------------------------------------------------------+
string TelegramClampLen(const string s, const int maxLen)
{
   if(maxLen < 4)
      return "";
   if(StringLen(s) <= maxLen)
      return s;
   return StringSubstr(s, 0, maxLen - 3) + "...";
}

//+------------------------------------------------------------------+
//| Một tin Telegram (text); tránh gọi trực tiếp nếu tin rất dài.     |
//+------------------------------------------------------------------+
void SendTelegramMessageOnce(const string msg)
{
   if(!EnableTelegram || StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatID) < 5)
      return;
   string url = "https://api.telegram.org/bot" + TelegramBotToken + "/sendMessage";
   string body = "chat_id=" + TelegramChatID + "&text=" + UrlEncodeForTelegram(msg) + "&disable_web_page_preview=true";
   uchar ubody[];
   int nw = StringToCharArray(body, ubody, 0, WHOLE_ARRAY, CP_UTF8);
   if(nw <= 0)
      return;
   int blen = nw;
   if(blen > 0 && ubody[blen - 1] == 0)
      blen--;
   char post[];
   ArrayResize(post, blen);
   for(int b = 0; b < blen; b++)
      post[b] = (char)ubody[b];

   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/x-www-form-urlencoded; charset=UTF-8\r\n";
   ResetLastError();
   int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
   if(res == 200 && TelegramDeletePreviousBotMessagesOnNotify)
   {
      string okBody = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      long mid = TelegramExtractMessageIdFromJson(okBody);
      if(mid > 0)
         TelegramNotifyIdsAppend(mid);
   }
   if(res != 200)
   {
      string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      Print("Telegram: mã HTTP ", res, " GetLastError=", GetLastError(), " | phản hồi: ", StringSubstr(resp, 0, 700));
      if(res < 0)
         Print("Telegram: mã <0 — thường WebRequest chưa được phép: Tools→Options→Expert Advisors → Allow WebRequest → https://api.telegram.org");
      else
         Print("Telegram: mã HTTP ", res, " — thường do Bot Token / Chat ID, tin quá dài (4096), hoặc tham số; xem JSON phía trên.");
   }
}

//+------------------------------------------------------------------+
//| Send message to Telegram — tự tách nếu vượt ~3800 ký tự (giới hạn Telegram). |
//+------------------------------------------------------------------+
void SendTelegramMessage(const string msg)
{
   if(!EnableTelegram || StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatID) < 5)
      return;
   const int softMax = 3800;
   int total = StringLen(msg);
   if(total <= softMax)
   {
      SendTelegramMessageOnce(msg);
      return;
   }
   int start = 0;
   int partNum = 0;
   while(start < total)
   {
      partNum++;
      int chunkEnd = start + softMax;
      if(chunkEnd > total)
         chunkEnd = total;
      else
      {
         int breakPref = start + (softMax * 3) / 4;
         int br = -1;
         for(int p = chunkEnd - 1; p >= breakPref; p--)
         {
            if(StringGetCharacter(msg, p) == '\n')
            {
               br = p + 1;
               break;
            }
         }
         if(br > start)
            chunkEnd = br;
      }
      string slice = StringSubstr(msg, start, chunkEnd - start);
      string head = (partNum > 1) ? ("[Tiếp " + IntegerToString(partNum) + "]\n") : "";
      SendTelegramMessageOnce(head + slice);
      start = chunkEnd;
      if(start < total)
         Sleep(200);
   }
}

//+------------------------------------------------------------------+
//| Gửi thông báo MT5 + Telegram khi reset / dừng EA (nội dung tiếng Việt). |
//| Telegram: (1) sendMessage tin EA. (2) Nội dung chart+phân tích local: sendPhoto (caption ngắn) + sendMessage (tách chunk nếu dài); |
//|    không ảnh: một hoặc nhiều sendMessage. |
//|    Nếu bật TelegramDeletePreviousBotMessagesOnNotify: trước khi gửi, xóa các tin bot đã gửi ở lần thông báo trước (deleteMessage). |
//+------------------------------------------------------------------+
void SendResetNotification(const string reason)
{
   if(!EnableResetNotification && !EnableTelegram) return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int symDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   // % TEV hiện tại vs mốc TEV lúc khởi động EA (một mốc; reset phiên không làm mới mốc)
   double pct = GetTradingEquityViewPctVsScaleBaseline();
   double maxLossUSD = globalPeakTradingEquityView - globalMinTradingEquityView;
   // Tin đầy đủ (Telegram + chi tiết)
   string msg = "Thông báo VDualGrid\n";
   msg += "Biểu đồ: " + _Symbol + "\n";
   msg += "Lý do: " + reason + "\n";
   msg += "Giá tại thời điểm báo: " + DoubleToString(bid, symDigits) + "\n\n";
   msg += "--- THAM CHIẾU ---\n";
   msg += "Số dư ledger khi gắn EA: " + DoubleToString(attachBalance, 2) + " USD\n";
   msg += "TEV mốc khởi động (một lần, đóng+treo tại lúc đó): " + DoubleToString(GetScaleCapitalReferenceUSD(), 2) + " USD\n";
   msg += "Nạp/rút sau đó: không đổi mốc TEV/ledger snapshot, không đổi % trong tin theo nạp/rút; EA lưới/lot/mục tiêu theo input + P/L lệnh cùng magic.\n";
   if(EnableCapitalBasedScaling)
   {
      if(ScaleSessionProfitTargetsWithCapital)
         msg += "Đang bật scale vốn: nhân mult cho lot (L1 + Add cấp số cộng) và ngưỡng reset phiên USD (cùng X% + trần mult); mốc TEV không đổi khi reset phiên.\n";
      else
         msg += "Đang bật scale vốn: nhân mult cho lot (L1 + Add); ngưỡng phiên USD giữ đúng số input (tắt “nhân ngưỡng phiên” trong nhóm 5).\n";
   }
   msg += "\n--- TRẠNG THÁI ---\n";
   msg += "Số dư broker hiện tại: " + DoubleToString(bal, 2) + " USD\n";
   msg += "Lãi/lỗ TEV vs mốc khởi động EA (đóng + treo magic, không nạp/rút vào mốc): " + (pct >= 0 ? "+" : "") + DoubleToString(pct, 2) + "%\n";
   msg += "Biên độ sụt giảm tối đa (theo equity EA tính từ lúc gắn): " + DoubleToString(maxLossUSD, 2) + " USD\n";
   msg += "Mức equity thấp nhất kể từ lúc gắn EA: " + DoubleToString(globalMinTradingEquityView, 2) + " USD\n";
   msg += "--- EA MIỄN PHÍ ---\n";
   msg += "EA giao dịch tự động trên MT5 miễn phí.\n";
   msg += "Đăng ký tài khoản qua liên kết: https://one.exnessonelink.com/a/iu0hffnbzb\n";
   msg += "Sau khi đăng ký, gửi ID tài khoản để nhận EA.";
   // Điện thoại (SendNotification): tối đa 255 ký tự, chỉ tiếng Việt gọn
   string rShort = reason;
   const int rMaxPhone = 70;
   if(StringLen(rShort) > rMaxPhone)
      rShort = StringSubstr(rShort, 0, rMaxPhone - 3) + "...";
   const double v0 = GetScaleCapitalReferenceUSD();
   string msgPhone = "VDualGrid • " + _Symbol + "\n";
   msgPhone += "Lý do: " + rShort + "\n";
   msgPhone += "Số vốn lúc đầu: " + DoubleToString(v0, 2) + " USD\n";
   msgPhone += "Số dư hiện tại: " + DoubleToString(bal, 2) + " USD • Lãi/lỗ: ";
   msgPhone += (pct >= 0 ? "+" : "") + DoubleToString(pct, 1) + "%";
   string chartFullVi = "";
   string chartCompactVi = "";
   if(EnableTelegramChartAnalysis && (EnableTelegram || EnableResetNotification))
      BuildRealtimeChartAnalysisVI(_Symbol, symDigits, chartFullVi, chartCompactVi);
   while(StringLen(msgPhone) > 255)
      msgPhone = StringSubstr(msgPhone, 0, 252) + "...";
   if(EnableResetNotification)
      SendNotification(msgPhone);
   if(EnableTelegram)
   {
      if(TelegramDeletePreviousBotMessagesOnNotify)
         TelegramDeleteAllPreviousNotifyMessages();

      SendTelegramMessageOnce(TelegramClampLen(msg, 4096));
      Sleep(200);

      const bool hasChartText = EnableTelegramChartAnalysis && StringLen(chartFullVi) > 5;
      const bool wantTin2 = TelegramFunAIAnalysis || EnableTelegramChartScreenshot || hasChartText;
      if(!wantTin2)
         return;

      string aiBlock = "";

      if(TelegramFunAIAnalysis)
      {
         aiBlock = BuildFunAIAnalysisTelegram(reason, pct, maxLossUSD, chartCompactVi);
      }

      string part2 = "";
      if(hasChartText)
         part2 += chartFullVi;
      if(TelegramFunAIAnalysis && StringLen(aiBlock) > 0)
      {
         if(hasChartText)
            part2 += "\n\n";
         part2 += aiBlock;
      }
      else if(!TelegramFunAIAnalysis && EnableTelegramChartScreenshot && !hasChartText)
         part2 += "Ảnh chart MT5.\n";
      else if(!TelegramFunAIAnalysis && hasChartText)
         part2 += "\n(AI tắt — chỉ số liệu nến.)\n";

      if(StringLen(part2) < 8)
         part2 = "VDualGrid • " + _Symbol;

      if(EnableTelegramChartScreenshot)
      {
         string capShot = _Symbol + " • chart";
         SendTelegramChartScreenshotIfEnabled(TelegramClampLen(capShot, 1024));
         Sleep(200);
         SendTelegramMessage(part2);
      }
      else
         SendTelegramMessage(part2);
   }
}

#endif // VDUALGRID_ENABLE_TELEGRAM

//+------------------------------------------------------------------+
//| Gửi thông báo MT5 khi reset / dừng EA (push).                      |
//+------------------------------------------------------------------+
#ifndef VDUALGRID_ENABLE_TELEGRAM
void SendResetNotification(const string reason)
{
   if(!EnableResetNotification)
      return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double pct = GetTradingEquityViewPctVsScaleBaseline();
   string rShort = reason;
   const int rMaxPhone = 70;
   if(StringLen(rShort) > rMaxPhone)
      rShort = StringSubstr(rShort, 0, rMaxPhone - 3) + "...";
   const double v0 = GetScaleCapitalReferenceUSD();
   string msgPhone = "VDualGrid • " + _Symbol + "\n";
   msgPhone += "Lý do: " + rShort + "\n";
   msgPhone += "Số vốn lúc đầu: " + DoubleToString(v0, 2) + " USD\n";
   msgPhone += "Số dư hiện tại: " + DoubleToString(bal, 2) + " USD • Lãi/lỗ: ";
   msgPhone += (pct >= 0.0 ? "+" : "") + DoubleToString(pct, 1) + "%";
   while(StringLen(msgPhone) > 255)
      msgPhone = StringSubstr(msgPhone, 0, 252) + "...";
   SendNotification(msgPhone);
}
#endif

//+------------------------------------------------------------------+
//| Reset “đóng sạch” EA chart này: đóng toàn bộ vị thế mở (magic+symbol), |
//| xóa lệnh chờ broker cùng magic+symbol, xóa toàn bộ chờ ảo, tắt cờ gồng lãi. |
//+------------------------------------------------------------------+
void CloseAllPositionsAndOrders()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionIsOurSymbolAndMagic(ticket)) continue;
      trade.PositionClose(ticket);
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderIsOurSymbolAndMagic(ticket)) continue;
      trade.OrderDelete(ticket);
   }
   VirtualPendingClear();
   CompoundModeClearState();
   InitBaseEmaVirtGapClearZone();
}

//+------------------------------------------------------------------+
//| Giữ chờ ảo / lệnh broker chỉ trên các mức đã đăng ký; xóa lạc mức. |
void CancelStopOrdersOutsideBaseZone()
{
   if(basePrice <= 0.0 || ArraySize(gridLevels) < MaxGridLevels + 1)
      return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0 || !IsOurMagic(OrderGetInteger(ORDER_MAGIC)) || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      if(!VirtualPriceMatchesRegisteredGrid(price))
         trade.OrderDelete(ticket);
   }
   for(int j = ArraySize(g_virtualPending) - 1; j >= 0; j--)
   {
      double price = g_virtualPending[j].priceLevel;
      if(!VirtualPriceMatchesRegisteredGrid(price))
         VirtualPendingRemoveAt(j);
   }
}

//+------------------------------------------------------------------+
//| Add closed profit/loss to session (by Magic)                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   // Chỉ lệnh Mua/Bán thật — bỏ qua nạp/rút/bonus/credit (DEAL_TYPE_BALANCE, CREDIT, …)
   const long dType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dType != DEAL_TYPE_BUY && dType != DEAL_TYPE_SELL)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;
   if(!IsOurMagic(HistoryDealGetInteger(trans.deal, DEAL_MAGIC)))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   // Level-side closed -> require price to move away by >=1 level before re-adding virtual pending.
   ulong posId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double entryPrice = 0.0;
   bool isBuyEntry = false;
   if(basePrice > 0.0 && ArraySize(gridLevels) >= MaxGridLevels + 1 && GetPositionEntryByPositionId(posId, entryPrice, isBuyEntry))
   {
      int entryLvl = 0;
      if(FindSignedLevelNumForPrice(entryPrice, entryLvl) && entryLvl != 0)
      {
         double levelPrice = NormalizeDouble(basePrice + GridOffsetFromBaseForSignedLevel(entryLvl), dgt);
         VirtualRearmGateSet(levelPrice, isBuyEntry);
      }
   }

   // Đóng vị thế: bổ sung chờ ảo (không áp khi vừa chờ ảo->market — xem VirtualExecCooldown).
   if(basePrice > 0.0 && ArraySize(gridLevels) >= MaxGridLevels + 1 && EnableAutoReplenishVirtualOrders)
      ManageGridOrders();

   long dealTime = (long)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   double fullDealPnL = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                  + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                  + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   if(eaAttachTime > 0 && dealTime >= (long)eaAttachTime)
      eaCumulativeTradingPL += fullDealPnL;

   // Only count deals closed in current session (from sessionStartTime). EA attach or EA reset = new session, sessionStartTime updated.
   if(sessionStartTime > 0 && dealTime < (long)sessionStartTime)
      return;
   if(lastResetTime > 0 && dealTime >= lastResetTime && dealTime <= lastResetTime + 15)
      return;   // Avoid double-counting deals from positions just closed on reset
   const long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   if(reason == DEAL_REASON_TP)
      sessionClosedProfit += fullDealPnL;         // Legacy: chỉ TP
   if(reason == DEAL_REASON_TP || reason == DEAL_REASON_SL)
      sessionClosedProfitTpSl += fullDealPnL;     // TP + SL
}

//+------------------------------------------------------------------+
//| Grid: không đặt lệnh tại gốc. Tắt AP: ±1 = gốc±0.5*D; các bậc kế tiếp cách D. |
//| Bật cấp số cộng: lệch gốc ±n = n*D + n(n-1)/2*A; khoảng bậc k-1→k = D+(k-1)A. |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Độ lệch giá từ gốc tới bậc ký hiệu signedLevel = ±1, ±2, …         |
//+------------------------------------------------------------------+
double GridOffsetFromBaseForSignedLevel(int signedLevel)
{
   int n = MathAbs(signedLevel);
   if(n <= 0) return 0.0;
   double D = GridDistancePips * pnt * 10.0;
   if(D <= 0.0) return 0.0;
   if(!EnableGridArithmeticSpacing)
   {
      double off = ((double)n - 0.5) * D;
      return (signedLevel > 0) ? off : -off;
   }
   double A = MathMax(0.0, GridArithmeticAddPips) * pnt * 10.0;
   // Tích lũy n bước: bước đầu D, sau đó D+A, D+2A, … → tổng = n*D + A*(0+1+…+(n-1))
   double offAp = (double)n * D + 0.5 * (double)n * (double)(n - 1) * A;
   return (signedLevel > 0) ? offAp : -offAp;
}

//+------------------------------------------------------------------+
//| Giá mức levelIndex (0..2*MaxGridLevels-1).                         |
//| Trên gốc: index 0..Max-1 → bậc +1..+Max. Dưới gốc: +Max.. → -1..-Max. |
//+------------------------------------------------------------------+
double GetGridLevelPrice(int levelIndex)
{
   int s;
   if(levelIndex < MaxGridLevels)
      s = levelIndex + 1;
   else
      s = -(levelIndex - MaxGridLevels + 1);
   return NormalizeDouble(basePrice + GridOffsetFromBaseForSignedLevel(s), dgt);
}

//+------------------------------------------------------------------+
//| Tier signed vs base for lot/comment: +1..+N above, -1..-N below. |
//| idx = row in gridLevels[] (0 .. 2*MaxGridLevels-1).              |
//+------------------------------------------------------------------+
int GridSignedLevelNumFromIndex(int idx)
{
   if(idx < 0 || idx >= ArraySize(gridLevels)) return 0;
   if(idx < MaxGridLevels)
      return idx + 1;
   return -(idx - MaxGridLevels + 1);
}

//+------------------------------------------------------------------+
//| Bậc dương = trên gốc; bậc âm = dưới gốc. Buy/Sell theo loại lệnh. |
//+------------------------------------------------------------------+
ENUM_VGRID_LEG VirtualGridLegFromLevelSide(const bool isBuy, const int signedLevelNum)
{
   if(signedLevelNum > 0)
      return isBuy ? VGRID_LEG_BUY_ABOVE : VGRID_LEG_SELL_ABOVE;
   if(signedLevelNum < 0)
      return isBuy ? VGRID_LEG_BUY_BELOW : VGRID_LEG_SELL_BELOW;
   return VGRID_LEG_SELL_ABOVE;
}

ENUM_VGRID_LEG VirtualGridLegFromOrder(const ENUM_ORDER_TYPE orderType, const int signedLevelNum)
{
   const bool isBuy = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
   return VirtualGridLegFromLevelSide(isBuy, signedLevelNum);
}

double VirtualGridResolvedL1(const ENUM_VGRID_LEG leg)
{
   if(!VirtualGridUsePerLegLotTpParams)
      return VirtualGridLotSize;
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridL1BuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridL1SellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridL1SellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridL1BuyBelow;
   }
   return VirtualGridLotSize;
}

ENUM_LOT_SCALE VirtualGridResolvedScale(const ENUM_VGRID_LEG leg)
{
   if(!VirtualGridUsePerLegLotTpParams)
      return VirtualGridLotScale;
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridScaleBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridScaleSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridScaleSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridScaleBuyBelow;
   }
   return VirtualGridLotScale;
}

double VirtualGridResolvedAddRaw(const ENUM_VGRID_LEG leg)
{
   if(!VirtualGridUsePerLegLotTpParams)
      return VirtualGridLotAdd;
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridLotAddBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridLotAddSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridLotAddSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridLotAddBuyBelow;
   }
   return VirtualGridLotAdd;
}

double VirtualGridResolvedMult(const ENUM_VGRID_LEG leg)
{
   if(!VirtualGridUsePerLegLotTpParams)
      return VirtualGridLotMult;
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridLotMultBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridLotMultSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridLotMultSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridLotMultBuyBelow;
   }
   return VirtualGridLotMult;
}

double VirtualGridResolvedMaxLot(const ENUM_VGRID_LEG leg)
{
   if(!VirtualGridUsePerLegLotTpParams)
      return VirtualGridMaxLot;
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridMaxLotBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridMaxLotSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridMaxLotSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridMaxLotBuyBelow;
   }
   return VirtualGridMaxLot;
}

bool VirtualGridResolvedTpAtNextLevel(const ENUM_VGRID_LEG leg)
{
   if(!VirtualGridUsePerLegLotTpParams)
      return VirtualGridTakeProfitAtNextLevel;
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridTpNextBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridTpNextSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridTpNextSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridTpNextBuyBelow;
   }
   return VirtualGridTakeProfitAtNextLevel;
}

double VirtualGridResolvedTpPips(const ENUM_VGRID_LEG leg)
{
   if(!VirtualGridUsePerLegLotTpParams)
      return VirtualGridTakeProfitPips;
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridTpPipsBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridTpPipsSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridTpPipsSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridTpPipsBuyBelow;
   }
   return VirtualGridTakeProfitPips;
}

//+------------------------------------------------------------------+
//| Lot bậc 1 sau scale vốn (nhóm 5).                                 |
//+------------------------------------------------------------------+
double GetBaseLotForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return VirtualGridResolvedL1(leg) * GetCapitalScaleMultiplier();
}

double GetLotMultForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return VirtualGridResolvedMult(leg);
}

double GetLotAddForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   double add = MathMax(0.0, VirtualGridResolvedAddRaw(leg));
   if(EnableCapitalBasedScaling)
      add *= GetCapitalScaleMultiplier();
   return add;
}

ENUM_LOT_SCALE GetLotScaleForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return VirtualGridResolvedScale(leg);
}

double GetTakeProfitPipsForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return VirtualGridResolvedTpPips(leg);
}

//+------------------------------------------------------------------+
//| LOT theo chân: L1; cộng/hình học theo |bậc|.                       |
//+------------------------------------------------------------------+
double GetLotForVirtualGridLeg(const ENUM_VGRID_LEG leg, const int absLevelRaw)
{
   const int absLevel = MathAbs(absLevelRaw);
   const double baseLot = GetBaseLotForVirtualGridLeg(leg);
   const ENUM_LOT_SCALE scale = GetLotScaleForVirtualGridLeg(leg);
   double lot = baseLot;
   if(absLevel <= 1 || scale == LOT_FIXED)
      lot = baseLot;
   else if(scale == LOT_ARITHMETIC)
      lot = baseLot + (double)(absLevel - 1) * GetLotAddForVirtualGridLeg(leg);
   else if(scale == LOT_GEOMETRIC)
      lot = baseLot * MathPow(GetLotMultForVirtualGridLeg(leg), absLevel - 1);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double cap = VirtualGridResolvedMaxLot(leg);
   if(cap > 0.0)
      maxLot = MathMin(maxLot, cap);
   const double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot)
      lot = minLot;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Buy trên gốc (+): BUY STOP / BUY LIMIT tại bậc dương.             |
//+------------------------------------------------------------------+
double GetLotBuyAboveBaseForLevel(const int absLevel)
{
   return GetLotForVirtualGridLeg(VGRID_LEG_BUY_ABOVE, absLevel);
}

//+------------------------------------------------------------------+
//| Sell dưới gốc (-): SELL STOP.                                     |
//+------------------------------------------------------------------+
double GetLotSellBelowBaseForLevel(const int absLevel)
{
   return GetLotForVirtualGridLeg(VGRID_LEG_SELL_BELOW, absLevel);
}

//+------------------------------------------------------------------+
//| Sell trên gốc (+): SELL LIMIT.                                    |
//+------------------------------------------------------------------+
double GetLotSellAboveBaseForLevel(const int absLevel)
{
   return GetLotForVirtualGridLeg(VGRID_LEG_SELL_ABOVE, absLevel);
}

//+------------------------------------------------------------------+
//| Buy dưới gốc (-): BUY LIMIT.                                      |
//+------------------------------------------------------------------+
double GetLotBuyBelowBaseForLevel(const int absLevel)
{
   return GetLotForVirtualGridLeg(VGRID_LEG_BUY_BELOW, absLevel);
}

//+------------------------------------------------------------------+
//| Gọi khi đặt chờ ảo: map (loại lệnh, bậc có dấu) → chân.          |
//+------------------------------------------------------------------+
double GetLotForLevel(const ENUM_ORDER_TYPE orderType, const int levelNum)
{
   if(orderType != ORDER_TYPE_BUY_LIMIT && orderType != ORDER_TYPE_SELL_LIMIT && orderType != ORDER_TYPE_BUY_STOP && orderType != ORDER_TYPE_SELL_STOP)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const ENUM_VGRID_LEG leg = VirtualGridLegFromOrder(orderType, levelNum);
   return GetLotForVirtualGridLeg(leg, MathAbs(levelNum));
}

//+------------------------------------------------------------------+
//| Buy: +1→+2; -1→+1 (bậc trên gốc); -k (k≥2)→-(k-1).                |
//| Sell: +1→-1 (bậc dưới gốc); +k (k≥2)→+(k-1); -k→-(k+1).           |
//+------------------------------------------------------------------+
bool GridNeighborTakeProfitPrice(ENUM_ORDER_TYPE orderType, int signedLevelNum, double &tpOut)
{
   tpOut = 0.0;
   if(basePrice <= 0.0)
      return false;
   int n = ArraySize(gridLevels);
   if(n < 1)
      return false;
   bool isBuy = (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_LIMIT);

   if(isBuy)
   {
      if(signedLevelNum > 0)
      {
         if(signedLevelNum >= MaxGridLevels)
            return false;
         int idx = signedLevelNum;
         if(idx < 0 || idx >= n)
            return false;
         tpOut = NormalizeDouble(gridLevels[idx], dgt);
         return true;
      }
      if(signedLevelNum < 0)
      {
         int k = -signedLevelNum;
         if(k == 1)
         {
            if(MaxGridLevels < 1 || n < 1)
               return false;
            tpOut = NormalizeDouble(gridLevels[0], dgt);   // +1 (trên gốc), không TP tại gốc
            return true;
         }
         if(k > MaxGridLevels)
            return false;
         int idx = MaxGridLevels + k - 2;
         if(idx < MaxGridLevels || idx >= n)
            return false;
         tpOut = NormalizeDouble(gridLevels[idx], dgt);
         return true;
      }
   }
   else
   {
      if(signedLevelNum > 0)
      {
         if(signedLevelNum == 1)
         {
            if(MaxGridLevels < 1 || n <= MaxGridLevels)
               return false;
            tpOut = NormalizeDouble(gridLevels[MaxGridLevels], dgt);   // -1 (dưới gốc), không TP tại gốc
            return true;
         }
         int idx = signedLevelNum - 2;
         if(idx < 0 || idx >= MaxGridLevels)
            return false;
         tpOut = NormalizeDouble(gridLevels[idx], dgt);
         return true;
      }
      if(signedLevelNum < 0)
      {
         int k = -signedLevelNum;
         if(k >= MaxGridLevels)
            return false;
         int idx = MaxGridLevels + k;
         if(idx < 0 || idx >= n)
            return false;
         tpOut = NormalizeDouble(gridLevels[idx], dgt);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Giá TP tuyệt đối: ưu tiên mức lưới kế, không được thì pip (nếu >0).   |
//+------------------------------------------------------------------+
double ComputeVirtualTakeProfitPrice(ENUM_ORDER_TYPE orderType, double entryPrice, int signedLevelNum)
{
   const bool isBuy = (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_LIMIT);
   const ENUM_VGRID_LEG leg = VirtualGridLegFromLevelSide(isBuy, signedLevelNum);

   double tpGrid = 0.0;
   if(VirtualGridResolvedTpAtNextLevel(leg))
   {
      if(GridNeighborTakeProfitPrice(orderType, signedLevelNum, tpGrid))
      {
         if(isBuy && tpGrid > entryPrice)
            return tpGrid;
         if(!isBuy && tpGrid < entryPrice)
            return tpGrid;
      }
      return 0.0;
   }
   const double tpPips = GetTakeProfitPipsForVirtualGridLeg(leg);
   if(tpPips <= 0.0)
      return 0.0;
   if(isBuy)
      return NormalizeDouble(entryPrice + tpPips * pnt * 10.0, dgt);
   return NormalizeDouble(entryPrice - tpPips * pnt * 10.0, dgt);
}

//+------------------------------------------------------------------+
//| Nạp gridLevels. gridStep: thước dung sai (tắt AP = D; bật AP = D+A nếu A>0). |
//+------------------------------------------------------------------+
void InitializeGridLevels()
{
   VirtualPendingClear();
   OrderBalanceResetSideDwellState();
   // Current session = 0 and start counting from here (called when EA attached or EA auto reset)
   sessionStartTime = TimeCurrent();
   sessionStartBalance = GetTradingEquityViewUSD();
   g_gridBuiltOnceThisSession = false;
   double tevSess = GetTradingEquityViewUSD();
   sessionPeakTradingEquityView = tevSess;
   sessionMinTradingEquityView = tevSess;
   // attachBalance / initialCapitalBaselineUSD NOT updated here — mốc scale & % chỉ lúc OnInit
   double D = GridDistancePips * pnt * 10.0;
   double A = MathMax(0.0, GridArithmeticAddPips) * pnt * 10.0;
   if(EnableGridArithmeticSpacing)
      gridStep = (A > 0.0) ? (D + A) : D; // khoảng nhỏ nhất giữa hai bậc liền kề (+1↔+2) là D+A khi A>0
   else
      gridStep = D;
   int totalLevels = MaxGridLevels * 2;

   ArrayResize(gridLevels, totalLevels);

   for(int i = 0; i < totalLevels; i++)
      gridLevels[i] = GetGridLevelPrice(i);
   if(EnableGridArithmeticSpacing)
      Print("Initialized ", totalLevels, " levels: cấp số cộng D=", GridDistancePips, " pip, A=", GridArithmeticAddPips,
            " | +n: gốc + n*D + n(n-1)/2*A; bước k→k+1: D + k*A");
   else
      Print("Initialized ", totalLevels, " levels: ±1 at ", DoubleToString(0.5 * GridDistancePips, 1), " pip from base; step ", GridDistancePips, " pips between levels");

   InitBaseEmaVirtGapSnapshotFromGridInit();
}

//+------------------------------------------------------------------+
//| Manage grid: bậc ±1 gần gốc nhất; xa dần ±2,±3…                    |
//| Giá bậc: theo GetGridLevelPrice / cấp số cộng (input nhóm 1).      |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Per level: max 1 order per side (Buy/Sell) per magic. Remove duplicate virtual pendings. |
//+------------------------------------------------------------------+
void RemoveDuplicateOrdersAtLevel()
{
   double tolerance = gridStep * 0.5;
   if(gridStep <= 0) tolerance = pnt * 10.0 * GridDistancePips * 0.5;
   int nLevels = ArraySize(gridLevels);
   long magics[] = {MagicAA};
   bool enabled[] = {true};
   bool buySides[] = {true, false};
   for(int L = 0; L < nLevels; L++)
   {
      double priceLevel = gridLevels[L];
      for(int m = 0; m < 1; m++)
      {
         if(!enabled[m]) continue;
         long whichMagic = magics[m];
         for(int side = 0; side < 2; side++)
         {
            bool isBuy = buySides[side];
            int positionCount = 0;
            for(int i = 0; i < PositionsTotal(); i++)
            {
               ulong ticket = PositionGetTicket(i);
               if(ticket <= 0) continue;
               if(PositionGetInteger(POSITION_MAGIC) != whichMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) != isBuy) continue;
               if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - priceLevel) < tolerance)
                  positionCount++;
            }
            int idxList[];
            ArrayResize(idxList, 0);
            for(int i = 0; i < ArraySize(g_virtualPending); i++)
            {
               if(g_virtualPending[i].magic != whichMagic) continue;
               ENUM_ORDER_TYPE ot = g_virtualPending[i].orderType;
               bool orderBuy = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT);
               if(orderBuy != isBuy) continue;
               if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) >= tolerance) continue;
               int n = ArraySize(idxList);
               ArrayResize(idxList, n + 1);
               idxList[n] = i;
            }
            int keep = (positionCount >= 1) ? 0 : 1;
            if(ArraySize(idxList) <= keep) continue;
            for(int a = keep; a < ArraySize(idxList) - 1; a++)
               for(int b = a + 1; b < ArraySize(idxList); b++)
                  if(idxList[a] < idxList[b]) { int t = idxList[a]; idxList[a] = idxList[b]; idxList[b] = t; }
            for(int k = keep; k < ArraySize(idxList); k++)
               VirtualPendingRemoveAt(idxList[k]);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Mỗi bậc lưới: đúng 1 Buy + 1 Sell ảo (loại đổi theo giá vs mức).    |
//+------------------------------------------------------------------+
void ManageGridOrders()
{
   if(basePrice <= 0.0)
      return;
   if(g_compoundTotalProfitActive || g_compoundAfterClearWaitGrid)
      return;

   // Nếu tắt auto replenish: chỉ dựng chờ ảo đúng 1 lần sau khi đặt gốc (mỗi phiên).
   if(!EnableAutoReplenishVirtualOrders && g_gridBuiltOnceThisSession)
      return;

   CancelStopOrdersOutsideBaseZone();

   if(ArraySize(gridLevels) < MaxGridLevels + 1)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int n = ArraySize(gridLevels);
   for(int L = 0; L < n; L++)
   {
      double pl = gridLevels[L];
      int lvlNum = GridSignedLevelNumFromIndex(L);
      ENUM_ORDER_TYPE wantBuy, wantSell;
      GetVirtualPairForLevel(pl, bid, ask, wantBuy, wantSell);
      RemoveStaleVirtualTypesAtLevel(pl, wantBuy, wantSell, MagicAA);
      if(EnableBaseDirectionalMode)
      {
         if(lvlNum > 0)
         {
            // Above base: Buy only
            RemoveVirtualPendingsAtLevelSide(pl, false, MagicAA); // remove sell side at this level
            EnsureOrderAtLevel(wantBuy, pl, lvlNum);
         }
         else if(lvlNum < 0)
         {
            // Below base: Sell only
            RemoveVirtualPendingsAtLevelSide(pl, true, MagicAA);  // remove buy side at this level
            EnsureOrderAtLevel(wantSell, pl, lvlNum);
         }
         else
         {
            // No orders at base
            RemoveVirtualPendingsAtLevelSide(pl, true, MagicAA);
            RemoveVirtualPendingsAtLevelSide(pl, false, MagicAA);
         }
      }
      else
      {
         EnsureOrderAtLevel(wantBuy, pl, lvlNum);
         EnsureOrderAtLevel(wantSell, pl, lvlNum);
      }
   }
   RemoveDuplicateOrdersAtLevel();

   if(!EnableAutoReplenishVirtualOrders)
      g_gridBuiltOnceThisSession = true;
}

//+------------------------------------------------------------------+
//| Ensure order at level - add only when missing (no pending and no position of same type at level). |
//+------------------------------------------------------------------+
void EnsureOrderAtLevel(ENUM_ORDER_TYPE orderType, double priceLevel, int levelNum)
{
   bool isBuyOrder = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
   ulong  ticket       = 0;
   double existingPrice = 0.0;
   if(GetPendingOrderAtLevel(orderType, priceLevel, ticket, existingPrice, MagicAA))
   {
      double desiredPrice = NormalizeDouble(priceLevel, dgt);
      if(MathAbs(existingPrice - desiredPrice) > (pnt / 2.0))
         AdjustVirtualPendingToLevel(MagicAA, orderType, existingPrice, priceLevel, levelNum);
      return;
   }
   if(VirtualReplenishBlockedAfterExecution(priceLevel, orderType, MagicAA))
      return;
   if(EnableBaseDirectionalMode && VirtualRearmGateIsActive(priceLevel, isBuyOrder))
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(!IsDirectionalDistanceSatisfied(levelNum, isBuyOrder, bid, ask))
         return;
      VirtualRearmGateClear(priceLevel, isBuyOrder);
   }
   if(!CanPlaceOrderAtLevel(orderType, priceLevel, MagicAA))
      return;
   if(InitBaseEmaVirtGapSuppressesVirtual(orderType, priceLevel, levelNum))
      return;
   PlacePendingOrder(orderType, priceLevel, levelNum);
}

//+------------------------------------------------------------------+
//| Virtual pending at level: same type + magic (no broker pendings) |
//+------------------------------------------------------------------+
bool GetPendingOrderAtLevel(ENUM_ORDER_TYPE orderType,
                            double priceLevel,
                            ulong &ticket,
                            double &orderPrice,
                            long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return false;
   double tolerance = gridStep * 0.5;
   if(gridStep <= 0) tolerance = pnt * 10.0 * GridDistancePips * 0.5;
   ticket = 0;
   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(g_virtualPending[i].magic != whichMagic) continue;
      if(g_virtualPending[i].orderType != orderType) continue;
      if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) < tolerance)
      {
         orderPrice = g_virtualPending[i].priceLevel;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Adjust virtual pending price to a new grid                         |
//+------------------------------------------------------------------+
void AdjustVirtualPendingToLevel(long magic, ENUM_ORDER_TYPE orderType, double oldPrice, double priceLevel, int signedLevelNum)
{
   if(!IsOurMagic(magic)) return;
   int idx = VirtualPendingFindIndex(magic, orderType, oldPrice);
   if(idx < 0) return;
   double price = NormalizeDouble(priceLevel, dgt);
   if(InitBaseEmaVirtGapSuppressesVirtual(orderType, price, signedLevelNum))
   {
      VirtualPendingRemoveAt(idx);
      return;
   }
   double tp = ComputeVirtualTakeProfitPrice(orderType, price, signedLevelNum);
   g_virtualPending[idx].priceLevel = price;
   g_virtualPending[idx].tpPrice = tp;
   Print("VDualGrid adjust: ", EnumToString(orderType), " magic ", magic, " at ", price, " TP ", tp);
}

//+------------------------------------------------------------------+
//| Max 1 order per side per level per magic (virtual pending or open position). |
//+------------------------------------------------------------------+
bool CanPlaceOrderAtLevel(ENUM_ORDER_TYPE orderType, double priceLevel, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return false;
   double tolerance = gridStep * 0.5;
   if(gridStep <= 0) tolerance = pnt * 10.0 * GridDistancePips * 0.5;
   bool isBuyOrder = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
   int countSameLevel = 0;

   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(g_virtualPending[i].magic != whichMagic) continue;
      if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) >= tolerance) continue;
      bool orderBuy = (g_virtualPending[i].orderType == ORDER_TYPE_BUY_LIMIT || g_virtualPending[i].orderType == ORDER_TYPE_BUY_STOP);
      if(orderBuy == isBuyOrder)
         countSameLevel++;
   }
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != whichMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(posPrice - priceLevel) >= tolerance) continue;
      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((pt == POSITION_TYPE_BUY) == isBuyOrder)
         countSameLevel++;
   }
   return (countSameLevel < 1);   // Max 1 order (pending or position) per type per level
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Place pending order with TP; lot by grid level. SL set by trailing only |
//+------------------------------------------------------------------+
void PlacePendingOrder(ENUM_ORDER_TYPE orderType, double priceLevel, int levelNum)
{
   double price = NormalizeDouble(priceLevel, dgt);
   if(InitBaseEmaVirtGapSuppressesVirtual(orderType, price, levelNum))
      return;
   double lot   = GetLotForLevel(orderType, levelNum);
   double tp = ComputeVirtualTakeProfitPrice(orderType, price, levelNum);
   VirtualPendingAdd(MagicAA, orderType, price, levelNum, tp, lot);
   Print("VDualGrid: ", EnumToString(orderType), " at ", price, " lot ", lot, " (level ", levelNum > 0 ? "+" : "", levelNum, ")");
}

//+------------------------------------------------------------------+
