//+------------------------------------------------------------------+
//|                                                VDualGrid.mq5      |
//|     VDualGrid — chờ ảo full lưới, mỗi bậc Buy+Sell (1 magic)       |
//+------------------------------------------------------------------+
// Allow wrapper versions to reuse this file while overriding #property fields.
#ifndef VDUALGRID_SKIP_PROPERTIES
#property copyright "VDualGrid"
#property version   "3.26"
#property description "VDualGrid: virtual dual-side grid; half-step to level 1; session reset; cumulative total TP stop"
#endif
// Telegram: Add https://api.telegram.org to Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL

#include <Trade\Trade.mqh>

//--- Lot scale: 0=Fixed, 2=Geometric. Level 1 = LotSize; level 2+ = multiplier.
enum ENUM_LOT_SCALE { LOT_FIXED = 0, LOT_GEOMETRIC = 2 };

//+------------------------------------------------------------------+
//| 1. LƯỚI — khoảng cách bậc & số bậc mỗi phía so với giá gốc        |
//+------------------------------------------------------------------+
input group "=== 1. GRID — Lưới giá ==="
input double GridDistancePips = 1500.0;         // Bước lưới chuẩn (pip). Bậc ±1 cách gốc ½ bước; các bậc kế tiếp cách nhau 1 bước
input int MaxGridLevels = 200;                  // Số bậc phía trên gốc + số bậc phía dưới (tổng 2× mức trên lưới)

//+------------------------------------------------------------------+
//| 2. LỆNH CHUNG — magic & comment (chờ ảo không gửi lệnh broker)    |
//+------------------------------------------------------------------+
input group "=== 2. ORDERS — Chung ==="
input int MagicNumber = 123456;                // Magic: chờ ảo + lệnh market do EA đặt
input string CommentOrder = "VPGrid";           // Comment lệnh market (khớp từ chờ ảo)

//+------------------------------------------------------------------+
//| 3. CHỜ ẢO — mỗi bậc 1 Buy+1 Sell ảo; khớp -> market + TP pip       |
//+------------------------------------------------------------------+
input group "=== 3. ORDERS — Chờ ảo (full lưới) ==="
input double VirtualGridLotSize = 0.02;          // Lot bậc ±1 (bậc ±2,±3… theo cố định/hình học bên dưới)
input ENUM_LOT_SCALE VirtualGridLotScale = LOT_GEOMETRIC; // Cố định: mọi bậc cùng lot | Hình học: nhân theo bậc
input double VirtualGridLotMult = 1.2;           // Hệ số nhân mỗi bậc xa thêm (chỉ khi chọn Hình học)
input double VirtualGridMaxLot = 3.0;             // Trần lot (0 = chỉ giới hạn của sàn)
input double VirtualGridTakeProfitPips = 1500.0;  // TP pip cho lệnh market sau khi chờ ảo khớp (0=tắt). Đóng TP -> bổ sung chờ ảo lại

//+------------------------------------------------------------------+
//| 4. PHIÊN — reset khi lãi mục tiêu (float + TP đóng trong phiên)   |
//+------------------------------------------------------------------+
input group "=== 4. SESSION — Reset theo mục tiêu lãi ==="
input bool     EnableSessionProfitReset   = true;   // Bật: đạt mục tiêu thì đóng hết & tính lại gốc/lưới
input double   SessionProfitTargetUSD     = 100.0;  // Ngưỡng USD: P/L nổi hiện tại + tổng lãi đóng bằng TP trong phiên

//+------------------------------------------------------------------+
//| 4.1 TP TỔNG — đạt ngưỡng thì đóng hết lệnh EA & gỡ EA khỏi chart  |
//+------------------------------------------------------------------+
input group "=== 4.1 SESSION — TP tổng (dừng hẳn EA) ==="
input double TotalProfitStopUSD = 0.0;           // 0=tắt. Mỗi lần đạt mục tiêu reset phiên (4): cộng (TP phiên+float); tổng dồn ≥ ngưỡng → đóng hết & gỡ EA. Chạy lại: xóa GV trong log

