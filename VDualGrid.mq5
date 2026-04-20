//+------------------------------------------------------------------+
//|                                                VDualGrid.mq5      |
//|     VDualGrid — chờ ảo full lưới, mỗi bậc Buy+Sell (1 magic)       |
//+------------------------------------------------------------------+
// Allow wrapper versions to reuse this file while overriding #property fields.
#ifndef VDUALGRID_SKIP_PROPERTIES
#property copyright "VDualGrid"
#property version   "4.17"
#property description "VDualGrid: lưới chờ ảo, gồng lãi/cân bằng. Nạp/rút không đổi mốc TEV trong code (tin có thể hiện số dư)."
#endif
#include <Trade\Trade.mqh>

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
   VGRID_LEG_BUY_ABOVE = 0,   // Bậc dương + Buy (BUY STOP / BUY LIMIT tại mức trên gốc)
   VGRID_LEG_SELL_BELOW = 1,  // Bậc âm + Sell (SELL STOP)
   VGRID_LEG_SELL_ABOVE = 2,  // Bậc dương + Sell (SELL LIMIT)
   VGRID_LEG_BUY_BELOW = 3    // Bậc âm + Buy (BUY LIMIT)
};

//+------------------------------------------------------------------+
//| Tab Inputs — [1–2] lưới+lệnh → [4] lot theo chân |
//| → [6b–6c] gồng/cân bằng → [8–9] lịch, MT5.                      |
//+------------------------------------------------------------------+

//——— Giao dịch: lưới, lệnh, lot ———
input group "━━ 1. Lưới giá (GRID) ━━"
input double GridDistancePips = 2000.0;         // Bước D giữa các mức (pip): bậc ±1 cách gốc nửa bước; các bậc kế tiếp cách D
input int MaxGridLevels = 50;                  // Số mức chờ ảo mỗi phía (trên và dưới giá gốc)

input group "━━ 2. Lệnh chung (magic / comment) ━━"
input int MagicNumber = 123456;                // Magic dùng chung cho chờ ảo và lệnh khớp (nhận diện lệnh EA)
input string CommentOrder = "VPGrid";           // Ghi chú (comment) gắn lệnh market

input group "━━ 2c. Bổ sung lệnh (replenish) ━━"
input bool EnableAutoReplenishVirtualOrders = true; // Bật: khớp/đóng lệnh thì tự dựng lại chờ ảo; Tắt: chỉ dựng một lần khi có gốc

input group "━━ 2d. Vùng cấm chờ ảo theo Gốc–EMA lúc khởi tạo lưới (phiên) ━━"
input bool   EnableInitBaseEmaVirtGapBlock = true; // Bật: chỉ chụp vùng Gốc–EMA lần đầu khi vừa đặt gốc; cùng gốc cả phiên thì giữ vùng. Chỉ cấm chờ ảo Stop (không cấm Limit). base>EMA → [EMA..base] cấm Sell Stop dưới gốc; base<EMA → [base..EMA] cấm Buy Stop trên gốc
input int    InitBaseEmaVirtGapEMAPeriod = 50;      // Chu kỳ EMA (PRICE_CLOSE), ≥1
input ENUM_TIMEFRAMES InitBaseEmaVirtGapEMATimeframe = PERIOD_M5; // Khung EMA lúc chụp (PERIOD_CURRENT = khung chart)

// Quy ước nhóm 2e (khi bật EnableStartupEmaFastSlowCross):
// — EA chỉ coi là “khởi động lưới” sau khi có tín hiệu EMA nhanh cắt EMA chậm; ngay lúc đó đặt đường gốc = Bid (GridBasePriceAtPlacement) rồi khởi tạo lưới.
// — Khi đã có gốc và EA đang chạy: mọi lần EMA cắt sau đó bị bỏ qua hoàn toàn — không đổi gốc, không phụ thuộc cắt EMA nữa (chỉ nhánh basePrice<=0 mới gọi hàm kiểm tra cắt).

input group "━━ 2e. Chờ EMA nhanh cắt EMA chậm mới đặt gốc (chỉ khi chưa có gốc) ━━"
input bool   EnableStartupEmaFastSlowCross = true; // Bật: chờ cắt EMA (shift 0 vs 1) mới đặt gốc; đã có gốc → EA chạy bình thường, không xét cắt nữa
input int    StartupEmaFastPeriod = 1;             // Chu kỳ EMA nhanh (PRICE_CLOSE), ≥1; nếu ≥ chậm thì tự đổi thành nhanh < chậm
input int    StartupEmaSlowPeriod = 50;           // Chu kỳ EMA chậm, ≥1
input ENUM_TIMEFRAMES StartupEmaCrossTimeframe = PERIOD_M5; // Khung so cắt (PERIOD_CURRENT = khung chart)

