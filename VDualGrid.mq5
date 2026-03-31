//+------------------------------------------------------------------+
//|                                                VDualGrid.mq5      |
//|     VDualGrid — chờ ảo full lưới, mỗi bậc Buy+Sell (1 magic)       |
//+------------------------------------------------------------------+
// Allow wrapper versions to reuse this file while overriding #property fields.
#ifndef VDUALGRID_SKIP_PROPERTIES
#property copyright "VDualGrid"
#property version   "3.51"
#property description "VDualGrid: virtual dual-side grid; half-step to level 1; session reset; cumulative total TP stop"
#endif
// WebRequest: Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL:
//   https://api.telegram.org

#include <Trade\Trade.mqh>

//--- Lot scale: 0=Fixed, 2=Geometric. Level 1 = LotSize; level 2+ = multiplier.
enum ENUM_LOT_SCALE { LOT_FIXED = 0, LOT_GEOMETRIC = 2 };

//+------------------------------------------------------------------+
//| 1. LƯỚI — khoảng cách bậc & số bậc mỗi phía so với giá gốc        |
//+------------------------------------------------------------------+
input group "=== 1. GRID — Lưới giá ==="
input double GridDistancePips = 3000.0;         // Bước lưới chuẩn (pip). Bậc ±1 cách gốc ½ bước; các bậc kế tiếp cách nhau 1 bước
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
input double VirtualGridTakeProfitPips = 3000.0;  // TP pip cho lệnh market sau khi chờ ảo khớp (0=tắt). Đóng TP -> bổ sung chờ ảo lại

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
input bool EnableTelegram = true;               // Gửi cùng nội dung qua Telegram (cần WebRequest + điền Token/Chat ID)
input string TelegramBotToken = "";             // Bot Token (@BotFather)
input string TelegramChatID = "";               // Chat ID nhóm (số âm, ví dụ -1001234567890)
input bool   TelegramFunAIAnalysis = true;        // Khối phân tích vui trên Telegram (local), không dùng Groq
input bool   EnableTelegramChartAnalysis = true;    // Thống kê nến thời gian thực (CopyRates) kèm tin để chém gió local
input ENUM_TIMEFRAMES ChartAnalysisTimeframe = PERIOD_CURRENT; // Khung nến (PERIOD_CURRENT = khung chart đang gắn EA)
input int    ChartAnalysisBars = 64;               // Số nến lấy về (10–500)
input bool   EnableTelegramChartScreenshot = true;  // Gửi thêm ảnh chart (GIF) chụp đúng lúc gửi tin — chart phải đang mở trên MT5
input int    TelegramScreenshotWidth = 1200;        // Chiều ngang (320–1920)
input int    TelegramScreenshotHeight = 800;        // Chiều dọc (240–1080)


