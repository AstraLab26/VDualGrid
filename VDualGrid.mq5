//+------------------------------------------------------------------+
//|                                                VDualGrid.mq5      |
//|     VDualGrid — chờ ảo full lưới, mỗi bậc Buy+Sell (1 magic)       |
//+------------------------------------------------------------------+
// Allow wrapper versions to reuse this file while overriding #property fields.
#ifndef VDUALGRID_SKIP_PROPERTIES
#property copyright "VDualGrid"
#property version   "4.25"
#property description "VDualGrid: lưới chờ ảo, gồng lãi/cân bằng. Nạp/rút không đổi mốc TEV trong code (tin có thể hiện số dư)."
#endif
#include <Trade\Trade.mqh>

#ifndef VDUALGRID_ENABLE_TELEGRAM
#define VDUALGRID_ENABLE_TELEGRAM
#endif

//+------------------------------------------------------------------+
//| Quy ước NẠP/RÚT (các nhóm input bên dưới — nạp/rút không đổi logic EA): |
//| — EA không đọc ACCOUNT_BALANCE sau khi gắn (trừ dòng hiện số dư thông báo nếu bật). |
//| — attachBalance = số dư ledger snapshot một lần lúc OnInit; nạp/rút không cập nhật. |
//| — initialCapitalBaselineUSD = TEV snapshot một lần lúc OnInit — mốc % P/L trong tin (reset phiên không đổi mốc). |
//| — P/L tích lũy chỉ từ deal BUY/SELL OUT cùng magic+symbol biểu đồ (bỏ deal balance). |
//| — Mọi quét vị thế/lệnh chờ/lịch sử: chỉ magic MagicNumber + _Symbol chart (không gộp magic khác). |
//| — Lưới/lot/TP: theo input.                                        |
//| — Thông báo/lịch: không đổi lưới/lot/ngưỡng.                      |
//+------------------------------------------------------------------+

//--- Kiểu tăng lot theo bậc lưới: 0=Cố định mọi bậc; 1=Cộng thêm mỗi bậc; 2=Nhân mỗi bậc.
enum ENUM_LOT_SCALE { LOT_FIXED = 0, LOT_ARITHMETIC = 1, LOT_GEOMETRIC = 2 };

// Bốn “chân” chờ ảo theo vị trí bậc so với gốc (+ trên / - dưới) và phía Buy/Sell.
enum ENUM_VGRID_LEG
{
   VGRID_LEG_BUY_ABOVE = 0,   // A: Bậc dương + Buy (BUY STOP / BUY LIMIT tại mức trên gốc)
   VGRID_LEG_SELL_BELOW = 1,  // B: Bậc âm + Sell (SELL STOP)
   VGRID_LEG_SELL_ABOVE = 2,  // C: Bậc dương + Sell (SELL LIMIT)
   VGRID_LEG_BUY_BELOW = 3,   // D: Bậc âm + Buy (BUY LIMIT)
   VGRID_LEG_BUY_ABOVE_E = 4, // E: Bậc dương + Buy (chạy song song độc lập với A)
   VGRID_LEG_SELL_BELOW_F = 5, // F: Bậc âm + Sell (chạy song song độc lập với B)
   VGRID_LEG_SELL_ABOVE_G = 6,  // G: Bậc dương + Sell (chạy song song độc lập với C)
   VGRID_LEG_BUY_BELOW_H = 7    // H: Bậc âm + Buy (chạy song song độc lập với D)
};

// 6b: kiểu tính tiến độ ngưỡng gồng lãi tổng.
enum ENUM_COMPOUND_TRIGGER_PROGRESS_MODE
{
   COMPOUND_PROGRESS_OPEN_SESSION_ONLY = 0,                 // Chỉ tổng lệnh mở trong phiên hiện tại
   COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_NEGATIVE = 1, // Tổng lệnh mở phiên + phần đóng âm phiên + phần đóng TP phiên
   COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_TOTAL = 2,    // Tổng lệnh mở phiên + toàn bộ lệnh đóng trong phiên (TP/SL/auto/tay)
   COMPOUND_PROGRESS_OPEN_EXCLUDE_POSITIVE_EF = 3           // Chỉ tổng lệnh mở phiên, nhưng không cộng phần lãi dương của chân E/F
};

// 6c2: kiểu lọc EMA cho cân bằng lệnh.
enum ENUM_ORDER_BALANCE_EMA_FILTER_MODE
{
   ORDER_BALANCE_EMA_CLOSE_ONLY = 0,    // Chỉ dùng EMA(Close)
   ORDER_BALANCE_EMA_HIGH_LOW_ONLY = 1  // Chỉ dùng EMA(High/Low)
};

input group "━━ 1) GRID ━━"
input double GridDistancePips = 2000.0;         // Bước lưới D (pip) từ bậc 2+
input double GridFirstLevelOffsetPips = 1000.0; // Khoảng cách bậc ±1 so với gốc (pip)
input int MaxGridLevels = 50;                   // Số bậc mỗi phía

input group "━━ 2) CHUNG (MAGIC/COMMENT) ━━"
input int MagicNumber = 123456;                 // Magic của EA
input string CommentOrder = "VPGrid";           // Comment lệnh market

input group "━━ 2D) LỌC GỐC-EMA CHO CHỜ ẢO ━━"
input bool   EnableInitBaseEmaVirtGapBlock = true; // Chặn chờ ảo Stop trong vùng Gốc-EMA đã chụp lúc init
input int    InitBaseEmaVirtGapEMAPeriod = 50;      // Chu kỳ EMA
input ENUM_TIMEFRAMES InitBaseEmaVirtGapEMATimeframe = PERIOD_M5; // Khung EMA

input group "━━ 2E) KHỞI ĐỘNG THEO EMA (FAST/SLOW HOẶC XẾP 3 ĐƯỜNG) ━━"
input bool   EnableStartupEmaFastSlowCross = true; // Chỉ đặt gốc khi EMA nhanh cắt EMA chậm (khi chưa có gốc; bị bỏ qua nếu bật xếp 3 EMA bên dưới)
input int    StartupEmaFastPeriod = 1;             // Chu kỳ EMA nhanh
input int    StartupEmaSlowPeriod = 50;            // Chu kỳ EMA chậm
input ENUM_TIMEFRAMES StartupEmaCrossTimeframe = PERIOD_M5; // Khung EMA dùng chung cho cắt nhanh/chậm, xếp 3 EMA và EMA(X) của lọc Open-EMA
input bool   EnableStartupThreeEmaOrdered = false; // Bật: chỉ đặt gốc khi EMA1>EMA2>EMA3 hoặc EMA1<EMA2<EMA3 (chu kỳ nhỏ→vừa→lớn; ưu tiên hơn cắt nhanh/chậm)
input int    StartupThreeEmaPeriod1 = 9;           // Chu kỳ EMA 1 (nhỏ nhất)
input int    StartupThreeEmaPeriod2 = 21;          // Chu kỳ EMA 2 (vừa)
input int    StartupThreeEmaPeriod3 = 50;          // Chu kỳ EMA 3 (lớn nhất)
input bool   EnableStartupThreeEmaCandleVsEma3 = true; // Bật: nến hiện tại phải cùng phía EMA3 theo chiều xếp EMA
input bool   EnableStartupOpenGapToEmaLimit = false; // Bật: chỉ đặt gốc khi |Open nến hiện tại - EMA(X)| <= ngưỡng pip
input int    StartupOpenGapToEmaPeriod = 50;       // Chu kỳ EMA(X) để đo khoảng cách Open nến hiện tại (dùng chung StartupEmaCrossTimeframe)
input double StartupOpenGapToEmaMaxPips = 50.0;    // Ngưỡng khoảng cách tối đa cho phép (pip)

input group "━━ 2F) KHỞI ĐỘNG THEO RSI ━━"
input bool   EnableStartupRsiBaseFilter = false;   // Chỉ đặt gốc khi RSI cắt mức (khi chưa có gốc)
input ENUM_TIMEFRAMES StartupRsiTimeframe = PERIOD_M5; // Khung RSI
input int    StartupRsiPeriod = 14;                // Chu kỳ RSI
input double StartupRsiAboveLevel = 70.0;          // Cắt lên mức X (đặt <0 để tắt)
input double StartupRsiBelowLevel = 30.0;          // Cắt xuống mức X1 (đặt <0 để tắt)
input int    StartupRsiCrossLookbackBars = 0;     // N nến đóng trước nến cắt (shift2…N+1): cắt lên → RSI đều < X; cắt xuống → đều > X1. 0 = chỉ cắt shift2→1 như cũ
input bool   EnableStartupRsiRecentTouchFilter = false; // Bật: phải có RSI cắt mức tại shift2→1, và trong X nến quá khứ có ít nhất 1 nến RSI > mức cắt lên hoặc RSI < mức cắt xuống
input int    StartupRsiRecentTouchBars = 10;      // X nến quá khứ để xét đã từng >X hoặc <X1 (>=1)

input group "━━ 2G) AUTO LOT BẬC 1 THEO GỐC-EMA ━━"
input bool   EnableAutoFirstLotByBaseEmaGap = false; // Nếu |Gốc-EMA| <= ngưỡng thì dùng lot bậc 1 auto
input int    AutoFirstLotByBaseEmaPeriod = 100;      // Chu kỳ EMA
input ENUM_TIMEFRAMES AutoFirstLotByBaseEmaTimeframe = PERIOD_M5; // Khung EMA
input double AutoFirstLotByBaseEmaMaxGapPips = 50.0; // Ngưỡng |Gốc-EMA| (pip)
input double AutoFirstLotByBaseEmaLot = 0.02;        // Lot bậc 1 auto

input group "━━ 2H) KHỞI ĐỘNG THEO ADX ━━"
input bool   EnableStartupAdxBaseFilter = false;   // Chỉ đặt gốc khi đủ điều kiện ADX trên X nến đóng (kết hợp 2E/2F); X1/X2 = tắt từng nhánh
input ENUM_TIMEFRAMES StartupAdxTimeframe = PERIOD_M5; // Khung ADX
input int    StartupAdxPeriod = 14;              // Chu kỳ ADX (period)
input int    StartupAdxBarsAboveLevel = 1;       // Số nến đóng gần nhất (shift 1→X): kiểm tra từng nến (≥1)
input double StartupAdxGreaterThanLevel = 20.0;  // X1: ADX > X1 trên mỗi nến; đặt ≤0 để tắt điều kiện này
input double StartupAdxLessThanLevel = 0.0;     // X2: ADX < X2 trên mỗi nến; đặt ≤0 để tắt điều kiện này

input group "━━ 2I) KHỞI ĐỘNG THEO X NẾN LIỀN KỀ CÙNG MÀU ━━"
input bool   EnableStartupThreeSameColorCandles = false; // Bật: X nến đóng liên tiếp cùng màu; nến đóng ngay trước chuỗi phải khác màu
input int    StartupSameColorConsecutiveCount = 3;       // X: số nến đóng liên tiếp cùng màu (shift1..X); 1..50 (ngoài khoảng bị giới hạn trong EA)
input ENUM_TIMEFRAMES StartupThreeSameColorCandlesTimeframe = PERIOD_M5; // Khung thời gian: X+1 nến đóng (shift1..X cùng màu, shift X+1 khác)

input group "━━ 2J) LỌC NẾN ĐÓNG TRƯỚC CHO CHỜ ẢO A-H (AND với 4a–4i) ━━"
input bool   EnableVirtualGridPrevClosedCandleDirectionFilter = false; // Bật: nến đóng shift1 chặn theo hướng. Mỗi chân vẫn phải Bật ở nhóm 4a–4i; công thức = (chân Bật) AND (nến cho phép hướng đó). Nếu cả 8 chân đều Bật: tăng chỉ Buy A,D,E,H; giảm chỉ Sell B,C,F,G. Bật đồng thời với lọc đóng vs EMA bên dưới → thêm: chỉ đặt gốc khi có ít nhất một chân thỏa cả hai lọc
input ENUM_TIMEFRAMES VirtualGridPrevClosedCandleTimeframe = PERIOD_CURRENT; // Khung nến đọc shift1 (PERIOD_CURRENT = khung chart EA)
input bool   EnableVirtualGridPrevClosedVsEmaSideFilter = false; // Bật: đóng shift1 vs EMA (cùng khung) — Close>EMA chỉ Buy ảo trên gốc (A,E); Close<EMA chỉ Sell ảo dưới gốc (B,F); Close=EMA không chặn thêm. AND với 4a–4i và lọc hướng nến 2J (nếu bật). Bật đồng thời lọc hướng nến → thêm: chỉ đặt gốc khi có ít nhất một chân thỏa cả hai lọc
input int    VirtualGridPrevClosedVsEmaPeriod = 50; // Chu kỳ EMA (≥1; giá đóng & EMA cùng nến shift1)

input group "━━ 4) CHỜ ẢO A-H (LOT/TP) ━━"

input group "━━ 4a. Buy A trên gốc (+) — lot / TP ━━"
input bool   EnableLegBuyAboveA = true; // Bật/tắt chân 4a: Buy A trên gốc
input double VGridL1BuyAbove = 0.01;
input ENUM_LOT_SCALE VGridScaleBuyAbove = LOT_ARITHMETIC;
input double VGridLotAddBuyAbove = 0.02;
input double VGridLotMultBuyAbove = 1.5;
input double VGridMaxLotBuyAbove = 3.0;
input bool   VGridTpNextBuyAbove = false;
input double VGridTpPipsBuyAbove = 0.0;

input group "━━ 4b. Sell B dưới gốc (-) — lot / TP ━━"
input bool   EnableLegSellBelowB = true; // Bật/tắt chân 4b: Sell B dưới gốc
input double VGridL1SellBelow = 0.01;
input ENUM_LOT_SCALE VGridScaleSellBelow = LOT_ARITHMETIC;
input double VGridLotAddSellBelow = 0.02;
input double VGridLotMultSellBelow = 1.5;
input double VGridMaxLotSellBelow = 3.0;
input bool   VGridTpNextSellBelow = false;
input double VGridTpPipsSellBelow = 0.0;

input group "━━ 4c. Sell C trên gốc (+) — lot / TP ━━"
input bool   EnableLegSellAboveC = true; // Bật/tắt chân 4c: Sell C trên gốc
input double VGridL1SellAbove = 0.01;
input ENUM_LOT_SCALE VGridScaleSellAbove = LOT_FIXED;
input double VGridLotAddSellAbove = 0.05;
input double VGridLotMultSellAbove = 1.5;
input double VGridMaxLotSellAbove = 3.0;
input bool   VGridTpNextSellAbove = true;
input double VGridTpPipsSellAbove = 0.0;

input group "━━ 4d. Buy D dưới gốc (-) — lot / TP ━━"
input bool   EnableLegBuyBelowD = true; // Bật/tắt chân 4d: Buy D dưới gốc
input double VGridL1BuyBelow = 0.01;
input ENUM_LOT_SCALE VGridScaleBuyBelow = LOT_FIXED;
input double VGridLotAddBuyBelow = 0.05;
input double VGridLotMultBuyBelow = 1.5;
input double VGridMaxLotBuyBelow = 3.0;
input bool   VGridTpNextBuyBelow = true;
input double VGridTpPipsBuyBelow = 0.0;

input group "━━ 4e. Buy E trên gốc (+) — lot / TP ━━"
input bool   EnableLegBuyAboveE = true; // Bật/tắt chân 4e: Buy E trên gốc
input double VGridL1BuyAboveE = 0.01;
input ENUM_LOT_SCALE VGridScaleBuyAboveE = LOT_ARITHMETIC;
input double VGridLotAddBuyAboveE = 0.02;
input double VGridLotMultBuyAboveE = 1.5;
input double VGridMaxLotBuyAboveE = 3.0;
input bool   VGridTpNextBuyAboveE = false;
input double VGridTpPipsBuyAboveE = 0.0;

input group "━━ 4f. Sell F dưới gốc (-) — lot / TP ━━"
input bool   EnableLegSellBelowF = true; // Bật/tắt chân 4f: Sell F dưới gốc
input double VGridL1SellBelowF = 0.01;
input ENUM_LOT_SCALE VGridScaleSellBelowF = LOT_ARITHMETIC;
input double VGridLotAddSellBelowF = 0.02;
input double VGridLotMultSellBelowF = 1.5;
input double VGridMaxLotSellBelowF = 3.0;
input bool   VGridTpNextSellBelowF = false;
input double VGridTpPipsSellBelowF = 0.0;

input group "━━ 4h. Sell G trên gốc (+) — lot / TP ━━"
input bool   EnableLegSellAboveG = true; // Bật/tắt chân 4h: Sell G trên gốc
input double VGridL1SellAboveG = 0.01;
input ENUM_LOT_SCALE VGridScaleSellAboveG = LOT_FIXED;
input double VGridLotAddSellAboveG = 0.05;
input double VGridLotMultSellAboveG = 1.5;
input double VGridMaxLotSellAboveG = 3.0;
input bool   VGridTpNextSellAboveG = true;
input double VGridTpPipsSellAboveG = 0.0;

input group "━━ 4i. Buy H dưới gốc (-) — lot / TP ━━"
input bool   EnableLegBuyBelowH = true; // Bật/tắt chân 4i: Buy H dưới gốc
input double VGridL1BuyBelowH = 0.01;
input ENUM_LOT_SCALE VGridScaleBuyBelowH = LOT_FIXED;
input double VGridLotAddBuyBelowH = 0.05;
input double VGridLotMultBuyBelowH = 1.5;
input double VGridMaxLotBuyBelowH = 3.0;
input bool   VGridTpNextBuyBelowH = true;
input double VGridTpPipsBuyBelowH = 0.0;

input group "━━ 4g. Buy E / Sell F — lot L1 khi P/L nổi âm đủ lớn (chờ ảo) ━━"
input bool   EnableEfFirstLotFromOpenFloatingLoss = false; // Bật: khi đủ float âm (+ tuỳ chọn carry X bên dưới) thì L1 E/F = lot cố định; không khớp → như 4e/4f; không sửa lệnh thực đã khớp
input double EfFloatingLossTriggerUsd = 3000.0; // Ngưỡng âm: tổng float ≤ −3000 (vd −3000, −3001 USD) → dùng lot L1 auto; đặt ≤0 = không áp công thức
input double EfFloatingLossFirstLot = 0.5;     // Lot bậc 1 E/F khi đã vượt ngưỡng (vd −3001 USD vẫn 0.5 nếu cài ngưỡng 3000); ≤0 = không áp
input bool   EnableEfFloatingLossGateByCompoundCarry = false; // Bật: thêm điều kiện carry 6c (phần cộng vào ngưỡng gồng 6b) ≥ X USD
input double EfFloatingLossMinCompoundCarryUsd = 0.0; // X (USD): GetCompoundCarryContributionUsd() phải ≥ giá trị này; chỉ kiểm khi bật gate phía trên và X > 0
input double EfFloatingLossCarryMatchedFirstLot = 0.0; // x lot L1 EF khi gate carry (X USD) được thỏa; đặt ≤0 → dùng chung Lot bên float (FirstLot ngay trên)

input group "━━ 6B1) GỒNG LÃI TỔNG STOP ━━"
input bool   EnableCompoundTotalFloatingProfit = true; // Bật gồng lãi tổng 6b1 (Stop)
input ENUM_COMPOUND_TRIGGER_PROGRESS_MODE CompoundTriggerProgressMode = COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_TOTAL; // Kiểu tính tiến độ ngưỡng
input double CompoundTotalProfitTriggerUSD = 20.0; // Ngưỡng kích hoạt (USD)
input bool   CompoundResetOnCommonSlHit = true; // Chạm SL chung thì reset

input group "━━ 6B2) GỒNG LÃI TỔNG LIMIT ━━"
input bool   EnableCompoundTotalFloatingProfitLimitReverse = false; // Bật gồng lãi tổng 6b2 (Limit ngược): trên gốc chọn Sell dương nhỏ nhất, dưới gốc chọn Buy dương nhỏ nhất
input ENUM_COMPOUND_TRIGGER_PROGRESS_MODE CompoundLimitReverseTriggerProgressMode = COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_TOTAL; // Kiểu tính tiến độ ngưỡng cho mode ngược (mirror 6b)
input double CompoundTotalProfitLimitReverseTriggerUSD = 20.0; // Ngưỡng X (USD) cho mode ngược
input bool   CompoundLimitReverseResetOnCommonSlHit = true; // Chạm SL chung thì reset (mode ngược)

input group "━━ 6C) CÂN BẰNG LỆNH ━━"
input bool   EnableOrderBalanceMode = true;        // Bật cân bằng lệnh 6c
input group "━━ 6C1) ĐIỀU KIỆN CƠ BẢN ━━"
input int    OrderBalanceMinGridStepsFromBase = 5; // Giá cách gốc tối thiểu (số bậc)
input int    OrderBalanceMinMinutesOnSideOfBase = 30; // Thời gian cùng phía gốc tối thiểu (phút)
input int    OrderBalanceMinOrderCountGap = 1;     // Lệch số lệnh tối thiểu hai phía
input int    OrderBalanceCooldownSeconds = 60;     // Thời gian chờ giữa 2 lần cân bằng (giây)
input group "━━ 6C2) LỌC EMA HIGH/LOW/CLOSE ━━"
input bool   EnableOrderBalanceEMAFilter = true;  // Bật lọc EMA cho hướng đóng
input ENUM_ORDER_BALANCE_EMA_FILTER_MODE OrderBalanceEMAFilterMode = ORDER_BALANCE_EMA_HIGH_LOW_ONLY; // Chọn kiểu lọc: EMA Close hoặc EMA High/Low
input int    OrderBalanceEMAPeriod = 50;           // Chu kỳ EMA
input ENUM_TIMEFRAMES OrderBalanceEMATimeframe = PERIOD_M5; // Khung EMA
input int    OrderBalanceEMAHighConfirmBars = 10;  // X1: nến close>EMA(High) cho nhánh đóng dưới gốc
input int    OrderBalanceEMALowConfirmBars = 10;   // X2: nến close<EMA(Low) cho nhánh đóng trên gốc
input int    OrderBalanceEMACloseConfirmBars = 10; // X3: số nến xác nhận EMA(Close)
input group "━━ 6C3) LỌC EMA FAST/SLOW (TÙY CHỌN) ━━"
input bool   EnableOrderBalanceFastSlowFilter = false; // Bật lọc EMA nhanh/chậm
input int    OrderBalanceFastEMAPeriod = 9;       // Chu kỳ EMA nhanh
input int    OrderBalanceSlowEMAPeriod = 21;      // Chu kỳ EMA chậm
input ENUM_TIMEFRAMES OrderBalanceFastSlowTimeframe = PERIOD_M5; // Khung EMA nhanh/chậm
input group "━━ 6C4) LỌC RSI (TÙY CHỌN) ━━"
input bool   EnableOrderBalanceRSIFilter = false; // Bật lọc RSI
input ENUM_TIMEFRAMES OrderBalanceRSITimeframe = PERIOD_M5; // Khung RSI
input int    OrderBalanceRSIPeriod = 14;          // Chu kỳ RSI
input double OrderBalanceRSIGreaterLevel = 70.0;  // RSI > mức thì cho nhánh đóng dưới gốc (đặt <0 để tắt)
input double OrderBalanceRSILessLevel = 30.0;     // RSI < mức thì cho nhánh đóng trên gốc (đặt <0 để tắt)
input group "━━ 6C5) CÁCH ĐÓNG LỆNH ━━"
input bool   EnableOrderBalanceCloseBothSidesPaired = false; // Thêm: đóng toàn bộ lệnh cùng phía với giá (Buy trên gốc hoặc Sell dưới gốc) từ bậc 1 → bậc |±N| xa nhất trong các lệnh yếu vừa đóng
input group "━━ 6C6) GIỚI HẠN CARRY 6C -> 6B ━━"
input bool   EnableOrderBalanceCarryCapPerSession = false; // Bật trần carry mỗi phiên
input double OrderBalanceCarryCapPerSessionUSD = 2000.0;   // Trần carry mỗi phiên (USD)
input group "━━ 6C7) CARRY: CHỈ ÂM HOẶC ÂM+RỒI CẢ DƯƠNG ━━"
input bool   EnableOrderBalanceCarryFullPnLAfterNegUsdAccum = false; // Bật: carry hiện tại > X thì carry tính cả lệnh đóng dương; carry <= X thì chỉ tính lệnh đóng âm
input double OrderBalanceCarryFullPnLAfterNegativeUsdAccum = 2000.0; // Ngưỡng X (USD) áp trên carry hiện tại; <=0 hoặc tắt 6C7 = chỉ đóng âm như cũ

input group "━━ 6D) RESET THEO ĐIỀU KIỆN PHIÊN (chỉ khi chưa bật 6b: không trailing / không treo ARM / không chờ bước sau kích hoạt) ━━"
input bool   EnableSessionDistanceAndTotalProfitReset = false; // Reset khi đạt xa gốc + lãi mở
input double SessionDistanceResetPips = 500.0; // Xa gốc tối thiểu (pip)
input double SessionTotalProfitResetUSD = 100.0; // Lãi mở tối thiểu (USD)
input bool   EnableSessionResetRequireOrderBalanceNegative = false; // Yêu cầu đã có âm tích lũy 6c
input double SessionOrderBalanceNegativeTriggerUSD = 1000.0; // Ngưỡng âm tích lũy 6c (USD)
input bool   EnableResetWhenReachPrevSessionPeak = false; // Reset khi đạt mốc đỉnh lãi phiên trước
input bool   EnableSessionOpenPlusClosedProfitReset = false; // Reset khi (mở+đóng) đạt ngưỡng
input double SessionOpenPlusClosedProfitResetUSD = 1000.0; // Ngưỡng (mở+đóng) (USD)
input bool   EnableSessionPlAndTotalOpenLotsReset = false; // Reset khi P/L phiên (đã đóng + đang mở) đạt ngưỡng + Σ lot (deal OUT trong phiên + vị thế đang mở) = X
input double SessionPlLotsResetThresholdUsd = 500.0;       // Ngưỡng P/L (USD): cơ sở = Σ(deal đóng OUT trong phiên) + Σ(profit+swap vị thế mở); dương ≥; âm ≤; 0 = tắt nhánh P/L
input double SessionPlLotsResetTotalOpenLots = 1.50;       // Tổng lot mục tiêu: Σ VOL deal OUT trong phiên + Σ lot vị thế đang mở (cùng lọc phiên; khớp SYMBOL_VOLUME_STEP)
input bool   EnableSessionNegativePlHardStopReset = false; // SL phiên: chạm ngưỡng âm → reset; |âm| phiên cộng vào carry → ngưỡng gồng lãi tổng phiên sau = CompoundTotalProfitTriggerUSD + carry (xem HUD)
input double SessionNegativePlHardStopUsd = 300.0;       // X dương: P/L phiên <= -X thì reset. Ví dụ thực tế -2000 USD → carry +2000 USD vào ngưỡng gồng (cộng thêm vào input ngưỡng). 0=tắt
input bool   EnableSessionCarryExceededReset = false;   // Từ đầu phiên: carry phiên đạt ≥ X → chỉ reset EA; gồng lãi tổng vẫn chỉ từ carry tổng (cộng dồn)
input double SessionCarryExceededResetUsd = 5000.0;       // Ngưỡng carry phiên (USD, >0) để reset EA; 0=tắt. Không cộng hai lần vào gồng — carry tổng đã gồm phần trong phiên
input bool   ResetCarrySessionNegativeAsOneBucket = true; // Bật: khi reset phiên, carry += max(0,−(P/L phiên mở+đóng)); Tắt: += max(0,−đóng)+max(0,−treo) (hai nhánh không triệt tiêu)
input double ResetCarryMinSessionNegativeUsd = 0.0;       // >0: chỉ cộng phần carry trên khi P/L phiên (mở+đóng) ≤ −X USD; 0 = mọi mức âm đều xét theo bucket trên

input bool   EnableResetWhenPriceOutsideTopBottomGrid = false; // Giá ra ngoài biên ±Max bậc tính từ gốc (Bid > gốc+offset(+Max) hoặc Ask < gốc+offset(−Max); cùng FirstOffset+D như lưới, kể cả khi EA không đặt chờ ảo một phía) → reset EA; carry theo nhóm Reset carry… (tổng P/L phiên = mở thô+đóng, âm bao nhiêu USD thì cộng vào carry)
input bool   EnableResetWhenVirtualOnlyWrongSideOfPriceVsBase = false; // Chỉ chờ ảo một phía gốc, không vị thế, không lệnh chờ broker EA; giá ngược gốc (theo **đóng nến** khung bên dưới) → reset; carry như reset ngoài lưới
input ENUM_TIMEFRAMES ResetWhenVirtualWrongSideConfirmBarTimeframe = PERIOD_CURRENT; // Khung xác nhận đóng nến (PERIOD_CURRENT = khung chart EA). Reset chỉ khi nến vừa đóng (shift=1) thỏa giá vs gốc
input int    ResetWhenVirtualWrongSideMinGridLevelsFromBase = 0; // ≥1: giá hiện tại (Bid phía dưới gốc / Ask phía trên gốc) phải cách gốc ít nhất X bậc theo FirstOffset+D; 0 = không kiểm tra

input bool   EnableResetWhenNoOpenPosMinGridAndOutsidePrevBody = false; // Bật: reset EA (gốc/lưới/chờ ảo) khi không vị thế mở + max(|Bid−gốc|,|Ask−gốc|) ≥ X bậc + mid ngoài thân nến đóng trước; carry tổng không đổi
input int    ResetWhenNoOpenPosMinGridLevelsFromBase = 3;       // X bậc (FirstOffset+D như lưới); ≥1 mới kiểm tra xa gốc; 0 = bỏ qua điều kiện khoảng cách
input ENUM_TIMEFRAMES ResetWhenNoOpenPosPrevCandleBodyTimeframe = PERIOD_CURRENT; // Khung nến trước = nến đóng shift 1; PERIOD_CURRENT = khung chart EA

input group "━━ 8A) LỊCH CHẠY THEO GIỜ (GIỜ SERVER SÀN — TimeCurrent) ━━"
input bool   EnableRunTimeWindow = false;      // Chỉ chạy trong khung giờ (so với giờ server broker, không phải giờ máy tính)
input int    RunStartHour = 1;                 // Giờ bắt đầu (0–23, server)
input int    RunStartMinute = 0;               // Phút bắt đầu (0–59, server)
input int    RunEndHour = 16;                  // Giờ kết thúc (0–23, server)
input int    RunEndMinute = 0;                 // Phút kết thúc (0–59, server)
input int    StartupRestartDelayMinutes = 0;   // Delay trước khi cho đặt gốc mới (phút, đếm theo TimeCurrent server)

input group "━━ 8A2) MỐC 1 — TRÌ HOÃN ĐẶT CHỜ ẢO SAU GỐC ━━"
input bool   EnableDeferVirtualPendingAfterBase = false; // (1) Bật: trì hoãn đặt chờ ảo sau gốc tới khi đủ các điều kiện đang dùng (0 phút / 0 pip = tắt điều kiện đó; cả hai =0 → không trì hoãn)
input int    DeferVirtualPendingDelayMinutes = 0;        // (2) Phút chờ sau khi đặt gốc rồi mới được xét chờ ảo (≥0; 0 = không chờ theo thời gian)
input double DeferVirtualPendingMinDistanceFromBasePips = 10.0; // (3) Khoảng cách tối đa X pip: max(|Bid−gốc|,|Ask−gốc|)/pip ≤ X mới đủ; 0 = không kiểm tra khoảng cách

input group "━━ 8A3) MỐC 2 — ĐỔI GỐC NẾU CHƯA ĐẶT CHỜ ẢO ━━"
input bool EnableRebaseIfNoVirtualExecWithinMinutes = false; // Bật: từ lúc có đường gốc đếm X phút — có chờ ảo thì bỏ đếm; hết X phút chưa có chờ ảo → reset như reset phiên (delay khởi động/lịch/8D/EMA…), chờ đặt gốc mới
input int  RebaseIfNoVirtualExecWithinMinutes = 30;          // Số phút từ lúc đặt gốc (0 = tắt). Có vị thế mở phiên hiện tại: gia hạn thêm X phút, không đổi gốc

input group "━━ 8B) LỊCH CHẠY THEO NGÀY (NGÀY SERVER SÀN — TimeCurrent) ━━"
input bool EnableRunDayFilter = false;         // Bật lọc ngày chạy
input bool RunOnMonday    = true;              // Thứ 2
input bool RunOnTuesday   = true;              // Thứ 3
input bool RunOnWednesday = true;              // Thứ 4
input bool RunOnThursday  = true;              // Thứ 5
input bool RunOnFriday    = true;              // Thứ 6
input bool RunOnSaturday  = true;              // Thứ 7
input bool RunOnSunday    = true;              // Chủ nhật

input group "━━ 8C) TRÁNH TIN USD HIGH IMPACT ━━"
input bool EnableAvoidUsdHighImpactNews = false; // Hôm nay hoặc ngày mai có tin USD mức cao thì chặn phiên mới

