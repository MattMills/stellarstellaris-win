-- targets.lua : the game functions the C++ patches of stellar-injected hook or patch.
--
-- Plain data, also read by tools/make_signatures.lua (outside the game).
--
--   name      the PDB name of the function (stellar-fnmatch names)
--   overload  for names on several functions in the reference builds: which one, by address
--             order (the C++ code calls them name_1, name_2)
--   cpp       the C++ symbol (address_helper.cpp) and file, and whether dllmain.cpp enables it
--   pattern   the sigmatch pattern address_helper.cpp searches for (at the function start)
--   inside    { pattern, what }: an instruction sequence the C++ code patches inside the function
--   calls     the function the `inside` instruction calls (checked by the report)

return {
    {
        name = "CShip::CalcRegenAmount",
        cpp = { symbol = "CShip::CalcRegenAmount", file = "cship.cpp", enabled = true,
            what = "hull/armor/shield regen computed in doubles (fixed point overflow)" },
        pattern = "49 0f af d0 48 b8 09 e1 d1 c6 11 6b f1 29 4c 8b d1 48 f7 ea 48 c1 fa 0e 48 8b c2 48 c1 e8 3f 48 03 d0 48 b8 fe ff ff ff ff ff ff 7f",
    },
    {
        name = "CShip::DailyUpdateRepair",
        cpp = { symbol = "CShip::DailyUpdateRepair", file = "cship.cpp", enabled = false, what = "logging" },
        pattern = "48 89 5c 24 08 48 89 6c 24 18 48 89 74 24 20 57 41 54 41 55 41 56 41 57 48 83 ec 70 48 8b ?? 45 32 ?? ?? 8b ?? ?? ?? ?? ?? ?? 85 ?? 74 ?? ?? 8b ?? ?? ?? ?? ??",
    },
    {
        name = "CAlertManager::Update",
        cpp = { symbol = "CAlertManager::Update_asm_target_1", file = "assembly_patches.cpp", enabled = false,
            what = "NOPs the call to NSpeciesModification::CanCreateTemplateFrom (species alert lag)" },
        inside = { pattern = "e8 ?? ?? ?? ?? 84 c0 74 ?? ?? 8b 45 08 48 8b 14 18 48 8b 52 18 49 8b ce", what = "call" },
        calls = "NSpeciesModification::CanCreateTemplateFrom",
    },
    {
        name = "NSpeciesModification::CanCreateTemplateFrom",
        cpp = { file = "assembly_patches.cpp", enabled = false, what = "the call CAlertManager::Update makes" },
    },
    {
        name = "COutlinerGroupArmy::UpdateInternal",
        cpp = { symbol = "COutlinerGroupArmy::UpdateInternal_asm_target_1", file = "assembly_patches.cpp", enabled = false,
            what = "rewrites a size computation (armies vanishing from the outliner)" },
        inside = { pattern = "41 8b c4 41 0f af c4 8d 3c c5 00 00 00 00 8d 04 3b 03 c0 39 81 a0 03 00 00 0f 8c 18 04 00 00 85 c0 0f 88 10 04 00 00", what = "mov eax, r12d; imul eax, r12d" },
    },
    {
        name = "CEffect::ExecuteActual",
        cpp = { symbol = "CEffect::ExecuteActual", file = "ceffect.cpp", enabled = false, what = "logging" },
        pattern = "?? 89 5c ?? 10 ?? 89 6c ?? 18 56 57 ?? 54 ?? 56 ?? 57 ?? 83 ec 20 ?? 8b f2 ?? 8b f9 ?? 63 79 14 ?? 85 ff 0f 8e ?? ?? ?? ?? ?? 33 e4 ?? 8b f4 90",
    },
    {
        name = "CEvent::Execute",
        cpp = { symbol = "CEvent::Execute", file = "cevent.cpp", enabled = false, what = "logging" },
        pattern = "?? 89 5c ?? 10 ?? 89 6c ?? 18 56 57 ?? 54 ?? 56 ?? 57 ?? 83 ec 50 ?? 8b e1 ?? 63 f0 ?? 8b f2 ?? 8b e9 bf 40 01 00 00 65 ?? 8b 04 ?? 58 00 00 00 ?? 03 38 ?? 8b 1f ?? 89 9c ?? 80 00 00 00 ?? 89 0f",
    },
    {
        name = "CEvent::PerformImmediate",
        cpp = { symbol = "CEvent::PerformImmediate", file = "cevent.cpp", enabled = false, what = "logging" },
        pattern = "?? 89 5c ?? 10 ?? 89 6c ?? 18 56 57 ?? 54 ?? 56 ?? 57 ?? 83 ec 30 ?? 8b f1 ?? 8b e8 ?? 8b e2 ?? 8b f9 ?? 8b b1 48 0c 00 00 ?? 85 f6 74 ?? ?? 8d 40 ff 83 f8 01 77 ?? ?? 8b d1 ?? 8b ce e8 ?? ?? ?? ?? 84 c0 74 ??",
    },
    {
        name = "CRandomInListEffect::ExecuteActual",
        cpp = { symbol = "CRandomInListEffect::ExecuteActual", file = "crandominlisteffect.cpp", enabled = false, what = "logging" },
        pattern = "?? 89 54 ?? 10 55 53 56 57 ?? 54 ?? 55 ?? 56 ?? 57 ?? 81 ec 58 02 00 00 ?? 8d 6c ?? 20 ?? 8b f2 ?? 8b f1 ?? 33 ff ?? 8b ef ?? 89 bd 80 02 00 00",
    },
    {
        name = "CEveryInListEffect::ExecuteActual",
        cpp = { symbol = "CEveryInListEffect::ExecuteActual", file = "ceveryinlisteffect.cpp", enabled = false, what = "logging" },
        pattern = "?? 55 57 ?? 54 ?? 56 ?? 57 ?? 81 ec b0 00 00 00 ?? 8d 6c ?? 20 ?? 89 9d c8 00 00 00 ?? 89 b5 d0 00 00 00 ?? 8b f2 ?? 8b f1 ?? 33 ff ?? 89 7d 08 0f 57 c0 66 0f 7f 45 10 ?? 8b 05 ?? ?? ?? ?? ?? 89 45 20 ?? 8d 05 ?? ?? ?? ?? ?? 89 45 00 ?? 8d 45 00 ?? 89 45 28 ?? 8d 45 00 ?? 89 45 30 ?? 8d 45 00",
    },
    {
        name = "COnActionDatabase::PerformEvent", overload = 1,
        cpp = { symbol = "COnActionDatabase::PerformEvent", file = "conactiondatabase.cpp", enabled = false, what = "logging" },
        pattern = "?? 55 ?? 54 ?? 56 ?? 83 ec 40 80 3d ?? ?? ?? ?? 00 ?? 8b e1 ?? 8b f0 ?? 8b ea 0f 84 ?? ?? ?? ?? ?? 85 d2 0f 84 ?? ?? ?? ?? ?? 63 42 54 ?? 89 5c ?? 60 ?? 8b 5a 48 ?? 89 7c ?? 70 ?? 89 7c ?? 30",
    },
    {
        name = "COnActionDatabase::PerformEvent", overload = 2,
        cpp = { symbol = "COnActionDatabase::PerformEvent", file = "conactiondatabase.cpp", enabled = false, what = "logging" },
    },
    {
        name = "CTrigger::Evaluate", overload = 1,
        cpp = { symbol = "CTrigger::Evaluate_1", file = "ctrigger.cpp", enabled = false, what = "logging" },
    },
    {
        name = "CTrigger::Evaluate", overload = 2,
        cpp = { symbol = "CTrigger::Evaluate_2", file = "ctrigger.cpp", enabled = false, what = "logging" },
    },
    {
        name = "CTrigger::EvaluateExtended",
        cpp = { symbol = "CTrigger::EvaluateExtended", file = "ctrigger.cpp", enabled = false, what = "logging" },
    },
    {
        name = "CToken::Init",
        cpp = { symbol = "CToken::Init", file = "ctoken.cpp", enabled = false, what = "logging" },
    },
    {
        name = "CTextLexer::GetTok",
        cpp = { symbol = "CTextLexer::GetTok", file = "ctoken.cpp", enabled = false, what = "logging" },
    },
    {
        name = "CPlanetView::UpdatePopulationTab",
        cpp = { symbol = "CPlanetView::UpdatePopulationTab", file = "limit_once_in_x_seconds.cpp", enabled = false, what = "runs at most once every few seconds" },
    },
    {
        name = "CFleetManagerView::Update",
        cpp = { symbol = "CFleetManagerView::Update", file = "limit_once_in_x_seconds.cpp", enabled = false, what = "runs at most once every few seconds" },
    },
    {
        name = "CPlanetView::GetToolTip",
        cpp = { symbol = "CPlanetView::GetToolTip", file = "limit_once_in_x_seconds.cpp", enabled = false, what = "tooltip cache" },
    },
    {
        name = "CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>",
        cpp = { symbol = "CEconomicUnitBase<...>::ApplyModifiersToValue<2,0>", file = "limit_once_in_x_seconds.cpp", enabled = false, what = "result cache" },
    },
    {
        name = "CFleetTemplateManager::CalcShipsToReinforceInternal",
        cpp = { symbol = "CFleetTemplateManager::CalcShipsToReinforceInternal", file = "limit_once_in_x_seconds.cpp", enabled = false, what = "result cache" },
    },
    {
        name = "CCountry::GetLatestShipDesign", overload = 1,
        cpp = { symbol = "CCountry::GetLatestShipDesign", file = "limit_once_in_x_seconds.cpp", enabled = false, what = "result cache" },
    },
    {
        name = "CCountry::GetLatestShipDesign", overload = 2,
        cpp = { symbol = "CCountry::GetLatestShipDesign", file = "limit_once_in_x_seconds.cpp", enabled = false, what = "result cache" },
    },
}