//+------------------------------------------------------------------+
//| 5. THÔNG BÁO — push khi reset/stop EA                              |
//+------------------------------------------------------------------+
input group "=== 5. NOTIFICATIONS ==="
input bool EnableResetNotification = true;     // Gửi thông báo MT5 khi EA reset (mục tiêu phiên) hoặc dừng

input group "=== 5.1 NOTIFICATIONS — Telegram ==="
input bool EnableTelegram = false;              // Gửi cùng nội dung qua Telegram (cần WebRequest)
input string TelegramBotToken = "";             // Bot Token (@BotFather)
input string TelegramChatID = "";               // Chat ID nhóm (số âm, ví dụ -1001234567890)

//--- Global variables
CTrade trade;
double pnt;
int dgt;
double basePrice;                               // Base price (base line)
double gridLevels[];                            // Array of level prices (evenly spaced by GridDistancePips)
double gridStep;                                // One grid step (price) = GridDistancePips, used for tolerance/snap
double lastTickBid = 0.0;
double lastTickAsk = 0.0;
// Session TP-net — chỉ đóng TP, không pool cân bằng.
double sessionClosedProfit = 0.0;               // Session: TP profit in session. Reset on EA reset.
datetime lastResetTime = 0;                     // Last reset time (avoid double-count from orders just closed on reset)
double attachBalance = 0.0;                    // Balance when EA first attached: never reset. Reference for trading-equity view (không cập nhật khi nạp/rút sau đó)
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
double sessionStartBalance = 0.0;             // Balance at session start (for info panel and session %)
int MagicAA = 0;                              // Strategy magic (= MagicNumber in OnInit)
double g_accumResetSessionPL = 0.0;           // TP tổng: cộng dồn effectiveSession mỗi lần reset phiên (mục 4)

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
//| Swap helpers for sort by distance                                |
//+------------------------------------------------------------------+
void SwapDouble(double &a, double &b) { double t = a; a = b; b = t; }
void SwapULong(ulong &a, ulong &b) { ulong t = a; a = b; b = t; }

string BuildOrderCommentWithLevel(int levelNum)
{
   return "VDualGrid|L" + (levelNum > 0 ? "+" : "") + IntegerToString(levelNum);
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
      if(IsOurMagic(e.magic) && basePrice > 0.0 && ArraySize(gridLevels) >= MaxGridLevels + 1)
      {
         if(!VirtualPriceMatchesRegisteredGrid(e.priceLevel))
         {
            VirtualPendingRemoveAt(i);
            continue;
         }
      }
      bool trigger = false;
      // Trên gốc (+1): Buy Stop & Sell Limit — Ask cắt mức từ dưới lên.
      if(e.orderType == ORDER_TYPE_BUY_STOP || e.orderType == ORDER_TYPE_SELL_LIMIT)
         trigger = (prevAsk < (e.priceLevel - tol) && ask >= (e.priceLevel - tol));
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
   // Update last tick prices after processing triggers.
   lastTickBid = bid;
   lastTickAsk = ask;
}

