# CandleEcho

MetaTrader 5 Expert Advisor that trades the direction of the most recently completed candle, holding each position for exactly N candles before closing. Position sizing (martingale-style recovery, independent of direction) and direction are decoupled on purpose, to separate the effect of the signal from the effect of the lot-sizing scheme.

Source: `MQL5/Experts/CandleEcho/CandleEcho.mq5`

No indicators, no TP/SL — the EA exists to test whether one-candle directional continuation has a positive expectancy after spread/commission/slippage.