input group "━━ 8D) TẠM DỪNG THEO LỢI NHUẬN NGÀY (CỘNG DỒN PHIÊN) ━━"
input bool   EnableDailyProfitPauseAfterReset = false; // Bật: mỗi ngày server, chừng chưa đạt ngưỡng thì lãi đóng cộng dồn sang phiên sau trong cùng ngày; đạt ngưỡng → dừng hết ngày đó; sang ngày server mới → đếm lại từ 0 (không cộng dồn qua ngày)
input double DailyProfitPauseThresholdUSD = 1000.0;    // Ngưỡng tổng lãi đã đóng trong ngày server (USD), magic+symbol chart

input group "━━ 9) THÔNG BÁO ━━"
input bool EnableResetNotification = true;     // Gửi thông báo MT5
input bool EnableTelegram = true;              // Gửi Telegram
input bool TelegramDeletePreviousBotMessagesOnNotify = false; // Xóa tin bot cũ trước khi gửi tin mới
input string TelegramBotToken = "";            // Telegram bot token
input string TelegramChatID = "";              // Telegram chat id

// Cấu hình Telegram nâng cao giữ nguyên mặc định, không cho chỉnh bằng input.
bool EnableTelegramResetNotification = true;
bool EnableTelegramStartupScreenshot = true;
int  TelegramScreenshotWidth = 1280;
int  TelegramScreenshotHeight = 720;

input group "━━ 10) PANEL BIỂU ĐỒ ━━"
input bool   EnableMonthlyProfitPanel = false;       // Hiện panel lợi nhuận tháng
input bool   EnableBaseLineAndEaStartMarker = true;  // Hiện đường gốc + mốc thời gian bắt đầu EA

//--- Global variables
CTrade trade;
double pnt;
int dgt;
double basePrice;                               // Base price (base line)
double gridLevels[];                            // Giá từng mức (khoảng đều theo D)
double gridStep;                                // Bước tham chiếu (price): dung sai / khớp mức; khởi tạo trong InitializeGridLevels
double lastTickBid = 0.0;
double lastTickAsk = 0.0;
double attachBalance = 0.0;                    // Số dư ledger lúc gắn EA — không cập nhật khi nạp/rút; thành phần trong TEV
double initialCapitalBaselineUSD = 0.0;        // TEV một lần lúc OnInit — mốc % trong tin (không đổi mỗi reset phiên)
datetime eaAttachTime = 0;                     // OnInit time: chỉ cộng deal OUT vào eaCumulativeTradingPL khi deal >= thời điểm này
double eaCumulativeTradingPL = 0.0;            // Tổng (profit+swap+comm) deal OUT cùng magic symbol từ lúc gắn EA — không nạp/rút
double sessionPeakTradingEquityView = 0.0;   // Cao nhất (attachBalance + eaCumulativeTradingPL + float magic) trong phiên lưới
double sessionMinTradingEquityView = 0.0;     // Thấp nhất — cùng công thức; không tính nạp/rút
double g_sessionPeakClosedCapitalUsd = 0.0;      // Đỉnh vốn đã đóng trong phiên hiện tại (không tính lệnh thả nổi)
double g_sessionStartClosedCapitalUsd = 0.0;     // Vốn đã đóng tại đầu phiên hiện tại
double g_prevSessionPeakClosedProfitUsd = 0.0;   // Đỉnh lãi đã đóng của phiên trước (so với đầu phiên trước), dùng làm mốc reset
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
datetime g_startupDelayUntil = 0;             // Mốc thời gian kết thúc delay khởi động lại EA
bool g_startupDelayLogged = false;            // Tránh log lặp lại mỗi tick khi đang delay
datetime g_deferredVirtualGridOrdersAllowedAfter = 0; // 8A2: nếu chờ phút>0 thì TimeCurrent phải ≥ mốc này trước khi xét pip (nếu pip bật)
bool     g_deferVirtualPendingGateActive = false; // 8A2: true = đang trì hoãn chờ ảo tới khi đủ điều kiện đang bật (phút/pip) hoặc bị hủy gồng/cân bằng
bool     g_deferVirtReleaseLogged = false;   // 8A2: log một lần khi bắt đầu đặt chờ ảo sau trì hoãn
bool     g_noVirtExecHadSuccessfulTrigger = false; // 8A3: đã đặt chờ ảo hoặc chờ ảo đã khớp market — không còn theo dõi hết giờ
datetime g_noVirtExecDeadline = 0;           // 8A3: mốc hết hạn (từ lúc đặt gốc + X phút); 0 = không đếm
datetime g_resetVwSideLastConfirmBarTime = 0; // Reset “chờ ảo ngược giá/gốc”: iTime khung xác nhận shift0 lần trước; 0 = chưa đồng bộ
bool g_compoundTotalProfitActive = false;     // Chế độ gồng lãi tổng (nhóm 6b): SL chung, không nạp chờ ảo, SL trượt
bool g_compoundBuyBasketMode = false;         // true = giá Bid≥gốc: giữ BUY, SL chung buy; false = dưới gốc: giữ SELL
double g_compoundCommonSlLine = 0.0;          // Giá SL chung (0 = chưa đặt bước đầu); Buy: SL dưới giá; Sell: SL trên giá
bool g_compoundAfterClearWaitGrid = false;    // Sau kích hoạt: chờ thêm 1 bước lưới có lợi rồi SL tại ref + đóng phía ngược
double g_compoundFrozenRefPx = 0.0;           // Tham chiếu khóa lúc kích hoạt (xóa chờ ảo)
bool g_compoundActivationBuyBasket = false;   // Hướng bước lưới có lợi khi chờ (Bid≥gốc = buy basket)
bool g_compoundArmed = false;                 // Đạt ngưỡng treo, chờ giá xác nhận (chưa đóng lệnh / chưa xóa chờ ảo)
bool g_compoundArmBuyBasket = false;          // Hướng chờ khi armed (đồng nghĩa buyBasket khi xác nhận)
bool g_compoundUseLimitReverseMode = false;   // true khi vòng đời ARM/chờ bước/active đang chạy theo mode limit ngược
double g_balanceCompoundCarryUsd = 0.0;       // Carry tổng: cộng dồn mọi biến động (theo phiên thực chất vào một số duy nhất); đóng góp GetCompoundFloatingTriggerThresholdUsd (input + carry, trần 6c). Gán: CompoundCarryUsdSetTotal.
double g_carryTotalUsdAtGridSessionStart = 0.0; // Mốc carry tổng lúc bắt đầu phiên lưới — carry phiên = carry tổng hiện tại − mốc; chỉ để điều kiện reset EA (6h), không cộng thêm vào gồng riêng
double g_compoundSessionClosedNegativeProfitSwapUsd = 0.0; // 6b: Σ phần đóng âm (profit+swap) các deal OUT trong phiên hiện tại (magic+symbol), không commission
double g_compoundSessionClosedTpProfitSwapUsd = 0.0;       // 6b: Σ(profit+swap) các deal OUT có DEAL_REASON_TP trong phiên hiện tại (magic+symbol), không commission
double g_compoundSessionClosedTotalProfitSwapUsd = 0.0;    // 6b: Σ(profit+swap) toàn bộ deal OUT trong phiên hiện tại (magic+symbol), không commission
double g_compoundSessionClosedOutVolumeLots = 0.0;          // 6f: Σ khối lượng (lot) các deal OUT trong phiên hiện tại (cùng lọc thời gian phiên)
double g_sessionMaxAbsDistanceFromBasePips = 0.0;          // 6d: khoảng cách tuyệt đối lớn nhất giá (Bid/Ask) so với gốc trong phiên hiện tại
double g_orderBalanceSessionClosedNegativeUsd = 0.0;       // 6d: tổng âm tích lũy do nhánh cân bằng 6c đã đóng trong phiên (profit+swap, số âm)
datetime g_orderBalAboveSideSince = 0;        // 6c: Bid liên tục phía trên gốc (chưa xuống vùng cấm)
datetime g_orderBalBelowSideSince = 0;        // 6c: Bid liên tục phía dưới gốc
datetime g_orderBalLastExecTime = 0;          // 6c: cooldown sau lần đóng cân bằng
int    g_orderBalanceEmaHighHandle = INVALID_HANDLE; // iMA EMA(PRICE_HIGH) cho lọc EMA cân bằng (6c)
int    g_orderBalanceEmaLowHandle = INVALID_HANDLE;  // iMA EMA(PRICE_LOW) cho lọc EMA cân bằng (6c)
int    g_orderBalanceEmaCloseHandle = INVALID_HANDLE; // iMA EMA(PRICE_CLOSE) cho điều kiện nến đóng trên/dưới đường EMA trung bình (6c)
int    g_orderBalanceRsiHandle = INVALID_HANDLE; // iRSI khi bật lọc RSI cân bằng (6c)
int    g_orderBalanceFastEmaHandle = INVALID_HANDLE; // iMA EMA nhanh cho lọc nhanh/chậm cân bằng (6c)
int    g_orderBalanceSlowEmaHandle = INVALID_HANDLE; // iMA EMA chậm cho lọc nhanh/chậm cân bằng (6c)
int    g_initBaseEmaVirtGapHandle = INVALID_HANDLE; // iMA nhóm 2d: vùng cấm chờ ảo theo khoảng gốc−EMA lúc Init lưới
int    g_virtualGridPrevCloseEmaHandle = INVALID_HANDLE; // 2J: iMA — đóng shift1 vs EMA (chỉ Buy trên gốc / chỉ Sell dưới gốc)
bool   g_initBaseEmaVirtGapActive = false;    // 2d: vùng cấm theo gốc đã chụp; giữ cố định tới đổi gốc hoặc reset EA
double g_initBaseEmaVirtSnapBase = 0.0;       // 2d: gốc tại lúc chụp (đoạn gốc–EMA)
double g_initBaseEmaVirtSnapEma = 0.0;        // 2d: giá EMA tại lúc chụp (buffer shift 0)
bool   g_initBaseEmaVirtBaseAboveEma = false; // 2d: snapBase > snapEma
double g_initBaseEmaVirtGapPips = 0.0;        // 2d: |gốc−EMA| theo pip (10×point)
int    g_autoFirstLotByBaseEmaHandle = INVALID_HANDLE; // 2g: iMA cho auto lot bậc 1 theo khoảng gốc−EMA
bool   g_autoFirstLotSnapshotActive = false;   // 2g: đã chụp trạng thái cho base hiện tại
bool   g_autoFirstLotUsingOverride = false;    // 2g: true = dùng lot bậc 1 auto trong phiên hiện tại
double g_autoFirstLotSnapshotBase = 0.0;       // 2g: base đã chụp
double g_autoFirstLotSnapshotEma = 0.0;        // 2g: EMA tại lúc chụp
double g_autoFirstLotGapPips = 0.0;            // 2g: |base-ema| theo pip lúc chụp
int    g_startupEmaFastHandle = INVALID_HANDLE; // 2e: EMA nhanh — chỉ dùng khi chưa đặt gốc
int    g_startupEmaSlowHandle = INVALID_HANDLE; // 2e: EMA chậm
int    g_startupThreeEma1Handle = INVALID_HANDLE; // 2e: EMA chu kỳ nhỏ nhất (xếp 3 đường)
int    g_startupThreeEma2Handle = INVALID_HANDLE; // 2e: EMA chu kỳ vừa
int    g_startupThreeEma3Handle = INVALID_HANDLE; // 2e: EMA chu kỳ lớn nhất
int    g_startupOpenGapEmaHandle = INVALID_HANDLE; // 2e: EMA(X) để giới hạn khoảng cách Open nến hiện tại
int    g_startupRsiHandle = INVALID_HANDLE;     // 2f: RSI cho lọc khởi động đặt gốc
int    g_startupAdxHandle = INVALID_HANDLE;     // 2h: ADX cho lọc khởi động đặt gốc
string g_baseLineObjectName = "VPGrid_BaseLine";
#define VDGRID_EA_START_VLINE "VDG_EAStart_V"
#define VDGRID_EA_START_TEXT "VDG_EAStart_T"
datetime g_mpViewMonthStart = 0;               // 10: ngày 1 00:00:00 (server) của tháng đang xem trên panel
ulong    g_mpLastRedrawTick = 0;               // hạn chế vẽ lại panel (ms)
bool     g_mpPanelWasEnabled = false;          // tránh gọi DeleteAll lặp khi input tắt
bool     g_mpAutoFollowCurrentMonth = true;    // true: tự nhảy sang tháng hiện tại khi qua tháng mới (server)
datetime g_mpLastSeenServerMonthStart = 0;     // theo dõi mốc tháng server để reset panel khi sang tháng
bool     g_isOnInitBootstrap = false;          // true trong lúc OnInit để tránh gửi Telegram reset trùng với tin ảnh lúc vừa gắn EA
long     g_telegramNotifyMsgIds[];             // lưu message_id Telegram bot để tùy chọn xóa tin cũ
long     g_newsAvoidCachedDateKey = 0;         // cache theo ngày server cho tránh tin USD level 3
bool     g_newsAvoidHasUsdHighImpactToday = false;
long     g_newsAvoidLoggedBlockedDateKey = 0;  // tránh log lặp khi bị chặn bởi tin
long     g_newsAvoidLoggedCalendarErrDateKey = 0; // tránh log lỗi lịch lặp theo ngày
long     g_dailyProfitPauseDateKey = 0;        // ngày server đang bị khóa bởi chốt lời ngày (0 = không khóa)
long     g_dailyProfitPauseLoggedDateKey = 0;  // tránh log lặp khi đang khóa theo lợi nhuận ngày
//--- Sau khi chờ ảo khớp market: chặn bổ sung lại chờ ảo cùng phía/mức cho tới khi vị thế hiện hoặc hết hạn
#define VPGRID_VIRTUAL_EXEC_COOLDOWN_SEC 5
struct VirtualExecCooldownEntry
{
   double   priceLevel;
   bool     isBuy;
   ENUM_VGRID_LEG leg;
   datetime expireUtc;
};
VirtualExecCooldownEntry g_virtualExecCooldown[];

//--- Virtual pending: do not place broker pending orders; when price touches level -> Market + TP
struct VirtualPendingEntry
{
   long              magic;
   ENUM_ORDER_TYPE   orderType;
   ENUM_VGRID_LEG    leg;
   double            priceLevel;
   int               levelNum;
   double            tpPrice;
   double            lot;
};
VirtualPendingEntry g_virtualPending[];

void VirtualPendingClear();
void ManageGridOrders();
void CompoundResetAfterCommonSlHit();
void ResetAfterSessionDistanceAndTotalProfitHit(const double totalSessionProfitSwapUsd);
void ResetAfterSessionOpenPlusClosedProfitHit(const double totalSessionProfitSwapUsd);
void ResetAfterPrevSessionPeakReached(const double targetUsd, const double currentTevUsd);
void ResetAfterSessionPlAndTotalOpenLotsHit(const double totalSessionProfitSwapUsd,
                                            const double sessionOpenLotsSum, const double sessionClosedOutLotsSum);
void ResetAfterSessionNegativePlHardStopHit(const double totalSessionProfitSwapUsd);
void ResetAfterSessionCarryExceedsThresholdHit();
void ResetAfterPriceOutsideTopBottomGridHit(const double totalSessionProfitSwapUsd);
void ResetAfterVirtualPendingsWrongSideOfBaseHit(const double totalSessionProfitSwapUsd);
void ResetAfterNoOpenPosMinGridOutsidePrevBodyHit(const double totalSessionProfitSwapUsd);
bool PriceMidStrictlyOutsidePrevClosedBody(const ENUM_TIMEFRAMES candleTf, const double bid, const double ask);
double GridPriceTolerance();
void OrderBalanceResetSideDwellState();
double GetCompoundFloatingTriggerThresholdUsd();
double GetCompoundCarryContributionUsd();
void CompoundCarryUsdSetTotal(const double newTotalUsd);
double SessionLossCarryUsdForEaReset(const double sessionClosedProfitSwapUsd, const double sessionOpenProfitSwapUsd);
double ComputeSessionLossCarryUsdForReset(const double totalSessionProfitSwapUsd,
                                          const double snapClosedPnlSwap, const double snapOpenPnlSwap);
double GetCarryInSessionUsd(void);
void UpdateBaseLineOnChart();
void EaStartTimeObjectsApplyOrRemove();
bool OrderBalanceLastClosedVsEma(int &biasOut);
bool OrderBalanceFastSlowBias(int &biasOut);
bool OrderBalanceRsiPass(int &biasOut, double &rsiOut);
bool ProcessOrderBalanceMode();
bool IsVirtualGridLegEnabled(const ENUM_VGRID_LEG leg);
bool VirtualGridPrevClosedDualFiltersAllowBasePlacement();
void VirtualGridPrevClosedDualFilterMaybeLogWaitingForBase();
void InitBaseEmaVirtGapClearZone();
void InitBaseEmaVirtGapSnapshotFromGridInit();
bool InitBaseEmaVirtGapSuppressesVirtual(const ENUM_ORDER_TYPE orderType, const double priceLevel, const int signedLevelNum);
void InitBaseEmaVirtGapPurgeVirtualViolations();
void StartupEmaCrossReleaseHandles();
void StartupEmaCrossInitHandles();
bool StartupEmaFastSlowCrossShift0vs1();
bool StartupEmaAnyFilterWaiting();
bool StartupEmaBaseConditionPass();
bool StartupThreeEmaOrderedPassShift0();
bool StartupOpenGapToEmaPassShift0();
bool StartupThreeSameColorCandlesPass();
int  StartupSameColorConsecutiveBarsClamped();
bool StartupRsiPassForBase(double &rsiOut);
bool StartupAdxPassForBase(double &adxOut);
bool StartupRsiAndAdxPassForBase(double &rsiOut, double &adxOut);
string StartupRsiAdxWaitReasonPhrase();
datetime ServerDayStart(const datetime t);
long ServerDateKey(const datetime t);
bool HasUsdHighImpactNewsPauseWindow(const datetime nowSrv);
double GetTodayClosedProfitUsd(const datetime nowSrv);
bool IsDailyProfitPauseActiveNow(const datetime nowSrv);
bool EnsureDailyProfitPauseIfThresholdExceeded(const datetime nowSrv, const string reasonTag, const bool closeAllFirst);
bool TryPauseNewSessionAfterResetByDailyProfit(const string resetReasonTag);
void MonthlyProfitPanelDeleteAll();
void MonthlyProfitPanelRedrawIfNeeded(const bool force);
void MonthlyProfitPanelOnInitState();
void MonthlyProfitPanelOnTradeRefresh();
void CompoundFloatThrHudDeleteAll();
void CompoundFloatThrHudUpdate(const bool isEaGridReset);
void ArmStartupRestartDelay(const string reason);
bool IsStartupRestartDelayBlocking();
void ClearDeferVirtualPendingGate();
void NoVirtExecWatchDisarm();
bool NoVirtExecHasAnyOurVirtualPending();
bool NoVirtExecHasOpenSessionPosition();
void TryRebaseIfNoVirtualExecTimedOut();
void SendStartupTelegramScreenshot(const string reason);

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

string VirtualGridLegCode(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return "A";
      case VGRID_LEG_SELL_BELOW: return "B";
      case VGRID_LEG_SELL_ABOVE: return "C";
      case VGRID_LEG_BUY_BELOW: return "D";
      case VGRID_LEG_BUY_ABOVE_E: return "E";
      case VGRID_LEG_SELL_BELOW_F: return "F";
      case VGRID_LEG_SELL_ABOVE_G: return "G";
      case VGRID_LEG_BUY_BELOW_H: return "H";
   }
   return "A";
}

bool VirtualGridLegIsAboveBaseSide(const ENUM_VGRID_LEG leg)
{
   return (leg == VGRID_LEG_BUY_ABOVE || leg == VGRID_LEG_SELL_ABOVE
        || leg == VGRID_LEG_BUY_ABOVE_E || leg == VGRID_LEG_SELL_ABOVE_G);
}

void VirtualPendingCountOurMagicByBaseSide(int &aboveCount, int &belowCount)
{
   aboveCount = 0;
   belowCount = 0;
   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(!IsOurMagic(g_virtualPending[i].magic))
         continue;
      if(VirtualGridLegIsAboveBaseSide(g_virtualPending[i].leg))
         aboveCount++;
      else
         belowCount++;
   }
}

bool OurSymbolMagicHasAnyOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong t = PositionGetTicket(i);
      if(t > 0 && PositionIsOurSymbolAndMagic(t))
         return true;
   }
   return false;
}

bool OurSymbolMagicHasAnyBrokerPendingOrder()
{
   for(int i = 0; i < OrdersTotal(); i++)
   {
      const ulong t = OrderGetTicket(i);
      if(t > 0 && OrderIsOurSymbolAndMagic(t))
         return true;
   }
   return false;
}

string BuildOrderCommentWithLevel(const ENUM_VGRID_LEG leg, const int levelNum)
{
   return "VDualGrid|" + VirtualGridLegCode(leg) + "|L" + (levelNum > 0 ? "+" : "") + IntegerToString(levelNum);
}

bool TryParseLegFromOrderComment(const string cmt, ENUM_VGRID_LEG &legOut)
{
   if(StringFind(cmt, "|A|") >= 0) { legOut = VGRID_LEG_BUY_ABOVE; return true; }
   if(StringFind(cmt, "|B|") >= 0) { legOut = VGRID_LEG_SELL_BELOW; return true; }
   if(StringFind(cmt, "|C|") >= 0) { legOut = VGRID_LEG_SELL_ABOVE; return true; }
   if(StringFind(cmt, "|D|") >= 0) { legOut = VGRID_LEG_BUY_BELOW; return true; }
   if(StringFind(cmt, "|E|") >= 0) { legOut = VGRID_LEG_BUY_ABOVE_E; return true; }
   if(StringFind(cmt, "|F|") >= 0) { legOut = VGRID_LEG_SELL_BELOW_F; return true; }
   if(StringFind(cmt, "|G|") >= 0) { legOut = VGRID_LEG_SELL_ABOVE_G; return true; }
   if(StringFind(cmt, "|H|") >= 0) { legOut = VGRID_LEG_BUY_BELOW_H; return true; }
   return false;
}

bool TryParseSignedLevelFromOrderComment(const string cmt, int &signedLevelOut)
{
   signedLevelOut = 0;
   const int p = StringFind(cmt, "|L");
   if(p < 0)
      return false;
   const int s = p + 2;
   if(s >= StringLen(cmt))
      return false;
   string levelStr = StringSubstr(cmt, s);
   const int tailSep = StringFind(levelStr, "|");
   if(tailSep >= 0)
      levelStr = StringSubstr(levelStr, 0, tailSep);
   if(StringLen(levelStr) < 1)
      return false;
   signedLevelOut = (int)StringToInteger(levelStr);
   return (signedLevelOut != 0);
}

bool IsLegBuyAboveFamily(const ENUM_VGRID_LEG leg)
{
   return (leg == VGRID_LEG_BUY_ABOVE || leg == VGRID_LEG_BUY_ABOVE_E);
}

bool IsLegSellBelowFamily(const ENUM_VGRID_LEG leg)
{
   return (leg == VGRID_LEG_SELL_BELOW || leg == VGRID_LEG_SELL_BELOW_F);
}

// Chân vào lệnh Buy chờ ảo: A, D, E, H (còn B,C,F,G là Sell).
bool IsVirtualGridLegBuyEntryLeg(const ENUM_VGRID_LEG leg)
{
   return (leg == VGRID_LEG_BUY_ABOVE || leg == VGRID_LEG_BUY_BELOW
        || leg == VGRID_LEG_BUY_ABOVE_E || leg == VGRID_LEG_BUY_BELOW_H);
}

// Nến đóng shift1 trên khung chọn: tăng → chỉ Buy A,D,E,H; giảm → chỉ Sell B,C,F,G; doji → không chặn thêm.
bool VirtualGridPrevClosedCandleDirectionAllowsLeg(const ENUM_VGRID_LEG leg)
{
   if(!EnableVirtualGridPrevClosedCandleDirectionFilter)
      return true;

   ENUM_TIMEFRAMES tf = VirtualGridPrevClosedCandleTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)Period();

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, tf, 1, 1, rates) < 1)
      return true;

   const double o = rates[0].open;
   const double c = rates[0].close;
   if(c > o)
      return IsVirtualGridLegBuyEntryLeg(leg);
   if(c < o)
      return !IsVirtualGridLegBuyEntryLeg(leg);
   return true;
}

// Đóng shift1 vs EMA (cùng khung VirtualGridPrevClosedCandleTimeframe): Close>EMA → chỉ Buy trên gốc (A,E); Close<EMA → chỉ Sell dưới gốc (B,F); bằng → không chặn thêm.
bool VirtualGridPrevClosedVsEmaAllowsLeg(const ENUM_VGRID_LEG leg)
{
   if(!EnableVirtualGridPrevClosedVsEmaSideFilter)
      return true;
   if(g_virtualGridPrevCloseEmaHandle == INVALID_HANDLE)
      return true;

   ENUM_TIMEFRAMES tf = VirtualGridPrevClosedCandleTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)Period();

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, tf, 1, 1, rates) < 1)
      return true;

   double emaBuf[];
   ArraySetAsSeries(emaBuf, true);
   if(CopyBuffer(g_virtualGridPrevCloseEmaHandle, 0, 1, 1, emaBuf) != 1)
      return true;

   const double c = rates[0].close;
   const double ema = emaBuf[0];
   if(c > ema)
      return IsVirtualGridLegBuyEntryLeg(leg) && VirtualGridLegIsAboveBaseSide(leg);
   if(c < ema)
      return !IsVirtualGridLegBuyEntryLeg(leg) && !VirtualGridLegIsAboveBaseSide(leg);
   return true;
}

// Bật chân chờ ảo: (input Bật chân 4a–4i) AND (lọc 2J: hướng nến / đóng vs EMA — nếu bật; không thay thế từng loại lệnh).
bool IsVirtualGridLegEnabled(const ENUM_VGRID_LEG leg)
{
   bool on = false;
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE:    on = EnableLegBuyAboveA; break;
      case VGRID_LEG_SELL_BELOW:   on = EnableLegSellBelowB; break;
      case VGRID_LEG_SELL_ABOVE:   on = EnableLegSellAboveC; break;
      case VGRID_LEG_BUY_BELOW:    on = EnableLegBuyBelowD; break;
      case VGRID_LEG_BUY_ABOVE_E:  on = EnableLegBuyAboveE; break;
      case VGRID_LEG_SELL_BELOW_F: on = EnableLegSellBelowF; break;
      case VGRID_LEG_SELL_ABOVE_G: on = EnableLegSellAboveG; break;
      case VGRID_LEG_BUY_BELOW_H:  on = EnableLegBuyBelowH; break;
      default: return true;
   }
   if(!on)
      return false;
   if(!VirtualGridPrevClosedCandleDirectionAllowsLeg(leg))
      return false;
   return VirtualGridPrevClosedVsEmaAllowsLeg(leg);
}

// 2J: bật đồng thời lọc hướng nến + đóng vs EMA → chỉ đặt gốc khi có ít nhất một chân A–H (đã Bật 4a–4i) thỏa cả hai; vào chờ ảo vẫn kiểm từng chân qua IsVirtualGridLegEnabled.
bool VirtualGridPrevClosedDualFiltersAllowBasePlacement()
{
   if(!EnableVirtualGridPrevClosedCandleDirectionFilter || !EnableVirtualGridPrevClosedVsEmaSideFilter)
      return true;

   static const ENUM_VGRID_LEG kAllVirtLegs[8] =
   {
      VGRID_LEG_BUY_ABOVE, VGRID_LEG_SELL_BELOW, VGRID_LEG_SELL_ABOVE, VGRID_LEG_BUY_BELOW,
      VGRID_LEG_BUY_ABOVE_E, VGRID_LEG_SELL_BELOW_F, VGRID_LEG_SELL_ABOVE_G, VGRID_LEG_BUY_BELOW_H
   };
   for(int i = 0; i < 8; i++)
   {
      if(IsVirtualGridLegEnabled(kAllVirtLegs[i]))
         return true;
   }
   return false;
}

