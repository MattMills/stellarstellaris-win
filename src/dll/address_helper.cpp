#include "address_helper.h"
#include <map>

enumVersions extern global_current_version;
enumOperatingSystems extern global_current_os;
enumPlatforms extern global_current_platform;


typedef std::map<
		enumVersions, 
		std::map<
			enumOperatingSystems, 
			std::map<
				enumPlatforms, 
				std::map<
					const char *, 
					intptr_t
				>
			>
		>		
	> AddressMap;

AddressMap addr_map{};


//TODO: Refactor this more so it's more automatic from the fnaddr DB / built using instruction search
//addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM];
//["CTrigger::Evaluate_1"] = 0x140104ab0;


void init_address_map() {
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CTrigger::Evaluate_2"] = 0x1402ee3e0;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CTrigger::EvaluateExtended"] = 0x1402ee420;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CEffect::ExecuteActual"] = 0x140302b20;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CEvent::ExecuteActual"] = 0x1402df460;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CEvent::PerformImmediate"] = 0x1402df290;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["COnActionDatabase::PerformEvent"] = 0x1401d0790;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CEveryInListEffect::ExecuteActual"] = 0x140f01790;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CRandomInListEffect::ExecuteActual"] = 0x140f01d40;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CShip::DailyUpdateRepair"] = 0x1407bc4e0;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CShip::CalcRegenAmount"] = 0x1407cfc20;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CPlanetView::UpdatePopulationTab"] = 0x140b19f80;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CFleetManagerView::Update"] = 0x140b05280;
	addr_map[VERSION_3_4_5][OS_WINDOWS][STEAM]["CPlanetView::GetToolTip"] = 0x140b25540;

	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CTrigger::Evaluate_1"] = 0x1418ed9f0;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CTrigger::Evaluate_2"] = 0x140103fb0;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CTrigger::EvaluateExtended"] = 0x1402ec7b0;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CEffect::ExecuteActual"] = 0x140300eb0;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CEvent::ExecuteActual"] = 0x1402dd7f0;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CEvent::PerformImmediate"] = 0x1402dd620;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["COnActionDatabase::PerformEvent"] = 0x1401ceb00;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CEveryInListEffect::ExecuteActual"] = 0x140f00170;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CRandomInListEffect::ExecuteActual"] = 0x140f00720;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CShip::DailyUpdateRepair"] = 0x1407ba2b0;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CShip::CalcRegenAmount"] = 0x1407cd9f0;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CPlanetView::UpdatePopulationTab"] = 0x140B13190;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CFleetManagerView::Update"] = 0x140AFE490;
	addr_map[VERSION_3_4_5][OS_WINDOWS][GOG]["CPlanetView::GetToolTip"] = 0x140B1E750;

	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CTrigger::Evaluate_1"] = 0x1401d7700;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CTrigger::Evaluate_2"] = 0x0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CTrigger::EvaluateExtended"] = 0x0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CEffect::ExecuteActual"] = 0x1401f1cd0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CEvent::Execute"] = 0x140513750;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CEvent::PerformImmediate"] = 0x1405131c0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["COnActionDatabase::PerformEvent"] = 0x1402c02c0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CEveryInListEffect::ExecuteActual"] = 0x140f95ba0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CRandomInListEffect::ExecuteActual"] = 0x140f96160;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CShip::DailyUpdateRepair"] = 0x1407f6cd0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CShip::CalcRegenAmount"] = 0x14080ab70;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CPlanetView::UpdatePopulationTab"] = 0x140b757b0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CFleetManagerView::Update"] = 0x140b61260;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CPlanetView::GetToolTip"] = 0x140b811c0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CFleetTemplateManager::CalcShipsToReinforceInternal"] = 0x14090b0d0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>"] = 0x140366cf0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CCountry::GetLatestShipDesign"] = 0x14031a3f0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CAlertManager::Update_asm_target_1"] = 0x140a7fc43;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["COutlinerGroupArmy::UpdateInternal_asm_target_1"] = 0x140e280c3;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CToken::Init"] = 0x0;


	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CTrigger::Evaluate_1"] = 0x1401d59a0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CTrigger::Evaluate_2"] = 0x1400ec3f0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CTrigger::EvaluateExtended"] = 0x1401d5a50;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CEffect::ExecuteActual"] = 0x1401eff70;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CEvent::Execute"] = 0x140511a10;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CEvent::PerformImmediate"] = 0x140511480;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["COnActionDatabase::PerformEvent"] = 0x1402be560;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CEveryInListEffect::ExecuteActual"] = 0x140f945b0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CRandomInListEffect::ExecuteActual"] = 0x140f94b70;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CShip::DailyUpdateRepair"] = 0x1407f4a80;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CShip::CalcRegenAmount"] = 0x140808920;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CPlanetView::UpdatePopulationTab"] = 0x140b728b0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CFleetManagerView::Update"] = 0x140b5e360;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CPlanetView::GetToolTip"] = 0x140b7e2c0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CFleetTemplateManager::CalcShipsToReinforceInternal"] = 0x140908e80;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>"] = 0x140364FB0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CCountry::GetLatestShipDesign"] = 0x140318690;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CAlertManager::Update_asm_target_1"] = 0x140a7d033;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["COutlinerGroupArmy::UpdateInternal_asm_target_1"] = 0x140e26ad3;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CToken::Init"] = 0x14134dc10; //std::string
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CToken::Init_2"] = 0x14134dc70; //const char*
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CTextLexer::GetTok"] = 0x14134c100;

	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CTrigger::Evaluate_1"] = 0x1401df220;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CTrigger::Evaluate_2"] = 0x1400ef0e0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CTrigger::EvaluateExtended"] = 0x1401df3f0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CEffect::ExecuteActual"] = 0x1402012b0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CEvent::Execute"] = 0x140549b70;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CEvent::PerformImmediate"] = 0x140549310;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["COnActionDatabase::PerformEvent"] = 0x1402f7e10;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CEveryInListEffect::ExecuteActual"] = 0x141002050;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CRandomInListEffect::ExecuteActual"] = 0x141002610;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CShip::DailyUpdateRepair"] = 0x14083dd70;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CShip::CalcRegenAmount"] = 0x1408521f0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CPlanetView::UpdatePopulationTab"] = 0x140bcfcb0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CFleetManagerView::Update"] = 0x140bbb440;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CPlanetView::GetToolTip"] = 0x140bdb5b0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CFleetTemplateManager::CalcShipsToReinforceInternal"] = 0x14095a440;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>"] = 0x1403a21b0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CCountry::GetLatestShipDesign"] = 0x1403547b0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CAlertManager::Update_asm_target_1"] = 0x140ad4ea1;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["COutlinerGroupArmy::UpdateInternal_asm_target_1"] = 0x140e8be13;
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CToken::Init"] = 0x1413be6c0; //std::string
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CToken::Init_2"] = 0x1413be720; //const char*
	addr_map[VERSION_3_6_1][OS_WINDOWS][STEAM]["CTextLexer::GetTok"] = 0x1413bcbb0;

	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CTrigger::Evaluate_1"] = 0x1401dd4d0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CTrigger::Evaluate_2"] = 0x1400ee5e0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CTrigger::EvaluateExtended"] = 0x1401dd6a0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CEffect::ExecuteActual"] = 0x1401ff560;
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CEvent::Execute"] = 0x140547e40;
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CEvent::PerformImmediate"] = 0x1405475e0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["COnActionDatabase::PerformEvent"] = 0x1402f60c0;
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CEveryInListEffect::ExecuteActual"] = 0x141000a70;
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CRandomInListEffect::ExecuteActual"] = 0x141001030; // 48 89 54 24 10 55 53 56 57 41 54 41 55 41 56 41 57 48 81 ec 48 02 00 00
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CShip::DailyUpdateRepair"] = 0x14083bb20; // 48 89 5c 24 08 55 56 57 41 54 41 55 41 56 41 57 48 8d 6c 24 d9 48 81 ec b0 00 00 00 4c 8b f1 45 32 e4
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CShip::CalcRegenAmount"] = 0x14084ffa0; // 49 0f af d0 48 b8 09 e1 d1 c6 11 6b f1 29 4c 8b d1 48 f7 ea 48 c1 fa 0e 48 8b c2 48 c1 e8 3f 48 03 d0 48 b8 fe ff ff ff ff ff ff 7f
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CPlanetView::UpdatePopulationTab"] = 0x140bccdb0; // 48 89 5c 24 08 48 89 74 24 18 48 89 7c 24 20 55 41 54 41 55 41 56 41 57 48 8b ec 48 83 ec 60 4c 8b f1
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CFleetManagerView::Update"] = 0x140bb8540; // 40 55 53 56 57 41 54 41 55 41 56 41 57 48 8d 6c 24 e1 48 81 ec e8 00 00 00 48 8b f1 33 ff
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CPlanetView::GetToolTip"] = 0x140bd86b0; // 40 55 41 54 41 55 41 56 41 57 48 81 ec 80 03 00 00 48 8d 6c 24 50 48 89 9d 60 03 00 00 48 89 b5 68 03 00 00 48 89 bd 70 03 00 00
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CFleetTemplateManager::CalcShipsToReinforceInternal"] = 0x1409581f0; // 4c 89 4c 24 20 4c 89 44 24 18 48 89 54 24 10 48 89 4c 24 08 55 53 56 57 41 54 41 55 41 56 41 57 48 81 ec e8 02 00 00 48 8d 6c 24 30
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>"] = 0x1403a0480; //4c 8b dc 49 89 4b 08 55 56 57 41 55 41 57 48 83 ec 40 f6 82 f0 00 00 00 c0 4d 8b f9
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CCountry::GetLatestShipDesign"] = 0x140352a60; // 4c 89 4c 24 20 44 89 44 24 18 48 89 54 24 10 48 89 4c 24 08 55 53 56 57 41 54 41 55 41 56 41 57 48 8d ac 24 b8 fe ff ff 48 81 ec 48 02 00 00
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CAlertManager::Update_asm_target_1"] = 0x140ad2291;
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["COutlinerGroupArmy::UpdateInternal_asm_target_1"] = 0x140e8a833; // 41 8b c4 41 0f af c4 8d 3c c5 00 00 00 00 8d 04 3b 03 c0 39 81 a0 03 00 00 0f 8c 18 04 00 00 85 c0 0f 88 10 04 00 00
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CToken::Init"] = 0x1413babc0; //std::string // 48 89 5c 24 08 48 89 74 24 10 57 48 83 ec 20 49 83 78 18 10
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CToken::Init_2"] = 0x1413bac20; //const char* // 48 89 5c 24 08 48 89 74 24 10 57 48 83 ec 20 49 8b f0 48 8b f9 48 c7 c3 ff ff ff ff 0f 1f 40 00
	addr_map[VERSION_3_6_1][OS_WINDOWS][GOG]["CTextLexer::GetTok"] = 0x1413b90b0;


}

intptr_t find_address_from_symbol(const char * symbol) {
	CLog& logger = *getLogger();
	logger << "find_address_from_symbol(" << symbol << ")";
	logger << " address(" << addr_map[global_current_version][global_current_os][global_current_platform][symbol] << ")";
	logger << " Version(" << global_current_version << ") OS(" << global_current_os << ") platform(" << global_current_platform << ")";
	logger.endl();

	return addr_map[global_current_version][global_current_os][global_current_platform][symbol];
}