input group "━━ 4. Chờ ảo — lot & TP: luôn theo từng chân (4a–4d) ━━"

input group "━━ 4a. Buy trên gốc (+) — lot / TP ━━"
input double VGridL1BuyAbove = 0.01;
input ENUM_LOT_SCALE VGridScaleBuyAbove = LOT_ARITHMETIC;
input double VGridLotAddBuyAbove = 0.02;
input double VGridLotMultBuyAbove = 1.5;
input double VGridMaxLotBuyAbove = 3.0;
input bool   VGridTpNextBuyAbove = false;
input double VGridTpPipsBuyAbove = 0.0;

input group "━━ 4b. Sell dưới gốc (-) — lot / TP ━━"
input double VGridL1SellBelow = 0.01;
input ENUM_LOT_SCALE VGridScaleSellBelow = LOT_ARITHMETIC;
input double VGridLotAddSellBelow = 0.02;
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

input group "━━ 6b. Gồng lãi tổng — kích hoạt: xóa chờ ảo; chờ +1 bước lưới; SL chung tại ref; đóng SELL/BUY theo giá vs gốc; SL trượt ━━"
input bool   EnableCompoundTotalFloatingProfit = true; // ARM/chờ bước: hết ngưỡng VÀ (Bid<tham chiếu nếu rổ trên gốc | Ask>tham chiếu nếu rổ dưới gốc) → hủy, coi như chưa gồng; chờ bước thì ManageGridOrders. Còn lại: >1 pip+ngưỡng→kích hoạt xóa chờ; +1 bước→SL@ref→đóng SELL/BUY theo Bid vs gốc; SL trượt. Max loss vẫn xét nếu bật
input double CompoundTotalProfitTriggerUSD = 20.0; // Ngưỡng (USD): CHỈ Σ(profit+swap) các lệnh ĐANG MỞ (magic+symbol chart), không TP/SL đóng trong phiên, không commission; ≤0=tắt. Cộng thêm phần điều chỉnh từ nhóm 6c (nếu bật)
input bool   CompoundResetOnCommonSlHit = true; // Bật: giá quay đầu chạm mức SL chung → đóng hết, xóa lưới, chờ lịch/khung giờ hoặc đặt gốc ngay nếu trong lịch chạy

input group "━━ 6c. Cân bằng lệnh — đóng một phía + nâng ngưỡng gồng 6b ━━"
input bool   EnableOrderBalanceMode = true;        // Bật: khi giá xa gốc đủ bậc + đủ phút cùng phía gốc + lệch số lệnh hai phía → đóng hết lệnh phía yếu; P/L đóng (profit+swap) cộng vào ngưỡng Σ mở của 6b
input int    OrderBalanceMinGridStepsFromBase = 5; // Tối thiểu: Bid cách đường gốc theo số bậc lưới (trên hoặc dưới), ≥1
input int    OrderBalanceMinMinutesOnSideOfBase = 30; // Tối thiểu phút: Bid liên tục cùng phía đường gốc (chưa cắt qua vùng cấm quanh gốc), ≥1
input int    OrderBalanceCooldownSeconds = 60;     // Sau mỗi lần cân bằng: chờ N giây mới xét lại (0 = không chờ)
input bool   EnableOrderBalanceEMAFilter = true;  // Bật: N nến ĐÃ ĐÓNG gần nhất, liên tiếp theo thời gian (shift 1 = nến đóng mới nhất, 2,3… kế trước, không nhảy nến). Cả N đều close>EMA → chỉ nhánh đóng dưới gốc (+ Bid 6c); cả N close<EMA → chỉ đóng trên; lẫn hoặc có nến chạm EMA → không đóng
input int    OrderBalanceEMAPeriod = 50;        // Chu kỳ EMA (PRICE_CLOSE) cho lọc 6c, ≥1 (ví dụ: 100)
input ENUM_TIMEFRAMES OrderBalanceEMATimeframe = PERIOD_M5; // Khung nến so close vs EMA (PERIOD_CURRENT = khung chart)
input int    OrderBalanceEMAConfirmBars = 10;    // N = số nến đóng gần nhất, liên tiếp. Mỗi nến: close vs EMA cùng thời điểm; clamp 1..50

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
bool g_gridBuiltOnceThisSession = false;      // Khi tắt auto replenish: chỉ dựng chờ ảo 1 lần mỗi phiên (sau khi đặt base)
bool g_compoundTotalProfitActive = false;     // Chế độ gồng lãi tổng (nhóm 6b): SL chung, không nạp chờ ảo, SL trượt
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
int    g_startupEmaFastHandle = INVALID_HANDLE; // 2e: EMA nhanh — chỉ dùng khi chưa đặt gốc
int    g_startupEmaSlowHandle = INVALID_HANDLE; // 2e: EMA chậm
//--- Sau khi chờ ảo khớp market: chặn bổ sung lại chờ ảo cùng phía/mức cho tới khi vị thế hiện hoặc hết hạn
#define VPGRID_VIRTUAL_EXEC_COOLDOWN_SEC 5
struct VirtualExecCooldownEntry
{
   double   priceLevel;
   bool     isBuy;
   datetime expireUtc;
};
VirtualExecCooldownEntry g_virtualExecCooldown[];

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
void StartupEmaCrossReleaseHandles();
void StartupEmaCrossInitHandles();
bool StartupEmaFastSlowCrossShift0vs1();

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
         " | Chờ +1 bước lưới có lợi → SL chung tại ref → đóng toàn bộ SELL nếu Bid≥gốc, toàn bộ BUY nếu Bid<gốc.");
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

   if(EnableStartupEmaFastSlowCross)
   {
      ArrayResize(gridLevels, 0);
      sessionStartTime = 0;
      basePrice = 0.0;
      Print("VDualGrid: Gồng lãi — chạm SL chung — chờ cắt EMA nhanh/chậm để đặt gốc mới.");
      if(EnableResetNotification)
         SendResetNotification("Gồng lãi: SL chung — chờ EMA đặt gốc");
      return;
   }

   basePrice = GridBasePriceAtPlacement();
   InitializeGridLevels();
   Print("VDualGrid: Gồng lãi — chạm SL chung — đặt gốc mới ngay, base=", DoubleToString(basePrice, dgt));
   if(EnableResetNotification)
      SendResetNotification("Gồng lãi: chạm SL chung — lưới mới");
   ManageGridOrders();
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
      Print("VDualGrid: Gồng lãi tổng — hết vị thế quản lý, TẮT chế độ.");
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
}