void VirtualGridPrevClosedDualFilterMaybeLogWaitingForBase()
{
   static ulong s_lastMs = 0;
   const ulong now = GetTickCount64();
   if(now - s_lastMs < 60000)
      return;
   s_lastMs = now;
   ENUM_TIMEFRAMES tf = VirtualGridPrevClosedCandleTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;
   Print("VDualGrid: 2J — bật cả lọc hướng nến và đóng vs EMA; chưa có chân chờ ảo nào thỏa đồng thời cả hai — chờ nến shift1 khung ", EnumToString(tf), " (đặt gốc / khởi động phiên).");
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

void ArmStartupRestartDelay(const string reason)
{
   const int delayMin = MathMax(0, StartupRestartDelayMinutes);
   const int delaySec = delayMin * 60;
   if(delaySec <= 0)
   {
      g_startupDelayUntil = 0;
      g_startupDelayLogged = false;
      return;
   }
   g_startupDelayUntil = TimeCurrent() + delaySec;
   g_startupDelayLogged = false;
   Print("VDualGrid: ", reason, " — bật delay khởi động lại ", IntegerToString(delayMin), " phút.");
}

bool IsStartupRestartDelayBlocking()
{
   if(g_startupDelayUntil <= 0)
      return false;
   const datetime nowSrv = TimeCurrent();
   if(nowSrv < g_startupDelayUntil)
   {
      if(!g_startupDelayLogged)
      {
         Print("VDualGrid: đang delay khởi động lại đến ", TimeToString(g_startupDelayUntil, TIME_DATE|TIME_MINUTES|TIME_SECONDS), " (server).");
         g_startupDelayLogged = true;
      }
      return true;
   }
   g_startupDelayUntil = 0;
   if(g_startupDelayLogged)
      Print("VDualGrid: hết delay khởi động lại — cho phép đặt gốc/lưới mới.");
   g_startupDelayLogged = false;
   return false;
}

//+------------------------------------------------------------------+
//| 8A2: tắt trì hoãn chờ ảo (sau khi đủ điều kiện, hoặc khi gồng/cân bằng cần nạp chờ ảo ngay). |
//+------------------------------------------------------------------+
void ClearDeferVirtualPendingGate()
{
   g_deferVirtualPendingGateActive = false;
   g_deferredVirtualGridOrdersAllowedAfter = 0;
   g_deferVirtReleaseLogged = false;
}

//+------------------------------------------------------------------+
//| 8A3: tắt theo dõi “hết phút chưa đặt chờ ảo” (gồng / cân bằng / reset có chủ đích). |
//+------------------------------------------------------------------+
void NoVirtExecWatchDisarm()
{
   g_noVirtExecHadSuccessfulTrigger = false;
   g_noVirtExecDeadline = 0;
}

//+------------------------------------------------------------------+
//| 8A3: còn ít nhất một chờ ảo của EA trên sổ nội bộ.                 |
//+------------------------------------------------------------------+
bool NoVirtExecHasAnyOurVirtualPending()
{
   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(IsOurMagic(g_virtualPending[i].magic))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 8A3: có vị thế mở (magic+symbol) từ đầu phiên lưới hiện tại hay không. |
//+------------------------------------------------------------------+
bool NoVirtExecHasOpenSessionPosition()
{
   if(sessionStartTime <= 0)
      return false;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if((datetime)PositionGetInteger(POSITION_TIME) < sessionStartTime)
         continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 8A3: hết X phút từ lúc đặt gốc mà chưa có chờ ảo nào được đặt → chờ gốc mới. |
//+------------------------------------------------------------------+
void TryRebaseIfNoVirtualExecTimedOut()
{
   if(!EnableRebaseIfNoVirtualExecWithinMinutes || RebaseIfNoVirtualExecWithinMinutes <= 0)
      return;
   if(basePrice <= 0.0 || !g_runtimeSessionActive)
      return;
   if(IsStartupRestartDelayBlocking())
      return;
   if(g_compoundTotalProfitActive || g_compoundAfterClearWaitGrid)
      return;
   if(g_noVirtExecHadSuccessfulTrigger)
      return;
   if(g_noVirtExecDeadline > 0 && NoVirtExecHasAnyOurVirtualPending())
   {
      g_noVirtExecHadSuccessfulTrigger = true;
      g_noVirtExecDeadline = 0;
      return;
   }
   if(g_noVirtExecDeadline <= 0 || TimeCurrent() < g_noVirtExecDeadline)
      return;

   if(NoVirtExecHasOpenSessionPosition())
   {
      g_noVirtExecDeadline = TimeCurrent() + (datetime)(RebaseIfNoVirtualExecWithinMinutes * 60);
      return;
   }

   Print("VDualGrid: 8A3 — Hết ", IntegerToString(RebaseIfNoVirtualExecWithinMinutes),
         " phút kể từ đặt gốc, EA chưa đặt chờ ảo nào → reset phiên như các nhánh reset khác, chờ điều kiện đặt gốc mới.");
   if(EnableResetNotification)
      SendResetNotification("8A3: chưa đặt chờ ảo trong X phút — reset, chờ đặt gốc mới");

   ArmStartupRestartDelay("Reset 8A3 chưa đặt chờ ảo");
   CompoundFloatThrHudUpdate(false);

   const bool dailyPause = TryPauseNewSessionAfterResetByDailyProfit("Reset 8A3");

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   ClearDeferVirtualPendingGate();
   NoVirtExecWatchDisarm();
   OrderBalanceResetSideDwellState();
   InitBaseEmaVirtGapClearZone();
   AutoFirstLotByBaseEmaClearState();

   if(dailyPause)
   {
      CompoundFloatThrHudUpdate(false);
      UpdateBaseLineOnChart();
      return;
   }

   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: 8A3 — ngoài lịch chạy (giờ/ngày), EA chờ tới khi được phép phiên mới.");
      if(EnableResetNotification)
         SendResetNotification("8A3: reset — ngoài lịch chạy");
      CompoundFloatThrHudUpdate(false);
      UpdateBaseLineOnChart();
      return;
   }

   Print("VDualGrid: 8A3 — chờ đủ điều kiện input (giờ/ngày/news, EMA/RSI nếu bật) để đặt gốc mới.");
   if(EnableResetNotification)
      SendResetNotification("8A3: chờ đủ điều kiện input để đặt gốc mới");

   CompoundFloatThrHudUpdate(false);
   UpdateBaseLineOnChart();
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
   g_compoundUseLimitReverseMode = false;
   CompoundCarryUsdSetTotal(0.0);
   OrderBalanceResetSideDwellState();
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Ngưỡng Σ(profit+swap) mở cho logic gồng 6b (ARM + chờ bước hủy).   |
//+------------------------------------------------------------------+
double GetCompoundFloatingTriggerThresholdUsd()
{
   return CompoundTotalProfitTriggerUSD + GetCompoundCarryContributionUsd();
}

double GetCompoundCarryContributionUsd()
{
   double carryUsd = g_balanceCompoundCarryUsd;
   const double carryCapUsd = MathMax(0.0, OrderBalanceCarryCapPerSessionUSD);
   if(carryUsd > 0.0 && EnableOrderBalanceCarryCapPerSession && carryCapUsd > 0.0)
      carryUsd = MathMin(carryUsd, carryCapUsd);
   return carryUsd;
}

//+------------------------------------------------------------------+
//| Gán carry tổng → đóng góp ngưỡng gồng (cộng dồn). Carry phiên =   |
//| hiện tại − g_carryTotalUsdAtGridSessionStart; chỉ xét reset EA 6h. |
//+------------------------------------------------------------------+
void CompoundCarryUsdSetTotal(const double newTotalUsd)
{
   g_balanceCompoundCarryUsd = newTotalUsd;
}

//+------------------------------------------------------------------+
//| Cộng vào carry sau reset: phần âm của P/L đã đóng trong phiên +   |
//| phần âm float (lệnh EA sẽ đóng khi reset). Mỗi nhánh tính riêng.  |
//| Gọi trước CloseAllPositionsAndOrders; snapClosed = g_compoundSession… |
//| snapOpen = tổng P/L phiên (mở+đóng) truyền vào − snapClosed.       |
//+------------------------------------------------------------------+
double SessionLossCarryUsdForEaReset(const double sessionClosedProfitSwapUsd, const double sessionOpenProfitSwapUsd)
{
   return MathMax(0.0, -sessionClosedProfitSwapUsd) + MathMax(0.0, -sessionOpenProfitSwapUsd);
}

//+------------------------------------------------------------------+
//| Carry cộng khi reset phiên: theo P/L mở+đóng (profit+swap).         |
//| One-bucket: += max(0,−tổng). Tách: += SessionLossCarryUsdForEaReset. |
//| MinSessionNegativeUsd>0: chỉ cộng khi tổng ≤ −X (âm đủ sâu).       |
//+------------------------------------------------------------------+
double ComputeSessionLossCarryUsdForReset(const double totalSessionProfitSwapUsd,
                                          const double snapClosedPnlSwap, const double snapOpenPnlSwap)
{
   if(ResetCarryMinSessionNegativeUsd > 0.0
      && totalSessionProfitSwapUsd > -ResetCarryMinSessionNegativeUsd)
      return 0.0;
   if(ResetCarrySessionNegativeAsOneBucket)
      return MathMax(0.0, -totalSessionProfitSwapUsd);
   return SessionLossCarryUsdForEaReset(snapClosedPnlSwap, snapOpenPnlSwap);
}

double GetCarryInSessionUsd(void)
{
   if(sessionStartTime <= 0)
      return 0.0;
   return g_balanceCompoundCarryUsd - g_carryTotalUsdAtGridSessionStart;
}

#define COMPOUND_FLOAT_THR_HUD_PREFIX "VDG_CMPFTHR_"
#define COMPOUND_FLOAT_THR_HUD_PREFIX_LEGACY "VDG_CARRYHUD_"

bool CompoundFloatThrHudLabelSet(const string name, const int x, const int y, const string text,
                                   const int fontPx, const color clr, const bool bold,
                                   const ENUM_BASE_CORNER corner)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontPx);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

void CompoundFloatThrHudDeleteAll()
{
   string toDel[];
   const int total = ObjectsTotal(0, -1, -1);
   for(int i = 0; i < total; i++)
   {
      const string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, COMPOUND_FLOAT_THR_HUD_PREFIX) == 0
         || StringFind(nm, COMPOUND_FLOAT_THR_HUD_PREFIX_LEGACY) == 0)
      {
         const int n = ArraySize(toDel);
         ArrayResize(toDel, n + 1);
         toDel[n] = nm;
      }
   }
   for(int j = 0; j < ArraySize(toDel); j++)
      ObjectDelete(0, toDel[j]);
}

// HUD ngưỡng gồng lãi tổng: vẽ lại khi reset lưới/EA (isEaGridReset) hoặc khi chữ ngưỡng/phiên đổi (thường do carry 6c).
void CompoundFloatThrHudUpdate(const bool isEaGridReset)
{
   static string s_snapL1 = "";
   static string s_snapL2 = "";
   static string s_snapL3 = "";
   static bool s_snapValid = false;

   const ENUM_BASE_CORNER crn = CORNER_RIGHT_UPPER;
   const int x = 14;
   const int y1 = 22;
   const int y2 = 38;
   const int y3 = 54;
   const color C_MUTED = C'140,145,158';
   const color C_BLUE = C'60,150,255';

   string line1;
   if(EnableCompoundTotalFloatingProfit && CompoundTotalProfitTriggerUSD > 0.0)
   {
      const double thrUsd = GetCompoundFloatingTriggerThresholdUsd();
      line1 = "Ngưỡng gồng lãi tổng: " + DoubleToString(thrUsd, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
   }
   else
      line1 = "Gồng lãi tổng: tắt hoặc ngưỡng ≤ 0";

   string line2 = "Phiên lưới: ";
   if(sessionStartTime > 0)
      line2 += TimeToString(sessionStartTime, TIME_DATE | TIME_MINUTES);
   else
      line2 += "—";
   if(!g_runtimeSessionActive)
      line2 += "  |  Lịch: chờ phiên";

   const string line3 = "Carry tổng (cộng dồn các phiên → ngưỡng gồng): " + DoubleToString(g_balanceCompoundCarryUsd, 2)
                    + " " + AccountInfoString(ACCOUNT_CURRENCY)
                    + "  |  Carry phiên (từ đầu phiên, đủ ngưỡng → reset EA 6h): " + DoubleToString(GetCarryInSessionUsd(), 2)
                    + " " + AccountInfoString(ACCOUNT_CURRENCY);

   if(!isEaGridReset && s_snapValid && line1 == s_snapL1 && line2 == s_snapL2 && line3 == s_snapL3)
      return;
   s_snapValid = true;
   s_snapL1 = line1;
   s_snapL2 = line2;
   s_snapL3 = line3;

   CompoundFloatThrHudLabelSet(COMPOUND_FLOAT_THR_HUD_PREFIX "L1", x, y1, line1, 9, C_BLUE, true, crn);
   CompoundFloatThrHudLabelSet(COMPOUND_FLOAT_THR_HUD_PREFIX "L2", x, y2, line2, 8, C_MUTED, false, crn);
   CompoundFloatThrHudLabelSet(COMPOUND_FLOAT_THR_HUD_PREFIX "L3", x, y3, line3, 7, C_MUTED, false, crn);
   ChartRedraw(0);
}

double GetCompoundOpenProfitSwapContribution(const ulong ticket)
{
   if(ticket <= 0 || !PositionSelectByTicket(ticket))
      return 0.0;
   if(!PositionIsOurSymbolAndMagic(ticket))
      return 0.0;

   const double posProfitSwap = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   if(CompoundTriggerProgressMode != COMPOUND_PROGRESS_OPEN_EXCLUDE_POSITIVE_EF)
      return posProfitSwap;

   const string cmt = PositionGetString(POSITION_COMMENT);
   ENUM_VGRID_LEG leg = VGRID_LEG_BUY_ABOVE;
   if(!TryParseLegFromOrderComment(cmt, leg))
      return posProfitSwap;

   if((leg == VGRID_LEG_BUY_ABOVE_E || leg == VGRID_LEG_SELL_BELOW_F) && posProfitSwap > 0.0)
      return 0.0;
   return posProfitSwap;
}

double GetCompoundTriggerProgressUsd(const double totalOpenProfitSwapUsd)
{
   if(CompoundTriggerProgressMode == COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_TOTAL)
      return totalOpenProfitSwapUsd + g_compoundSessionClosedTotalProfitSwapUsd;
   if(CompoundTriggerProgressMode == COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_NEGATIVE)
      return totalOpenProfitSwapUsd + g_compoundSessionClosedNegativeProfitSwapUsd + g_compoundSessionClosedTpProfitSwapUsd;
   return totalOpenProfitSwapUsd;
}

double GetCompoundTriggerProgressUsdByMode(const double totalOpenProfitSwapUsd, const bool useLimitReverseMode)
{
   const ENUM_COMPOUND_TRIGGER_PROGRESS_MODE mode = (useLimitReverseMode
                                                      ? CompoundLimitReverseTriggerProgressMode
                                                      : CompoundTriggerProgressMode);
   if(mode == COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_TOTAL)
      return totalOpenProfitSwapUsd + g_compoundSessionClosedTotalProfitSwapUsd;
   if(mode == COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_NEGATIVE)
      return totalOpenProfitSwapUsd + g_compoundSessionClosedNegativeProfitSwapUsd + g_compoundSessionClosedTpProfitSwapUsd;
   return totalOpenProfitSwapUsd;
}

double GetCompoundFloatingTriggerThresholdUsdByMode(const bool useLimitReverseMode)
{
   const double baseTrig = (useLimitReverseMode ? CompoundTotalProfitLimitReverseTriggerUSD : CompoundTotalProfitTriggerUSD);
   return baseTrig + GetCompoundCarryContributionUsd();
}

// Mode limit ngược: trên gốc dùng SELL dương nhỏ nhất; dưới gốc dùng BUY dương nhỏ nhất.
bool CompoundEvaluateDeferredBasketLimitReverse(bool &buyBasketOut, double &refPxOut)
{
   buyBasketOut = false;
   refPxOut = 0.0;
   if(basePrice <= 0.0)
      return false;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const bool isAboveBase = (bid >= basePrice);
   buyBasketOut = !isAboveBase; // Trên gốc -> giữ SELL (false); dưới gốc -> giữ BUY (true)

   bool haveRef = false;
   double minPositiveProfit = DBL_MAX;
   for(int k = 0; k < PositionsTotal(); k++)
   {
      const ulong ticket = PositionGetTicket(k);
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;

      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double op = PositionGetDouble(POSITION_PRICE_OPEN);
      const double ps = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(ps <= 0.0)
         continue;

      if(isAboveBase)
      {
         if(ptp != POSITION_TYPE_SELL || op <= basePrice)
            continue;
      }
      else
      {
         if(ptp != POSITION_TYPE_BUY || op >= basePrice)
            continue;
      }

      if(!haveRef || ps < minPositiveProfit)
      {
         minPositiveProfit = ps;
         refPxOut = op;
         haveRef = true;
      }
   }
   return haveRef;
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
//| Điểm A tham chiếu: lệnh đúng phía, cùng phiên, có bậc dương xa gốc nhất. |
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
//| Đặt SL theo mức line chung (ref) cho phía đang giữ trong 6b.      |
//+------------------------------------------------------------------+
void CompoundApplyCommonSlLineToBasketPositions(const bool buyBasket, const double lineNorm, const double minDist)
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
      if(buyBasket && ptp != POSITION_TYPE_BUY)
         continue;
      if(!buyBasket && ptp != POSITION_TYPE_SELL)
         continue;
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double curSL = PositionGetDouble(POSITION_SL);
      const double curTP = PositionGetDouble(POSITION_TP);
      double newSL = 0.0;

      if(ptp == POSITION_TYPE_BUY)
      {
         if(g_compoundUseLimitReverseMode)
            newSL = lineNorm;
         else
            newSL = MathMax(lineNorm, openPrice + minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL >= bid - minDist)
            continue;
         if(!g_compoundUseLimitReverseMode && newSL <= openPrice)
            continue;
         if(curSL > 0.0 && newSL <= curSL + pt)
            continue;
      }
      else
      {
         if(g_compoundUseLimitReverseMode)
            newSL = lineNorm;
         else
            newSL = MathMin(lineNorm, openPrice - minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL <= ask + minDist)
            continue;
         if(!g_compoundUseLimitReverseMode && newSL >= openPrice)
            continue;
         if(curSL > 0.0 && newSL >= curSL - pt)
            continue;
      }

      if(ModifyPositionSLTP(ticket, newSL, curTP))
         Print("VDualGrid: Gồng lãi — SL tại điểm A ticket ", ticket, " SL=", DoubleToString(newSL, dgt));
   }
}

//+------------------------------------------------------------------+
//| Đủ giá + đủ ngưỡng: xóa hết chờ ảo; chờ thêm 1 bước lưới có lợi.   |
//+------------------------------------------------------------------+
void CompoundOnActivationConfirmed(const bool buyBasket, const double refPx)
{
   ClearDeferVirtualPendingGate();
   NoVirtExecWatchDisarm();
   // Carry 6c giữ đến khi vào hẳn trượt SL gồng lãi tổng (ProcessCompoundPostActivationGridStepWait),
   // để ngưỡng hiển thị không tụt về gốc input trong lúc chờ bước lưới / hủy pha chờ vẫn còn carry.
   VirtualPendingClear();
   g_compoundFrozenRefPx = refPx;
   g_compoundActivationBuyBasket = buyBasket;
   g_compoundAfterClearWaitGrid = true;
   g_compoundArmed = false;
   g_compoundTotalProfitActive = false;
   g_compoundCommonSlLine = 0.0;
   Print("VDualGrid: Gồng lãi — KÍCH HOẠT: đã xóa hết chờ ảo. Tham chiếu=", DoubleToString(refPx, dgt),
         " | Chờ +1 bước lưới có lợi → SL chung tại ref → đóng toàn bộ SELL nếu Bid≥gốc, toàn bộ BUY nếu Bid<gốc.");
}

//+------------------------------------------------------------------+
//| Sau kích hoạt: giá đi thêm 1 bước lưới có lợi → SL tại A → đóng phía ngược. |
//| Nếu giá hồi ngược 1 bước từ A trước khi vào SL chung → khôi phục chờ ảo. |
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

   // Nếu giá hồi ngược 1 bước từ điểm A trước khi vào SL chung:
   // coi như chưa kích hoạt 6b, khôi phục lưới chờ ảo ban đầu.
   if(g_compoundActivationBuyBasket)
   {
      if((g_compoundFrozenRefPx - bid) >= step - pt * 0.5)
      {
         g_compoundAfterClearWaitGrid = false;
         g_compoundFrozenRefPx = 0.0;
         Print("VDualGrid: Gồng lãi — giá hồi xuống dưới A 1 bước lưới trước khi vào SL chung → khôi phục chờ ảo.");
         ClearDeferVirtualPendingGate();
         NoVirtExecWatchDisarm();
         ManageGridOrders();
         return;
      }
   }
   else
   {
      if((ask - g_compoundFrozenRefPx) >= step - pt * 0.5)
      {
         g_compoundAfterClearWaitGrid = false;
         g_compoundFrozenRefPx = 0.0;
         Print("VDualGrid: Gồng lãi — giá hồi lên trên A 1 bước lưới trước khi vào SL chung → khôi phục chờ ảo.");
         ClearDeferVirtualPendingGate();
         NoVirtExecWatchDisarm();
         ManageGridOrders();
         return;
      }
   }

   const double modeTriggerUsd = (g_compoundUseLimitReverseMode ? CompoundTotalProfitLimitReverseTriggerUSD : CompoundTotalProfitTriggerUSD);
   const double modeThresholdUsd = GetCompoundFloatingTriggerThresholdUsdByMode(g_compoundUseLimitReverseMode);
   const double triggerProgressUsd = GetCompoundTriggerProgressUsdByMode(totalOpenProfitSwapUsd, g_compoundUseLimitReverseMode);
   if(modeTriggerUsd > 0.0 && triggerProgressUsd < modeThresholdUsd)
   {
      double distFromA = 0.0;
      if(g_compoundActivationBuyBasket)
         distFromA = MathAbs(bid - g_compoundFrozenRefPx);
      else
         distFromA = MathAbs(ask - g_compoundFrozenRefPx);
      if(step > 0.0 && distFromA < step)
      {
         g_compoundAfterClearWaitGrid = false;
         g_compoundFrozenRefPx = 0.0;
         Print("VDualGrid: Gồng lãi — RESET điểm A khi chờ bước: (tiến độ + carry) < ngưỡng và giá cách A < 1 bước lưới.");
         ClearDeferVirtualPendingGate();
         NoVirtExecWatchDisarm();
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
   CompoundApplyCommonSlLineToBasketPositions(g_compoundActivationBuyBasket, lineNorm, minDist);

   trade.SetExpertMagicNumber(MagicAA);
   if(g_compoundActivationBuyBasket)
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
      Print("VDualGrid: Gồng lãi — BUY basket: đã đóng toàn bộ SELL (phiên).");
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
      Print("VDualGrid: Gồng lãi — SELL basket: đã đóng toàn bộ BUY (phiên).");
   }

   // Tiêu thụ carry 6c tại thời điểm bật trượt SL gồng lãi tổng (đã qua chờ bước lưới), không phải lúc mới xóa chờ ảo.
   {
      const double usedCarryUsd = GetCompoundCarryContributionUsd();
      if(EnableOrderBalanceCarryCapPerSession && OrderBalanceCarryCapPerSessionUSD > 0.0 && g_balanceCompoundCarryUsd > 0.0)
         CompoundCarryUsdSetTotal(MathMax(0.0, g_balanceCompoundCarryUsd - MathMax(0.0, usedCarryUsd)));
      else
         CompoundCarryUsdSetTotal(0.0);
   }
   CompoundFloatThrHudUpdate(false);

   g_compoundBuyBasketMode = g_compoundActivationBuyBasket;
   g_compoundAfterClearWaitGrid = false;
   g_compoundFrozenRefPx = 0.0;
   g_compoundTotalProfitActive = true;

   Print("VDualGrid: ", (g_compoundUseLimitReverseMode ? "Gồng lãi tổng LIMIT-ngược" : "Gồng lãi tổng"),
         " — SL chung tại tham chiếu, đóng phía xong → bật trượt SL theo bậc. Rổ ",
         (g_compoundBuyBasketMode ? "BUY" : "SELL"), ".");
}

//+------------------------------------------------------------------+
//| Đạt ngưỡng Σ(profit+swap) lệnh mở: chỉ ARM — chưa đóng lệnh / chưa xóa chờ ảo. |
//+------------------------------------------------------------------+
void TryArmCompoundTotalProfitMode(const bool useLimitReverseMode, const double triggerUsd)
{
   if(g_compoundTotalProfitActive || g_compoundArmed || g_compoundAfterClearWaitGrid)
      return;
   if(triggerUsd <= 0.0)
      return;
   if(basePrice <= 0.0)
      return;

   bool buyBasket = (SymbolInfoDouble(_Symbol, SYMBOL_BID) >= basePrice);
   double refPx = 0.0;
   const bool gotRef = (useLimitReverseMode
                        ? CompoundEvaluateDeferredBasketLimitReverse(buyBasket, refPx)
                        : CompoundEvaluateDeferredBasket(buyBasket, refPx));
   if(!gotRef)
   {
      g_compoundFrozenRefPx = 0.0;
      if(useLimitReverseMode)
         Print("VDualGrid: Gồng lãi tổng LIMIT-ngược — không tìm được điểm A (trên gốc: Sell dương nhỏ nhất / dưới gốc: Buy dương nhỏ nhất) — không ARM.");
      else
         Print("VDualGrid: Gồng lãi tổng — không tìm được điểm A (bậc dương nhỏ nhất ", (buyBasket ? "BUY trên gốc" : "SELL dưới gốc"), ") — không ARM.");
      return;
   }

   g_compoundArmed = true;
   g_compoundArmBuyBasket = buyBasket;
   g_compoundUseLimitReverseMode = useLimitReverseMode;
   g_compoundFrozenRefPx = refPx;
   const double step = CompoundModeGridStepPrice();
   const double onePip = OnePipPrice();
   const double carryContributionUsd = GetCompoundCarryContributionUsd();
   string carryLog = "";
   if(MathAbs(carryContributionUsd) > 1e-8)
   {
      carryLog = "; gốc input " + DoubleToString(triggerUsd, 2)
                 + " +6c " + DoubleToString(carryContributionUsd, 2);
      if(EnableOrderBalanceCarryCapPerSession && OrderBalanceCarryCapPerSessionUSD > 0.0)
         carryLog += " / max6c " + DoubleToString(OrderBalanceCarryCapPerSessionUSD, 2);
      if(carryContributionUsd > 0.0
         && EnableOrderBalanceCarryCapPerSession && OrderBalanceCarryCapPerSessionUSD > 0.0
         && g_balanceCompoundCarryUsd > carryContributionUsd + 1e-8)
      {
         carryLog += " (trần phiên " + DoubleToString(OrderBalanceCarryCapPerSessionUSD, 2)
                     + ", dư " + DoubleToString(g_balanceCompoundCarryUsd - carryContributionUsd, 2) + ")";
      }
   }
   Print("VDualGrid: ", (useLimitReverseMode ? "Gồng lãi tổng LIMIT-ngược" : "Gồng lãi tổng"),
         " — ARM (chờ đủ giá + đủ ngưỡng). Điểm A=", DoubleToString(refPx, dgt),
         " | 1 pip=", DoubleToString(onePip, dgt),
         (step > 0.0 ? (" | bước lưới=" + DoubleToString(step, dgt)) : ""),
         " | ngưỡng=", DoubleToString(GetCompoundFloatingTriggerThresholdUsdByMode(useLimitReverseMode), 2), " USD (",
         (useLimitReverseMode ? "Σ mở phiên + Σ đóng toàn phiên"
          : (CompoundTriggerProgressMode == COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_TOTAL
             ? "Σ mở phiên + Σ đóng toàn phiên"
             : (CompoundTriggerProgressMode == COMPOUND_PROGRESS_OPEN_PLUS_SESSION_CLOSED_NEGATIVE
                ? "Σ mở phiên + Σ đóng âm phiên + Σ đóng TP phiên"
                : (CompoundTriggerProgressMode == COMPOUND_PROGRESS_OPEN_EXCLUDE_POSITIVE_EF
                   ? "Σ mở phiên (loại lãi dương chân E/F)"
                   : "Σ mở phiên")))),
         carryLog,
         ")",
         (buyBasket ? " | Đủ giá: (Bid−ref)>1 pip; HỦY: Bid≤ref−1 pip." : " | Đủ giá: (ref−Ask)>1 pip; HỦY: Ask≥ref+1 pip."));
}

