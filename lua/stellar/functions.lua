-- functions.lua : game functions the Lua side uses itself (hook points, and functions whose code
-- names a global), as opposed to targets.lua, the functions the C++ patches target.
--
-- Plain data, also read by tools/make_signatures.lua (outside the game). See docs/main_loop.md.

return {
    { name = "CGameState::HandleTurnTick", what = "one tick (10 per game day): the turn tick hook (stellar.game)" },
    { name = "CGameApplication::Update", what = "opens the game state for a frame: names g_AllowGlobalGameStateAccess, g_AllowGetPlayer, g_CurrentGameState" },
    { name = "CInGameIdler::CheckTick", what = "opens the game state for the tick: confirms g_AllowGlobalGameStateAccess" },
}