//+------------------------------------------------------------------+
//| 2e: tạo iMA nhanh/chậm (chu kỳ nhanh < chậm).                      |
//+------------------------------------------------------------------+
void StartupEmaCrossInitHandles()
{
   StartupEmaCrossReleaseHandles();
   if(!EnableStartupEmaFastSlowCross)
      return;
   ENUM_TIMEFRAMES tf = StartupEmaCrossTimeframe;
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)_Period;
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
//| Giá đặt gốc lưới: Bid hiện tại.                                    |
//+------------------------------------------------------------------+
double GridBasePriceAtPlacement()
{
   return NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), dgt);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   eaAttachTime = TimeCurrent();
   MagicAA = MagicNumber;
   trade.SetExpertMagicNumber(MagicAA);
   dgt = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pnt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
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
   StartupEmaCrossInitHandles();
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

   g_runtimeSessionActive = IsSchedulingAllowedForNewSession(TimeCurrent());
   if(EnableRunDayFilter && !RunDayFilterAnyDaySelected())
      Print("VDualGrid: lọc ngày bật nhưng chưa chọn ngày nào — coi như không khóa theo ngày.");
   if(g_runtimeSessionActive)
   {
      if(EnableStartupEmaFastSlowCross)
      {
         VirtualPendingClear();
         ArrayResize(gridLevels, 0);
         sessionStartTime = 0;
         Print("VDualGrid: trong lịch chạy — chờ tín hiệu EMA nhanh cắt EMA chậm mới đặt gốc (khung ", EnumToString(StartupEmaCrossTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : StartupEmaCrossTimeframe), ").");
         if(EnableResetNotification)
            SendResetNotification("EA khởi động — chờ EMA nhanh/chậm đặt gốc");
      }
      else
      {
         basePrice = GridBasePriceAtPlacement();
         InitializeGridLevels();
         if(EnableResetNotification)
            SendResetNotification("EA đã khởi động");
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
   Print("Chờ ảo: mỗi bậc lưới 1 Buy+1 Sell (Stop/Limit theo vị trí giá) | mức=", ArraySize(gridLevels), " | lot L1=", GetLotForLevel(ORDER_TYPE_BUY_STOP, 1));
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
   // Đang chờ lịch (giờ/ngày server): chỉ bật phiên mới khi IsSchedulingAllowedForNewSession.
   if(!g_runtimeSessionActive)
   {
      if(IsSchedulingAllowedForNewSession(TimeCurrent()))
      {
         g_runtimeSessionActive = true;
         if(EnableStartupEmaFastSlowCross)
         {
            Print("VDualGrid: vào lịch chạy — chờ EMA nhanh cắt EMA chậm để đặt gốc.");
            if(EnableResetNotification)
               SendResetNotification("Vào lịch — chờ EMA nhanh/chậm đặt gốc");
         }
         else
         {
            basePrice = GridBasePriceAtPlacement();
            InitializeGridLevels();
            Print("VDualGrid: vào lịch chạy — khởi động phiên mới, base=", DoubleToString(basePrice, dgt));
            if(EnableResetNotification)
               SendResetNotification("Vào lịch chạy — EA khởi động phiên mới");
            ManageGridOrders();
         }
      }
      return;
   }

   const int expectedGridLevelCount = MaxGridLevels * 2;

   // Chưa có đường gốc: trong lịch + khung giờ (nếu bật) → đặt gốc một lần rồi khởi tạo lưới. Có 2e: thêm chờ cắt EMA; đã có gốc thì không vào khối này — EA chạy tiếp, không phụ thuộc EMA.
   if(g_runtimeSessionActive && basePrice <= 0.0)
   {
      if(!IsNowWithinRunWindow(TimeCurrent()))
         return;
      if(EnableStartupEmaFastSlowCross && !StartupEmaFastSlowCrossShift0vs1())
         return;
      basePrice = GridBasePriceAtPlacement();
      InitializeGridLevels();
      Print("VDualGrid: đủ điều kiện đặt gốc — base=", DoubleToString(basePrice, dgt),
            (EnableStartupEmaFastSlowCross ? " (lịch + khung giờ + cắt EMA shift0/1)" : " (lịch + khung giờ nếu bật)"));
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

   double compoundOpenProfitSwapUsd = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !IsOurMagic(PositionGetInteger(POSITION_MAGIC)) || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      compoundOpenProfitSwapUsd += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   if(g_compoundTotalProfitActive)
      ProcessCompoundTotalProfitTrailing();
   else if(g_compoundAfterClearWaitGrid)
      ProcessCompoundPostActivationGridStepWait(compoundOpenProfitSwapUsd);

   if(EnableResetNotification)
      UpdateSessionStatsForNotification();

   if(EnableCompoundTotalFloatingProfit && CompoundTotalProfitTriggerUSD > 0.0 && basePrice > 0.0
      && !g_compoundTotalProfitActive && !g_compoundArmed && !g_compoundAfterClearWaitGrid
      && compoundOpenProfitSwapUsd >= GetCompoundFloatingTriggerThresholdUsd())
   {
      TryArmCompoundTotalProfitMode();
   }

   ProcessCompoundArming(compoundOpenProfitSwapUsd);

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
   if(StringFind(reason, "EA đã dừng") >= 0)
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
//| Deal OUT: cập nhật P/L tích lũy + bổ sung chờ ảo (replenish).      |
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
   if(basePrice > 0.0 && ArraySize(gridLevels) >= MaxGridLevels + 1 && EnableAutoReplenishVirtualOrders)
      ManageGridOrders();

   long dealTime = (long)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   double fullDealPnL = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                  + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                  + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   if(eaAttachTime > 0 && dealTime >= (long)eaAttachTime)
      eaCumulativeTradingPL += fullDealPnL;
}

//+------------------------------------------------------------------+
//| Grid: không đặt lệnh tại gốc. ±1 = gốc±0.5*D; các bậc kế tiếp cách D. |
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
   double off = ((double)n - 0.5) * D;
   return (signedLevel > 0) ? off : -off;
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
   }
   return VGridTpPipsBuyAbove;
}