//+------------------------------------------------------------------+
//| Đang ARM: đủ giá = Bid/Ask lệch tham chiếu > 1 pip; + Σ profit+swap mở phiên ≥ ngưỡng → execute. |
//| totalOpenProfitSwapUsd = chỉ lệnh mở magic+symbol trong phiên hiện tại (lọc theo sessionStartTime). |
//+------------------------------------------------------------------+
void ProcessCompoundArming(const double totalOpenProfitSwapUsd)
{
   if(!g_compoundArmed)
      return;

   const bool useLimitReverseMode = g_compoundUseLimitReverseMode;
   const double triggerUsd = (useLimitReverseMode ? CompoundTotalProfitLimitReverseTriggerUSD : CompoundTotalProfitTriggerUSD);
   bool buyBasket = g_compoundArmBuyBasket;
   double refPx = 0.0;
   const bool gotRef = (useLimitReverseMode
                        ? CompoundEvaluateDeferredBasketLimitReverse(buyBasket, refPx)
                        : CompoundEvaluateDeferredBasket(buyBasket, refPx));
   if(!gotRef)
   {
      g_compoundArmed = false;
      g_compoundFrozenRefPx = 0.0;
      Print("VDualGrid: Gồng lãi tổng — mất điểm A khi chờ — HỦY ARM (không đóng lệnh).");
      return;
   }
   g_compoundArmBuyBasket = buyBasket;
   g_compoundFrozenRefPx = refPx;

   const double onePip = OnePipPrice();
   if(onePip <= 0.0)
      return;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double compoundFloatThr = GetCompoundFloatingTriggerThresholdUsdByMode(useLimitReverseMode);
   const double triggerProgressUsd = GetCompoundTriggerProgressUsdByMode(totalOpenProfitSwapUsd, useLimitReverseMode);
   const bool floatOk = (triggerUsd > 0.0 && triggerProgressUsd >= compoundFloatThr);
   const double step = CompoundModeGridStepPrice();
   if(triggerUsd > 0.0 && triggerProgressUsd < compoundFloatThr)
   {
      double distFromA = 0.0;
      if(buyBasket)
         distFromA = MathAbs(bid - refPx);
      else
         distFromA = MathAbs(ask - refPx);
      if(step > 0.0 && distFromA < step)
      {
         g_compoundArmed = false;
         g_compoundFrozenRefPx = 0.0;
         Print("VDualGrid: Gồng lãi tổng — RESET điểm A: (tiến độ + carry) < ngưỡng và giá cách A < 1 bước lưới.");
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
   ArmStartupRestartDelay("Reset sau chạm SL chung");
   const bool keepCarryForNextSession = (EnableOrderBalanceCarryCapPerSession
                                         && OrderBalanceCarryCapPerSessionUSD > 0.0
                                         && g_balanceCompoundCarryUsd > 0.0);
   const double carryBackup = g_balanceCompoundCarryUsd;
   CloseAllPositionsAndOrders();
   if(keepCarryForNextSession)
      CompoundCarryUsdSetTotal(carryBackup);
   CompoundFloatThrHudUpdate(false);

   if(TryPauseNewSessionAfterResetByDailyProfit("Reset sau SL chung"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Gồng lãi — chạm SL chung, reset ngoài lịch chạy — EA chờ giờ/ngày.");
      if(EnableResetNotification)
         SendResetNotification("Gồng lãi: chạm SL chung — ngoài lịch chạy");
      CompoundFloatThrHudUpdate(false);
      return;
   }

   Print("VDualGrid: Gồng lãi — chạm SL chung — chờ đủ điều kiện input (giờ/ngày/news, EMA/RSI nếu bật) để đặt gốc mới.");
   if(EnableResetNotification)
      SendResetNotification("Gồng lãi: SL chung — chờ đủ điều kiện input để đặt gốc");
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Reset EA khi thỏa điều kiện 6d: khoảng cách giá + tổng P/L phiên. |
//+------------------------------------------------------------------+
void ResetAfterSessionDistanceAndTotalProfitHit(const double totalSessionProfitSwapUsd)
{
   ArmStartupRestartDelay("Reset 6d");
   const bool keepCarryForNextSession = (EnableOrderBalanceCarryCapPerSession
                                         && OrderBalanceCarryCapPerSessionUSD > 0.0
                                         && g_balanceCompoundCarryUsd > 0.0);
   const double carryBackup = g_balanceCompoundCarryUsd;
   const double snapClosedPnlSwap = g_compoundSessionClosedTotalProfitSwapUsd;
   const double snapOpenPnlSwap = totalSessionProfitSwapUsd - snapClosedPnlSwap;
   const double sessionLossCarryUsd = ComputeSessionLossCarryUsdForReset(totalSessionProfitSwapUsd, snapClosedPnlSwap, snapOpenPnlSwap);
   CloseAllPositionsAndOrders();
   double restoredCarryUsd = 0.0;
   if(keepCarryForNextSession)
      restoredCarryUsd += carryBackup;
   // 6d: carry khi reset theo nhóm input Reset carry (tổng phiên âm hoặc tách đóng/treo).
   restoredCarryUsd += sessionLossCarryUsd;
   if(restoredCarryUsd > 0.0)
      CompoundCarryUsdSetTotal(restoredCarryUsd);
   CompoundFloatThrHudUpdate(false);

   if(TryPauseNewSessionAfterResetByDailyProfit("Reset 6d"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }

   const string extra = " | maxDist=" + DoubleToString(g_sessionMaxAbsDistanceFromBasePips, 1)
                     + " pip | tổng P/L phiên=" + DoubleToString(totalSessionProfitSwapUsd, 2)
                     + " USD | carry phiên sau=" + DoubleToString(sessionLossCarryUsd, 2) + " USD";

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Reset 6d — ngoài lịch chạy, EA chờ.", extra);
      if(EnableResetNotification)
         SendResetNotification("Reset 6d: ngoài lịch chạy" + extra);
      CompoundFloatThrHudUpdate(false);
      return;
   }

   Print("VDualGrid: Reset 6d — chờ đủ điều kiện input (giờ/ngày/news, EMA/RSI nếu bật) để đặt gốc mới.", extra);
   if(EnableResetNotification)
      SendResetNotification("Reset 6d: chờ đủ điều kiện input để đặt gốc mới" + extra);
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Reset EA khi tổng P/L phiên (mở + đã đóng) đạt ngưỡng 6e.         |
//+------------------------------------------------------------------+
void ResetAfterSessionOpenPlusClosedProfitHit(const double totalSessionProfitSwapUsd)
{
   ArmStartupRestartDelay("Reset 6e");
   const bool keepCarryForNextSession = (EnableOrderBalanceCarryCapPerSession
                                         && OrderBalanceCarryCapPerSessionUSD > 0.0
                                         && g_balanceCompoundCarryUsd > 0.0);
   const double carryBackup = g_balanceCompoundCarryUsd;
   const double snapClosedPnlSwap = g_compoundSessionClosedTotalProfitSwapUsd;
   const double snapOpenPnlSwap = totalSessionProfitSwapUsd - snapClosedPnlSwap;
   const double sessionLossCarryUsd = ComputeSessionLossCarryUsdForReset(totalSessionProfitSwapUsd, snapClosedPnlSwap, snapOpenPnlSwap);
   CloseAllPositionsAndOrders();
   double restoredCarryUsd = 0.0;
   if(keepCarryForNextSession)
      restoredCarryUsd += carryBackup;
   restoredCarryUsd += sessionLossCarryUsd;
   if(restoredCarryUsd > 0.0)
      CompoundCarryUsdSetTotal(restoredCarryUsd);
   CompoundFloatThrHudUpdate(false);

   if(TryPauseNewSessionAfterResetByDailyProfit("Reset 6e"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }

   const string extra = " | tổng P/L phiên (mở+đóng)=" + DoubleToString(totalSessionProfitSwapUsd, 2)
                     + " USD | carry phiên sau=" + DoubleToString(sessionLossCarryUsd, 2) + " USD";

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Reset 6e — ngoài lịch chạy, EA chờ.", extra);
      if(EnableResetNotification)
         SendResetNotification("Reset 6e: ngoài lịch chạy" + extra);
      CompoundFloatThrHudUpdate(false);
      return;
   }

   Print("VDualGrid: Reset 6e — chờ đủ điều kiện input (giờ/ngày/news, EMA/RSI nếu bật) để đặt gốc mới.", extra);
   if(EnableResetNotification)
      SendResetNotification("Reset 6e: chờ đủ điều kiện input để đặt gốc mới" + extra);
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Reset EA khi giá ngoài biên ±Max bậc tính từ gốc (FirstOffset+D). |
//| Biên không phụ thuộc việc có chờ ảo/lệnh phía dưới hay phía trên. |
//| Đóng toàn bộ vị thế EA; totalSessionProfitSwapUsd = P/L mở thô+đóng phiên; |
//| carry += theo nhóm Reset carry… (ComputeSessionLossCarryUsdForReset). |
//+------------------------------------------------------------------+
void ResetAfterPriceOutsideTopBottomGridHit(const double totalSessionProfitSwapUsd)
{
   ArmStartupRestartDelay("Reset giá ngoài lưới trên/dưới");
   const bool keepCarryForNextSession = (EnableOrderBalanceCarryCapPerSession
                                         && OrderBalanceCarryCapPerSessionUSD > 0.0
                                         && g_balanceCompoundCarryUsd > 0.0);
   const double carryBackup = g_balanceCompoundCarryUsd;
   const double snapClosedPnlSwap = g_compoundSessionClosedTotalProfitSwapUsd;
   const double snapOpenPnlSwap = totalSessionProfitSwapUsd - snapClosedPnlSwap;
   const double closedLossToCarryUsd = MathMax(0.0, -snapClosedPnlSwap);
   const double openFloatLossToCarryUsd = MathMax(0.0, -snapOpenPnlSwap);
   const double sessionLossCarryUsd = ComputeSessionLossCarryUsdForReset(totalSessionProfitSwapUsd, snapClosedPnlSwap, snapOpenPnlSwap);
   CloseAllPositionsAndOrders();
   double restoredCarryUsd = 0.0;
   if(keepCarryForNextSession)
      restoredCarryUsd += carryBackup;
   restoredCarryUsd += sessionLossCarryUsd;
   if(restoredCarryUsd > 0.0)
      CompoundCarryUsdSetTotal(restoredCarryUsd);
   CompoundFloatThrHudUpdate(false);

   if(TryPauseNewSessionAfterResetByDailyProfit("Reset giá ngoài lưới trên/dưới"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }

   string extraCarryLine;
   if(ResetCarrySessionNegativeAsOneBucket)
      extraCarryLine = " USD | carry += max(0,−P/L phiên)=" + DoubleToString(sessionLossCarryUsd, 2) + " USD";
   else
      extraCarryLine = " USD | carry += (đóng âm " + DoubleToString(closedLossToCarryUsd, 2)
                     + " + treo âm " + DoubleToString(openFloatLossToCarryUsd, 2) + ")="
                     + DoubleToString(sessionLossCarryUsd, 2) + " USD";
   const string extra = " | tổng P/L phiên (mở+đóng)=" + DoubleToString(totalSessionProfitSwapUsd, 2) + extraCarryLine;

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Reset — giá ngoài lưới trên/dưới — ngoài lịch chạy, EA chờ.", extra);
      if(EnableResetNotification)
         SendResetNotification("Reset: giá ngoài lưới trên/dưới — ngoài lịch chạy" + extra);
      CompoundFloatThrHudUpdate(false);
      return;
   }

   Print("VDualGrid: Reset — giá ngoài lưới trên/dưới — chờ đủ điều kiện input (giờ/ngày/news, EMA/RSI nếu bật) để đặt gốc mới.", extra);
   if(EnableResetNotification)
      SendResetNotification("Reset: giá ngoài lưới trên/dưới — chờ đủ điều kiện input để đặt gốc mới" + extra);
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Reset EA: chỉ chờ ảo một phía gốc, giá ngược gốc (điều kiện đã   |
//| xác nhận ở tick đầu sau **đóng nến** khung input — Close shift=1). |
//| Không vị thế / không lệnh chờ broker tại thời điểm gọi. Carry: ComputeSessionLossCarryUsdForReset. |
//+------------------------------------------------------------------+
void ResetAfterVirtualPendingsWrongSideOfBaseHit(const double totalSessionProfitSwapUsd)
{
   ArmStartupRestartDelay("Reset chờ ảo một phía ngược giá/gốc");
   const bool keepCarryForNextSession = (EnableOrderBalanceCarryCapPerSession
                                         && OrderBalanceCarryCapPerSessionUSD > 0.0
                                         && g_balanceCompoundCarryUsd > 0.0);
   const double carryBackup = g_balanceCompoundCarryUsd;
   const double snapClosedPnlSwap = g_compoundSessionClosedTotalProfitSwapUsd;
   const double snapOpenPnlSwap = totalSessionProfitSwapUsd - snapClosedPnlSwap;
   const double closedLossToCarryUsd = MathMax(0.0, -snapClosedPnlSwap);
   const double openFloatLossToCarryUsd = MathMax(0.0, -snapOpenPnlSwap);
   const double sessionLossCarryUsd = ComputeSessionLossCarryUsdForReset(totalSessionProfitSwapUsd, snapClosedPnlSwap, snapOpenPnlSwap);
   CloseAllPositionsAndOrders();
   double restoredCarryUsd = 0.0;
   if(keepCarryForNextSession)
      restoredCarryUsd += carryBackup;
   restoredCarryUsd += sessionLossCarryUsd;
   if(restoredCarryUsd > 0.0)
      CompoundCarryUsdSetTotal(restoredCarryUsd);
   CompoundFloatThrHudUpdate(false);

   if(TryPauseNewSessionAfterResetByDailyProfit("Reset chờ ảo một phía ngược giá/gốc"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }

   string extraCarryLineVw;
   if(ResetCarrySessionNegativeAsOneBucket)
      extraCarryLineVw = " USD | carry += max(0,−P/L phiên)=" + DoubleToString(sessionLossCarryUsd, 2) + " USD";
   else
      extraCarryLineVw = " USD | carry += (đóng âm " + DoubleToString(closedLossToCarryUsd, 2)
                     + " + treo âm " + DoubleToString(openFloatLossToCarryUsd, 2) + ")="
                     + DoubleToString(sessionLossCarryUsd, 2) + " USD";
   const string extra = " | tổng P/L phiên (mở+đóng)=" + DoubleToString(totalSessionProfitSwapUsd, 2) + extraCarryLineVw;

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Reset — chờ ảo một phía, giá ngược gốc — ngoài lịch chạy, EA chờ.", extra);
      if(EnableResetNotification)
         SendResetNotification("Reset: chờ ảo một phía ngược giá/gốc — ngoài lịch chạy" + extra);
      CompoundFloatThrHudUpdate(false);
      return;
   }

   Print("VDualGrid: Reset — chờ ảo một phía, giá ngược gốc — chờ đủ điều kiện input (giờ/ngày/news, EMA/RSI nếu bật) để đặt gốc mới.", extra);
   if(EnableResetNotification)
      SendResetNotification("Reset: chờ ảo một phía ngược giá/gốc — chờ đủ điều kiện input để đặt gốc mới" + extra);
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Reset EA: không vị thế mở; xa gốc ≥ X bậc; mid ngoài thân nến đóng trước. |
//| Carry tổng không đổi (không cộng P/L phiên; sau đóng lệnh khôi phục như reset 6h). |
//+------------------------------------------------------------------+
void ResetAfterNoOpenPosMinGridOutsidePrevBodyHit(const double totalSessionProfitSwapUsd)
{
   const double snapCarryKeep = g_balanceCompoundCarryUsd;

   ArmStartupRestartDelay("Reset: không lệnh mở + xa gốc + ngoài thân nến trước");
   CloseAllPositionsAndOrders();
   // CloseAllPositionsAndOrders có thể xóa state compound/carry; giữ carry tổng sang phiên lưới sau.
   CompoundCarryUsdSetTotal(snapCarryKeep);
   CompoundFloatThrHudUpdate(false);

   if(TryPauseNewSessionAfterResetByDailyProfit("Reset không lệnh mở + xa gốc + ngoài thân nến"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }

   const string extra = " | tổng P/L phiên (mở+đóng)=" + DoubleToString(totalSessionProfitSwapUsd, 2)
                     + " USD | carry tổng giữ nguyên=" + DoubleToString(snapCarryKeep, 2) + " USD";

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Reset — không lệnh mở + xa gốc + ngoài thân nến trước — ngoài lịch chạy, EA chờ.", extra);
      if(EnableResetNotification)
         SendResetNotification("Reset: không lệnh mở + xa gốc + ngoài thân nến — ngoài lịch chạy" + extra);
      CompoundFloatThrHudUpdate(false);
      return;
   }

   Print("VDualGrid: Reset — không lệnh mở + xa gốc + ngoài thân nến trước — chờ đủ điều kiện input (giờ/ngày/news, EMA/RSI nếu bật) để đặt gốc mới.", extra);
   if(EnableResetNotification)
      SendResetNotification("Reset: không lệnh mở + xa gốc + ngoài thân nến — chờ đủ điều kiện input để đặt gốc mới" + extra);
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Reset EA — SL âm phiên (carry): Σ P/L đóng+mở trong phiên <= -X. |
//+------------------------------------------------------------------+
void ResetAfterSessionNegativePlHardStopHit(const double totalSessionProfitSwapUsd)
{
   ArmStartupRestartDelay("Reset 6g SL âm phiên carry");
   const bool keepCarryForNextSession = (EnableOrderBalanceCarryCapPerSession
                                         && OrderBalanceCarryCapPerSessionUSD > 0.0
                                         && g_balanceCompoundCarryUsd > 0.0);
   const double carryBackup = g_balanceCompoundCarryUsd;
   const double snapClosedPnlSwap = g_compoundSessionClosedTotalProfitSwapUsd;
   const double snapOpenPnlSwap = totalSessionProfitSwapUsd - snapClosedPnlSwap;
   const double sessionLossCarryUsd = ComputeSessionLossCarryUsdForReset(totalSessionProfitSwapUsd, snapClosedPnlSwap, snapOpenPnlSwap);
   CloseAllPositionsAndOrders();
   double restoredCarryUsd = 0.0;
   if(keepCarryForNextSession)
      restoredCarryUsd += carryBackup;
   restoredCarryUsd += sessionLossCarryUsd;
   if(restoredCarryUsd > 0.0)
      CompoundCarryUsdSetTotal(restoredCarryUsd);
   CompoundFloatThrHudUpdate(false);

   if(TryPauseNewSessionAfterResetByDailyProfit("Reset 6g SL âm phiên"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }

   string extra = " | P/L phiên (đóng+mở)=" + DoubleToString(totalSessionProfitSwapUsd, 2)
                    + " USD ≤ -" + DoubleToString(SessionNegativePlHardStopUsd, 2)
                    + " | carry cộng ngưỡng gồng +=" + DoubleToString(sessionLossCarryUsd, 2) + " USD";
   if(EnableCompoundTotalFloatingProfit && CompoundTotalProfitTriggerUSD > 0.0)
      extra += " | ngưỡng gồng lãi tổng=" + DoubleToString(GetCompoundFloatingTriggerThresholdUsd(), 2)
               + " (input " + DoubleToString(CompoundTotalProfitTriggerUSD, 2) + " + carry "
               + DoubleToString(GetCompoundCarryContributionUsd(), 2) + ")";

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Reset 6g — SL âm phiên carry — ngoài lịch chạy, EA chờ.", extra);
      if(EnableResetNotification)
         SendResetNotification("Reset 6g SL âm phiên: ngoài lịch chạy" + extra);
      CompoundFloatThrHudUpdate(false);
      return;
   }

   Print("VDualGrid: Reset 6g — SL âm phiên carry — chờ đủ điều kiện input để đặt gốc mới.", extra);
   if(EnableResetNotification)
      SendResetNotification("Reset 6g SL âm phiên carry: chờ đủ điều kiện input để đặt gốc mới" + extra);
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Reset EA — 6h: carry phiên (từ đầu phiên) đủ ngưỡng → chỉ reset EA.|
//| Carry tổng không cần “cộng thêm” — đã vào đóng góp ngưỡng gồng.     |
//+------------------------------------------------------------------+
void ResetAfterSessionCarryExceedsThresholdHit()
{
   const double snapTot0 = g_balanceCompoundCarryUsd;
   const double snapSess = GetCarryInSessionUsd();

   ArmStartupRestartDelay("Reset 6h carry vượt ngưỡng");
   CloseAllPositionsAndOrders();
   // CloseAllPositionsAndOrders → CompoundModeClearState đặt carry = 0; cần giữ carry tổng (đã cộng dồn) sang phiên sau → gồng.
   CompoundCarryUsdSetTotal(snapTot0);
   CompoundFloatThrHudUpdate(false);

   if(TryPauseNewSessionAfterResetByDailyProfit("Reset 6h carry vượt ngưỡng"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }

   const double thrUsd = SessionCarryExceededResetUsd;
   const string extra = " | carry trong phiên=" + DoubleToString(snapSess, 2) + " USD ≥ " + DoubleToString(thrUsd, 2)
                     + " | carry tổng (đã vào stash gồng)=" + DoubleToString(snapTot0, 2) + " USD";

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Reset 6h — carry vượt ngưỡng — ngoài lịch chạy, EA chờ.", extra);
      if(EnableResetNotification)
         SendResetNotification("Reset 6h carry vượt ngưỡng: ngoài lịch chạy" + extra);
      CompoundFloatThrHudUpdate(false);
      return;
   }

   Print("VDualGrid: Reset 6h — carry vượt ngưỡng — chờ đủ điều kiện input (giờ/ngày/news, EMA/RSI/ADX nếu bật) để đặt gốc mới.", extra);
   if(EnableResetNotification)
      SendResetNotification("Reset 6h carry vượt ngưỡng: chờ đủ điều kiện input để đặt gốc mới" + extra);
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Reset EA khi P/L phiên Σ(đóng+mở) + Σ lot Σ(OUT+mở) thỏa 6f.     |
//+------------------------------------------------------------------+
void ResetAfterSessionPlAndTotalOpenLotsHit(const double totalSessionProfitSwapUsd,
                                             const double sessionOpenLotsSum, const double sessionClosedOutLotsSum)
{
   ArmStartupRestartDelay("Reset 6f P/L+volum");
   const bool keepCarryForNextSession = (EnableOrderBalanceCarryCapPerSession
                                         && OrderBalanceCarryCapPerSessionUSD > 0.0
                                         && g_balanceCompoundCarryUsd > 0.0);
   const double carryBackup = g_balanceCompoundCarryUsd;
   const double snapClosedPnlSwap = g_compoundSessionClosedTotalProfitSwapUsd;
   const double snapOpenPnlSwap = totalSessionProfitSwapUsd - snapClosedPnlSwap;
   const double sessionLossCarryUsd = ComputeSessionLossCarryUsdForReset(totalSessionProfitSwapUsd, snapClosedPnlSwap, snapOpenPnlSwap);
   CloseAllPositionsAndOrders();
   double restoredCarryUsd = 0.0;
   if(keepCarryForNextSession)
      restoredCarryUsd += carryBackup;
   restoredCarryUsd += sessionLossCarryUsd;
   if(restoredCarryUsd > 0.0)
      CompoundCarryUsdSetTotal(restoredCarryUsd);
   CompoundFloatThrHudUpdate(false);

   if(TryPauseNewSessionAfterResetByDailyProfit("Reset 6f"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }

   const double totalLotsClosedPlusOpen = sessionClosedOutLotsSum + sessionOpenLotsSum;
   const string extra = " | P/L phiên (đóng+mở)=" + DoubleToString(totalSessionProfitSwapUsd, 2)
                     + " USD | lot Σ(OUT+mở)=" + DoubleToString(totalLotsClosedPlusOpen, 4)
                     + " (OUT " + DoubleToString(sessionClosedOutLotsSum, 4) + " + mở " + DoubleToString(sessionOpenLotsSum, 4) + ")"
                     + " | carry phiên sau=" + DoubleToString(sessionLossCarryUsd, 2) + " USD";

   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Reset 6f — ngoài lịch chạy, EA chờ.", extra);
      if(EnableResetNotification)
         SendResetNotification("Reset 6f (P/L+lot đóng+mở): ngoài lịch chạy" + extra);
      CompoundFloatThrHudUpdate(false);
      return;
   }

   Print("VDualGrid: Reset 6f — chờ đủ điều kiện input (giờ/ngày/news, EMA/RSI nếu bật) để đặt gốc mới.", extra);
   if(EnableResetNotification)
      SendResetNotification("Reset 6f (P/L+lot đóng+mở): chờ đủ điều kiện input để đặt gốc mới" + extra);
   CompoundFloatThrHudUpdate(false);
}

//+------------------------------------------------------------------+
//| Reset EA khi lãi TEV hiện tại đạt mốc lãi đóng của phiên trước.   |
//+------------------------------------------------------------------+
void ResetAfterPrevSessionPeakReached(const double targetUsd, const double currentTevUsd)
{
   ArmStartupRestartDelay("Reset theo đỉnh phiên trước");
   CloseAllPositionsAndOrders();
   if(TryPauseNewSessionAfterResetByDailyProfit("Reset đỉnh phiên trước"))
   {
      CompoundFloatThrHudUpdate(false);
      return;
   }
   const string extra = " | mốc lãi đóng phiên trước=" + DoubleToString(targetUsd, 2)
                     + " USD | lãi TEV hiện tại=" + DoubleToString(currentTevUsd, 2) + " USD";
   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   CompoundFloatThrHudUpdate(false);

   if(!g_runtimeSessionActive)
   {
      Print("VDualGrid: Reset theo đỉnh phiên trước — đã đóng hết và xóa chờ ảo; ngoài lịch chạy, EA chờ.", extra);
      if(EnableResetNotification)
         SendResetNotification("Reset đỉnh phiên trước: đóng hết + xóa chờ ảo, ngoài lịch chạy, chờ điều kiện input" + extra);
      return;
   }

   Print("VDualGrid: Reset theo đỉnh phiên trước — đã đóng hết và xóa chờ ảo; chờ đủ điều kiện input để đặt gốc mới.", extra);
   if(EnableResetNotification)
      SendResetNotification("Reset đỉnh phiên trước: đóng hết + xóa chờ ảo, chờ điều kiện input đặt gốc mới" + extra);
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
   const double prevCommonSlLine = g_compoundCommonSlLine;

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
      if(g_compoundUseLimitReverseMode && g_compoundCommonSlLine > 0.0)
      {
         Print("VDualGrid: Gồng lãi LIMIT — không còn vị thế quản lý sau khi đã đặt SL chung, reset EA và reset gốc.");
         CompoundResetAfterCommonSlHit();
         return;
      }
      CompoundModeClearState();
      Print("VDualGrid: Gồng lãi tổng — hết vị thế quản lý, TẮT chế độ.");
      ClearDeferVirtualPendingGate();
      NoVirtExecWatchDisarm();
      ManageGridOrders();
      return;
   }

   CompoundClearVirtualPendingsIfPriceAboveReference(g_compoundBuyBasketMode, extOpen);

   const bool resetOnCommonSl = (g_compoundUseLimitReverseMode ? true : CompoundResetOnCommonSlHit);
   if(resetOnCommonSl && g_compoundCommonSlLine > 0.0)
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

   if(prevCommonSlLine > 0.0 && MathAbs(g_compoundCommonSlLine - prevCommonSlLine) >= step - pt * 0.5)
   {
      const int movedSteps = (int)MathRound(MathAbs(g_compoundCommonSlLine - prevCommonSlLine) / step);
      Print("VDualGrid: Gồng lãi — SL chung dịch theo hướng có lợi ",
            IntegerToString(MathMax(1, movedSteps)), " bước lưới -> ",
            DoubleToString(g_compoundCommonSlLine, dgt));
   }
   else if(prevCommonSlLine <= 0.0 && g_compoundCommonSlLine > 0.0)
   {
      Print("VDualGrid: Gồng lãi — SL chung khởi tạo tại ",
            DoubleToString(g_compoundCommonSlLine, dgt));
   }

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
         if(g_compoundUseLimitReverseMode)
            newSL = g_compoundCommonSlLine;
         else
            newSL = MathMax(g_compoundCommonSlLine, openPrice + minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL >= bid - minDist)
            continue;
         if(!g_compoundUseLimitReverseMode && newSL <= openPrice)
            continue;
         if(curSL > 0.0 && newSL <= curSL + pt)
            continue;
      }
      else
      {
         if(g_compoundUseLimitReverseMode)
            newSL = g_compoundCommonSlLine;
         else
            newSL = MathMin(g_compoundCommonSlLine, openPrice - minDist);
         newSL = NormalizeDouble(newSL, dgt);
         if(newSL <= 0.0 || newSL <= ask + minDist)
            continue;
         if(!g_compoundUseLimitReverseMode && newSL >= openPrice)
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
   g_noVirtExecDeadline = 0;
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
int VirtualPendingFindIndex(long magic, ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel)
{
   if(!IsOurMagic(magic)) return -1;
   double tol = gridStep * 0.5;
   if(gridStep <= 0) tol = pnt * 10.0 * GridDistancePips * 0.5;
   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(g_virtualPending[i].magic != magic) continue;
      if(!VirtualPendingSameSide(g_virtualPending[i].orderType, orderType)) continue;
      if(g_virtualPending[i].orderType != orderType) continue;
      if(g_virtualPending[i].leg != leg) continue;
      if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) < tol)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Add virtual pending if not duplicate at level                     |
//+------------------------------------------------------------------+
bool VirtualPendingAdd(long magic, ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel, int levelNum, double tpPrice, double lot)
{
   if(!IsOurMagic(magic))
      return false;
   if(VirtualPendingFindIndex(magic, orderType, leg, priceLevel) >= 0)
      return true;
   int n = ArraySize(g_virtualPending);
   ArrayResize(g_virtualPending, n + 1);
   g_virtualPending[n].magic = magic;
   g_virtualPending[n].orderType = orderType;
   g_virtualPending[n].leg = leg;
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
//| 6c: X nến ĐÃ ĐÓNG gần nhất, liên tiếp (shift 1..X), theo mode EMA đã chọn. |
//| CLOSE: bias +1 khi đủ X3 nến close>EMA(Close), bias -1 khi đủ X3 nến close<EMA(Close). |
//| HIGH/LOW: bias +1 khi đủ X1 nến close>EMA(High), bias -1 khi đủ X2 nến close<EMA(Low). |
//+------------------------------------------------------------------+
bool OrderBalanceLastClosedVsEma(int &biasOut)
{
   biasOut = 0;
   if(!EnableOrderBalanceEMAFilter)
      return false;
   const bool useCloseOnly = (OrderBalanceEMAFilterMode == ORDER_BALANCE_EMA_CLOSE_ONLY);
   if(useCloseOnly)
   {
      if(g_orderBalanceEmaCloseHandle == INVALID_HANDLE)
         return false;
   }
   else
   {
      if(g_orderBalanceEmaHighHandle == INVALID_HANDLE || g_orderBalanceEmaLowHandle == INVALID_HANDLE)
         return false;
   }
   ENUM_TIMEFRAMES tf = OrderBalanceEMATimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;
   int nHigh = OrderBalanceEMAHighConfirmBars;
   if(nHigh < 1)
      nHigh = 1;
   if(nHigh > 50)
      nHigh = 50;
   int nLow = OrderBalanceEMALowConfirmBars;
   if(nLow < 1)
      nLow = 1;
   if(nLow > 50)
      nLow = 50;
   int nClose = OrderBalanceEMACloseConfirmBars;
   if(nClose < 1)
      nClose = 1;
   if(nClose > 50)
      nClose = 50;
   int nBar = (useCloseOnly ? nClose : MathMax(nHigh, nLow));
   const int emaP = MathMax(1, OrderBalanceEMAPeriod);
   if(useCloseOnly)
   {
      if(BarsCalculated(g_orderBalanceEmaCloseHandle) < emaP + nBar + 2)
         return false;
   }
   else
   {
      if(BarsCalculated(g_orderBalanceEmaHighHandle) < emaP + nBar + 2)
         return false;
      if(BarsCalculated(g_orderBalanceEmaLowHandle) < emaP + nBar + 2)
         return false;
   }

   // shift 1 = nến đóng mới nhất; shift 2..N = các nến đóng liền trước đó (không bỏ sót).
   double emaHighVal[];
   double emaLowVal[];
   double emaCloseVal[];
   ArrayResize(emaCloseVal, nBar);
   if(useCloseOnly)
   {
      if(CopyBuffer(g_orderBalanceEmaCloseHandle, 0, 1, nBar, emaCloseVal) != nBar)
         return false;
   }
   else
   {
      ArrayResize(emaHighVal, nBar);
      ArrayResize(emaLowVal, nBar);
      if(CopyBuffer(g_orderBalanceEmaHighHandle, 0, 1, nBar, emaHighVal) != nBar)
         return false;
      if(CopyBuffer(g_orderBalanceEmaLowHandle, 0, 1, nBar, emaLowVal) != nBar)
         return false;
   }

   MqlRates rr[];
   ArrayResize(rr, nBar);
   if(CopyRates(_Symbol, tf, 1, nBar, rr) != nBar)
      return false;

   bool allAbove = true;
   int upCount = (useCloseOnly ? nClose : nHigh);
   for(int i = 0; i < upCount; i++)
   {
      const double cls = rr[i].close;
      bool fail = false;
      if(useCloseOnly)
         fail = (cls <= emaCloseVal[i]);
      else
         fail = (cls <= emaHighVal[i]);
      if(fail)
         allAbove = false;
   }

   bool allBelow = true;
   int downCount = (useCloseOnly ? nClose : nLow);
   for(int j = 0; j < downCount; j++)
   {
      const double cls = rr[j].close;
      bool fail = false;
      if(useCloseOnly)
         fail = (cls >= emaCloseVal[j]);
      else
         fail = (cls >= emaLowVal[j]);
      if(fail)
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
//| 6c: EMA nhanh/chậm tại nến đóng gần nhất (shift 1).               |
//| bias +1: nhanh>chậm (chỉ đóng dưới gốc), -1: nhanh<chậm (chỉ đóng trên). |
//+------------------------------------------------------------------+
bool OrderBalanceFastSlowBias(int &biasOut)
{
   biasOut = 0;
   if(!EnableOrderBalanceFastSlowFilter
      || g_orderBalanceFastEmaHandle == INVALID_HANDLE
      || g_orderBalanceSlowEmaHandle == INVALID_HANDLE)
      return false;

   int pSlow = MathMax(2, OrderBalanceSlowEMAPeriod);
   int pFast = MathMax(1, OrderBalanceFastEMAPeriod);
   if(pFast >= pSlow)
      pFast = pSlow - 1;
   if(pFast < 1)
      pFast = 1;

   const int needBars = pSlow + 2;
   if(BarsCalculated(g_orderBalanceFastEmaHandle) < needBars
      || BarsCalculated(g_orderBalanceSlowEmaHandle) < needBars)
      return false;

   double fastBuf[];
   double slowBuf[];
   ArrayResize(fastBuf, 1);
   ArrayResize(slowBuf, 1);
   if(CopyBuffer(g_orderBalanceFastEmaHandle, 0, 1, 1, fastBuf) != 1)
      return false;
   if(CopyBuffer(g_orderBalanceSlowEmaHandle, 0, 1, 1, slowBuf) != 1)
      return false;

   const double fastVal = fastBuf[0];
   const double slowVal = slowBuf[0];
   if(fastVal > slowVal)
      biasOut = 1;
   else if(fastVal < slowVal)
      biasOut = -1;
   else
      biasOut = 0;
   return true;
}

//+------------------------------------------------------------------+
//| 6c: RSI theo ngưỡng mức tại nến đóng gần nhất (shift1).            |
//| bias +1: RSI > mức trên (đóng dưới gốc), -1: RSI < mức dưới (đóng trên). |
//+------------------------------------------------------------------+
bool OrderBalanceRsiPass(int &biasOut, double &rsiOut)
{
   biasOut = 0;
   rsiOut = 0.0;
   if(!EnableOrderBalanceRSIFilter)
      return false;
   const bool useGreater = (OrderBalanceRSIGreaterLevel >= 0.0);
   const bool useLess = (OrderBalanceRSILessLevel >= 0.0);
   if((!useGreater && !useLess) || g_orderBalanceRsiHandle == INVALID_HANDLE)
      return false;

   const int rsiP = MathMax(1, OrderBalanceRSIPeriod);
   if(BarsCalculated(g_orderBalanceRsiHandle) < rsiP + 1)
      return false;

   double rsiVal[];
   ArrayResize(rsiVal, 1);
   if(CopyBuffer(g_orderBalanceRsiHandle, 0, 1, 1, rsiVal) != 1)
      return false;

   const double rsiCur = rsiVal[0];   // shift 1
   rsiOut = rsiCur;
   double gtLevel = OrderBalanceRSIGreaterLevel;
   if(gtLevel < 0.0) gtLevel = -1.0;
   if(gtLevel > 100.0) gtLevel = 100.0;

   double ltLevel = OrderBalanceRSILessLevel;
   if(ltLevel < 0.0) ltLevel = -1.0;
   if(ltLevel > 100.0) ltLevel = 100.0;

   bool passGreater = false;
   bool passLess = false;
   if(useGreater && gtLevel >= 0.0)
      passGreater = (rsiCur > gtLevel);
   if(useLess && ltLevel >= 0.0)
      passLess = (rsiCur < ltLevel);

   if(passGreater && !passLess)
      biasOut = 1;
   else if(passLess && !passGreater)
      biasOut = -1;
   else
      biasOut = 0;
   return (biasOut != 0);
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
//| 2g: xóa trạng thái auto lot bậc 1 theo Gốc–EMA.                  |
//+------------------------------------------------------------------+
void AutoFirstLotByBaseEmaClearState()
{
   g_autoFirstLotSnapshotActive = false;
   g_autoFirstLotUsingOverride = false;
   g_autoFirstLotSnapshotBase = 0.0;
   g_autoFirstLotSnapshotEma = 0.0;
   g_autoFirstLotGapPips = 0.0;
}

//+------------------------------------------------------------------+
//| 2g: chụp theo base lúc init lưới để quyết định lot bậc 1 phiên này. |
//+------------------------------------------------------------------+
void AutoFirstLotByBaseEmaSnapshotFromGridInit()
{
   if(!EnableAutoFirstLotByBaseEmaGap)
   {
      AutoFirstLotByBaseEmaClearState();
      return;
   }
   if(basePrice <= 0.0)
   {
      AutoFirstLotByBaseEmaClearState();
      return;
   }

   const double baseSnapTol = MathMax(GridPriceTolerance(), SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 2.0);
   if(g_autoFirstLotSnapshotActive && MathAbs(basePrice - g_autoFirstLotSnapshotBase) <= baseSnapTol)
      return;

   AutoFirstLotByBaseEmaClearState();
   if(g_autoFirstLotByBaseEmaHandle == INVALID_HANDLE)
      return;

   const int emaP = MathMax(1, AutoFirstLotByBaseEmaPeriod);
   if(BarsCalculated(g_autoFirstLotByBaseEmaHandle) < emaP + 1)
      return;
   double emaBuf[1];
   if(CopyBuffer(g_autoFirstLotByBaseEmaHandle, 0, 0, 1, emaBuf) != 1)
      return;
   const double emaPx = emaBuf[0];
   if(!MathIsValidNumber(emaPx) || emaPx <= 0.0)
      return;

   const double pipPx = pnt * 10.0;
   if(pipPx <= 0.0)
      return;

   g_autoFirstLotSnapshotBase = basePrice;
   g_autoFirstLotSnapshotEma = emaPx;
   g_autoFirstLotGapPips = MathAbs(basePrice - emaPx) / pipPx;
   g_autoFirstLotSnapshotActive = true;

   const double gapLimit = MathMax(0.0, AutoFirstLotByBaseEmaMaxGapPips);
   g_autoFirstLotUsingOverride = (AutoFirstLotByBaseEmaLot > 0.0 && g_autoFirstLotGapPips <= gapLimit);

   Print("VDualGrid: 2g — auto lot bậc 1 theo Gốc–EMA | base=", DoubleToString(g_autoFirstLotSnapshotBase, dgt),
         " EMA=", DoubleToString(g_autoFirstLotSnapshotEma, dgt),
         " khoảng=", DoubleToString(g_autoFirstLotGapPips, 1), " pip | ngưỡng=", DoubleToString(gapLimit, 1),
         " pip | ", (g_autoFirstLotUsingOverride ? "DÙNG lot auto L1=" + DoubleToString(AutoFirstLotByBaseEmaLot, 2) : "GIỮ lot L1 theo input từng chân"));
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
   int minGap = OrderBalanceMinOrderCountGap;
   if(minGap < 0) minGap = 0;
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
   const bool priceAboveBase = (bid > basePrice + baseEps);
   const bool priceBelowBase = (bid < basePrice - baseEps);
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

   int fastSlowBias = 0;
   if(EnableOrderBalanceFastSlowFilter)
   {
      if(!OrderBalanceFastSlowBias(fastSlowBias))
         return false;
      if(fastSlowBias > 0)
         allowCloseAboveByEma = false; // EMA nhanh > chậm: chỉ cho đóng SELL dưới gốc.
      else if(fastSlowBias < 0)
         allowCloseBelowByEma = false; // EMA nhanh < chậm: chỉ cho đóng BUY trên gốc.
      else
      {
         allowCloseBelowByEma = false;
         allowCloseAboveByEma = false;
      }
   }

   double rsiValue = 0.0;
   int rsiBias = 0;
   const bool useRsiFilter = (EnableOrderBalanceRSIFilter && (OrderBalanceRSIGreaterLevel >= 0.0 || OrderBalanceRSILessLevel >= 0.0));
   if(useRsiFilter)
   {
      if(!OrderBalanceRsiPass(rsiBias, rsiValue))
         return false;
      if(rsiBias > 0)
         allowCloseAboveByEma = false; // RSI > mức trên: chỉ cho nhánh đóng dưới gốc.
      else if(rsiBias < 0)
         allowCloseBelowByEma = false; // RSI < mức dưới: chỉ cho nhánh đóng trên gốc.
   }

   bool wantCloseBelow = false;
   bool wantCloseAbove = false;
   const bool gapBelowOk = (minGap <= 0 || (cntAbove - cntBelow) >= minGap);
   const bool gapAboveOk = (minGap <= 0 || (cntBelow - cntAbove) >= minGap);
   if(allowCloseBelowByEma && priceAboveBase && distAboveOk && g_orderBalAboveSideSince > 0 && (now - g_orderBalAboveSideSince) >= needSec
      && gapBelowOk && cntBelow > 0)
      wantCloseBelow = true;
   if(allowCloseAboveByEma && priceBelowBase && distBelowOk && g_orderBalBelowSideSince > 0 && (now - g_orderBalBelowSideSince) >= needSec
      && gapAboveOk && cntAbove > 0)
      wantCloseAbove = true;

   if(!wantCloseBelow && !wantCloseAbove)
      return false;

   ulong weakTickets[];
   double weakPnLs[];
   int weakLevels[];
   ulong strongTickets[];
   double strongPnLs[];
   int strongLevels[];
   ArrayResize(weakTickets, 0);
   ArrayResize(weakPnLs, 0);
   ArrayResize(weakLevels, 0);
   ArrayResize(strongTickets, 0);
   ArrayResize(strongPnLs, 0);
   ArrayResize(strongLevels, 0);

   const bool closeWeakBelow = (wantCloseBelow && !wantCloseAbove);
   const bool closeWeakAbove = (!wantCloseBelow && wantCloseAbove);
   if(!closeWeakBelow && !closeWeakAbove)
      return false;

   for(int j = 0; j < PositionsTotal(); j++)
   {
      ulong ticket = PositionGetTicket(j);
      if(ticket <= 0 || !PositionIsOurSymbolAndMagic(ticket))
         continue;
      const string posComment = PositionGetString(POSITION_COMMENT);
      int signedLevel = 0;
      if(!TryParseSignedLevelFromOrderComment(posComment, signedLevel))
         FindSignedLevelNumForPrice(PositionGetDouble(POSITION_PRICE_OPEN), signedLevel);
      const double op = PositionGetDouble(POSITION_PRICE_OPEN);
      const double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      const ENUM_POSITION_TYPE ptp = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const int absLevel = (signedLevel != 0 ? MathAbs(signedLevel) : 0);

      if(closeWeakBelow)
      {
         // Giá trên gốc: đóng toàn bộ SELL có giá mở dưới gốc.
         if(op < basePrice - baseEps && ptp == POSITION_TYPE_SELL)
         {
            const int nWeak = ArraySize(weakTickets);
            ArrayResize(weakTickets, nWeak + 1);
            ArrayResize(weakPnLs, nWeak + 1);
            ArrayResize(weakLevels, nWeak + 1);
            weakTickets[nWeak] = ticket;
            weakPnLs[nWeak] = pnl;
            weakLevels[nWeak] = absLevel;
         }
         // 6C5: đóng BUY trên gốc cùng bậc |±N| với SELL dưới gốc sẽ đóng.
         else if(EnableOrderBalanceCloseBothSidesPaired
                 && op > basePrice + baseEps && ptp == POSITION_TYPE_BUY)
         {
            const int nStrong = ArraySize(strongTickets);
            ArrayResize(strongTickets, nStrong + 1);
            ArrayResize(strongPnLs, nStrong + 1);
            ArrayResize(strongLevels, nStrong + 1);
            strongTickets[nStrong] = ticket;
            strongPnLs[nStrong] = pnl;
            strongLevels[nStrong] = absLevel;
         }
      }
      else if(closeWeakAbove)
      {
         // Giá dưới gốc: đóng toàn bộ BUY có giá mở trên gốc.
         if(op > basePrice + baseEps && ptp == POSITION_TYPE_BUY)
         {
            const int nWeak = ArraySize(weakTickets);
            ArrayResize(weakTickets, nWeak + 1);
            ArrayResize(weakPnLs, nWeak + 1);
            ArrayResize(weakLevels, nWeak + 1);
            weakTickets[nWeak] = ticket;
            weakPnLs[nWeak] = pnl;
            weakLevels[nWeak] = absLevel;
         }
         // 6C5: đóng SELL dưới gốc cùng bậc |±N| với BUY trên gốc sẽ đóng.
         else if(EnableOrderBalanceCloseBothSidesPaired
                 && op < basePrice - baseEps && ptp == POSITION_TYPE_SELL)
         {
            const int nStrong = ArraySize(strongTickets);
            ArrayResize(strongTickets, nStrong + 1);
            ArrayResize(strongPnLs, nStrong + 1);
            ArrayResize(strongLevels, nStrong + 1);
            strongTickets[nStrong] = ticket;
            strongPnLs[nStrong] = pnl;
            strongLevels[nStrong] = absLevel;
         }
      }
   }

   const int weakCount = ArraySize(weakTickets);
   if(weakCount < 1)
      return false;

   int maxWeakLevel = 0;
   for(int wl = 0; wl < weakCount; wl++)
   {
      if(weakLevels[wl] > maxWeakLevel)
         maxWeakLevel = weakLevels[wl];
   }

   ulong toClose[];
   double toClosePnL[];
   bool toCloseIsWeak[];
   ArrayResize(toClose, 0);
   ArrayResize(toClosePnL, 0);
   ArrayResize(toCloseIsWeak, 0);

   for(int w = 0; w < weakCount; w++)
   {
      const int n = ArraySize(toClose);
      ArrayResize(toClose, n + 1);
      ArrayResize(toClosePnL, n + 1);
      ArrayResize(toCloseIsWeak, n + 1);
      toClose[n] = weakTickets[w];
      toClosePnL[n] = weakPnLs[w];
      toCloseIsWeak[n] = true;
   }
   for(int s = 0; s < ArraySize(strongTickets); s++)
   {
      if(!EnableOrderBalanceCloseBothSidesPaired)
         break;
      // 6C5: phía cùng với giá hiện tại — từ gốc (bậc 1) đến bậc |±N| = max bậc yếu đang đóng.
      if(maxWeakLevel >= 1)
      {
         if(strongLevels[s] < 1 || strongLevels[s] > maxWeakLevel)
            continue;
      }
      const int n = ArraySize(toClose);
      ArrayResize(toClose, n + 1);
      ArrayResize(toClosePnL, n + 1);
      ArrayResize(toCloseIsWeak, n + 1);
      toClose[n] = strongTickets[s];
      toClosePnL[n] = strongPnLs[s];
      toCloseIsWeak[n] = false;
   }

   if(ArraySize(toClose) < 1)
      return false;

   trade.SetExpertMagicNumber(MagicAA);
   int closed = 0;
   int weakClosed = 0;
   int strongClosed = 0;
   double weakClosedPnL = 0.0;
   double strongClosedPnL = 0.0;
   double totalClosedNegativePnL = 0.0;
   for(int k = ArraySize(toClose) - 1; k >= 0; k--)
   {
      if(!trade.PositionClose(toClose[k]))
         continue;
      closed++;
      if(toClosePnL[k] < 0.0)
         totalClosedNegativePnL += toClosePnL[k];
      if(toCloseIsWeak[k])
      {
         weakClosed++;
         weakClosedPnL += toClosePnL[k];
      }
      else
      {
         strongClosed++;
         strongClosedPnL += toClosePnL[k];
      }
   }

   if(closed < 1)
      return false;

   const double totalClosedPnLSwap = weakClosedPnL + strongClosedPnL;
   const double carryThrUsd = MathMax(0.0, OrderBalanceCarryFullPnLAfterNegativeUsdAccum);
   const bool carryGateOn = EnableOrderBalanceCarryFullPnLAfterNegUsdAccum && carryThrUsd > 0.0;
   const double carryBeforeCloseUsd = g_balanceCompoundCarryUsd;
   // Ngưỡng động theo carry hiện tại: carry > X thì tính cả dương; carry <= X thì chỉ tính âm.
   const bool carryUseFullClosedPnL = carryGateOn && (carryBeforeCloseUsd > carryThrUsd);
   const double carryDeltaUsd = carryUseFullClosedPnL ? totalClosedPnLSwap : totalClosedNegativePnL;
   // Cộng carry vào ngưỡng gồng 6b theo ΔP/L đóng: mặc định chỉ phần âm; sau ngưỡng 6C7 thì gồm cả đóng dương.
   CompoundCarryUsdSetTotal(g_balanceCompoundCarryUsd - carryDeltaUsd);
   // 6d: lưu tổng âm tích lũy do cân bằng 6c đã đóng trong phiên (USD âm).
   if(totalClosedNegativePnL < 0.0)
      g_orderBalanceSessionClosedNegativeUsd += totalClosedNegativePnL;
   OrderBalanceResetSideDwellState();
   g_orderBalLastExecTime = TimeCurrent();

   string emaLog = "";
   if(EnableOrderBalanceEMAFilter)
   {
      int nHighLog = OrderBalanceEMAHighConfirmBars;
      if(nHighLog < 1) nHighLog = 1;
      if(nHighLog > 50) nHighLog = 50;
      int nLowLog = OrderBalanceEMALowConfirmBars;
      if(nLowLog < 1) nLowLog = 1;
      if(nLowLog > 50) nLowLog = 50;
      int nCloseLog = OrderBalanceEMACloseConfirmBars;
      if(nCloseLog < 1) nCloseLog = 1;
      if(nCloseLog > 50) nCloseLog = 50;
      string modeText = (OrderBalanceEMAFilterMode == ORDER_BALANCE_EMA_CLOSE_ONLY
                         ? "EMA Close (X3=" + IntegerToString(nCloseLog) + ")"
                         : "EMA High/Low (X1=" + IntegerToString(nHighLog) + ", X2=" + IntegerToString(nLowLog) + ")");
      emaLog = " | " + modeText + ": "
            + (emaBias > 0 ? "đủ điều kiện nhánh đóng dưới gốc" : (emaBias < 0 ? "đủ điều kiện nhánh đóng trên gốc" : "chưa đủ điều kiện"));
   }
   string fastSlowLog = "";
   if(EnableOrderBalanceFastSlowFilter)
      fastSlowLog = " | EMA nhanh/chậm(shift1): " + (fastSlowBias > 0 ? "nhanh>chậm (chỉ đóng dưới gốc)" : (fastSlowBias < 0 ? "nhanh<chậm (chỉ đóng trên gốc)" : "bằng nhau"));
   string rsiLog = "";
   if(useRsiFilter)
   {
      string cond = "";
      if(OrderBalanceRSIGreaterLevel >= 0.0)
         cond = " > " + DoubleToString(OrderBalanceRSIGreaterLevel, 2) + " (đóng dưới gốc)";
      if(OrderBalanceRSILessLevel >= 0.0)
         cond = (StringLen(cond) > 0 ? cond + " OR < " : " < ") + DoubleToString(OrderBalanceRSILessLevel, 2) + " (đóng trên gốc)";
      string biasText = (rsiBias > 0 ? "bias dưới gốc" : (rsiBias < 0 ? "bias trên gốc" : "không bias"));
      rsiLog = " | RSI(shift1)=" + DoubleToString(rsiValue, 2) + " | điều kiện" + cond + " | " + biasText;
   }
   string pairedLog = "";
   if(EnableOrderBalanceCloseBothSidesPaired)
   {
      pairedLog = " | paired 2 phía (cùng phía giá, bậc 1→" + IntegerToString(maxWeakLevel) + "): yếu "
                  + IntegerToString(weakClosed) + " (" + DoubleToString(weakClosedPnL, 2)
                  + " USD), đối ứng " + IntegerToString(strongClosed) + " (" + DoubleToString(strongClosedPnL, 2) + " USD)";
      if(carryGateOn)
         pairedLog += " | carry Δ " + (carryUseFullClosedPnL ? "Σ đóng (âm+dương)" : "chỉ phần âm");
      else
         pairedLog += " | carry cộng theo tổng phần âm đã đóng";
   }
   string carry6c7Log = "";
   if(carryGateOn)
   {
      if(!carryUseFullClosedPnL)
         carry6c7Log = " | 6C7: carry trước đóng=" + DoubleToString(carryBeforeCloseUsd, 2)
                      + " <= " + DoubleToString(carryThrUsd, 2)
                      + " USD → carry chỉ theo âm";
      else
         carry6c7Log = " | 6C7: carry trước đóng=" + DoubleToString(carryBeforeCloseUsd, 2)
                      + " > " + DoubleToString(carryThrUsd, 2)
                      + " USD → carry theo Σ đóng (âm+dương)";
   }
   else if(!EnableOrderBalanceCloseBothSidesPaired)
      carry6c7Log = " | carry chỉ theo phần đóng âm (6c)";
   Print("VDualGrid: Cân bằng lệnh (6c) — đóng ", closed, " vị thế ",
         (wantCloseBelow ? "dưới" : "trên"), " gốc | P/L đóng (profit+swap) ", DoubleToString(totalClosedPnLSwap, 2),
         " USD | điều chỉnh ngưỡng gồng Σ mở → ", DoubleToString(GetCompoundFloatingTriggerThresholdUsd(), 2), " USD",
         pairedLog, carry6c7Log, emaLog, fastSlowLog, rsiLog);

   ClearDeferVirtualPendingGate();
   NoVirtExecWatchDisarm();
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
void VirtualExecCooldownAdd(double priceLevel, bool isBuy, ENUM_VGRID_LEG leg)
{
   double p = NormalizeDouble(priceLevel, dgt);
   int n = ArraySize(g_virtualExecCooldown);
   ArrayResize(g_virtualExecCooldown, n + 1);
   g_virtualExecCooldown[n].priceLevel = p;
   g_virtualExecCooldown[n].isBuy = isBuy;
   g_virtualExecCooldown[n].leg = leg;
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
bool VirtualReplenishBlockedAfterExecution(double priceLevel, ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, long whichMagic)
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
      if(g_virtualExecCooldown[i].leg != leg) continue;
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
   // Compare previous tick vs current (no triggers on the very first tick).
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
      if(!IsVirtualGridLegEnabled(e.leg))
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
      string cmt = BuildOrderCommentWithLevel(e.leg, e.levelNum);
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
         VirtualExecCooldownAdd(e.priceLevel, (e.orderType == ORDER_TYPE_BUY_STOP || e.orderType == ORDER_TYPE_BUY_LIMIT), e.leg);
         g_noVirtExecHadSuccessfulTrigger = true;
         g_noVirtExecDeadline = 0;
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
//| Tổng float (profit+swap) vị thế mở: magic EA + symbol biểu đồ (không gộp symbol khác). |
//+------------------------------------------------------------------+
double GetOurMagicFloatingUSD()
{
   double f = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
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
//| Vốn đã đóng: chỉ balance gốc + P/L deal OUT, bỏ qua lệnh thả nổi. |
//+------------------------------------------------------------------+
double GetTradingClosedCapitalUSD()
{
   return attachBalance + eaCumulativeTradingPL;
}

//+------------------------------------------------------------------+
//| Mốc cho % P/L trong tin: TEV tại khởi động EA (đóng+treo tại thời điểm đó). |
//| Reset phiên không làm mới mốc.                                   |
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

// nowSrv phải là TimeCurrent() (giờ server sàn), không dùng TimeLocal.
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
   if(EnableAvoidUsdHighImpactNews && HasUsdHighImpactNewsPauseWindow(nowSrv))
      return false;
   return true;
}

datetime ServerDayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

long ServerDateKey(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return (long)dt.year * 10000L + (long)dt.mon * 100L + (long)dt.day;
}

bool HasUsdHighImpactNewsPauseWindow(const datetime nowSrv)
{
   if(!EnableAvoidUsdHighImpactNews)
      return false;

   const long dateKey = ServerDateKey(nowSrv);
   if(g_newsAvoidCachedDateKey == dateKey)
      return g_newsAvoidHasUsdHighImpactToday;

   g_newsAvoidCachedDateKey = dateKey;
   g_newsAvoidHasUsdHighImpactToday = false;

   const datetime dayStart = ServerDayStart(nowSrv);
   // Chặn phiên mới trong "ngày trước tin + ngày có tin":
   // nếu hôm nay hoặc ngày mai có USD high impact thì khóa.
   const datetime dayEnd = dayStart + 2 * 24 * 60 * 60 - 1;
   MqlCalendarValue values[];
   ResetLastError();
   const int total = CalendarValueHistory(values, dayStart, dayEnd, NULL, "USD");
   if(total < 0)
   {
      const int err = GetLastError();
      if(g_newsAvoidLoggedCalendarErrDateKey != dateKey)
      {
         Print("VDualGrid: tránh tin USD L3 — không đọc được lịch kinh tế (err=", err, "). Bỏ chặn tin trong cửa sổ hôm nay+ngày mai.");
         g_newsAvoidLoggedCalendarErrDateKey = dateKey;
      }
      return false;
   }

   for(int i = 0; i < total; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if((int)ev.importance >= 2) // MQL5: High impact (thường hiển thị cấp độ 3)
      {
         g_newsAvoidHasUsdHighImpactToday = true;
         break;
      }
   }

   if(g_newsAvoidHasUsdHighImpactToday && g_newsAvoidLoggedBlockedDateKey != dateKey)
   {
      Print("VDualGrid: tránh tin USD L3 — hôm nay hoặc ngày mai có tin quan trọng, khóa khởi động phiên mới.");
      g_newsAvoidLoggedBlockedDateKey = dateKey;
   }
   return g_newsAvoidHasUsdHighImpactToday;
}

//| Tổng P/L đã chốt (profit+swap+commission) từ 00:00 server → hiện tại, chart này + Magic. |
//| Trong ngày: chưa đạt ngưỡng 8D thì phiên sau vẫn cộng dồn (mọi phiên cùng ngày gộp một tổng). |
//| Sang ngày server mới: chỉ tính deal từ 0h ngày mới → không mang phần dư sang ngày kế. |
double GetTodayClosedProfitUsd(const datetime nowSrv)
{
   const datetime dayStart = ServerDayStart(nowSrv);
   if(!HistorySelect(dayStart, nowSrv + 1))
      return 0.0;

   const int deals = HistoryDealsTotal();
   double totalUsd = 0.0;
   for(int i = 0; i < deals; i++)
   {
      const ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      const long dType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      if(dType != DEAL_TYPE_BUY && dType != DEAL_TYPE_SELL)
         continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      if(!IsOurMagic(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)))
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;

      totalUsd += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
               +  HistoryDealGetDouble(dealTicket, DEAL_SWAP)
               +  HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   }
   return totalUsd;
}

bool IsDailyProfitPauseActiveNow(const datetime nowSrv)
{
   if(g_dailyProfitPauseDateKey == 0)
      return false;
   const long nowDateKey = ServerDateKey(nowSrv);
   if(g_dailyProfitPauseDateKey != nowDateKey)
   {
      g_dailyProfitPauseDateKey = 0;
      g_dailyProfitPauseLoggedDateKey = 0;
      return false;
   }
   return true;
}

//| 8D: tổng lãi đóng trong ngày server (cộng dồn mọi phiên trong ngày) ≥ ngưỡng → khóa tới ngày sau. |
//| Chưa đạt ngưỡng trong ngày: phiên kế tiếp vẫn tính trên cùng tổng (không reset giữa phiên).        |
//| closeAllFirst=true: đóng hết vị thế/chờ khi kích hoạt giữa phiên; false: caller đã đóng sạch.|
//| Trả về true nếu đang khóa theo ngày (sẵn có hoặc vừa kích hoạt).                            |
bool EnsureDailyProfitPauseIfThresholdExceeded(const datetime nowSrv, const string reasonTag, const bool closeAllFirst)
{
   if(!EnableDailyProfitPauseAfterReset || DailyProfitPauseThresholdUSD <= 0.0)
      return false;

   if(IsDailyProfitPauseActiveNow(nowSrv))
   {
      g_runtimeSessionActive = false;
      return true;
   }

   const double dayClosedProfitUsd = GetTodayClosedProfitUsd(nowSrv);
   if(dayClosedProfitUsd + 1e-8 < DailyProfitPauseThresholdUSD)
      return false;

   if(closeAllFirst)
   {
      CloseAllPositionsAndOrders();
      CompoundFloatThrHudUpdate(false);
   }

   const long nowDateKey = ServerDateKey(nowSrv);
   g_dailyProfitPauseDateKey = nowDateKey;
   g_dailyProfitPauseLoggedDateKey = nowDateKey;
   g_runtimeSessionActive = false;
   VirtualPendingClear();
   ArrayResize(gridLevels, 0);
   sessionStartTime = 0;
   basePrice = 0.0;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;

   const string msg = reasonTag + " — lãi ngày (cộng dồn phiên) đạt " + DoubleToString(dayClosedProfitUsd, 2)
                    + " USD (ngưỡng " + DoubleToString(DailyProfitPauseThresholdUSD, 2)
                    + ") => tạm dừng EA tới ngày server kế tiếp.";
   Print("VDualGrid: ", msg);
   if(EnableResetNotification)
      SendResetNotification(msg);
   return true;
}

bool TryPauseNewSessionAfterResetByDailyProfit(const string resetReasonTag)
{
   return EnsureDailyProfitPauseIfThresholdExceeded(TimeCurrent(), resetReasonTag, false);
}

//+------------------------------------------------------------------+
//| 2e: giải phóng handle EMA khởi động.                               |
//+------------------------------------------------------------------+
void StartupEmaCrossReleaseHandles()
{
   if(g_startupEmaFastHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_startupEmaFastHandle);
      g_startupEmaFastHandle = INVALID_HANDLE;
   }
   if(g_startupEmaSlowHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_startupEmaSlowHandle);
      g_startupEmaSlowHandle = INVALID_HANDLE;
   }
   if(g_startupThreeEma1Handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_startupThreeEma1Handle);
      g_startupThreeEma1Handle = INVALID_HANDLE;
   }
   if(g_startupThreeEma2Handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_startupThreeEma2Handle);
      g_startupThreeEma2Handle = INVALID_HANDLE;
   }
   if(g_startupThreeEma3Handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_startupThreeEma3Handle);
      g_startupThreeEma3Handle = INVALID_HANDLE;
   }
   if(g_startupOpenGapEmaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_startupOpenGapEmaHandle);
      g_startupOpenGapEmaHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| 2e: tạo iMA nhanh/chậm (chu kỳ nhanh < chậm).                      |
//+------------------------------------------------------------------+
void StartupEmaCrossInitHandles()
{
   StartupEmaCrossReleaseHandles();
   ENUM_TIMEFRAMES tf = StartupEmaCrossTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;

   if(EnableStartupOpenGapToEmaLimit)
   {
      const int pGap = MathMax(1, StartupOpenGapToEmaPeriod);
      g_startupOpenGapEmaHandle = iMA(_Symbol, tf, pGap, 0, MODE_EMA, PRICE_CLOSE);
      if(g_startupOpenGapEmaHandle == INVALID_HANDLE)
         Print("VDualGrid: 2e — không tạo iMA EMA(Open-gap) để giới hạn khoảng cách Open-EMA.");
   }

   if(EnableStartupThreeEmaOrdered)
   {
      int a = MathMax(1, StartupThreeEmaPeriod1);
      int b = MathMax(1, StartupThreeEmaPeriod2);
      int c = MathMax(1, StartupThreeEmaPeriod3);
      int pSmall = a, pMid = b, pLarge = c;
      if(pSmall > pMid) { const int t = pSmall; pSmall = pMid; pMid = t; }
      if(pSmall > pLarge) { const int t = pSmall; pSmall = pLarge; pLarge = t; }
      if(pMid > pLarge) { const int t = pMid; pMid = pLarge; pLarge = t; }
      if(pMid <= pSmall)
         pMid = pSmall + 1;
      if(pLarge <= pMid)
         pLarge = pMid + 1;
      g_startupThreeEma1Handle = iMA(_Symbol, tf, pSmall, 0, MODE_EMA, PRICE_CLOSE);
      g_startupThreeEma2Handle = iMA(_Symbol, tf, pMid, 0, MODE_EMA, PRICE_CLOSE);
      g_startupThreeEma3Handle = iMA(_Symbol, tf, pLarge, 0, MODE_EMA, PRICE_CLOSE);
      if(g_startupThreeEma1Handle == INVALID_HANDLE || g_startupThreeEma2Handle == INVALID_HANDLE
         || g_startupThreeEma3Handle == INVALID_HANDLE)
         Print("VDualGrid: 2e — không tạo iMA xếp 3 EMA (chờ thứ tự đường đặt gốc).");
      return;
   }

   if(!EnableStartupEmaFastSlowCross)
      return;
   int pLo = MathMax(1, MathMin(StartupEmaFastPeriod, StartupEmaSlowPeriod));
   int pHi = MathMax(1, MathMax(StartupEmaFastPeriod, StartupEmaSlowPeriod));
   if(pLo >= pHi)
      pHi = pLo + 1;
   g_startupEmaFastHandle = iMA(_Symbol, tf, pLo, 0, MODE_EMA, PRICE_CLOSE);
   g_startupEmaSlowHandle = iMA(_Symbol, tf, pHi, 0, MODE_EMA, PRICE_CLOSE);
   if(g_startupEmaFastHandle == INVALID_HANDLE || g_startupEmaSlowHandle == INVALID_HANDLE)
      Print("VDualGrid: 2e — không tạo iMA EMA nhanh/chậm (chờ cắt đặt gốc).");
}

//+------------------------------------------------------------------+
//| 2e: cắt EMA nhanh/chậm “1 shift”: so shift 0 (nến hiện tại) với 1. |
//| Cắt lên: f0>s0 && f1<=s1; cắt xuống: f0<s0 && f1>=s1.              |
//| Chỉ gọi khi basePrice<=0; khi đã có gốc, OnTick không gọi hàm này. |
//+------------------------------------------------------------------+
bool StartupEmaFastSlowCrossShift0vs1()
{
   if(!EnableStartupEmaFastSlowCross)
      return true;
   if(g_startupEmaFastHandle == INVALID_HANDLE || g_startupEmaSlowHandle == INVALID_HANDLE)
      return false;
   double bf[2], bs[2];
   if(CopyBuffer(g_startupEmaFastHandle, 0, 0, 2, bf) != 2)
      return false;
   if(CopyBuffer(g_startupEmaSlowHandle, 0, 0, 2, bs) != 2)
      return false;
   const double f0 = bf[0], f1 = bf[1], s0 = bs[0], s1 = bs[1];
   if(!MathIsValidNumber(f0) || !MathIsValidNumber(f1) || !MathIsValidNumber(s0) || !MathIsValidNumber(s1))
      return false;
   const bool crossUp = (f0 > s0 && f1 <= s1);
   const bool crossDn = (f0 < s0 && f1 >= s1);
   return (crossUp || crossDn);
}

//+------------------------------------------------------------------+
//| 2e: có bất kỳ lọc EMA khởi động nào đang bật (chờ trước khi đặt gốc). |
//+------------------------------------------------------------------+
bool StartupEmaAnyFilterWaiting()
{
   return (EnableStartupThreeEmaOrdered
           || EnableStartupEmaFastSlowCross
           || EnableStartupOpenGapToEmaLimit
           || EnableStartupThreeSameColorCandles);
}

//+------------------------------------------------------------------+
//| 2e: đủ điều kiện EMA để đặt gốc (xếp 3 đường ưu tiên hơn cắt nhanh/chậm). |
//+------------------------------------------------------------------+
bool StartupEmaBaseConditionPass()
{
   bool emaPass = true;
   if(EnableStartupThreeEmaOrdered)
      emaPass = StartupThreeEmaOrderedPassShift0();
   else if(EnableStartupEmaFastSlowCross)
      emaPass = StartupEmaFastSlowCrossShift0vs1();
   if(!emaPass)
      return false;
   if(!StartupOpenGapToEmaPassShift0())
      return false;
   return StartupThreeSameColorCandlesPass();
}

//+------------------------------------------------------------------+
//| Giới hạn X cho điều kiện 2i (tránh buffer quá lớn / giá trị vô nghĩa). |
//+------------------------------------------------------------------+
int StartupSameColorConsecutiveBarsClamped()
{
   int x = StartupSameColorConsecutiveCount;
   if(x < 1)
      x = 1;
   if(x > 50)
      x = 50;
   return x;
}

//+------------------------------------------------------------------+
//| 2i: X nến đóng gần nhất (shift1..X) cùng màu xanh/đỏ,            |
//| nến đóng shift X+1 phải khác màu. Doji (close==open) → không đạt.  |
//+------------------------------------------------------------------+
bool StartupThreeSameColorCandlesPass()
{
   if(!EnableStartupThreeSameColorCandles)
      return true;

   ENUM_TIMEFRAMES tf = StartupThreeSameColorCandlesTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;

   const int x = StartupSameColorConsecutiveBarsClamped();
   const int need = x + 1;

   double o[], c[];
   ArrayResize(o, need);
   ArrayResize(c, need);
   if(CopyOpen(_Symbol, tf, 1, need, o) != need)
      return false;
   if(CopyClose(_Symbol, tf, 1, need, c) != need)
      return false;

   int dir = 0; // 1: xanh, -1: đỏ (X nến → phần tử 0..x-1 = shift1..X)
   for(int i = 0; i < x; i++)
   {
      if(!MathIsValidNumber(o[i]) || !MathIsValidNumber(c[i]))
         return false;
      if(c[i] > o[i])
      {
         if(dir == -1)
            return false;
         dir = 1;
      }
      else if(c[i] < o[i])
      {
         if(dir == 1)
            return false;
         dir = -1;
      }
      else
      {
         return false;
      }
   }

   // Nến ngay trước chuỗi (shift X+1) phải rõ xanh/đỏ và ngược màu
   if(!MathIsValidNumber(o[x]) || !MathIsValidNumber(c[x]))
      return false;
   if(c[x] == o[x])
      return false;
   const int dirPrev = (c[x] > o[x]) ? 1 : -1;
   return (dirPrev != dir);
}

//+------------------------------------------------------------------+
//| 2e: EMA1>EMA2>EMA3 (và tùy chọn nến hiện tại > EMA3), hoặc EMA1<EMA2<EMA3 (và tùy chọn nến hiện tại < EMA3). |
//+------------------------------------------------------------------+
bool StartupThreeEmaOrderedPassShift0()
{
   if(!EnableStartupThreeEmaOrdered)
      return true;
   if(g_startupThreeEma1Handle == INVALID_HANDLE || g_startupThreeEma2Handle == INVALID_HANDLE
      || g_startupThreeEma3Handle == INVALID_HANDLE)
      return false;

   if(BarsCalculated(g_startupThreeEma1Handle) < 2
      || BarsCalculated(g_startupThreeEma2Handle) < 2
      || BarsCalculated(g_startupThreeEma3Handle) < 2)
      return false;

   double v1[1], v2[1], v3[1];
   if(CopyBuffer(g_startupThreeEma1Handle, 0, 0, 1, v1) != 1)
      return false;
   if(CopyBuffer(g_startupThreeEma2Handle, 0, 0, 1, v2) != 1)
      return false;
   if(CopyBuffer(g_startupThreeEma3Handle, 0, 0, 1, v3) != 1)
      return false;
   const double e1 = v1[0], e2 = v2[0], e3 = v3[0];
   if(!MathIsValidNumber(e1) || !MathIsValidNumber(e2) || !MathIsValidNumber(e3))
      return false;

   const bool upStack = (e1 > e2 && e2 > e3);
   const bool dnStack = (e1 < e2 && e2 < e3);
   if(!EnableStartupThreeEmaCandleVsEma3)
      return (upStack || dnStack);

   ENUM_TIMEFRAMES tf = StartupEmaCrossTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;
   double c0[1];
   if(CopyClose(_Symbol, tf, 0, 1, c0) != 1)
      return false;
   const double close0 = c0[0];
   if(!MathIsValidNumber(close0))
      return false;

   const bool upPass = (upStack && close0 > e3);
   const bool dnPass = (dnStack && close0 < e3);
   return (upPass || dnPass);
}

//+------------------------------------------------------------------+
//| 2e: chỉ cho đặt gốc khi khoảng cách Open nến hiện tại đến EMA(X) không vượt quá ngưỡng pip. |
//+------------------------------------------------------------------+
bool StartupOpenGapToEmaPassShift0()
{
   if(!EnableStartupOpenGapToEmaLimit)
      return true;
   if(g_startupOpenGapEmaHandle == INVALID_HANDLE)
      return false;
   if(BarsCalculated(g_startupOpenGapEmaHandle) < 2)
      return false;

   ENUM_TIMEFRAMES tf = StartupEmaCrossTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;

   double open0Buf[1];
   if(CopyOpen(_Symbol, tf, 0, 1, open0Buf) != 1)
      return false;
   double ema0Buf[1];
   if(CopyBuffer(g_startupOpenGapEmaHandle, 0, 0, 1, ema0Buf) != 1)
      return false;

   const double open0 = open0Buf[0];
   const double ema0 = ema0Buf[0];
   if(!MathIsValidNumber(open0) || !MathIsValidNumber(ema0))
      return false;

   const double pipPx = OnePipPrice();
   if(pipPx <= 0.0)
      return false;

   const double gapPips = MathAbs(open0 - ema0) / pipPx;
   const double maxGapPips = MathMax(0.0, StartupOpenGapToEmaMaxPips);
   return (gapPips <= maxGapPips);
}

//+------------------------------------------------------------------+
//| 2f: RSI cắt mức (shift2→1), tùy chọn N nến đóng trước đó cùng phía ngưỡng (lookback). |
//+------------------------------------------------------------------+
bool StartupRsiPassForBase(double &rsiOut)
{
   rsiOut = 0.0;
   if(!EnableStartupRsiBaseFilter)
      return true;
   const bool useAbove = (StartupRsiAboveLevel >= 0.0);
   const bool useBelow = (StartupRsiBelowLevel >= 0.0);
   if(!useAbove && !useBelow)
      return false;
   if(g_startupRsiHandle == INVALID_HANDLE)
      return false;

   const int rsiP = MathMax(1, StartupRsiPeriod);
   const int lookN = MathMax(0, StartupRsiCrossLookbackBars);
   const bool useRecentTouch = EnableStartupRsiRecentTouchFilter;
   const int recentBars = MathMax(1, StartupRsiRecentTouchBars);
   int copyCount = (lookN > 0 ? lookN + 1 : 2);
   if(useRecentTouch)
      copyCount = MathMax(copyCount, recentBars + 1);
   if(BarsCalculated(g_startupRsiHandle) < rsiP + copyCount + 1)
      return false;

   double rsiVal[];
   ArrayResize(rsiVal, copyCount);
   if(CopyBuffer(g_startupRsiHandle, 0, 1, copyCount, rsiVal) != copyCount)
      return false;

   const double rsiCur = rsiVal[0];   // shift 1 — nến đóng gần nhất
   const double rsiPrev = (copyCount >= 2 ? rsiVal[1] : rsiVal[0]);  // shift 2
   rsiOut = rsiCur;
   double aboveLv = StartupRsiAboveLevel;
   if(aboveLv > 100.0) aboveLv = 100.0;
   double belowLv = StartupRsiBelowLevel;
   if(belowLv > 100.0) belowLv = 100.0;

   bool passAbove = false;
   bool passBelow = false;
   if(useAbove)
   {
      if(lookN <= 0)
         passAbove = (rsiPrev <= aboveLv && rsiCur > aboveLv);
      else if(rsiCur > aboveLv)
      {
         passAbove = true;
         for(int i = 1; i <= lookN; i++)
         {
            if(i >= copyCount || !(rsiVal[i] < aboveLv))
            {
               passAbove = false;
               break;
            }
         }
      }
   }
   if(useBelow)
   {
      if(lookN <= 0)
         passBelow = (rsiPrev >= belowLv && rsiCur < belowLv);
      else if(rsiCur < belowLv)
      {
         passBelow = true;
         for(int i = 1; i <= lookN; i++)
         {
            if(i >= copyCount || !(rsiVal[i] > belowLv))
            {
               passBelow = false;
               break;
            }
         }
      }
   }
   if(useRecentTouch)
   {
      bool seenPastExtreme = false; // Trong quá khứ có ít nhất 1 nến >X hoặc <X1
      for(int i = 1; i <= recentBars; i++) // shift2…shift(X+1)
      {
         if(i >= copyCount)
            break;
         const double r = rsiVal[i];
         if((useAbove && r > aboveLv) || (useBelow && r < belowLv))
         {
            seenPastExtreme = true;
            break;
         }
      }
      passAbove = (passAbove && seenPastExtreme);
      passBelow = (passBelow && seenPastExtreme);
   }
   return (passAbove || passBelow);
}

//+------------------------------------------------------------------+
//| 2h: ADX đường chính — từng nến đóng shift 1…X: tùy chọn ADX>X1 và/hoặc ADX<X2 (X≤0 = tắt nhánh đó). |
//+------------------------------------------------------------------+
bool StartupAdxPassForBase(double &adxOut)
{
   adxOut = 0.0;
   if(!EnableStartupAdxBaseFilter)
      return true;
   if(g_startupAdxHandle == INVALID_HANDLE)
      return false;

   const double x1 = StartupAdxGreaterThanLevel;
   const double x2 = StartupAdxLessThanLevel;
   const bool needGt = (x1 > 0.0);
   const bool needLt = (x2 > 0.0);
   if(!needGt && !needLt)
      return true;

   const int adxP = MathMax(1, StartupAdxPeriod);
   const int nBars = MathMax(1, StartupAdxBarsAboveLevel);
   const int needBars = MathMax(adxP * 2, adxP + nBars + 2);
   if(BarsCalculated(g_startupAdxHandle) < needBars)
      return false;

   double adxVal[];
   ArrayResize(adxVal, nBars);
   if(CopyBuffer(g_startupAdxHandle, 0, 1, nBars, adxVal) != nBars)
      return false;

   adxOut = adxVal[0];
   for(int i = 0; i < nBars; i++)
   {
      if(needGt && !(adxVal[i] > x1))
         return false;
      if(needLt && !(adxVal[i] < x2))
         return false;
   }
   return true;
}

bool StartupRsiAndAdxPassForBase(double &rsiOut, double &adxOut)
{
   rsiOut = 0.0;
   adxOut = 0.0;
   return StartupRsiPassForBase(rsiOut) && StartupAdxPassForBase(adxOut);
}

string StartupAdxWaitReasonAdxPart()
{
   const int n = MathMax(1, StartupAdxBarsAboveLevel);
   const string nStr = IntegerToString(n);
   const double x1 = StartupAdxGreaterThanLevel;
   const double x2 = StartupAdxLessThanLevel;
   const bool g = (x1 > 0.0);
   const bool l = (x2 > 0.0);
   if(g && l)
      return "ADX>" + DoubleToString(x1, 1) + " và ADX<" + DoubleToString(x2, 1) + " trên " + nStr + " nến đóng (shift1→" + nStr + ")";
   if(g)
      return "ADX>" + DoubleToString(x1, 1) + " trên " + nStr + " nến đóng (shift1→" + nStr + ")";
   if(l)
      return "ADX<" + DoubleToString(x2, 1) + " trên " + nStr + " nến đóng (shift1→" + nStr + ")";
   return "ADX (2h bật nhưng X1/X2 đều tắt — không lọc ngưỡng)";
}

string StartupAdxEmaCondTagShort()
{
   const int n = MathMax(1, StartupAdxBarsAboveLevel);
   const double x1 = StartupAdxGreaterThanLevel;
   const double x2 = StartupAdxLessThanLevel;
   const bool g = (x1 > 0.0);
   const bool l = (x2 > 0.0);
   if(!g && !l)
      return "ADX(2h: X1/X2 tắt)";
   string s = "ADX";
   if(g)
      s += ">" + DoubleToString(x1, 1);
   if(l)
      s += (g ? "+" : "") + "<" + DoubleToString(x2, 1);
   s += "×" + IntegerToString(n) + "nến";
   return s;
}

string StartupRsiWaitReasonRsiPart()
{
   if(EnableStartupRsiRecentTouchFilter)
   {
      const int x = MathMax(1, StartupRsiRecentTouchBars);
      return "RSI cắt mức (shift2→1) + trong " + IntegerToString(x)
           + " nến quá khứ có ít nhất 1 nến RSI >X hoặc RSI <X1";
   }
   const int lb = MathMax(0, StartupRsiCrossLookbackBars);
   if(lb > 0)
      return "RSI cắt (shift2→1) + " + IntegerToString(lb)
           + " nến đóng trước: cắt lên → RSI đều <X; cắt xuống → đều >X1";
   return "RSI cắt mức (shift2→1)";
}

string StartupRsiAdxWaitReasonPhrase()
{
   const bool r = EnableStartupRsiBaseFilter;
   const bool a = EnableStartupAdxBaseFilter;
   if(!r && !a)
      return "";
   if(r && !a)
      return StartupRsiWaitReasonRsiPart();
   if(!r && a)
      return StartupAdxWaitReasonAdxPart();
   return StartupRsiWaitReasonRsiPart() + " và " + StartupAdxWaitReasonAdxPart();
}

//+------------------------------------------------------------------+
//| 10: Panel bảng lợi nhuận tháng (deal OUT, magic+symbol EA).       |
//| Tiền tố object có Magic để không trùng khi >1 EA cùng biểu đồ.     |
//+------------------------------------------------------------------+
string MpPanelObjPrefix()
{
   return "VDG_MPROF_" + IntegerToString(MagicAA) + "_";
}

int MpDaysInMonth(const int year, const int mon)
{
   if(mon == 2)
      return ((((year % 4 == 0) && (year % 100 != 0)) || (year % 400 == 0)) ? 29 : 28);
   if(mon == 4 || mon == 6 || mon == 9 || mon == 11)
      return 30;
   return 31;
}

datetime MpMonthStartServer(const int year, const int mon)
{
   MqlDateTime d;
   ZeroMemory(d);
   d.year = year;
   d.mon = mon;
   d.day = 1;
   d.hour = 0;
   d.min = 0;
   d.sec = 0;
   return StructToTime(d);
}

bool MpIsSameMonth(const datetime t, const datetime monthStart)
{
   MqlDateTime a, b;
   TimeToStruct(t, a);
   TimeToStruct(monthStart, b);
   return (a.year == b.year && a.mon == b.mon);
}

void MonthlyProfitPanelDeleteAll()
{
   const string pref = MpPanelObjPrefix();
   string toDel[];
   const int total = ObjectsTotal(0, -1, -1);
   for(int i = 0; i < total; i++)
   {
      const string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, pref) == 0)
      {
         const int n = ArraySize(toDel);
         ArrayResize(toDel, n + 1);
         toDel[n] = nm;
      }
   }
   for(int j = 0; j < ArraySize(toDel); j++)
      ObjectDelete(0, toDel[j]);
}

bool MpLabelCreate(const string name, const int x, const int y, const string text,
                   const int fontPx, const color clr, const bool bold,
                   const ENUM_BASE_CORNER corner)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontPx);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

bool MpRectCreate(const string name, const int x, const int y, const int w, const int h,
                  const color bg, const color border, const ENUM_BASE_CORNER corner)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

bool MpButtonCreate(const string name, const int x, const int y, const int w, const int h,
                    const string caption, const ENUM_BASE_CORNER corner)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, caption);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'45,48,58');
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C'70,75,90');
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

int MpCountOpenOurPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      n++;
   }
   return n;
}

void MonthlyProfitPanelOnInitState()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now); // Dùng giờ server theo tick hiện tại của sàn
   g_mpViewMonthStart = MpMonthStartServer(now.year, now.mon);
    g_mpLastSeenServerMonthStart = g_mpViewMonthStart;
   g_mpAutoFollowCurrentMonth = true;
}

void MonthlyProfitPanelOnTradeRefresh()
{
   if(!EnableMonthlyProfitPanel)
      return;
   g_mpLastRedrawTick = 0;
   MonthlyProfitPanelRedrawIfNeeded(true);
}

void MonthlyProfitPanelRedrawIfNeeded(const bool force)
{
   if(!EnableMonthlyProfitPanel)
   {
      if(g_mpPanelWasEnabled)
      {
         MonthlyProfitPanelDeleteAll();
         g_mpPanelWasEnabled = false;
      }
      return;
   }
   g_mpPanelWasEnabled = true;
   const ulong nowMs = GetTickCount64();
   if(!force && (nowMs - g_mpLastRedrawTick) < 400)
      return;
   g_mpLastRedrawTick = nowMs;

   if(g_mpViewMonthStart <= 0)
      MonthlyProfitPanelOnInitState();

   MqlDateTime vm;
   TimeToStruct(g_mpViewMonthStart, vm);
   const int vy = vm.year;
   const int vmon = vm.mon;
   const int dim = MpDaysInMonth(vy, vmon);
   const datetime tFrom = MpMonthStartServer(vy, vmon);
   MqlDateTime endm;
   endm.year = vy;
   endm.mon = vmon;
   endm.day = dim;
   endm.hour = 23;
   endm.min = 59;
   endm.sec = 59;
   const datetime tTo = StructToTime(endm);

   static double dayPnl[32];
   static int dayDeals[32];
   ArrayInitialize(dayPnl, 0.0);
   ArrayInitialize(dayDeals, 0);

   double monthTotal = 0.0;
   int totalClosedDeals = 0;
   // Chỉ tháng đang xem (vy/vmon): sang tháng mới = tổng lại từ deal tháng đó (chưa có deal → 0).
   double monthSumUsdProfit = 0.0;   // Σ lệnh đóng lãi trong tháng (profit+swap+commission), >0
   double monthSumUsdLossAbs = 0.0; // Σ |lỗ| trong tháng (deal đóng âm)
   int tradingDays = 0;

   if(HistorySelect(tFrom, tTo))
   {
      const int nd = HistoryDealsTotal();
      for(int i = 0; i < nd; i++)
      {
         const ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0)
            continue;
         const long dType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
         if(dType != DEAL_TYPE_BUY && dType != DEAL_TYPE_SELL)
            continue;
         if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
            continue;
         if(!IsOurMagic(HistoryDealGetInteger(dealTicket, DEAL_MAGIC)))
            continue;
         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
            continue;
         const datetime dt = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
         if(dt < tFrom || dt > tTo)
            continue;

         MqlDateTime dd;
         TimeToStruct(dt, dd);
         if(dd.year != vy || dd.mon != vmon || dd.day < 1 || dd.day > 31)
            continue;

         const double fullPnL = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                                + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                                + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         const int di = dd.day;
         dayPnl[di] += fullPnL;
         dayDeals[di]++;
         monthTotal += fullPnL;
         totalClosedDeals++;
         if(fullPnL > 0.0)
            monthSumUsdProfit += fullPnL;
         else if(fullPnL < 0.0)
            monthSumUsdLossAbs += -fullPnL;
      }
   }

   for(int d = 1; d <= 31; d++)
   {
      if(dayDeals[d] > 0)
         tradingDays++;
   }

   const double avgDaily = (tradingDays > 0) ? (monthTotal / (double)tradingDays) : 0.0;
   const double usdWinLossDenom = monthSumUsdProfit + monthSumUsdLossAbs;
   double winRateUsdPct = 0.0;
   if(usdWinLossDenom > 1e-8)
      winRateUsdPct = 100.0 * monthSumUsdProfit / usdWinLossDenom;

   MqlDateTime srvNow;
   TimeToStruct(TimeCurrent(), srvNow); // Dùng giờ server theo tick hiện tại của sàn
   const datetime todayMonthStart = MpMonthStartServer(srvNow.year, srvNow.mon);
   if(g_mpLastSeenServerMonthStart <= 0)
      g_mpLastSeenServerMonthStart = todayMonthStart;
   if(todayMonthStart != g_mpLastSeenServerMonthStart)
   {
      // Sang tháng mới: ép panel về tháng hiện tại để tổng tháng bắt đầu lại từ 0.
      g_mpLastSeenServerMonthStart = todayMonthStart;
      g_mpViewMonthStart = todayMonthStart;
      g_mpAutoFollowCurrentMonth = true;
   }
   if(g_mpAutoFollowCurrentMonth && g_mpViewMonthStart != todayMonthStart)
      g_mpViewMonthStart = todayMonthStart;
   const bool isViewingCurrentMonth = (g_mpViewMonthStart == todayMonthStart);

   MonthlyProfitPanelDeleteAll();

   const ENUM_BASE_CORNER crn = CORNER_LEFT_UPPER;
   const int ox = 12;
   const int oy = 28;
   const int f0 = 9;
   const int fTitle = f0 + 2;
   const int fBig = f0 + 4;

   const color C_BG = C'14,16,20';
   const color C_CARD = C'28,31,38';
   const color C_BORDER = C'48,52,62';
   const color C_TEXT = clrWhite;
   const color C_MUTED = C'140,145,158';
   const color C_GREEN = C'0,220,130';
   const color C_RED = C'255,120,120';
   const color C_BLUE = C'60,150,255';

   const int W = 900;
   const int H = 604;
   const int pad = 10;
   int y = oy;

   MpRectCreate(MpPanelObjPrefix() + "main", ox, y, W, H, C_BG, C_BORDER, crn);
   y += pad;

   MpLabelCreate(MpPanelObjPrefix() + "hdr", ox + pad, y,
                  "BẢNG LỢI NHUẬN THÁNG (#" + IntegerToString(MagicAA) + ")", fTitle, C_TEXT, true, crn);
   y += 26;

   const int cardW = (W - pad * 5) / 4;
   const int cardH = 98;
   const int gap = pad;
   int cx = ox + pad;

   MpRectCreate(MpPanelObjPrefix() + "c1", cx, y, cardW, cardH, C_CARD, C_BORDER, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c1t", cx + 8, y + 6, "TỔNG LỢI NHUẬN THÁNG", f0, C_MUTED, false, crn);
   string sTot = (monthTotal >= 0.0 ? "+" : "") + DoubleToString(monthTotal, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
   MpLabelCreate(MpPanelObjPrefix() + "c1v", cx + 8, y + 24, sTot, fBig, (monthTotal >= 0.0 ? C_GREEN : C_RED), true, crn);
   if(isViewingCurrentMonth)
      MpLabelCreate(MpPanelObjPrefix() + "c1b", cx + cardW - 86, y + 30, "THÁNG NÀY", f0 - 1, C_GREEN, true, crn);

   cx += cardW + gap;
   MpRectCreate(MpPanelObjPrefix() + "c2", cx, y, cardW, cardH, C_CARD, C_BORDER, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c2t", cx + 8, y + 6, "LỢI NHUẬN TB NGÀY", f0, C_MUTED, false, crn);
   string sAvg = (avgDaily >= 0.0 ? "+" : "") + DoubleToString(avgDaily, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
   MpLabelCreate(MpPanelObjPrefix() + "c2v", cx + 8, y + 24, sAvg, fBig, C_TEXT, true, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c2s", cx + 8, y + 74, IntegerToString(tradingDays) + " Ngày giao dịch", f0 - 1, C_MUTED, false, crn);

   cx += cardW + gap;
   MpRectCreate(MpPanelObjPrefix() + "c3", cx, y, cardW, cardH, C_CARD, C_BORDER, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c3t", cx + 8, y + 4, "LÃI/LỖ USD (THEO THÁNG)", f0, C_MUTED, false, crn);
   const color c3PctClr = (totalClosedDeals == 0 ? C_TEXT : (winRateUsdPct >= 50.0 ? C_GREEN : C_RED));
   MpLabelCreate(MpPanelObjPrefix() + "c3v", cx + 8, y + 22, DoubleToString(winRateUsdPct, 1) + "%", fBig, c3PctClr, true, crn);
   const int c3sx = cx + 8;
   const int c3fSmall = f0 - 2;
   const string c3MonthOnly = "Tháng " + IntegerToString(vmon) + "/" + IntegerToString(vy);
   MpLabelCreate(MpPanelObjPrefix() + "c3sm", c3sx, y + 42, c3MonthOnly, f0 - 1, C_MUTED, false, crn);

   const string c3Cur = AccountInfoString(ACCOUNT_CURRENCY);
   if(totalClosedDeals == 0)
      MpLabelCreate(MpPanelObjPrefix() + "c3p", c3sx, y + 56, "Chưa có lệnh đóng (0)", c3fSmall, C_MUTED, false, crn);
   else if(usdWinLossDenom <= 1e-8)
      MpLabelCreate(MpPanelObjPrefix() + "c3p", c3sx, y + 56, "Hòa vốn (0 USD)", c3fSmall, C_MUTED, false, crn);
   else
   {
      const bool c3Up = (winRateUsdPct >= 50.0);
      const color c3BadgeBg = (c3Up ? C'24,92,58' : C'110,42,42');
      const color c3BadgeFg = (c3Up ? C'160,255,200' : C'255,190,190');
      const int c3bw = 52;
      const int c3bh = 16;
      const int c3bx = cx + cardW - 8 - c3bw;
      const int c3by = y + 40;
      MpRectCreate(MpPanelObjPrefix() + "c3bdg", c3bx, c3by, c3bw, c3bh, c3BadgeBg, c3BadgeBg, crn);
      MpLabelCreate(MpPanelObjPrefix() + "c3bdt", c3bx + 10, c3by + 2, (c3Up ? "Tăng" : "Giảm"), c3fSmall, c3BadgeFg, true, crn);
      MpLabelCreate(MpPanelObjPrefix() + "c3p", c3sx, y + 56, "Lãi +" + DoubleToString(monthSumUsdProfit, 2), c3fSmall, C_MUTED, false, crn);
      MpLabelCreate(MpPanelObjPrefix() + "c3l", c3sx, y + 68, "Lỗ " + DoubleToString(monthSumUsdLossAbs, 2) + " " + c3Cur, c3fSmall, C_MUTED, false, crn);
   }

   cx += cardW + gap;
   MpRectCreate(MpPanelObjPrefix() + "c4", cx, y, cardW, cardH, C_CARD, C_BORDER, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c4t", cx + 8, y + 6, "LỢI NHUẬN TỪ LÚC GẮN EA", f0, C_MUTED, false, crn);
   const double attachProfitUsd = eaCumulativeTradingPL;
   string sAttach = (attachProfitUsd >= 0.0 ? "+" : "") + DoubleToString(attachProfitUsd, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
   MpLabelCreate(MpPanelObjPrefix() + "c4v", cx + 8, y + 24, sAttach, fBig, (attachProfitUsd >= 0.0 ? C_GREEN : C_RED), true, crn);
   MpLabelCreate(MpPanelObjPrefix() + "c4s", cx + 8, y + 74, "Không reset theo tháng", f0 - 1, C_MUTED, false, crn);

   y += cardH + 10;
   {
      string sCmpThr;
      if(EnableCompoundTotalFloatingProfit && CompoundTotalProfitTriggerUSD > 0.0)
         sCmpThr = "Ngưỡng gồng lãi tổng: " + DoubleToString(GetCompoundFloatingTriggerThresholdUsd(), 2)
                   + " " + AccountInfoString(ACCOUNT_CURRENCY);
      else
         sCmpThr = "Gồng lãi tổng: tắt hoặc ngưỡng ≤ 0";
      MpLabelCreate(MpPanelObjPrefix() + "cmpthr", ox + pad, y, sCmpThr, f0, C_BLUE, true, crn);
   }
   y += 22;

   MpButtonCreate(MpPanelObjPrefix() + "prev", ox + pad, y, 26, 22, "<", crn);
   string monthTitle = "Tháng " + IntegerToString(vmon) + ", " + IntegerToString(vy);
   MpLabelCreate(MpPanelObjPrefix() + "month", ox + pad + 34, y + 3, monthTitle, f0, C_TEXT, true, crn);
   MpButtonCreate(MpPanelObjPrefix() + "next", ox + pad + 34 + 150, y, 26, 22, ">", crn);

   int legX = ox + W - pad - 300;
   MpLabelCreate(MpPanelObjPrefix() + "lg0", legX, y + 3, "●", f0 - 1, C_GREEN, false, crn);
   legX += 14;
   MpLabelCreate(MpPanelObjPrefix() + "lg1", legX, y + 3, "Lợi nhuận", f0 - 1, C_MUTED, false, crn);
   legX += 62;
   MpLabelCreate(MpPanelObjPrefix() + "lg2", legX, y + 3, "●", f0 - 1, C_RED, false, crn);
   legX += 14;
   MpLabelCreate(MpPanelObjPrefix() + "lg3", legX, y + 3, "Thua lỗ", f0 - 1, C_MUTED, false, crn);
   legX += 54;
   MpLabelCreate(MpPanelObjPrefix() + "lg4", legX, y + 3, "●", f0 - 1, C_BLUE, false, crn);
   legX += 14;
   MpLabelCreate(MpPanelObjPrefix() + "lg5", legX, y + 3, "Hôm nay", f0 - 1, C_MUTED, false, crn);

   y += 36;
   const string dowNames[7] = {"CHỦ NHẬT", "THỨ HAI", "THỨ BA", "THỨ TƯ", "THỨ NĂM", "THỨ SÁU", "THỨ BẢY"};
   const int cellW = (W - pad * 2) / 7;
   const int cellH = 56;
   int hx = ox + pad;
   for(int c = 0; c < 7; c++)
   {
      MpLabelCreate(MpPanelObjPrefix() + "hd" + IntegerToString(c), hx + 2, y, dowNames[c], f0 - 1, C_MUTED, false, crn);
      hx += cellW;
   }
   y += 24;

   MqlDateTime first;
   first.year = vy;
   first.mon = vmon;
   first.day = 1;
   first.hour = 12;
   first.min = 0;
   first.sec = 0;
   const datetime tFirst = StructToTime(first);
   MqlDateTime df;
   TimeToStruct(tFirst, df);
   const int lead = df.day_of_week;

   const bool monthIsFuture = (vy > srvNow.year)
                              || (vy == srvNow.year && vmon > srvNow.mon);
   const bool monthIsPast = (vy < srvNow.year)
                            || (vy == srvNow.year && vmon < srvNow.mon);

   int curDay = 1;
   for(int row = 0; row < 6; row++)
   {
      for(int col = 0; col < 7; col++)
      {
         if(row == 0 && col < lead)
            continue;
         if(curDay > dim)
            continue;

         const int cellX = ox + pad + col * cellW;
         const int cellY = y + row * cellH;

         MqlDateTime wk;
         ZeroMemory(wk);
         wk.year = vy;
         wk.mon = vmon;
         wk.day = curDay;
         wk.hour = 12;
         TimeToStruct(StructToTime(wk), wk);
         const int cellDow = wk.day_of_week;
         const bool weekend = (cellDow == 0 || cellDow == 6);

         const bool isToday = (vy == srvNow.year && vmon == srvNow.mon && curDay == srvNow.day);
         const bool cellFuture = monthIsFuture
                                 || (vy == srvNow.year && vmon == srvNow.mon && curDay > srvNow.day);
         const bool cellPast = monthIsPast
                               || (vy == srvNow.year && vmon == srvNow.mon && curDay < srvNow.day);

         if(isToday)
            MpRectCreate(MpPanelObjPrefix() + "cd" + IntegerToString(curDay), cellX + 1, cellY + 1, cellW - 2, cellH - 2,
                         C_CARD, C_BLUE, crn);
         else
            MpRectCreate(MpPanelObjPrefix() + "cd" + IntegerToString(curDay), cellX + 1, cellY + 1, cellW - 2, cellH - 2,
                         C_CARD, C_BORDER, crn);

         MpLabelCreate(MpPanelObjPrefix() + "dn" + IntegerToString(curDay), cellX + 6, cellY + 4,
                       IntegerToString(curDay), f0, C_TEXT, true, crn);

         string line2 = "";
         string line3 = "";
         color c2 = C_MUTED;

         if(dayDeals[curDay] > 0)
         {
            const double p = dayPnl[curDay];
            line2 = (p >= 0.0 ? "+" : "") + DoubleToString(p, 2);
            c2 = (p >= 0.0 ? C_GREEN : C_RED);
            line3 = IntegerToString(dayDeals[curDay]) + " LỆNH";
         }
         else if(isToday)
         {
            const int opn = MpCountOpenOurPositions();
            line2 = "ĐANG CHẠY:";
            line3 = IntegerToString(opn) + " LỆNH";
            c2 = C_BLUE;
         }
         else if(cellFuture)
         {
            line2 = "--";
            line3 = "";
         }
         else if(weekend)
         {
            line2 = "Nghi";
            line3 = "";
            c2 = C_MUTED;
         }
         else if(cellPast)
         {
            line2 = "Không có giao dịch";
            line3 = "";
         }
         else
         {
            line2 = "--";
            line3 = "";
         }

         MpLabelCreate(MpPanelObjPrefix() + "dp" + IntegerToString(curDay), cellX + 4, cellY + 20, line2, f0 - 1, c2, false, crn);
         MpLabelCreate(MpPanelObjPrefix() + "dc" + IntegerToString(curDay), cellX + 4, cellY + 34, line3, f0 - 2, C_MUTED, false, crn);

         if(isToday)
            MpLabelCreate(MpPanelObjPrefix() + "dot" + IntegerToString(curDay), cellX + cellW - 16, cellY + 4, "●", f0 - 1, C_BLUE, false, crn);

         curDay++;
      }
   }

   ChartRedraw(0);
}

void MonthlyProfitPanelShiftMonth(const int deltaMon)
{
   MqlDateTime d;
   TimeToStruct(g_mpViewMonthStart, d);
   int m = d.mon + deltaMon;
   int yr = d.year;
   while(m > 12)
   {
      m -= 12;
      yr++;
   }
   while(m < 1)
   {
      m += 12;
      yr--;
   }
   g_mpViewMonthStart = MpMonthStartServer(yr, m);
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now); // Dùng giờ server theo tick hiện tại của sàn
   const datetime todayMonthStart = MpMonthStartServer(now.year, now.mon);
   g_mpAutoFollowCurrentMonth = (g_mpViewMonthStart == todayMonthStart);
   g_mpLastRedrawTick = 0;
   MonthlyProfitPanelRedrawIfNeeded(true);
}

//+------------------------------------------------------------------+
//| Giá đặt gốc lưới: Bid hiện tại.                                    |
//+------------------------------------------------------------------+
double GridBasePriceAtPlacement()
{
   return NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), dgt);
}

//+------------------------------------------------------------------+
//| Vẽ/cập nhật đường gốc trực tiếp trên chart.                      |
//+------------------------------------------------------------------+
void UpdateBaseLineOnChart()
{
   EaStartTimeObjectsApplyOrRemove();
   if(!EnableBaseLineAndEaStartMarker)
   {
      ObjectDelete(0, g_baseLineObjectName);
      return;
   }
   if(basePrice <= 0.0 || !MathIsValidNumber(basePrice))
   {
      ObjectDelete(0, g_baseLineObjectName);
      return;
   }

   if(ObjectFind(0, g_baseLineObjectName) < 0)
   {
      if(!ObjectCreate(0, g_baseLineObjectName, OBJ_HLINE, 0, 0, basePrice))
         return;
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_COLOR, clrDeepSkyBlue);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_BACK, false);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, g_baseLineObjectName, OBJPROP_HIDDEN, true);
      ObjectSetString(0, g_baseLineObjectName, OBJPROP_TEXT, "VDualGrid Base");
   }
   ObjectSetDouble(0, g_baseLineObjectName, OBJPROP_PRICE, NormalizeDouble(basePrice, dgt));
}

//+------------------------------------------------------------------+
//| Vạch dọc + nhãn thời gian đặt đường gốc của phiên hiện tại.        |
//+------------------------------------------------------------------+
void EaStartTimeObjectsApplyOrRemove()
{
   const datetime baseAnchorTime = (basePrice > 0.0 && sessionStartTime > 0 ? sessionStartTime : 0);
   if(!EnableBaseLineAndEaStartMarker || baseAnchorTime <= 0)
   {
      ObjectDelete(0, VDGRID_EA_START_VLINE);
      ObjectDelete(0, VDGRID_EA_START_TEXT);
      return;
   }

   if(ObjectFind(0, VDGRID_EA_START_VLINE) < 0)
   {
      if(!ObjectCreate(0, VDGRID_EA_START_VLINE, OBJ_VLINE, 0, baseAnchorTime, 0.0))
      {
         Print("VDualGrid: không tạo vạch dọc thời gian đặt gốc (OBJ_VLINE).");
         return;
      }
   }
   ObjectMove(0, VDGRID_EA_START_VLINE, 0, baseAnchorTime, 0.0);
   ObjectSetInteger(0, VDGRID_EA_START_VLINE, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, VDGRID_EA_START_VLINE, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, VDGRID_EA_START_VLINE, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, VDGRID_EA_START_VLINE, OBJPROP_BACK, true);
   ObjectSetInteger(0, VDGRID_EA_START_VLINE, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, VDGRID_EA_START_VLINE, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, VDGRID_EA_START_VLINE, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, VDGRID_EA_START_VLINE, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
   ObjectSetString(0, VDGRID_EA_START_VLINE, OBJPROP_TOOLTIP,
                   "VDualGrid đặt đường gốc (server): " + TimeToString(baseAnchorTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS));

   double pr = ChartGetDouble(0, CHART_PRICE_MAX);
   if(!MathIsValidNumber(pr) || pr <= 0.0)
      pr = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ObjectFind(0, VDGRID_EA_START_TEXT) < 0)
   {
      if(!ObjectCreate(0, VDGRID_EA_START_TEXT, OBJ_TEXT, 0, baseAnchorTime, pr))
      {
         Print("VDualGrid: không tạo nhãn thời gian đặt gốc (OBJ_TEXT).");
         return;
      }
   }
   ObjectMove(0, VDGRID_EA_START_TEXT, 0, baseAnchorTime, pr);
   const string txt = "BASE " + TimeToString(baseAnchorTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   ObjectSetString(0, VDGRID_EA_START_TEXT, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, VDGRID_EA_START_TEXT, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, VDGRID_EA_START_TEXT, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, VDGRID_EA_START_TEXT, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, VDGRID_EA_START_TEXT, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, VDGRID_EA_START_TEXT, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, VDGRID_EA_START_TEXT, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, VDGRID_EA_START_TEXT, OBJPROP_BACK, false);
   ObjectSetString(0, VDGRID_EA_START_TEXT, OBJPROP_TOOLTIP, "Thời gian EA đặt đường gốc (TimeCurrent server)");

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_isOnInitBootstrap = true;
   eaAttachTime = TimeCurrent();
   MagicAA = MagicNumber;
   trade.SetExpertMagicNumber(MagicAA);
   dgt = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pnt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_orderBalanceEmaHighHandle = INVALID_HANDLE;
   g_orderBalanceEmaLowHandle = INVALID_HANDLE;
   g_orderBalanceEmaCloseHandle = INVALID_HANDLE;
   g_orderBalanceRsiHandle = INVALID_HANDLE;
   g_orderBalanceFastEmaHandle = INVALID_HANDLE;
   g_orderBalanceSlowEmaHandle = INVALID_HANDLE;
   g_startupRsiHandle = INVALID_HANDLE;
   g_autoFirstLotByBaseEmaHandle = INVALID_HANDLE;
   if(EnableOrderBalanceEMAFilter)
   {
      ENUM_TIMEFRAMES obTf = OrderBalanceEMATimeframe;
      if(obTf == PERIOD_CURRENT)
         obTf = (ENUM_TIMEFRAMES)_Period;
      const int obP = MathMax(1, OrderBalanceEMAPeriod);
      if(OrderBalanceEMAFilterMode == ORDER_BALANCE_EMA_CLOSE_ONLY)
      {
         g_orderBalanceEmaCloseHandle = iMA(_Symbol, obTf, obP, 0, MODE_EMA, PRICE_CLOSE);
         if(g_orderBalanceEmaCloseHandle == INVALID_HANDLE)
            Print("VDualGrid: 6c — không tạo iMA EMA(Close) cho lọc EMA cân bằng lệnh.");
      }
      else
      {
         g_orderBalanceEmaHighHandle = iMA(_Symbol, obTf, obP, 0, MODE_EMA, PRICE_HIGH);
         g_orderBalanceEmaLowHandle = iMA(_Symbol, obTf, obP, 0, MODE_EMA, PRICE_LOW);
         if(g_orderBalanceEmaHighHandle == INVALID_HANDLE || g_orderBalanceEmaLowHandle == INVALID_HANDLE)
            Print("VDualGrid: 6c — không tạo iMA EMA(High/Low) cho lọc EMA cân bằng lệnh.");
      }
   }
   if(EnableOrderBalanceRSIFilter && (OrderBalanceRSIGreaterLevel >= 0.0 || OrderBalanceRSILessLevel >= 0.0))
   {
      ENUM_TIMEFRAMES obRsiTf = OrderBalanceRSITimeframe;
      if(obRsiTf == PERIOD_CURRENT)
         obRsiTf = (ENUM_TIMEFRAMES)_Period;
      const int obRsiP = MathMax(1, OrderBalanceRSIPeriod);
      g_orderBalanceRsiHandle = iRSI(_Symbol, obRsiTf, obRsiP, PRICE_CLOSE);
      if(g_orderBalanceRsiHandle == INVALID_HANDLE)
         Print("VDualGrid: 6c — không tạo iRSI cho lọc RSI cân bằng lệnh.");
   }
   if(EnableOrderBalanceFastSlowFilter)
   {
      ENUM_TIMEFRAMES fsTf = OrderBalanceFastSlowTimeframe;
      if(fsTf == PERIOD_CURRENT)
         fsTf = (ENUM_TIMEFRAMES)_Period;
      int fsSlowP = MathMax(2, OrderBalanceSlowEMAPeriod);
      int fsFastP = MathMax(1, OrderBalanceFastEMAPeriod);
      if(fsFastP >= fsSlowP)
         fsFastP = fsSlowP - 1;
      if(fsFastP < 1)
         fsFastP = 1;
      g_orderBalanceFastEmaHandle = iMA(_Symbol, fsTf, fsFastP, 0, MODE_EMA, PRICE_CLOSE);
      g_orderBalanceSlowEmaHandle = iMA(_Symbol, fsTf, fsSlowP, 0, MODE_EMA, PRICE_CLOSE);
      if(g_orderBalanceFastEmaHandle == INVALID_HANDLE || g_orderBalanceSlowEmaHandle == INVALID_HANDLE)
         Print("VDualGrid: 6c — không tạo iMA EMA nhanh/chậm cho lọc cân bằng lệnh.");
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
   g_virtualGridPrevCloseEmaHandle = INVALID_HANDLE;
   if(EnableVirtualGridPrevClosedVsEmaSideFilter)
   {
      ENUM_TIMEFRAMES vgTf = VirtualGridPrevClosedCandleTimeframe;
      if(vgTf == PERIOD_CURRENT)
         vgTf = (ENUM_TIMEFRAMES)_Period;
      const int vgEmaP = MathMax(1, VirtualGridPrevClosedVsEmaPeriod);
      g_virtualGridPrevCloseEmaHandle = iMA(_Symbol, vgTf, vgEmaP, 0, MODE_EMA, PRICE_CLOSE);
      if(g_virtualGridPrevCloseEmaHandle == INVALID_HANDLE)
         Print("VDualGrid: 2J — không tạo iMA (lọc đóng nến vs EMA cho chờ ảo).");
   }
   if(EnableAutoFirstLotByBaseEmaGap)
   {
      ENUM_TIMEFRAMES afTf = AutoFirstLotByBaseEmaTimeframe;
      if(afTf == PERIOD_CURRENT)
         afTf = (ENUM_TIMEFRAMES)_Period;
      const int afP = MathMax(1, AutoFirstLotByBaseEmaPeriod);
      g_autoFirstLotByBaseEmaHandle = iMA(_Symbol, afTf, afP, 0, MODE_EMA, PRICE_CLOSE);
      if(g_autoFirstLotByBaseEmaHandle == INVALID_HANDLE)
         Print("VDualGrid: 2g — không tạo iMA (auto lot bậc 1 theo Gốc–EMA).");
   }
   StartupEmaCrossInitHandles();
   if(EnableStartupRsiBaseFilter)
   {
      ENUM_TIMEFRAMES srTf = StartupRsiTimeframe;
      if(srTf == PERIOD_CURRENT)
         srTf = (ENUM_TIMEFRAMES)_Period;
      const int srP = MathMax(1, StartupRsiPeriod);
      g_startupRsiHandle = iRSI(_Symbol, srTf, srP, PRICE_CLOSE);
      if(g_startupRsiHandle == INVALID_HANDLE)
         Print("VDualGrid: 2f — không tạo iRSI (lọc khởi động đặt gốc).");
   }
   if(EnableStartupAdxBaseFilter)
   {
      ENUM_TIMEFRAMES adxTf = StartupAdxTimeframe;
      if(adxTf == PERIOD_CURRENT)
         adxTf = (ENUM_TIMEFRAMES)_Period;
      const int adxP = MathMax(1, StartupAdxPeriod);
      g_startupAdxHandle = iADX(_Symbol, adxTf, adxP);
      if(g_startupAdxHandle == INVALID_HANDLE)
         Print("VDualGrid: 2h — không tạo iADX (lọc khởi động đặt gốc).");
   }
   basePrice = 0.0;
   lastTickBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   lastTickAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   eaCumulativeTradingPL = 0.0;

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
   CompoundModeClearState();
   InitBaseEmaVirtGapClearZone();
   AutoFirstLotByBaseEmaClearState();

   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(EnableRunDayFilter && !RunDayFilterAnyDaySelected())
      Print("VDualGrid: lọc ngày bật nhưng chưa chọn ngày nào — coi như không khóa theo ngày.");
   if(g_runtimeSessionActive)
   {
      if(StartupEmaAnyFilterWaiting())
      {
         VirtualPendingClear();
         ArrayResize(gridLevels, 0);
         sessionStartTime = 0;
         if(EnableStartupThreeEmaOrdered)
         {
            Print("VDualGrid: trong lịch chạy — chờ xếp 3 EMA (EMA nhỏ>EMA vừa>EMA lớn hoặc cả ba ngược lại), khung ",
                  EnumToString(StartupEmaCrossTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : StartupEmaCrossTimeframe), ".");
            if(EnableResetNotification)
               SendResetNotification("EA khởi động — chờ xếp 3 EMA đặt gốc");
         }
         else if(EnableStartupEmaFastSlowCross)
         {
            Print("VDualGrid: trong lịch chạy — chờ tín hiệu EMA nhanh cắt EMA chậm mới đặt gốc (khung ", EnumToString(StartupEmaCrossTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : StartupEmaCrossTimeframe), ").");
            if(EnableResetNotification)
               SendResetNotification("EA khởi động — chờ EMA nhanh/chậm đặt gốc");
         }
         else
         {
            Print("VDualGrid: trong lịch chạy — chờ khoảng cách Open nến hiện tại với EMA(", IntegerToString(MathMax(1, StartupOpenGapToEmaPeriod)),
                  ") <= ", DoubleToString(MathMax(0.0, StartupOpenGapToEmaMaxPips), 1), " pip để đặt gốc.");
            if(EnableResetNotification)
               SendResetNotification("EA khởi động — chờ khoảng cách Open-EMA đạt ngưỡng");
         }
      }
      else
      {
         double startupRsi = 0.0, startupAdx = 0.0;
         if(StartupRsiAndAdxPassForBase(startupRsi, startupAdx))
         {
            if(VirtualGridPrevClosedDualFiltersAllowBasePlacement())
            {
               basePrice = GridBasePriceAtPlacement();
               InitializeGridLevels();
               if(EnableResetNotification)
               {
                  SendResetNotification("EA đã khởi động");
               }
            }
            else
            {
               VirtualPendingClear();
               ArrayResize(gridLevels, 0);
               sessionStartTime = 0;
               basePrice = 0.0;
               Print("VDualGrid: trong lịch chạy — chờ 2J (cả hai lọc nến shift1) thỏa đồng thời trên ít nhất một chân A–H để đặt gốc.");
               if(EnableResetNotification)
                  SendResetNotification("EA khởi động — chờ 2J (hướng nến + đóng vs EMA) đặt gốc");
            }
         }
         else
         {
            VirtualPendingClear();
            ArrayResize(gridLevels, 0);
            sessionStartTime = 0;
            basePrice = 0.0;
            Print("VDualGrid: trong lịch chạy — chờ ", StartupRsiAdxWaitReasonPhrase(), " để đặt gốc.");
            if(EnableResetNotification)
            {
               SendResetNotification("EA khởi động — chờ đặt gốc (" + StartupRsiAdxWaitReasonPhrase() + ")");
            }
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
   Print("VDualGrid đã chạy.");
   Print("Symbol: ", _Symbol, " | Base: ", basePrice, " | Grid: ", GridDistancePips, " pips | Levels: ", ArraySize(gridLevels));
   Print("Chờ ảo: chạy theo từng chân A/B/C/D/E/F/G/H (song song) | mức=", ArraySize(gridLevels), " | lot L1 A=", VirtualGridResolvedL1(VGRID_LEG_BUY_ABOVE), " | lot L1 E=", VirtualGridResolvedL1(VGRID_LEG_BUY_ABOVE_E), " | lot L1 G=", VirtualGridResolvedL1(VGRID_LEG_SELL_ABOVE_G), " | lot L1 H=", VirtualGridResolvedL1(VGRID_LEG_BUY_BELOW_H));
   Print("VDualGrid: nạp/rút broker không đổi cấu hình EA — lưới/lot/mục tiêu theo input + P/L giao dịch (TEV), không theo số dư ledger.");
   if(EnableRunTimeWindow || EnableRunDayFilter)
   {
      string st = "ĐANG CHỜ LỊCH CHẠY";
      if(g_runtimeSessionActive)
         st = (basePrice > 0.0 ? "ĐANG CHẠY LƯỚI" : "TRONG LỊCH — CHỜ ĐẶT GỐC");
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
   if(EnableAvoidUsdHighImpactNews)
      Print("Tránh tin USD L3: ", (HasUsdHighImpactNewsPauseWindow(TimeCurrent()) ? "HÔM NAY/NGÀY MAI CÓ TIN (khóa phiên mới)" : "không có tin chặn phiên mới trong hôm nay+ngày mai"));
   Print("========================================");
   if(g_runtimeSessionActive)
      ManageGridOrders();
   UpdateBaseLineOnChart();
   MonthlyProfitPanelOnInitState();
   if(EnableMonthlyProfitPanel)
   {
      EventKillTimer();
      EventSetTimer(8);
      MonthlyProfitPanelRedrawIfNeeded(true);
   }
   else
   {
      EventKillTimer();
      MonthlyProfitPanelDeleteAll();
      g_mpPanelWasEnabled = false;
   }
   EaStartTimeObjectsApplyOrRemove();
   SendStartupTelegramScreenshot("EA vừa gắn vào biểu đồ");
   g_isOnInitBootstrap = false;
   CompoundFloatThrHudUpdate(true);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   CompoundFloatThrHudDeleteAll();
   MonthlyProfitPanelDeleteAll();
   ObjectDelete(0, VDGRID_EA_START_VLINE);
   ObjectDelete(0, VDGRID_EA_START_TEXT);
   if(g_orderBalanceEmaHighHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_orderBalanceEmaHighHandle);
      g_orderBalanceEmaHighHandle = INVALID_HANDLE;
   }
   if(g_orderBalanceEmaLowHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_orderBalanceEmaLowHandle);
      g_orderBalanceEmaLowHandle = INVALID_HANDLE;
   }
   if(g_orderBalanceEmaCloseHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_orderBalanceEmaCloseHandle);
      g_orderBalanceEmaCloseHandle = INVALID_HANDLE;
   }
   if(g_orderBalanceRsiHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_orderBalanceRsiHandle);
      g_orderBalanceRsiHandle = INVALID_HANDLE;
   }
   if(g_orderBalanceFastEmaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_orderBalanceFastEmaHandle);
      g_orderBalanceFastEmaHandle = INVALID_HANDLE;
   }
   if(g_orderBalanceSlowEmaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_orderBalanceSlowEmaHandle);
      g_orderBalanceSlowEmaHandle = INVALID_HANDLE;
   }
   if(g_startupRsiHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_startupRsiHandle);
      g_startupRsiHandle = INVALID_HANDLE;
   }
   if(g_startupAdxHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_startupAdxHandle);
      g_startupAdxHandle = INVALID_HANDLE;
   }
   if(g_initBaseEmaVirtGapHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_initBaseEmaVirtGapHandle);
      g_initBaseEmaVirtGapHandle = INVALID_HANDLE;
   }
   if(g_virtualGridPrevCloseEmaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_virtualGridPrevCloseEmaHandle);
      g_virtualGridPrevCloseEmaHandle = INVALID_HANDLE;
   }
   if(g_autoFirstLotByBaseEmaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_autoFirstLotByBaseEmaHandle);
      g_autoFirstLotByBaseEmaHandle = INVALID_HANDLE;
   }
   StartupEmaCrossReleaseHandles();
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
   UpdateBaseLineOnChart();
   MonthlyProfitPanelRedrawIfNeeded(false);

   // Delay khởi động lại: trong thời gian chờ thì EA đứng im hoàn toàn.
   if(IsStartupRestartDelayBlocking())
      return;

   // Đang chờ lịch (giờ/ngày server): chỉ bật phiên mới khi IsSchedulingAllowedForNewSession.
   if(!g_runtimeSessionActive)
   {
      const datetime nowSrv = TimeCurrent();
      if(IsDailyProfitPauseActiveNow(nowSrv))
      {
         const long nowDateKey = ServerDateKey(nowSrv);
         if(g_dailyProfitPauseLoggedDateKey != nowDateKey)
         {
            g_dailyProfitPauseLoggedDateKey = nowDateKey;
            Print("VDualGrid: đang tạm dừng do đạt lợi nhuận ngày (lãi đóng cộng dồn các phiên). Chờ sang ngày server mới để cho phép khởi động phiên mới.");
         }
         return;
      }

      if(IsSchedulingAllowedForNewSession(nowSrv))
      {
         g_runtimeSessionActive = true;
         if(IsStartupRestartDelayBlocking())
         {
            ArrayResize(gridLevels, 0);
            sessionStartTime = 0;
            basePrice = 0.0;
            return;
         }
         if(StartupEmaAnyFilterWaiting())
         {
            if(EnableStartupThreeSameColorCandles)
            {
               const int sx = StartupSameColorConsecutiveBarsClamped();
               Print("VDualGrid: vào lịch chạy — chờ ", sx,
                     " nến đóng liên tiếp cùng màu (nến đóng ngay trước chuỗi phải khác màu) để đặt gốc.");
               if(EnableResetNotification)
                  SendResetNotification("Vào lịch — chờ " + IntegerToString(sx) + " nến cùng màu, nến trước chuỗi khác màu");
            }
            else if(EnableStartupThreeEmaOrdered)
            {
               Print("VDualGrid: vào lịch chạy — chờ xếp 3 EMA để đặt gốc.");
               if(EnableResetNotification)
                  SendResetNotification("Vào lịch — chờ xếp 3 EMA đặt gốc");
            }
            else if(EnableStartupEmaFastSlowCross)
            {
               Print("VDualGrid: vào lịch chạy — chờ EMA nhanh cắt EMA chậm để đặt gốc.");
               if(EnableResetNotification)
                  SendResetNotification("Vào lịch — chờ EMA nhanh/chậm đặt gốc");
            }
            else
            {
               Print("VDualGrid: vào lịch chạy — chờ khoảng cách Open nến hiện tại với EMA(", IntegerToString(MathMax(1, StartupOpenGapToEmaPeriod)),
                     ") <= ", DoubleToString(MathMax(0.0, StartupOpenGapToEmaMaxPips), 1), " pip để đặt gốc.");
               if(EnableResetNotification)
                  SendResetNotification("Vào lịch — chờ khoảng cách Open-EMA đạt ngưỡng");
            }
         }
         else
         {
            double startupRsi = 0.0, startupAdx = 0.0;
            if(StartupRsiAndAdxPassForBase(startupRsi, startupAdx))
            {
               if(VirtualGridPrevClosedDualFiltersAllowBasePlacement())
               {
                  basePrice = GridBasePriceAtPlacement();
                  InitializeGridLevels();
                  Print("VDualGrid: vào lịch chạy — khởi động phiên mới, base=", DoubleToString(basePrice, dgt));
                  if(EnableResetNotification)
                  {
                     SendResetNotification("Vào lịch chạy — EA khởi động phiên mới");
                  }
                  ManageGridOrders();
               }
               else
               {
                  ArrayResize(gridLevels, 0);
                  sessionStartTime = 0;
                  basePrice = 0.0;
                  Print("VDualGrid: vào lịch chạy — chờ 2J (cả hai lọc nến shift1) thỏa đồng thời trên ít nhất một chân A–H để đặt gốc.");
                  if(EnableResetNotification)
                     SendResetNotification("Vào lịch — chờ 2J (hướng nến + đóng vs EMA) đặt gốc");
               }
            }
            else
            {
               ArrayResize(gridLevels, 0);
               sessionStartTime = 0;
               basePrice = 0.0;
               Print("VDualGrid: vào lịch chạy — chờ ", StartupRsiAdxWaitReasonPhrase(), " để đặt gốc.");
               if(EnableResetNotification)
               {
                  SendResetNotification("Vào lịch — chờ đặt gốc (" + StartupRsiAdxWaitReasonPhrase() + ")");
               }
            }
         }
      }
      return;
   }

   const int expectedGridLevelCount = MaxGridLevels * 2;

   // 8D: theo dõi lãi đã đóng trong ngày server (mọi phiên); không chờ tới lần reset.
   static ulong g_lastDailyProfitPauseScanMs = 0;
   if(EnableDailyProfitPauseAfterReset && DailyProfitPauseThresholdUSD > 0.0 && g_runtimeSessionActive)
   {
      const ulong msNow = GetTickCount64();
      if(msNow - g_lastDailyProfitPauseScanMs >= 1000)
      {
         g_lastDailyProfitPauseScanMs = msNow;
         const datetime nowSrvDaily = TimeCurrent();
         if(EnsureDailyProfitPauseIfThresholdExceeded(nowSrvDaily, "Giám sát lãi ngày", true))
            return;
      }
   }

   // Chưa có đường gốc: trong lịch + khung giờ (nếu bật) → đặt gốc một lần rồi khởi tạo lưới. Có 2e: thêm chờ cắt EMA; đã có gốc thì không vào khối này — EA chạy tiếp, không phụ thuộc EMA.
   if(g_runtimeSessionActive && basePrice <= 0.0)
   {
      if(IsStartupRestartDelayBlocking())
         return;
      if(!IsNowWithinRunWindow(TimeCurrent()))
         return;
      if(StartupEmaAnyFilterWaiting() && !StartupEmaBaseConditionPass())
         return;
      double startupRsi = 0.0, startupAdx = 0.0;
      if(!StartupRsiAndAdxPassForBase(startupRsi, startupAdx))
         return;
      if(!VirtualGridPrevClosedDualFiltersAllowBasePlacement())
      {
         VirtualGridPrevClosedDualFilterMaybeLogWaitingForBase();
         return;
      }
      basePrice = GridBasePriceAtPlacement();
      InitializeGridLevels();
      string emaCondTag = " (lịch + khung giờ nếu bật)";
      if(EnableStartupThreeSameColorCandles)
      {
         const int sx = StartupSameColorConsecutiveBarsClamped();
         emaCondTag = " (lịch + khung giờ + " + IntegerToString(sx) + " nến cùng màu, nến trước chuỗi khác màu)";
      }
      else if(EnableStartupThreeEmaOrdered)
         emaCondTag = " (lịch + khung giờ + xếp 3 EMA)";
      else if(EnableStartupEmaFastSlowCross)
         emaCondTag = " (lịch + khung giờ + cắt EMA shift0/1)";
      else if(EnableStartupOpenGapToEmaLimit)
         emaCondTag = " (lịch + khung giờ + giới hạn khoảng cách Open-EMA)";
      if(EnableStartupRsiBaseFilter || EnableStartupAdxBaseFilter)
      {
         emaCondTag += " + ";
         if(EnableStartupRsiBaseFilter && EnableStartupAdxBaseFilter)
            emaCondTag += "RSI+ADX";
         else if(EnableStartupRsiBaseFilter)
            emaCondTag += "RSI";
         else
            emaCondTag += StartupAdxEmaCondTagShort();
      }
      Print("VDualGrid: đủ điều kiện đặt gốc — base=", DoubleToString(basePrice, dgt), emaCondTag);
      if(EnableResetNotification)
      {
         SendResetNotification("Đủ điều kiện — bắt đầu lưới chờ ảo");
      }
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
   const bool orderBalanceJustExecuted = ProcessOrderBalanceMode();
   if(orderBalanceJustExecuted)
      CompoundFloatThrHudUpdate(false);

   double compoundOpenProfitSwapUsd = 0.0;
   double compoundSessionOpenLotsSum = 0.0;
   double compoundSessionPlRawOpenProfitSwapUsd = 0.0; // 6f: Σ(profit+swap) mở, không loại E/F theo CompoundTriggerProgressMode
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
      if(!CompoundPositionPassesSessionFilter(ticket))
         continue;
      compoundOpenProfitSwapUsd += GetCompoundOpenProfitSwapContribution(ticket);
      compoundSessionOpenLotsSum += PositionGetDouble(POSITION_VOLUME);
      compoundSessionPlRawOpenProfitSwapUsd += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   const double onePip = OnePipPrice();
   if(onePip > 0.0 && basePrice > 0.0)
   {
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      const double distPips = MathMax(MathAbs(bid - basePrice), MathAbs(ask - basePrice)) / onePip;
      if(distPips > g_sessionMaxAbsDistanceFromBasePips)
         g_sessionMaxAbsDistanceFromBasePips = distPips;
   }

   const double compoundTriggerProgressUsd = GetCompoundTriggerProgressUsd(compoundOpenProfitSwapUsd);

   if(EnableSessionDistanceAndTotalProfitReset
      && basePrice > 0.0
      && SessionDistanceResetPips > 0.0
      && SessionTotalProfitResetUSD > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid)
   {
      const double totalSessionProfitSwapUsd = compoundOpenProfitSwapUsd + g_compoundSessionClosedTotalProfitSwapUsd;
      const double orderBalanceNegThresholdUsd = MathAbs(SessionOrderBalanceNegativeTriggerUSD);
      const double orderBalanceNegAccumUsd = MathAbs(g_orderBalanceSessionClosedNegativeUsd);
      const bool orderBalanceNegativeGateOk = (!EnableSessionResetRequireOrderBalanceNegative
                                                || (orderBalanceNegThresholdUsd > 0.0
                                                    && orderBalanceNegAccumUsd >= orderBalanceNegThresholdUsd));
      if(g_sessionMaxAbsDistanceFromBasePips >= SessionDistanceResetPips
         && compoundOpenProfitSwapUsd >= SessionTotalProfitResetUSD
         && orderBalanceNegativeGateOk)
      {
         ResetAfterSessionDistanceAndTotalProfitHit(totalSessionProfitSwapUsd);
         return;
      }
   }

   if(EnableSessionOpenPlusClosedProfitReset
      && basePrice > 0.0
      && SessionOpenPlusClosedProfitResetUSD > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid)
   {
      const double totalSessionProfitSwapUsd = compoundOpenProfitSwapUsd + g_compoundSessionClosedTotalProfitSwapUsd;
      if(totalSessionProfitSwapUsd >= SessionOpenPlusClosedProfitResetUSD)
      {
         ResetAfterSessionOpenPlusClosedProfitHit(totalSessionProfitSwapUsd);
         return;
      }
   }

   if(EnableSessionNegativePlHardStopReset
      && SessionNegativePlHardStopUsd > 0.0
      && basePrice > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid)
   {
      const double totalSessionPlClosedPlusOpenUsd = compoundSessionPlRawOpenProfitSwapUsd + g_compoundSessionClosedTotalProfitSwapUsd;
      // X=2000 ⇒ kích hoạt tại P/L <= -2000 (bao gồm chính xác -2000); P/L -1999 không đạt ngưỡng.
      if(totalSessionPlClosedPlusOpenUsd <= -SessionNegativePlHardStopUsd)
      {
         ResetAfterSessionNegativePlHardStopHit(totalSessionPlClosedPlusOpenUsd);
         return;
      }
   }

   if(EnableSessionCarryExceededReset
      && SessionCarryExceededResetUsd > 0.0
      && basePrice > 0.0
      && sessionStartTime > 0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid)
   {
      if(GetCarryInSessionUsd() >= SessionCarryExceededResetUsd)
      {
         ResetAfterSessionCarryExceedsThresholdHit();
         return;
      }
   }

   // Giá ngoài biên ±Max bậc kể từ gốc (offset giống nấc ±Max trong lưới, kể cả khi không đặt chờ ảo một phía).
   // Carry: tổng P/L phiên = Σ(profit+swap) mở thô + đóng trong phiên (giống 6g), không dùng
   // compoundOpenProfitSwapUsd (có thể loại E/F dương theo CompoundTriggerProgressMode).
   if(EnableResetWhenPriceOutsideTopBottomGrid
      && basePrice > 0.0
      && MaxGridLevels > 0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid)
   {
      const double bidOut = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double askOut = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      const double ptOut = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      const double tolOut = MathMax(GridPriceTolerance(), ptOut * 2.0);
      const double topBoundPx = NormalizeDouble(basePrice + GridOffsetFromBaseForSignedLevel(MaxGridLevels), dgt);
      const double bottomBoundPx = NormalizeDouble(basePrice + GridOffsetFromBaseForSignedLevel(-MaxGridLevels), dgt);
      const bool priceAboveTopGrid = (bidOut > topBoundPx + tolOut);
      const bool priceBelowBottomGrid = (askOut < bottomBoundPx - tolOut);
      if(priceAboveTopGrid || priceBelowBottomGrid)
      {
         const double totalSessionProfitSwapUsdOut = compoundSessionPlRawOpenProfitSwapUsd + g_compoundSessionClosedTotalProfitSwapUsd;
         ResetAfterPriceOutsideTopBottomGridHit(totalSessionProfitSwapUsdOut);
         return;
      }
   }

   // Chỉ chờ ảo một phía gốc …; đóng nến khung xác nhận: Close[1] ngược gốc;
   // nếu MinGridLevels≥1: Bid (dưới gốc) / Ask (trên gốc) phải cách gốc ≥ X bậc (FirstOffset+D).
   if(!EnableResetWhenVirtualOnlyWrongSideOfPriceVsBase || basePrice <= 0.0)
      g_resetVwSideLastConfirmBarTime = 0;

   if(EnableResetWhenVirtualOnlyWrongSideOfPriceVsBase
      && g_runtimeSessionActive
      && basePrice > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid
      && !OurSymbolMagicHasAnyOpenPosition()
      && !OurSymbolMagicHasAnyBrokerPendingOrder())
   {
      int nVirtAbove = 0, nVirtBelow = 0;
      VirtualPendingCountOurMagicByBaseSide(nVirtAbove, nVirtBelow);
      const int nVirtTotal = nVirtAbove + nVirtBelow;
      if(nVirtTotal >= 1)
      {
         const bool onlyAboveVirtual = (nVirtAbove >= 1 && nVirtBelow == 0);
         const bool onlyBelowVirtual = (nVirtBelow >= 1 && nVirtAbove == 0);
         if(onlyAboveVirtual || onlyBelowVirtual)
         {
            ENUM_TIMEFRAMES confTf = ResetWhenVirtualWrongSideConfirmBarTimeframe;
            if(confTf == PERIOD_CURRENT)
               confTf = (ENUM_TIMEFRAMES)_Period;
            if(Bars(_Symbol, confTf) >= 2)
            {
               const datetime bar0Time = iTime(_Symbol, confTf, 0);
               if(bar0Time > 0)
               {
                  if(g_resetVwSideLastConfirmBarTime == 0)
                     g_resetVwSideLastConfirmBarTime = bar0Time;
                  else if(bar0Time != g_resetVwSideLastConfirmBarTime)
                  {
                     g_resetVwSideLastConfirmBarTime = bar0Time;
                     const double prevClose = iClose(_Symbol, confTf, 1);
                     const double ptVs = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
                     const double tolVs = MathMax(GridPriceTolerance(), ptVs * 3.0);
                     if(MathIsValidNumber(prevClose) && prevClose > 0.0)
                     {
                        const bool priceClosedBelowBase = (prevClose < basePrice - tolVs);
                        const bool priceClosedAboveBase = (prevClose > basePrice + tolVs);
                        if((onlyAboveVirtual && priceClosedBelowBase) || (onlyBelowVirtual && priceClosedAboveBase))
                        {
                           int minLv = ResetWhenVirtualWrongSideMinGridLevelsFromBase;
                           if(minLv > MaxGridLevels)
                              minLv = MaxGridLevels;
                           bool distOk = true;
                           if(minLv >= 1)
                           {
                              const double needDist = GridRadialDistanceFromBaseForAbsLevel(minLv);
                              const double bidNow = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                              const double askNow = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                              const double distTol = MathMax(GridPriceTolerance(), ptVs * 2.0);
                              if(onlyAboveVirtual && priceClosedBelowBase)
                                 distOk = ((basePrice - bidNow) >= needDist - distTol);
                              else if(onlyBelowVirtual && priceClosedAboveBase)
                                 distOk = ((askNow - basePrice) >= needDist - distTol);
                           }
                           if(distOk)
                           {
                              const double totalSessionProfitSwapVs = compoundSessionPlRawOpenProfitSwapUsd + g_compoundSessionClosedTotalProfitSwapUsd;
                              ResetAfterVirtualPendingsWrongSideOfBaseHit(totalSessionProfitSwapVs);
                              return;
                           }
                        }
                     }
                  }
               }
            }
         }
      }
   }

   // Không vị thế mở; max(|Bid−gốc|,|Ask−gốc|) ≥ X bậc (FirstOffset+D); mid ngoài thân nến đóng trước (shift1).
   if(EnableResetWhenNoOpenPosMinGridAndOutsidePrevBody
      && g_runtimeSessionActive
      && basePrice > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid
      && !OurSymbolMagicHasAnyOpenPosition())
   {
      const double bidNb = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double askNb = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      const double ptNb = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      const double distTolNb = MathMax(GridPriceTolerance(), ptNb * 2.0);
      int minLvNb = ResetWhenNoOpenPosMinGridLevelsFromBase;
      if(minLvNb > MaxGridLevels)
         minLvNb = MaxGridLevels;
      bool distOkNb = true;
      if(minLvNb >= 1)
      {
         const double needDistNb = GridRadialDistanceFromBaseForAbsLevel(minLvNb);
         const double radialNb = MathMax(MathAbs(bidNb - basePrice), MathAbs(askNb - basePrice));
         distOkNb = (radialNb >= needDistNb - distTolNb);
      }
      if(distOkNb && PriceMidStrictlyOutsidePrevClosedBody(ResetWhenNoOpenPosPrevCandleBodyTimeframe, bidNb, askNb))
      {
         const double totalSessionProfitSwapNb = compoundSessionPlRawOpenProfitSwapUsd + g_compoundSessionClosedTotalProfitSwapUsd;
         ResetAfterNoOpenPosMinGridOutsidePrevBodyHit(totalSessionProfitSwapNb);
         return;
      }
   }

   if(EnableSessionPlAndTotalOpenLotsReset
      && basePrice > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid)
   {
      const double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      const double lotsTol = (volStep > 0.0 ? volStep * 0.5 : 0.0005) + 1e-12;
      const double sessionLotsClosedPlusOpen = compoundSessionOpenLotsSum + g_compoundSessionClosedOutVolumeLots;
      const bool lotsMatch = (SessionPlLotsResetTotalOpenLots > 0.0
                             && MathAbs(sessionLotsClosedPlusOpen - SessionPlLotsResetTotalOpenLots) <= lotsTol);
      const double totalSessionProfitSwapUsd6f = compoundSessionPlRawOpenProfitSwapUsd + g_compoundSessionClosedTotalProfitSwapUsd;
      const bool thresholdPositive = (SessionPlLotsResetThresholdUsd > 0.0);
      const bool thresholdNegative = (SessionPlLotsResetThresholdUsd < 0.0);
      const bool plOk = (!thresholdPositive && !thresholdNegative
                        ? true
                        : ((thresholdPositive && totalSessionProfitSwapUsd6f >= SessionPlLotsResetThresholdUsd)
                           || (thresholdNegative && totalSessionProfitSwapUsd6f <= SessionPlLotsResetThresholdUsd)));
      if(lotsMatch && plOk)
      {
         ResetAfterSessionPlAndTotalOpenLotsHit(totalSessionProfitSwapUsd6f, compoundSessionOpenLotsSum,
                                                g_compoundSessionClosedOutVolumeLots);
         return;
      }
   }

   if(EnableResetWhenReachPrevSessionPeak
      && basePrice > 0.0
      && sessionStartTime > 0
      && g_prevSessionPeakClosedProfitUsd > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid)
   {
      const double closedCapitalNow = GetTradingClosedCapitalUSD();
      if(closedCapitalNow > g_sessionPeakClosedCapitalUsd)
         g_sessionPeakClosedCapitalUsd = closedCapitalNow;

      const double currentSessionTevProfitUsd = GetTradingEquityViewUSD() - sessionStartBalance;
      if(currentSessionTevProfitUsd >= g_prevSessionPeakClosedProfitUsd)
      {
         ResetAfterPrevSessionPeakReached(g_prevSessionPeakClosedProfitUsd, currentSessionTevProfitUsd);
         return;
      }
   }

   if(g_compoundTotalProfitActive)
      ProcessCompoundTotalProfitTrailing();
   else if(g_compoundAfterClearWaitGrid)
      ProcessCompoundPostActivationGridStepWait(compoundOpenProfitSwapUsd);

   if(EnableResetNotification)
      UpdateSessionStatsForNotification();

   if(basePrice > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid)
   {
      if(EnableCompoundTotalFloatingProfitLimitReverse && CompoundTotalProfitLimitReverseTriggerUSD > 0.0
         && GetCompoundTriggerProgressUsdByMode(compoundOpenProfitSwapUsd, true) >= GetCompoundFloatingTriggerThresholdUsdByMode(true))
      {
         TryArmCompoundTotalProfitMode(true, CompoundTotalProfitLimitReverseTriggerUSD);
      }
      else if(EnableCompoundTotalFloatingProfit && CompoundTotalProfitTriggerUSD > 0.0
              && compoundTriggerProgressUsd >= GetCompoundFloatingTriggerThresholdUsd())
      {
         TryArmCompoundTotalProfitMode(false, CompoundTotalProfitTriggerUSD);
      }
   }

   ProcessCompoundArming(compoundOpenProfitSwapUsd);

   ManageGridOrdersThrottled();
   TryRebaseIfNoVirtualExecTimedOut();
}