//+------------------------------------------------------------------+
//| Position P/L = profit + swap (overnight fee). Commission only when position closed (in DEAL). |
//+------------------------------------------------------------------+
double GetPositionPnL(ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket)) return 0.0;
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
   basePrice = 0.0;
   lastTickBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   lastTickAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   eaCumulativeTradingPL = 0.0;
   sessionClosedProfit = 0.0;
   lastResetTime = 0;

   attachBalance = AccountInfoDouble(ACCOUNT_BALANCE);   // Initial capital: balance when EA is first added (for panel only)
   double tevInit = GetTradingEquityViewUSD();
   sessionPeakTradingEquityView = tevInit;
   sessionMinTradingEquityView = tevInit;
   globalPeakTradingEquityView = tevInit;
   globalMinTradingEquityView = tevInit;
   sessionMaxSingleLot = 0.0;
   sessionTotalLotAtMaxLot = 0.0;
   g_accumResetSessionPL = 0.0;

   basePrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   InitializeGridLevels();
   if(EnableResetNotification)
      SendResetNotification("EA started");
   Print("========================================");
   Print("VDualGrid started. Session profit: 0 USD (open + closed from now)");
   Print("Symbol: ", _Symbol, " | Base: ", basePrice, " | Grid: ", GridDistancePips, " pips | Levels: ", ArraySize(gridLevels));
   Print("Chờ ảo: mỗi bậc lưới 1 Buy+1 Sell (Stop/Limit theo vị trí giá) | mức=", ArraySize(gridLevels), " | lot L1=", GetLotForLevel(ORDER_TYPE_BUY_STOP, 1));
   Print("========================================");
   ManageGridOrders();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Gỡ object chart từ bản EA cũ (tên cố định)
   ObjectDelete(0, "VPGrid_BaseLine");
   ObjectDelete(0, "VPGrid_PoolGateAbove");
   ObjectDelete(0, "VPGrid_PoolGateBelow");
   ObjectDelete(0, "VPGrid_PoolGateZone");
   if(EnableResetNotification || EnableTelegram)
   {
      UpdateSessionStatsForNotification();
      SendResetNotification("EA stopped (reason: " + IntegerToString(reason) + ")");
   }
   Print("VDualGrid stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ProcessVirtualPendingExecutions();

   if(EnableResetNotification)
      UpdateSessionStatsForNotification();
   
   double floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !IsOurMagic(PositionGetInteger(POSITION_MAGIC)) || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(sessionStartTime > 0 && (datetime)PositionGetInteger(POSITION_TIME) < sessionStartTime)
         continue;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   if(EnableSessionProfitReset && SessionProfitTargetUSD > 0)
   {
      double effectiveSession = sessionClosedProfit + floating;
      if(effectiveSession >= SessionProfitTargetUSD)
      {
         double tpSnap = sessionClosedProfit;
         double flSnap = floating;
         // TP tổng: cộng dồn mỗi lần reset phiên đủ điều kiện; đạt ngưỡng → dừng hẳn (không reset lưới tiếp)
         if(TotalProfitStopUSD > 0.0)
         {
            g_accumResetSessionPL += effectiveSession;
            if(g_accumResetSessionPL >= TotalProfitStopUSD)
            {
               CloseAllPositionsAndOrders();
               GlobalVariableSet(VDualGridTotalStopGvKey(), (double)TimeCurrent());
               Print("VDualGrid: TP tổng (cộng dồn các lần reset phiên) ", DoubleToString(g_accumResetSessionPL, 2), " >= ", DoubleToString(TotalProfitStopUSD, 2), " USD — đóng hết & gỡ EA. Xóa GV \"", VDualGridTotalStopGvKey(), "\" để chạy lại.");
               if(EnableResetNotification || EnableTelegram)
                  SendResetNotification("Total profit stop — accumulated session resets >= target");
               ExpertRemove();
               return;
            }
         }
         CloseAllPositionsAndOrders();
         lastResetTime = TimeCurrent();
         sessionClosedProfit = 0.0;
         basePrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         InitializeGridLevels();
         Print("Session profit target reached: ", DoubleToString(effectiveSession, 2), " (TP ", DoubleToString(tpSnap, 2), " + float ", DoubleToString(flSnap, 2), ") >= ", DoubleToString(SessionProfitTargetUSD, 2), ". Reset EA, new base = ", basePrice);
         if(TotalProfitStopUSD > 0.0)
            Print("TP tổng (dồn): ", DoubleToString(g_accumResetSessionPL, 2), " / ", DoubleToString(TotalProfitStopUSD, 2), " USD");
         if(EnableResetNotification || EnableTelegram)
            SendResetNotification("Session profit target reached - reset");
         ManageGridOrders();
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

//+------------------------------------------------------------------+
//| URL encode for Telegram text                                       |
//+------------------------------------------------------------------+
string UrlEncodeForTelegram(const string s)
{
   string result = "";
   for(int i = 0; i < StringLen(s); i++)
   {
      ushort c = StringGetCharacter(s, i);
      if(c == ' ') result += "+";
      else if(c == '\n') result += "%0A";
      else if(c == '\r') result += "%0D";
      else if(c == '&') result += "%26";
      else if(c == '=') result += "%3D";
      else if(c == '+') result += "%2B";
      else if(c == '%') result += "%25";
      else if(c >= 32 && c < 127) result += CharToString((uchar)c);
      else result += "%" + StringFormat("%02X", c);
   }
   return result;
}

//+------------------------------------------------------------------+
//| Send message to Telegram via Bot. Add https://api.telegram.org to Allow WebRequest. |
//+------------------------------------------------------------------+
void SendTelegramMessage(const string msg)
{
   if(!EnableTelegram || StringLen(TelegramBotToken) < 10 || StringLen(TelegramChatID) < 5)
      return;
   string url = "https://api.telegram.org/bot" + TelegramBotToken + "/sendMessage";
   string body = "chat_id=" + TelegramChatID + "&text=" + UrlEncodeForTelegram(msg);
   char post[], result[];
   string resultHeaders;
   StringToCharArray(body, post, 0, StringLen(body));
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   ResetLastError();
   int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
   if(res != 200)
      Print("Telegram: WebRequest failed, res=", res, " err=", GetLastError(), ". Add https://api.telegram.org to Tools->Options->Expert Advisors->Allow WebRequest.");
}

//+------------------------------------------------------------------+
//| Send notification when EA resets or stops. Example:                |
//| EA RESET                                                           |
//| Chart: EURUSD                                                     |
//| Reason: Session profit target                                       |
//| Initial balance: 10000.00 USD                                      |
//| Current broker balance: 10250.00 USD                                |
//| Trading P/L vs attach (excl. deposit/withdraw): +2.50%              |
//| Max drawdown (trading view): 150.00 USD                            |
//| Max single lot / total open (since attach): 0.05 / 0.25             |
//+------------------------------------------------------------------+
void SendResetNotification(const string reason)
{
   if(!EnableResetNotification && !EnableTelegram) return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int symDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double flNow = GetOurMagicFloatingUSD();
   // % chỉ từ giao dịch: (đóng lệnh + float) / vốn lúc gắn — không nạp/rút
   double pct = (attachBalance > 0) ? ((eaCumulativeTradingPL + flNow) / attachBalance * 100.0) : 0;
   double maxLossUSD = globalPeakTradingEquityView - globalMinTradingEquityView;
   string msg = "VDualGrid\n";
   msg += "Chart: " + _Symbol + "\n";
   msg += "Reason: " + reason + "\n";
   msg += "Price at reset: " + DoubleToString(bid, symDigits) + "\n\n";
   msg += "--- SETTINGS ---\n";
   msg += "Balance at EA attach (reference): " + DoubleToString(attachBalance, 2) + " USD\n\n";
   msg += "--- CURRENT STATUS ---\n";
   msg += "Current broker balance: " + DoubleToString(bal, 2) + " USD\n";
   msg += "Trading P/L vs attach (closed+float, excl. deposit/withdraw): " + (pct >= 0 ? "+" : "") + DoubleToString(pct, 2) + "%\n";
   msg += "Max drawdown (trading view): " + DoubleToString(maxLossUSD, 2) + " USD\n";
   msg += "Lowest trading-equity view (since attach): " + DoubleToString(globalMinTradingEquityView, 2) + " USD\n";
   msg += "--- FREE EA ---\n";
   msg += "Free MT5 automated trading EA.\n";
   msg += "Just register an account using this link: https://one.exnessonelink.com/a/iu0hffnbzb\n";
   msg += "After registering, send me your account ID to receive the EA.";
   if(EnableResetNotification)
      SendNotification(msg);
   SendTelegramMessage(msg);
}

//+------------------------------------------------------------------+
//| Close all positions and cancel all pending orders (EA magic).     |
//| After this: no open positions, no pending orders. Used on every reset. |
//+------------------------------------------------------------------+
void CloseAllPositionsAndOrders()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
         trade.PositionClose(ticket);
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && IsOurMagic(OrderGetInteger(ORDER_MAGIC)))
         trade.OrderDelete(ticket);
   }
   VirtualPendingClear();
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
   // Only count closes by TP (Take Profit). Closes by SL / manual / stop out do not add to session TP-net.
   if(HistoryDealGetInteger(trans.deal, DEAL_REASON) != DEAL_REASON_TP)
      return;

   sessionClosedProfit += fullDealPnL;   // Session TP từ đóng TP — không pool cân bằng
}