//+------------------------------------------------------------------+
//| Lot bậc 1 theo input chân.                                        |
//+------------------------------------------------------------------+
double GetBaseLotForVirtualGridLeg(const ENUM_VGRID_LEG leg)
{
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
//| Nạp gridLevels. gridStep = D (thước dung sai / khớp mức).         |
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
   // attachBalance / initialCapitalBaselineUSD NOT updated here — mốc % tin chỉ lúc OnInit
   double D = GridDistancePips * pnt * 10.0;
   gridStep = D;
   int totalLevels = MaxGridLevels * 2;

   ArrayResize(gridLevels, totalLevels);

   for(int i = 0; i < totalLevels; i++)
      gridLevels[i] = GetGridLevelPrice(i);
   Print("Initialized ", totalLevels, " levels: ±1 at ", DoubleToString(0.5 * GridDistancePips, 1), " pip from base; step ", GridDistancePips, " pips between levels");

   InitBaseEmaVirtGapSnapshotFromGridInit();
}

//+------------------------------------------------------------------+
//| Manage grid: bậc ±1 gần gốc nhất; xa dần ±2,±3… Giá bậc: GetGridLevelPrice. |
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
      EnsureOrderAtLevel(wantBuy, pl, lvlNum);
      EnsureOrderAtLevel(wantSell, pl, lvlNum);
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