//+------------------------------------------------------------------+
//| Timer: làm mới panel lợi nhuận tháng (khi bật).                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(EnableMonthlyProfitPanel)
      MonthlyProfitPanelRedrawIfNeeded(true);
}

//+------------------------------------------------------------------+
//| Click nút < > đổi tháng trên panel.                                |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   if(!EnableMonthlyProfitPanel)
      return;
   if(sparam == MpPanelObjPrefix() + "prev")
   {
      MonthlyProfitPanelShiftMonth(-1);
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   else if(sparam == MpPanelObjPrefix() + "next")
   {
      MonthlyProfitPanelShiftMonth(1);
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
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
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!PositionIsOurSymbolAndMagic(ticket))
         continue;
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
   if(!EnableTelegram)
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
//| Gửi thông báo MT5 + Telegram khi reset / dừng EA (nội dung tiếng Việt). |
//| Telegram: (1) sendMessage tin EA. (2) Nội dung chart+phân tích local: sendPhoto (caption ngắn) + sendMessage (tách chunk nếu dài); |
//|    không ảnh: một hoặc nhiều sendMessage. |
//|    Nếu bật TelegramDeletePreviousBotMessagesOnNotify: trước khi gửi, xóa các tin bot đã gửi ở lần thông báo trước (deleteMessage). |
//+------------------------------------------------------------------+
void SendResetNotification(const string reason)
{
   if(!EnableResetNotification && !(EnableTelegram && EnableTelegramResetNotification))
      return;
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
   while(StringLen(msgPhone) > 255)
      msgPhone = StringSubstr(msgPhone, 0, 252) + "...";
   if(EnableResetNotification)
      SendNotification(msgPhone);
   if(EnableTelegram && EnableTelegramResetNotification && !g_isOnInitBootstrap)
   {
      if(TelegramDeletePreviousBotMessagesOnNotify)
         TelegramDeleteAllPreviousNotifyMessages();
      // Telegram: chỉ gửi đúng 1 tin kèm ảnh (sendPhoto + caption), không gửi text rời.
      string capShot = "VDualGrid • " + _Symbol + "\nLý do: " + rShort + "\nGiá: " + DoubleToString(bid, symDigits)
                     + "\nSố dư: " + DoubleToString(bal, 2) + " USD | P/L: "
                     + (pct >= 0 ? "+" : "") + DoubleToString(pct, 1) + "%";
      SendTelegramChartScreenshotIfEnabled(TelegramClampLen(capShot, 1024));
   }
}

void SendStartupTelegramScreenshot(const string reason)
{
   if(!EnableTelegramStartupScreenshot)
      return;
   if(!EnableTelegram || !EnableTelegramResetNotification)
      return;
   string cap = _Symbol + " • khởi động EA";
   if(StringLen(reason) > 0)
      cap += " • " + reason;
   SendTelegramChartScreenshotIfEnabled(TelegramClampLen(cap, 1024));
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

void SendStartupTelegramScreenshot(const string reason)
{
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
//| Deal OUT: cập nhật P/L tích lũy + dựng lại chờ ảo.                  |
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

   // Đóng vị thế: bổ sung chờ ảo (không áp khi vừa chờ ảo->market — xem VirtualExecCooldown).
   if(basePrice > 0.0 && ArraySize(gridLevels) >= MaxGridLevels + 1)
      ManageGridOrders();

   long dealTime = (long)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   long dealReason = (long)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   double dealProfitSwap = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   double fullDealPnL = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                  + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                  + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   if(sessionStartTime > 0 && dealTime >= (long)sessionStartTime)
   {
      g_compoundSessionClosedTotalProfitSwapUsd += dealProfitSwap;
      g_compoundSessionClosedNegativeProfitSwapUsd += MathMin(0.0, dealProfitSwap);
      if(dealReason == DEAL_REASON_TP)
         g_compoundSessionClosedTpProfitSwapUsd += dealProfitSwap;
      g_compoundSessionClosedOutVolumeLots += HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   }
   if(eaAttachTime > 0 && dealTime >= (long)eaAttachTime)
   {
      eaCumulativeTradingPL += fullDealPnL;
      // Lưu tạm đỉnh vốn đóng theo thời gian thực khi có deal OUT (không cần đợi tick).
      const double closedCapitalNow = GetTradingClosedCapitalUSD();
      if(sessionStartTime > 0 && closedCapitalNow > g_sessionPeakClosedCapitalUsd)
         g_sessionPeakClosedCapitalUsd = closedCapitalNow;
   }

   MonthlyProfitPanelOnTradeRefresh();
}

//+------------------------------------------------------------------+
//| Grid: không đặt lệnh tại gốc. ±1 cách gốc theo GridFirstLevelOffsetPips; bậc kế tiếp cách D. |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Độ lệch giá từ gốc tới bậc ký hiệu signedLevel = ±1, ±2, …         |
//+------------------------------------------------------------------+
double GridOffsetFromBaseForSignedLevel(int signedLevel)
{
   int n = MathAbs(signedLevel);
   if(n <= 0) return 0.0;
   double D = GridDistancePips * pnt * 10.0;
   double firstOffset = GridFirstLevelOffsetPips * pnt * 10.0;
   if(D <= 0.0) return 0.0;
   if(firstOffset < 0.0)
      firstOffset = 0.0;
   double off = firstOffset + ((double)n - 1.0) * D;
   return (signedLevel > 0) ? off : -off;
}

//+------------------------------------------------------------------+
//| Khoảng giá từ gốc tới bậc ±X (cùng công thức bậc ±1, bậc ±2…).   |
//+------------------------------------------------------------------+
double GridRadialDistanceFromBaseForAbsLevel(const int absLevel)
{
   if(absLevel < 1)
      return 0.0;
   int n = absLevel;
   if(n > MaxGridLevels)
      n = MaxGridLevels;
   return MathAbs(GridOffsetFromBaseForSignedLevel(n));
}

//+------------------------------------------------------------------+
//| Mid (Bid+Ask)/2 nằm ngoài đoạn thân nến đóng shift1: [min(O,C), max(O,C)]. |
//+------------------------------------------------------------------+
bool PriceMidStrictlyOutsidePrevClosedBody(const ENUM_TIMEFRAMES candleTf, const double bid, const double ask)
{
   ENUM_TIMEFRAMES tf = candleTf;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;
   if(Bars(_Symbol, tf) < 2)
      return false;
   const double bo = iOpen(_Symbol, tf, 1);
   const double bc = iClose(_Symbol, tf, 1);
   if(!MathIsValidNumber(bo) || !MathIsValidNumber(bc))
      return false;
   const double bodyLo = MathMin(bo, bc);
   const double bodyHi = MathMax(bo, bc);
   const double mid = (bid + ask) * 0.5;
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double tol = MathMax(GridPriceTolerance(), pt * 2.0);
   return (mid < bodyLo - tol || mid > bodyHi + tol);
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
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridL1BuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridL1SellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridL1SellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridL1BuyBelow;
      case VGRID_LEG_BUY_ABOVE_E: return VGridL1BuyAboveE;
      case VGRID_LEG_SELL_BELOW_F: return VGridL1SellBelowF;
      case VGRID_LEG_SELL_ABOVE_G: return VGridL1SellAboveG;
      case VGRID_LEG_BUY_BELOW_H: return VGridL1BuyBelowH;
   }
   return VGridL1BuyAbove;
}

ENUM_LOT_SCALE VirtualGridResolvedScale(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridScaleBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridScaleSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridScaleSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridScaleBuyBelow;
      case VGRID_LEG_BUY_ABOVE_E: return VGridScaleBuyAboveE;
      case VGRID_LEG_SELL_BELOW_F: return VGridScaleSellBelowF;
      case VGRID_LEG_SELL_ABOVE_G: return VGridScaleSellAboveG;
      case VGRID_LEG_BUY_BELOW_H: return VGridScaleBuyBelowH;
   }
   return VGridScaleBuyAbove;
}