//+------------------------------------------------------------------+
//| Grid: gốc = 0. Bậc ±1 cách gốc ½ bước lưới; bậc ±2,±3… cách nhau   |
//| đúng 1 bước lưới (GridDistancePips). Không đặt lệnh tại gốc.        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Giá mức levelIndex (0..2*MaxGridLevels-1).                         |
//| Trên gốc: +1 = base+0.5*step, +2 = base+1.5*step, +k = base+(k-0.5)*step. |
//| Dưới gốc: -1 = base-0.5*step, -2 = base-1.5*step, …                |
//+------------------------------------------------------------------+
double GetGridLevelPrice(int levelIndex)
{
   if(levelIndex < MaxGridLevels)
      return NormalizeDouble(basePrice + ((double)levelIndex + 0.5) * gridStep, dgt);
   int k = levelIndex - MaxGridLevels;
   return NormalizeDouble(basePrice - ((double)k + 0.5) * gridStep, dgt);
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
//| First lot (level 1): EACH ORDER TYPE SEPARATE (VirtualGridLotSize). |
//+------------------------------------------------------------------+
double GetBaseLotForOrderType(ENUM_ORDER_TYPE orderType)
{
   if(orderType != ORDER_TYPE_BUY_LIMIT && orderType != ORDER_TYPE_SELL_LIMIT && orderType != ORDER_TYPE_BUY_STOP && orderType != ORDER_TYPE_SELL_STOP) return 0;
   return VirtualGridLotSize;
}

//+------------------------------------------------------------------+
//| Lot: Level 1 = fixed (input). Level 2+ = input * mult^(level-1)   |
//| Scale and mult per order type.                                    |
//+------------------------------------------------------------------+
double GetLotMultForOrderType(ENUM_ORDER_TYPE orderType)
{
   if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP || orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT) return VirtualGridLotMult;
   return 1.0;
}