//+------------------------------------------------------------------+
//| 6. VỐN — scale lot đầu & mục tiêu reset phiên theo số dư vs gốc   |
//+------------------------------------------------------------------+
input group "=== 6. CAPITAL — Scale theo vốn (gốc = số dư lúc gắn EA) ==="
input bool   EnableCapitalBasedScaling = true;  // Bật: lot bậc ±1 & SessionProfitTargetUSD nhân theo số dư hiện tại (nạp/rút → đổi hệ số theo input; còn % P/L trong tin vẫn tính trên gốc gắn EA)
input double CapitalGainScalePercent   = 80.0;  // X% (0–100). Vốn +100% vs gốc → mult chỉ áp X% phần tỷ lệ (50→1.5; 100→2). >100 bị giới hạn 100
input double CapitalScaleMaxBoostPercent = 100.0; // Trần % tăng tối đa so với gốc (100 = mult ≤ 2; 0 = không vượt ×1). Dù vốn tăng bao nhiêu cũng không vượt 1+this/100

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
double attachBalance = 0.0;                    // Số dư lúc gắn EA lần đầu — không cập nhật khi nạp/rút; dùng làm gốc % P/L trong tin (khác với nhánh scale vốn nhóm 6)
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
//| Gốc vốn = attachBalance (số dư khi gắn EA lần đầu, không đổi).    |
//| mult = 1 + (C/R - 1) * (X/100), rồi min(..., 1 + trần%/100).      |
//+------------------------------------------------------------------+
double GetCapitalScaleMultiplier()
{
   if(!EnableCapitalBasedScaling)
      return 1.0;
   double xEff = CapitalGainScalePercentEffective();
   if(attachBalance <= 0.0 || xEff <= 0.0)
      return 1.0;
   double C = AccountInfoDouble(ACCOUNT_BALANCE);
   if(C <= 0.0)
      return 1.0;
   double mult = 1.0 + (C / attachBalance - 1.0) * (xEff / 100.0);
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
double GetScaledSessionProfitTargetUSD()
{
   if(SessionProfitTargetUSD <= 0.0)
      return 0.0;
   double t = SessionProfitTargetUSD * GetCapitalScaleMultiplier();
   if(t < 0.01)
      t = 0.01;
   return t;
}

//+------------------------------------------------------------------+
double GetEffectiveVirtualGridBaseLot()
{
   return VirtualGridLotSize * GetCapitalScaleMultiplier();
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
   if(EnableResetNotification || EnableTelegram)
      SendResetNotification("EA đã khởi động");
   Print("========================================");
   Print("VDualGrid đã chạy. Lãi phiên: 0 USD (từ đây: mở + đã đóng trong phiên)");
   if(EnableTelegram)
      Print("VDualGrid: Telegram WebRequest — thêm https://api.telegram.org vào Tools → Options → Expert Advisors → Allow WebRequest.");
   if(EnableTelegram && EnableTelegramChartScreenshot)
      Print("VDualGrid: ảnh chart Telegram — ChartScreenShot cần chart EA đang gắn hiển thị; Strategy Tester thường không chụp được.");
   if(EnableTelegram && EnableTelegramChartAnalysis && TelegramFunAIAnalysis)
      Print("VDualGrid: Phân tích Telegram dùng local text (không dùng Groq).");
   Print("Symbol: ", _Symbol, " | Base: ", basePrice, " | Grid: ", GridDistancePips, " pips | Levels: ", ArraySize(gridLevels));
   Print("Chờ ảo: mỗi bậc lưới 1 Buy+1 Sell (Stop/Limit theo vị trí giá) | mức=", ArraySize(gridLevels), " | lot L1=", GetLotForLevel(ORDER_TYPE_BUY_STOP, 1));
   if(EnableCapitalBasedScaling)
   {
      double xEff = CapitalGainScalePercentEffective();
      double maxB = CapitalScaleMaxBoostPercentEffective();
      Print("Scale vốn: BẬT | gốc=", DoubleToString(attachBalance, 2), " USD | X% hiệu lực=", DoubleToString(xEff, 1), " (input ", DoubleToString(CapitalGainScalePercent, 1), ", max 100) | trần tăng=", DoubleToString(maxB, 1), "% (mult≤", DoubleToString(1.0 + maxB / 100.0, 4), ") | mult=", DoubleToString(GetCapitalScaleMultiplier(), 4), " | mục tiêu phiên (scale)=", DoubleToString(GetScaledSessionProfitTargetUSD(), 2), " USD");
      if(CapitalGainScalePercent > 100.0)
         Print("VDualGrid: CapitalGainScalePercent > 100 → dùng 100.");
      if(CapitalScaleMaxBoostPercent < 0.0 || CapitalScaleMaxBoostPercent > 1000000.0)
         Print("VDualGrid: CapitalScaleMaxBoostPercent ngoài [0, 1e6] → clamp.");
   }
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
      SendResetNotification("EA đã dừng (mã lý do: " + IntegerToString(reason) + ")");
   }
   Print("VDualGrid đã dừng. Mã lý do: ", reason);
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
      double sessionTargetScaled = GetScaledSessionProfitTargetUSD();
      if(effectiveSession >= sessionTargetScaled)
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
                  SendResetNotification("Dừng TP tổng — tổng lãi các lần reset phiên đạt mục tiêu");
               ExpertRemove();
               return;
            }
         }
         CloseAllPositionsAndOrders();
         lastResetTime = TimeCurrent();
         sessionClosedProfit = 0.0;
         basePrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         InitializeGridLevels();
         {
            double balNow = AccountInfoDouble(ACCOUNT_BALANCE);
            double capPct = (attachBalance > 0.0) ? ((balNow / attachBalance - 1.0) * 100.0) : 0.0;
            Print("Đạt mục tiêu lãi phiên: ", DoubleToString(effectiveSession, 2), " (TP ", DoubleToString(tpSnap, 2), " + treo ", DoubleToString(flSnap, 2), ") >= ", DoubleToString(sessionTargetScaled, 2), " USD (nhập ", DoubleToString(SessionProfitTargetUSD, 2), " × mult ", DoubleToString(GetCapitalScaleMultiplier(), 4), "). Reset EA, giá gốc mới = ", basePrice);
            Print("VDualGrid: vốn vs gốc gắn EA: ", DoubleToString(capPct, 2), "% (gốc ", DoubleToString(attachBalance, 2), " → hiện ", DoubleToString(balNow, 2), " USD)");
         }
         if(TotalProfitStopUSD > 0.0)
            Print("TP tổng (dồn): ", DoubleToString(g_accumResetSessionPL, 2), " / ", DoubleToString(TotalProfitStopUSD, 2), " USD");
         if(EnableResetNotification || EnableTelegram)
            SendResetNotification("Đạt mục tiêu lãi phiên — reset lưới");
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
                                  const double bal, const double attachBal, const string chartCompactVi)
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
      pl = "P/L giao dịch vs gắn EA: +" + DoubleToString(pct, 2) + "%. " + FunAI_Pick5(s1,
            "Woohoo xanh bụi! Thắt dây an toàn cảm xúc — tàu lượn lên dốc hét được nhưng đừng buông tay.",
            "Số đẹp phết — mai chart đổi kịch như đạo diễn uống quá caffeine, coi chừng plot twist.",
            "Đừng tưởng skill vĩnh viễn — đôi khi chỉ là sóng cho mượn, trả hồi còn lại.",
            "Kiêu nhẹ thôi nha — bot không khoe được, bạn cũng đừng khoe hộ nó quá.",
            "Chúc mừng! Giai đoạn dễ tự tin quá đà — bình tĩnh như ninja đi gác.");
   else if(pct > 0.05)
      pl = "P/L giao dịch vs gắn EA: +" + DoubleToString(pct, 2) + "%. " + FunAI_Pick5(s1,
            "Xanh nhạt matcha vibe — chill chill, chưa cần chạy vào phòng điều hành hò hét.",
            "Lãi tí cũng là lãi — lãi kép thích người không drama, drama để hội trưởng drama lo.",
            "Thắng nhẹ: đủ tự tin, chưa đủ màn hình cong — tiết kiệm ví, eco-friendly.",
            "Máy êm như xe đủ xăng — chưa nổ nhưng có ga là được.",
            "Vi mô ổn — vĩ mô thi riêng, coi như môn phụ kế bên.");
   else if(pct >= -0.05)
      pl = "P/L giao dịch vs gắn EA: " + DoubleToString(pct, 2) + "%. " + FunAI_Pick5(s1,
            "Mode Schrödinger: thắng hay thua tùy mood — chart không nói, chỉ nháy mắt.",
            "Hòa vốn cảm xúc: P/L im lặng nhưng tâm lý đang rap battle.",
            "Phẳng như ly soda quên nắp — không sai, chỉ hơi chán tí.",
            "Vùng F5 thiền: hoặc tĩnh tâm hoặc spam refresh như game idle.",
            "Không lên không xuống — ít nhất log có twist, đọc cho đỡ buồn ngủ.");
   else
      pl = "P/L giao dịch vs gắn EA: " + DoubleToString(pct, 2) + "%. " + FunAI_Pick5(s1,
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

   string balNote = "";
   if(attachBal > 0.0 && bal > attachBal * 1.01)
      balNote = "\nSố dư broker nhảy hơn gốc gắn EA — có thể vừa nạp, đừng tưởng skill +1000 overnight nha.";
   else if(attachBal > 0.0 && bal < attachBal * 0.99)
      balNote = "\nSố dư tụt hơn gốc — có thể rút hoặc lệnh làm việc, soi ledger kỹ, đừng chỉ soi meme.";

   string chartNote = "";
   if(StringLen(chartCompactVi) > 3)
      chartNote = "\n\nGợi nhanh chart: " + chartCompactVi + " — vibe nến cho đủ màu, không phải lệnh nha.";

   return out + ev + "\n\n" + pl + "\n" + dd + balNote + chartNote;
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
   // Tin đầy đủ (Telegram + chi tiết)
   string msg = "Thông báo VDualGrid\n";
   msg += "Biểu đồ: " + _Symbol + "\n";
   msg += "Lý do: " + reason + "\n";
   msg += "Giá tại thời điểm báo: " + DoubleToString(bid, symDigits) + "\n\n";
   msg += "--- THAM CHIẾU ---\n";
   msg += "Số dư khi gắn EA: " + DoubleToString(attachBalance, 2) + " USD\n";
   msg += "Nạp/rút tiền sau đó không đổi gốc này và không làm lệch % lãi/lỗ giao dịch trong tin (EA chỉ tích lũy P/L từ lệnh + swap + phí, cùng magic).\n";
   if(EnableCapitalBasedScaling)
      msg += "Đang bật scale vốn theo số dư (nhóm 6): nạp/rút có thể làm thay đổi hệ số lot & mục tiêu phiên theo quy tắc input — riêng % P/L trong thông báo vẫn so với gốc gắn EA.\n";
   msg += "\n--- TRẠNG THÁI ---\n";
   msg += "Số dư broker hiện tại: " + DoubleToString(bal, 2) + " USD\n";
   msg += "Lãi/lỗ giao dịch so với lúc gắn EA (đóng + đang treo, không tính nạp/rút): " + (pct >= 0 ? "+" : "") + DoubleToString(pct, 2) + "%\n";
   msg += "Biên độ sụt giảm tối đa (theo equity EA tính từ lúc gắn): " + DoubleToString(maxLossUSD, 2) + " USD\n";
   msg += "Mức equity thấp nhất kể từ lúc gắn EA: " + DoubleToString(globalMinTradingEquityView, 2) + " USD\n";
   msg += "--- EA MIỄN PHÍ ---\n";
   msg += "EA giao dịch tự động trên MT5 miễn phí.\n";
   msg += "Đăng ký tài khoản qua liên kết: https://one.exnessonelink.com/a/iu0hffnbzb\n";
   msg += "Sau khi đăng ký, gửi ID tài khoản để nhận EA.";
   // Điện thoại (SendNotification): tối đa 255 ký tự, chỉ tiếng Việt gọn
   string rShort = reason;
   const int rMaxPhone = 72;
   if(StringLen(rShort) > rMaxPhone)
      rShort = StringSubstr(rShort, 0, rMaxPhone - 3) + "...";
   string msgPhone = "VDualGrid • " + _Symbol + "\n";
   msgPhone += "Lý do: " + rShort + "\n";
   msgPhone += "Giá " + DoubleToString(bid, symDigits);
   msgPhone += " • Số dư " + DoubleToString(bal, 2) + " USD";
   msgPhone += " • Lãi/lỗ: " + (pct >= 0 ? "+" : "") + DoubleToString(pct, 1) + "%";
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
      SendTelegramMessageOnce(TelegramClampLen(msg, 4096));
      Sleep(200);

      const bool hasChartText = EnableTelegramChartAnalysis && StringLen(chartFullVi) > 5;
      const bool wantTin2 = TelegramFunAIAnalysis || EnableTelegramChartScreenshot || hasChartText;
      if(!wantTin2)
         return;

      string aiBlock = "";

      if(TelegramFunAIAnalysis)
      {
         aiBlock = BuildFunAIAnalysisTelegram(reason, pct, maxLossUSD, bal, attachBalance, chartCompactVi);
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
//| First lot (level 1): VirtualGridLotSize × mult vốn (mục 6) nếu bật. |
//+------------------------------------------------------------------+
double GetBaseLotForOrderType(ENUM_ORDER_TYPE orderType)
{
   if(orderType != ORDER_TYPE_BUY_LIMIT && orderType != ORDER_TYPE_SELL_LIMIT && orderType != ORDER_TYPE_BUY_STOP && orderType != ORDER_TYPE_SELL_STOP) return 0;
   return GetEffectiveVirtualGridBaseLot();
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