double VirtualGridResolvedAddRaw(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridLotAddBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridLotAddSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridLotAddSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridLotAddBuyBelow;
      case VGRID_LEG_BUY_ABOVE_E: return VGridLotAddBuyAboveE;
      case VGRID_LEG_SELL_BELOW_F: return VGridLotAddSellBelowF;
      case VGRID_LEG_SELL_ABOVE_G: return VGridLotAddSellAboveG;
      case VGRID_LEG_BUY_BELOW_H: return VGridLotAddBuyBelowH;
   }
   return VGridLotAddBuyAbove;
}

double VirtualGridResolvedMult(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridLotMultBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridLotMultSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridLotMultSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridLotMultBuyBelow;
      case VGRID_LEG_BUY_ABOVE_E: return VGridLotMultBuyAboveE;
      case VGRID_LEG_SELL_BELOW_F: return VGridLotMultSellBelowF;
      case VGRID_LEG_SELL_ABOVE_G: return VGridLotMultSellAboveG;
      case VGRID_LEG_BUY_BELOW_H: return VGridLotMultBuyBelowH;
   }
   return VGridLotMultBuyAbove;
}

double VirtualGridResolvedMaxLot(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridMaxLotBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridMaxLotSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridMaxLotSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridMaxLotBuyBelow;
      case VGRID_LEG_BUY_ABOVE_E: return VGridMaxLotBuyAboveE;
      case VGRID_LEG_SELL_BELOW_F: return VGridMaxLotSellBelowF;
      case VGRID_LEG_SELL_ABOVE_G: return VGridMaxLotSellAboveG;
      case VGRID_LEG_BUY_BELOW_H: return VGridMaxLotBuyBelowH;
   }
   return VGridMaxLotBuyAbove;
}

