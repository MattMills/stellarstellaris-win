-- functions.lua : game functions the Lua side uses (hook points, functions whose code names a
-- global, and methods that identify the script engine's classes).
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
    -- the text lexer: the game's PDXScript tokenizer (stellar.script.lexer replaces it)
    { name = "CTextLexer::GetTok", what = "the next token of a script text: the lexer hook" },
    { name = "CMemoryFile::CMemoryFile", what = "names the vtable of CMemoryFile: a lexer's file whose text is in memory" },
    { name = "CToken::SetCharInString", what = "writes a byte of a token's text, growing it: the lexer in replace mode" },
    -- the load screen: the stages of loading and its progress (stellar.loading)
    { name = "SPushLoadScreenState::SPushLoadScreenState", what = "a loading stage begins: its share of the progress bar and the C++ file and line" },
    { name = "SPushLoadScreenState::~SPushLoadScreenState", what = "a loading stage ends" },
    { name = "RenderLoadScreen", what = "draws the load screen at a progress (0 to 100)" },
    { name = "CGameApplication::LoadingScreenCallback", what = "a step of a phase of the startup load (current of total, the phase's start and span of the bar)" },
    -- the game databases (stellar.databases)
    { name = "NNullObjAndDatabaseInitUtil::SetupDatabases", what = "initializes the game databases: their table is in its code" },
    -- the steps of CGameApplication::InitGame around the databases (stellar.loading milestones)
    { name = "CGlobalScriptedVariablesDatabase::InitializeWithDirectory", what = "a milestone of the load: the scripted variables" },
    { name = "CModifier::InitDefinitions", what = "a milestone of the load: the modifier definitions" },
    { name = "CModifier::InitDefinitionIcons", what = "a milestone of the load: the end of SetupDatabases" },
    { name = "CGameRules::InitInstance", what = "a milestone of the load: the game rules" },
    { name = "CAchievementsManager::InitFromFile", what = "a milestone of the load: the achievements" },
    { name = "CApplication::CalculateGameFilesChecksum", what = "a milestone of the load: the checksum of the game files" },
    { name = "CStaticModifierDatabase::Init", what = "a milestone of the load: the static modifiers" },
    { name = "CTriggerDatabase::PostInit", what = "a milestone of the load: the triggers after the databases" },
    { name = "CTriggerDatabase::PostValidate", what = "a milestone of the load: the triggers validated" },
    { name = "CEffectDatabase::PostInit", what = "a milestone of the load: the effects after the databases" },
    { name = "CEffectDatabase::PostValidate", what = "a milestone of the load: the effects validated" },
    { name = "CEventManager::InitEventConnectivityMaps", what = "a milestone of the load: the event connectivity" },
    { name = "CModifier::LogDefinitions", what = "a milestone of the load: the modifiers logged" },
    { name = "CGameApplication::PrintScriptingDocumentation", what = "a milestone of the load: the script documentation written" },
    { name = "CPortraitSpriteType::InitializeScriptedLogic", what = "a milestone of the load: the portraits" },
    { name = "CFrontEndIdler::CFrontEndIdler", what = "a milestone of the load: the main menu" },
    { name = "DestroyLoadScreen", what = "a milestone of the load: the load screen goes away" },
}
