-- functions.lua : game functions the Lua side uses itself (hook points, and functions whose code
-- names a global), as opposed to targets.lua, the functions the C++ patches target.
--
-- Plain data, also read by tools/make_signatures.lua (outside the game). See docs/main_loop.md.

return {
    { name = "CGameState::HandleTurnTick", what = "one tick (10 per game day): the turn tick hook (stellar.game)" },
    { name = "CGameApplication::Update", what = "opens the game state for a frame: names g_AllowGlobalGameStateAccess, g_AllowGetPlayer, g_CurrentGameState" },
    { name = "CInGameIdler::CheckTick", what = "opens the game state for the tick: confirms g_AllowGlobalGameStateAccess" },
    { name = "CStaticLexer::AccessStaticLexer", what = "returns the lexer (token names): names its instance (stellar.script.catalog)" },
    { name = "CScriptListsRegistryHelper<CAgreementListBuilder>::CScriptListsRegistryHelper<CAgreementListBuilder>",
        what = "registers the agreement iterators: names CTriggerDatabase::_pTriggerDatabase and CEffectDatabase::_pEffectDatabase" },
    -- methods that tell the script classes without a token apart (stellar.script.catalog census)
    { name = "CScriptedTrigger::ActualEvaluate", what = "a scripted trigger (the vtable of CScriptedTrigger)" },
    { name = "CSharedScriptedTrigger::ActualEvaluate", what = "a shared scripted trigger (a CScriptedTrigger)" },
    { name = "CContextTrigger::ReadMember", what = "a scope change in a trigger (CContextTrigger)" },
    { name = "CTriggerMTTHModifier::ReadMember", what = "a weight / MTTH modifier block (CTriggerMTTHModifier)" },
    { name = "CAndTrigger::ReadMember", what = "a block of triggers (limit, trigger, potential, ...)" },
    { name = "CScriptedEffect::Read", what = "a scripted effect (CScriptedEffect)" },
    { name = "CContextEffect::ReadMember", what = "a scope change in an effect (CContextEffect)" },
    { name = "CRandomListEffect::CEntryEffect::ReadMember", what = "an entry of random_list" },
    { name = "CEffect::ReadMember", what = "a block of effects (immediate, option, ...)" },
}