bool VirtualGridResolvedTpAtNextLevel(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridTpNextBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridTpNextSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridTpNextSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridTpNextBuyBelow;
      case VGRID_LEG_BUY_ABOVE_E: return VGridTpNextBuyAboveE;
      case VGRID_LEG_SELL_BELOW_F: return VGridTpNextSellBelowF;
      case VGRID_LEG_SELL_ABOVE_G: return VGridTpNextSellAboveG;
      case VGRID_LEG_BUY_BELOW_H: return VGridTpNextBuyBelowH;
   }
   return VGridTpNextBuyAbove;
}

double VirtualGridResolvedTpPips(const ENUM_VGRID_LEG leg)
{
   switch(leg)
   {
      case VGRID_LEG_BUY_ABOVE: return VGridTpPipsBuyAbove;
      case VGRID_LEG_SELL_BELOW: return VGridTpPipsSellBelow;
      case VGRID_LEG_SELL_ABOVE: return VGridTpPipsSellAbove;
      case VGRID_LEG_BUY_BELOW: return VGridTpPipsBuyBelow;
      case VGRID_LEG_BUY_ABOVE_E: return VGridTpPipsBuyAboveE;
      case VGRID_LEG_SELL_BELOW_F: return VGridTpPipsSellBelowF;
      case VGRID_LEG_SELL_ABOVE_G: return VGridTpPipsSellAboveG;
      case VGRID_LEG_BUY_BELOW_H: return VGridTpPipsBuyBelowH;
   }
   return VGridTpPipsBuyAbove;
}