ENUM_LOT_SCALE GetLotScaleForOrderType(ENUM_ORDER_TYPE orderType)
{
   if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP || orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT) return VirtualGridLotScale;
   return LOT_FIXED;
}

//+------------------------------------------------------------------+
//| LOT CALC: Level +1/-1 = first lot. Level +2/-2, +3/-3... =         |
//| Scale by multiplier. levelNum: +1..+n (above), -1..-n (below).    |
//+------------------------------------------------------------------+
double GetLotForLevel(ENUM_ORDER_TYPE orderType, int levelNum)
{
   int absLevel = MathAbs(levelNum);
   double baseLot = GetBaseLotForOrderType(orderType);
   ENUM_LOT_SCALE scale = GetLotScaleForOrderType(orderType);
   double lot = baseLot;
   if(absLevel <= 1 || scale == LOT_FIXED)
      lot = baseLot;   // Level +1/-1 = first lot
   else if(scale == LOT_GEOMETRIC)
      lot = baseLot * MathPow(GetLotMultForOrderType(orderType), absLevel - 1);   // Level +2/-2... = scaled
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(VirtualGridMaxLot > 0)
      maxLot = MathMin(maxLot, VirtualGridMaxLot);   // Max lot cap (0 = no limit)
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot) lot = minLot;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Get Take Profit (pips) for order type; 0 = off                    |
//+------------------------------------------------------------------+
double GetTakeProfitPipsForOrderType(ENUM_ORDER_TYPE orderType)
{
   if(orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_SELL_STOP || orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_LIMIT) return VirtualGridTakeProfitPips;
   return 0;
}