//+------------------------------------------------------------------+
//| 4g: có đủ ô lot hợp lệ để có thể bật L1 EF theo điều kiện.        |
//+------------------------------------------------------------------+
bool EfFloatingLossModeInputsConfigured()
{
   if(!EnableEfFirstLotFromOpenFloatingLoss || EfFloatingLossTriggerUsd <= 0.0)
      return false;
   const bool carryConfigured = EnableEfFloatingLossGateByCompoundCarry && EfFloatingLossMinCompoundCarryUsd > 0.0;
   const bool carryLotSet = carryConfigured && EfFloatingLossCarryMatchedFirstLot > 0.0;
   const bool floatLotSet = EfFloatingLossFirstLot > 0.0;
   if(carryConfigured)
      return carryLotSet || floatLotSet;
   return floatLotSet;
}

//+------------------------------------------------------------------+
//| 4g: Lot L1 khi đã thỏa float (+ carry gate nếu bật).             |
//+------------------------------------------------------------------+
double EfFloatingLossResolvedFirstLot()
{
   if(EnableEfFloatingLossGateByCompoundCarry && EfFloatingLossMinCompoundCarryUsd > 0.0
      && EfFloatingLossCarryMatchedFirstLot > 0.0)
      return EfFloatingLossCarryMatchedFirstLot;
   return EfFloatingLossFirstLot;
}

//+------------------------------------------------------------------+
//| 4g: đủ điều kiện để L1 Buy E / Sell F = lot cố định (float + tuỳ chọn carry). |
//+------------------------------------------------------------------+
bool EfFirstLotFloatingLossConditionMet()
{
   if(!EfFloatingLossModeInputsConfigured())
      return false;
   if(EfFloatingLossResolvedFirstLot() <= 0.0)
      return false;
   const double floating = GetOurMagicFloatingUSD();
   if(floating > -EfFloatingLossTriggerUsd)
      return false;
   if(EnableEfFloatingLossGateByCompoundCarry && EfFloatingLossMinCompoundCarryUsd > 0.0)
   {
      if(GetCompoundCarryContributionUsd() + 1e-8 < EfFloatingLossMinCompoundCarryUsd)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Lot bậc 1 theo input chân.                                        |
//+------------------------------------------------------------------+
double GetBaseLotForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   if((leg == VGRID_LEG_BUY_ABOVE_E || leg == VGRID_LEG_SELL_BELOW_F) && EfFirstLotFloatingLossConditionMet())
      return EfFloatingLossResolvedFirstLot();
   if(EnableAutoFirstLotByBaseEmaGap && g_autoFirstLotSnapshotActive && g_autoFirstLotUsingOverride && AutoFirstLotByBaseEmaLot > 0.0)
      return AutoFirstLotByBaseEmaLot;
   return VirtualGridResolvedL1(leg);
}

double GetLotMultForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return VirtualGridResolvedMult(leg);
}

double GetLotAddForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
   return MathMax(0.0, VirtualGridResolvedAddRaw(leg));
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
double ComputeVirtualTakeProfitPrice(ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double entryPrice, int signedLevelNum)
{
   const bool isBuy = (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_LIMIT);

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
//| 4g: Cập nhật lot (+ TP đồng bộ chân E/F trên chờ ảo khi P/L thay đổi). |
//| Lệnh thực không qua nhánh chờ ảo → không đổi sau khi khớp.           |
//+------------------------------------------------------------------+
void RefreshEfVirtualPendingLotIfStale(long magic, ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel, int signedLevelNum)
{
   if(!EfFloatingLossModeInputsConfigured())
      return;
   if(leg != VGRID_LEG_BUY_ABOVE_E && leg != VGRID_LEG_SELL_BELOW_F)
      return;
   if(!IsOurMagic(magic))
      return;
   const int idx = VirtualPendingFindIndex(magic, orderType, leg, priceLevel);
   if(idx < 0)
      return;
   const double entryPx = g_virtualPending[idx].priceLevel;
   g_virtualPending[idx].lot = GetLotForVirtualGridLeg(leg, MathAbs(signedLevelNum));
   g_virtualPending[idx].tpPrice = ComputeVirtualTakeProfitPrice(orderType, leg, entryPx, signedLevelNum);
}

//+------------------------------------------------------------------+
//| Nạp gridLevels. gridStep = D (thước dung sai / khớp mức).         |
//+------------------------------------------------------------------+
void InitializeGridLevels()
{
   // Lưu mốc lãi đóng cao nhất của phiên vừa qua (so với vốn đóng đầu phiên) cho phiên kế tiếp.
   if(g_sessionPeakClosedCapitalUsd > 0.0)
      g_prevSessionPeakClosedProfitUsd = MathMax(0.0, g_sessionPeakClosedCapitalUsd - g_sessionStartClosedCapitalUsd);

   VirtualPendingClear();
   OrderBalanceResetSideDwellState();
   g_resetVwSideLastConfirmBarTime = 0;
   g_compoundSessionClosedNegativeProfitSwapUsd = 0.0;
   g_compoundSessionClosedTpProfitSwapUsd = 0.0;
   g_compoundSessionClosedTotalProfitSwapUsd = 0.0;
   g_compoundSessionClosedOutVolumeLots = 0.0;
   // Current session = 0 and start counting from here (called when EA attached or EA auto reset)
   sessionStartTime = TimeCurrent();
   sessionStartBalance = GetTradingEquityViewUSD();
   g_sessionStartClosedCapitalUsd = GetTradingClosedCapitalUSD();
   g_carryTotalUsdAtGridSessionStart = g_balanceCompoundCarryUsd;
   g_sessionMaxAbsDistanceFromBasePips = 0.0;
   g_orderBalanceSessionClosedNegativeUsd = 0.0;
   double tevSess = GetTradingEquityViewUSD();
   sessionPeakTradingEquityView = tevSess;
   sessionMinTradingEquityView = tevSess;
   g_sessionPeakClosedCapitalUsd = g_sessionStartClosedCapitalUsd;
   // attachBalance / initialCapitalBaselineUSD NOT updated here — mốc % tin chỉ lúc OnInit
   double D = GridDistancePips * pnt * 10.0;
   gridStep = D;
   int totalLevels = MaxGridLevels * 2;

   ArrayResize(gridLevels, totalLevels);

   for(int i = 0; i < totalLevels; i++)
      gridLevels[i] = GetGridLevelPrice(i);
   Print("Initialized ", totalLevels, " levels: ±1 at ", DoubleToString(GridFirstLevelOffsetPips, 1), " pip from base; step ", GridDistancePips, " pips between levels");

   InitBaseEmaVirtGapSnapshotFromGridInit();
   AutoFirstLotByBaseEmaSnapshotFromGridInit();
   CompoundFloatThrHudUpdate(true);

   if(EnableDeferVirtualPendingAfterBase && basePrice > 0.0)
   {
      const int dmin = MathMax(0, DeferVirtualPendingDelayMinutes);
      const bool needTimeDefer = (dmin > 0);
      const double minPipCfg = DeferVirtualPendingMinDistanceFromBasePips;
      const bool needDistDefer = (minPipCfg > 0.0);
      if(!needTimeDefer && !needDistDefer)
      {
         ClearDeferVirtualPendingGate();
      }
      else
      {
         g_deferVirtualPendingGateActive = true;
         g_deferredVirtualGridOrdersAllowedAfter = TimeCurrent() + (datetime)dmin * 60;
         g_deferVirtReleaseLogged = false;
         if(needTimeDefer && needDistDefer)
            Print("VDualGrid: 8A2 — Gốc + mức lưới đã khởi tạo; chưa đặt chờ ảo. Cần: (1) chờ ",
                  IntegerToString(dmin), " phút; (2) max(|Bid−gốc|,|Ask−gốc|)/pip ≤ ",
                  DoubleToString(minPipCfg, 1), " pip.");
         else if(needTimeDefer)
            Print("VDualGrid: 8A2 — Gốc + mức lưới đã khởi tạo; chưa đặt chờ ảo. Chỉ chờ ",
                  IntegerToString(dmin), " phút (X pip = 0, không kiểm tra khoảng cách).");
         else
            Print("VDualGrid: 8A2 — Gốc + mức lưới đã khởi tạo; chưa đặt chờ ảo. Chỉ cần max(|Bid−gốc|,|Ask−gốc|)/pip ≤ ",
                  DoubleToString(minPipCfg, 1), " pip (phút chờ = 0).");
      }
   }
   else
      ClearDeferVirtualPendingGate();

   g_noVirtExecHadSuccessfulTrigger = false;
   if(EnableRebaseIfNoVirtualExecWithinMinutes && RebaseIfNoVirtualExecWithinMinutes > 0 && basePrice > 0.0)
      g_noVirtExecDeadline = TimeCurrent() + (datetime)(RebaseIfNoVirtualExecWithinMinutes * 60);
   else
      g_noVirtExecDeadline = 0;
}

//+------------------------------------------------------------------+
//| Manage grid: bậc ±1 gần gốc nhất; xa dần ±2,±3… Giá bậc: GetGridLevelPrice. |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Per level: max 1 order cho từng chân (leg). Remove duplicate virtual pendings. |
//+------------------------------------------------------------------+
void RemoveDuplicateOrdersAtLevel()
{
   double tolerance = gridStep * 0.5;
   if(gridStep <= 0) tolerance = pnt * 10.0 * GridDistancePips * 0.5;
   int nLevels = ArraySize(gridLevels);
   long magics[] = {MagicAA};
   bool enabled[] = {true};
   ENUM_VGRID_LEG legs[] = {VGRID_LEG_BUY_ABOVE, VGRID_LEG_BUY_ABOVE_E, VGRID_LEG_SELL_ABOVE, VGRID_LEG_SELL_ABOVE_G, VGRID_LEG_SELL_BELOW, VGRID_LEG_SELL_BELOW_F, VGRID_LEG_BUY_BELOW, VGRID_LEG_BUY_BELOW_H};
   for(int L = 0; L < nLevels; L++)
   {
      double priceLevel = gridLevels[L];
      int lvlNum = GridSignedLevelNumFromIndex(L);
      for(int m = 0; m < 1; m++)
      {
         if(!enabled[m]) continue;
         long whichMagic = magics[m];
         for(int lg = 0; lg < ArraySize(legs); lg++)
         {
            const ENUM_VGRID_LEG leg = legs[lg];
            if((lvlNum > 0 && !(leg == VGRID_LEG_BUY_ABOVE || leg == VGRID_LEG_BUY_ABOVE_E || leg == VGRID_LEG_SELL_ABOVE || leg == VGRID_LEG_SELL_ABOVE_G))
               || (lvlNum < 0 && !(leg == VGRID_LEG_SELL_BELOW || leg == VGRID_LEG_SELL_BELOW_F || leg == VGRID_LEG_BUY_BELOW || leg == VGRID_LEG_BUY_BELOW_H)))
               continue;
            int positionCount = 0;
            for(int i = 0; i < PositionsTotal(); i++)
            {
               ulong ticket = PositionGetTicket(i);
               if(ticket <= 0) continue;
               if(PositionGetInteger(POSITION_MAGIC) != whichMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
               if(StringFind(PositionGetString(POSITION_COMMENT), "|" + VirtualGridLegCode(leg) + "|") < 0) continue;
               if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - priceLevel) < tolerance)
                  positionCount++;
            }
            int idxList[];
            ArrayResize(idxList, 0);
            for(int i = 0; i < ArraySize(g_virtualPending); i++)
            {
               if(g_virtualPending[i].magic != whichMagic) continue;
               if(g_virtualPending[i].leg != leg) continue;
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
//| Mỗi bậc lưới: dựng chờ ảo theo từng chân (A/B/C/D/E/F/G/H), chạy song song. |
//+------------------------------------------------------------------+
void ManageGridOrders()
{
   if(basePrice <= 0.0)
      return;
   if(g_compoundTotalProfitActive || g_compoundAfterClearWaitGrid)
      return;

   CancelStopOrdersOutsideBaseZone();

   if(g_deferVirtualPendingGateActive)
   {
      // 8A2: AND điều kiện đang bật — phút>0 mới chờ; X pip>0 thì cần max(|Bid−gốc|,|Ask−gốc|)/pip ≤ X.
      const int dminRt = MathMax(0, DeferVirtualPendingDelayMinutes);
      const bool needTimeRt = (dminRt > 0);
      if(needTimeRt && TimeCurrent() < g_deferredVirtualGridOrdersAllowedAfter)
         return;

      const double minPipRt = DeferVirtualPendingMinDistanceFromBasePips;
      const bool needDistRt = (minPipRt > 0.0);
      if(needDistRt)
      {
         const double pipPxDefer = OnePipPrice();
         if(pipPxDefer <= 0.0)
            return;
         const double bidD = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         const double askD = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         const double distPips = MathMax(MathAbs(bidD - basePrice), MathAbs(askD - basePrice)) / pipPxDefer;
         if(distPips > minPipRt)
            return;
      }

      if(!g_deferVirtReleaseLogged)
      {
         g_deferVirtReleaseLogged = true;
         if(needTimeRt && needDistRt)
            Print("VDualGrid: 8A2 — Đủ phút chờ và khoảng cách pip (≤ ", DoubleToString(minPipRt, 1), ") → bắt đầu đặt chờ ảo.");
         else if(needTimeRt)
            Print("VDualGrid: 8A2 — Đủ phút chờ → bắt đầu đặt chờ ảo (X pip = 0).");
         else
            Print("VDualGrid: 8A2 — Đủ khoảng cách pip (≤ ", DoubleToString(minPipRt, 1), ") → bắt đầu đặt chờ ảo (không chờ phút).");
      }
      ClearDeferVirtualPendingGate();
   }

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
      if(lvlNum > 0)
      {
         EnsureOrderAtLevel(VGRID_LEG_BUY_ABOVE, wantBuy, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_BUY_ABOVE_E, wantBuy, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_SELL_ABOVE, wantSell, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_SELL_ABOVE_G, wantSell, pl, lvlNum);
      }
      else if(lvlNum < 0)
      {
         EnsureOrderAtLevel(VGRID_LEG_SELL_BELOW, wantSell, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_SELL_BELOW_F, wantSell, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_BUY_BELOW, wantBuy, pl, lvlNum);
         EnsureOrderAtLevel(VGRID_LEG_BUY_BELOW_H, wantBuy, pl, lvlNum);
      }
   }
   RemoveDuplicateOrdersAtLevel();

}

//+------------------------------------------------------------------+
//| Ensure order at level - add only when missing (no pending and no position of same type at level). |
//+------------------------------------------------------------------+
void EnsureOrderAtLevel(ENUM_VGRID_LEG leg, ENUM_ORDER_TYPE orderType, double priceLevel, int levelNum)
{
   if(!IsVirtualGridLegEnabled(leg))
      return;
   ulong  ticket       = 0;
   double existingPrice = 0.0;
   if(GetPendingOrderAtLevel(orderType, leg, priceLevel, ticket, existingPrice, MagicAA))
   {
      RefreshEfVirtualPendingLotIfStale(MagicAA, orderType, leg, priceLevel, levelNum);
      double desiredPrice = NormalizeDouble(priceLevel, dgt);
      if(MathAbs(existingPrice - desiredPrice) > (pnt / 2.0))
         AdjustVirtualPendingToLevel(MagicAA, orderType, leg, existingPrice, priceLevel, levelNum);
      return;
   }
   if(VirtualReplenishBlockedAfterExecution(priceLevel, orderType, leg, MagicAA))
      return;
   if(!CanPlaceOrderAtLevel(orderType, leg, priceLevel, MagicAA))
      return;
   if(InitBaseEmaVirtGapSuppressesVirtual(orderType, priceLevel, levelNum))
      return;
   PlacePendingOrder(orderType, leg, priceLevel, levelNum);
}

//+------------------------------------------------------------------+
//| Virtual pending at level: same type + magic (no broker pendings) |
//+------------------------------------------------------------------+
bool GetPendingOrderAtLevel(ENUM_ORDER_TYPE orderType,
                            ENUM_VGRID_LEG leg,
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
      if(g_virtualPending[i].leg != leg) continue;
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
void AdjustVirtualPendingToLevel(long magic, ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double oldPrice, double priceLevel, int signedLevelNum)
{
   if(!IsOurMagic(magic)) return;
   int idx = VirtualPendingFindIndex(magic, orderType, leg, oldPrice);
   if(idx < 0) return;
   double price = NormalizeDouble(priceLevel, dgt);
   if(InitBaseEmaVirtGapSuppressesVirtual(orderType, price, signedLevelNum))
   {
      VirtualPendingRemoveAt(idx);
      return;
   }
   double tp = ComputeVirtualTakeProfitPrice(orderType, leg, price, signedLevelNum);
   g_virtualPending[idx].priceLevel = price;
   g_virtualPending[idx].tpPrice = tp;
   if((leg == VGRID_LEG_BUY_ABOVE_E || leg == VGRID_LEG_SELL_BELOW_F)
      && EfFloatingLossModeInputsConfigured())
      g_virtualPending[idx].lot = GetLotForVirtualGridLeg(leg, MathAbs(signedLevelNum));
   Print("VDualGrid adjust: ", EnumToString(orderType), " magic ", magic, " at ", price, " TP ", tp);
}

//+------------------------------------------------------------------+
//| Max 1 order per side per level per magic (virtual pending or open position). |
//+------------------------------------------------------------------+
bool CanPlaceOrderAtLevel(ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel, long whichMagic)
{
   if(!IsOurMagic(whichMagic)) return false;
   double tolerance = gridStep * 0.5;
   if(gridStep <= 0) tolerance = pnt * 10.0 * GridDistancePips * 0.5;
   int countSameLevel = 0;

   for(int i = 0; i < ArraySize(g_virtualPending); i++)
   {
      if(g_virtualPending[i].magic != whichMagic) continue;
      if(MathAbs(g_virtualPending[i].priceLevel - priceLevel) >= tolerance) continue;
      if(g_virtualPending[i].leg == leg)
         countSameLevel++;
   }
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != whichMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(posPrice - priceLevel) >= tolerance) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "|" + VirtualGridLegCode(leg) + "|") >= 0)
         countSameLevel++;
   }
   return (countSameLevel < 1);   // Max 1 order (pending or position) per type per level
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Place pending order with TP; lot by grid level. SL set by trailing only |
//+------------------------------------------------------------------+
void PlacePendingOrder(ENUM_ORDER_TYPE orderType, ENUM_VGRID_LEG leg, double priceLevel, int levelNum)
{
   double price = NormalizeDouble(priceLevel, dgt);
   if(InitBaseEmaVirtGapSuppressesVirtual(orderType, price, levelNum))
      return;
   double lot   = GetLotForVirtualGridLeg(leg, MathAbs(levelNum));
   double tp = ComputeVirtualTakeProfitPrice(orderType, leg, price, levelNum);
   VirtualPendingAdd(MagicAA, orderType, leg, price, levelNum, tp, lot);
   Print("VDualGrid: ", EnumToString(orderType), " at ", price, " lot ", lot, " (level ", levelNum > 0 ? "+" : "", levelNum, ")");
}

//+---------------------------------------------------------------