//+------------------------------------------------------------------+
//| Nạp gridLevels: bậc ±1 tại ±0.5*gridStep; khoảng giữa hai bậc liên tiếp = gridStep. |
//| gridStep = GridDistancePips * pip (5 số: 1 pip = 10*point).       |
//+------------------------------------------------------------------+
void InitializeGridLevels()
{
   VirtualPendingClear();
   // Current session = 0 and start counting from here (called when EA attached or EA auto reset)
   sessionStartTime = TimeCurrent();
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionStartBalance = bal;
   double tevSess = GetTradingEquityViewUSD();
   sessionPeakTradingEquityView = tevSess;
   sessionMinTradingEquityView = tevSess;
   // attachBalance NOT updated here - set once in OnInit (capital when EA first attached)
   gridStep = GridDistancePips * pnt * 10.0;
   int totalLevels = MaxGridLevels * 2;

   ArrayResize(gridLevels, totalLevels);

   for(int i = 0; i < totalLevels; i++)
      gridLevels[i] = GetGridLevelPrice(i);
   Print("Initialized ", totalLevels, " levels: ±1 at ", DoubleToString(0.5 * GridDistancePips, 1), " pip from base; step ", GridDistancePips, " pips between levels");
}

//+------------------------------------------------------------------+
//| Manage grid: bậc ±1 gần gốc nhất; xa dần ±2,±3…                    |
//| Giá bậc: ±1 = gốc ± 0.5*gridStep; khoảng giữa hai bậc liên tiếp = gridStep. |
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
}

//+------------------------------------------------------------------+
//| Ensure order at level - add only when missing (no pending and no position of same type at level). |
//+------------------------------------------------------------------+
void EnsureOrderAtLevel(ENUM_ORDER_TYPE orderType, double priceLevel, int levelNum)
{
   ulong  ticket       = 0;
   double existingPrice = 0.0;
   if(GetPendingOrderAtLevel(orderType, priceLevel, ticket, existingPrice, MagicAA))
   {
      double desiredPrice = NormalizeDouble(priceLevel, dgt);
      if(MathAbs(existingPrice - desiredPrice) > (pnt / 2.0))
         AdjustVirtualPendingToLevel(MagicAA, orderType, existingPrice, priceLevel, GetTakeProfitPipsForOrderType(orderType));
      return;
   }
   if(VirtualReplenishBlockedAfterExecution(priceLevel, orderType, MagicAA))
      return;
   if(!CanPlaceOrderAtLevel(orderType, priceLevel, MagicAA))
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
void AdjustVirtualPendingToLevel(long magic, ENUM_ORDER_TYPE orderType, double oldPrice, double priceLevel, double tpPipsOverride)
{
   int idx = VirtualPendingFindIndex(magic, orderType, oldPrice);
   if(idx < 0) return;
   double price = NormalizeDouble(priceLevel, dgt);
   double tp = 0;
   double tpPips = tpPipsOverride;
   if(tpPips > 0)
   {
      if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP)
         tp = NormalizeDouble(price + tpPips * pnt * 10.0, dgt);
      else
         tp = NormalizeDouble(price - tpPips * pnt * 10.0, dgt);
   }
   g_virtualPending[idx].priceLevel = price;
   g_virtualPending[idx].tpPrice = tp;
   Print("VDualGrid adjust: ", EnumToString(orderType), " magic ", magic, " at ", price, " TP ", tp);
}

//+------------------------------------------------------------------+
//| Max 1 order per side per level per magic (virtual pending or open position). |
//+------------------------------------------------------------------+
bool CanPlaceOrderAtLevel(ENUM_ORDER_TYPE orderType, double priceLevel, long whichMagic)
{
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
   double lot   = GetLotForLevel(orderType, levelNum);
   double tp = 0;
   double tpPips = GetTakeProfitPipsForOrderType(orderType);
   if(tpPips > 0)
   {
      bool isBuy = (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_LIMIT);
      if(isBuy)
         tp = NormalizeDouble(price + tpPips * pnt * 10.0, dgt);
      else
         tp = NormalizeDouble(price - tpPips * pnt * 10.0, dgt);
   }
   VirtualPendingAdd(MagicAA, orderType, price, levelNum, tp, lot);
   Print("VDualGrid: ", EnumToString(orderType), " at ", price, " lot ", lot, " (level ", levelNum > 0 ? "+" : "", levelNum, ")");
}

//+------------------------------------------------------------------+
