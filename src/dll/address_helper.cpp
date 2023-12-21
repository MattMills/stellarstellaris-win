#include "address_helper.h"
#include <map>
#include <sigmatch/sigmatch.hpp>





enumVersions extern global_current_version;
enumOperatingSystems extern global_current_os;
enumPlatforms extern global_current_platform;
intptr_t extern base_augustus_ptr;
HMODULE extern hModule;
intptr_t extern base_offset;



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


// search the memory of the loaded executable for a single address that represents the signature bytestring

// return value should be single intptr_t address representing start of signature match or 
// 0x0 if no match or if multiple matches.


intptr_t signature_search(std::string module_name, sigmatch::signature sig) {
	CLog& logger = *getLogger();

	sigmatch::this_process_target target;
	sigmatch::search_result result = target.in_module(module_name).search(sig);

	//TODO: check if we have more than 1 match and fail
	for (const std::byte* address : result.matches()) {
		logger << "[DBG-sigmatch] matched: " << address;
		logger.endl();
		return (intptr_t) address;
	}

	return 0x0;
}

//TODO: Refactor this more so it's more automatic from the fnaddr DB / built using instruction search
// (INPROGRESS)



void init_address_map() {
	CLog& logger = *getLogger();
	using namespace sigmatch_literals;
	//CShip::DailyUpdateRepair

	logger << "[DBG-sigmatch] CShip::DailyUpdateRepair";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["CShip::DailyUpdateRepair"] = signature_search("stellaris.exe", "48 89 5c 24 08 48 89 6c 24 18 48 89 74 24 20 57 41 54 41 55 41 56 41 57 48 83 ec 70 48 8b ?? 45 32 ?? ?? 8b ?? ?? ?? ?? ?? ?? 85 ?? 74 ?? ?? 8b ?? ?? ?? ?? ??"_sig);

	/*[01001...] 89 5c [..100100] 08 [01001...] 89 6c [..100100] 18 [01001...] 89 74 
	[..100100] 20 57 [01000...] 54 [01000...] 55 [01000...] 56 [01000...] 57 [01001...] 83 ec 70 
	[01001...] 8b [11......] [01000...] 32 [11......] [01001...] 8b [00...101] [........] [........] [........] [........] [01001...] 85 [11......] 74 [........] [01000...] 8b [10......] [........] [........] [........] [........] */
	
	//CShip::CalcRegenAmount
	logger << "[DBG-sigmatch] CShip::CalcRegenAmount";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["CShip::CalcRegenAmount"] = signature_search("stellaris.exe", "49 0f af d0 48 b8 09 e1 d1 c6 11 6b f1 29 4c 8b d1 48 f7 ea 48 c1 fa 0e 48 8b c2 48 c1 e8 3f 48 03 d0 48 b8 fe ff ff ff ff ff ff 7f"_sig);
	
	//CAlertManager::Update_asm_target_1
	logger << "[DBG-sigmatch] CAlertManager::Update_asm_target_1";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["CAlertManager::Update_asm_target_1"] = signature_search("stellaris.exe", "e8 ?? ?? ?? ?? 84 c0 74 ?? ?? 8b 45 08 48 8b 14 18 48 8b 52 18 49 8b ce"_sig);

	/*e8 [........] [........] [........] [........] 84 c0 74 [........] [01001...] 8b 45 08 [01001...] 8b 14 18 [01001...] 8b 52 18 [01001...] 8b ce */
	//COutlinerGroupArmy::UpdateInternal_asm_target_1
	logger << "[DBG-sigmatch] COutlinerGroupArmy::UpdateInternal_asm_target_1";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["COutlinerGroupArmy::UpdateInternal_asm_target_1"] = signature_search("stellaris.exe", "41 8b c4 41 0f af c4 8d 3c c5 00 00 00 00 8d 04 3b 03 c0 39 81 a0 03 00 00 0f 8c 18 04 00 00 85 c0 0f 88 10 04 00 00"_sig);
	
	/*
	[01001...] 89 5c [..100100] 10 [01001...] 89 6c [..100100] 18 56 57 [01000...] 54 [01000...] 56 [01000...] 57 [01001...] 83 ec 20 [01001...] 8b f2
	[01001...] 8b f9 [01001...] 63 79 14 [01001...] 85 ff 0f 8e [........] [........] [........] [........] [01000...] 33 e4 [01000...] 8b f4 90 

	48 89 5c 24 10 48 89 6c 24 18 56 57 41 54 41 56 41 57 48 83 ec 20 4c 8b f2 48 8b f9 4c 63 79 14 4d 85 ff 0f 8e 82 00 00 00 45 33 e4 41 8b f4 90
	*/

	logger << "[DBG-sigmatch] CEffect::ExecuteActual";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["CEffect::ExecuteActual"] = signature_search("stellaris.exe", "?? 89 5c ?? 10 ?? 89 6c ?? 18 56 57 ?? 54 ?? 56 ?? 57 ?? 83 ec 20 ?? 8b f2 ?? 8b f9 ?? 63 79 14 ?? 85 ff 0f 8e ?? ?? ?? ?? ?? 33 e4 ?? 8b f4 90"_sig);
		
	


	/*
	[01001...] 89 5c [..100100] 10 [01001...] 89 6c [..100100] 18 56 57 [01000...] 54 [01000...] 56 [01000...] 57 [01001...] 83 ec 30 [01001...] 8b f1
	[01000...] 8b e8 [01001...] 8b e2 [01001...] 8b f9 [01001...] 8b b1 48 0c 00 00 [01001...] 85 f6 74 [........] [01000...] 8d 40 ff 83 f8 01 77
	[........] [01001...] 8b d1 [01001...] 8b ce e8 [........] [........] [........] [........] 84 c0 74 [........] 
	*/
	logger << "[DBG-sigmatch] CEvent::PerformImmediate";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["CEvent::PerformImmediate"] = signature_search("stellaris.exe", "?? 89 5c ?? 10 ?? 89 6c ?? 18 56 57 ?? 54 ?? 56 ?? 57 ?? 83 ec 30 ?? 8b f1 ?? 8b e8 ?? 8b e2 ?? 8b f9 ?? 8b b1 48 0c 00 00 ?? 85 f6 74 ?? ?? 8d 40 ff 83 f8 01 77 ?? ?? 8b d1 ?? 8b ce e8 ?? ?? ?? ?? 84 c0 74 ??"_sig);

	/*
	[01001...] 89 5c [..100100] 10 [01001...] 89 6c [..100100] 18 56 57 [01000...] 54 [01000...] 56 [01000...] 57 [01001...] 83 ec 50 [01000...] 8b e1
	[01001...] 63 f0 [01001...] 8b f2 [01001...] 8b e9 bf 40 01 00 00 65 [01001...] 8b 04 [..100101] 58 00 00 00 [01001...] 03 38 [01001...] 8b 1f [01001...] 89 9c [..100100] 80 00 00 00 [01001...] 89 0f 
	*/
	logger << "[DBG-sigmatch] CEvent::Execute";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["CEvent::Execute"] = signature_search("stellaris.exe", "?? 89 5c ?? 10 ?? 89 6c ?? 18 56 57 ?? 54 ?? 56 ?? 57 ?? 83 ec 50 ?? 8b e1 ?? 63 f0 ?? 8b f2 ?? 8b e9 bf 40 01 00 00 65 ?? 8b 04 ?? 58 00 00 00 ?? 03 38 ?? 8b 1f ?? 89 9c ?? 80 00 00 00 ?? 89 0f"_sig);

	/*
	[01001...] 89 54 [..100100] 10 55 53 56 57 [01000...] 54 [01000...] 55 [01000...] 56 [01000...] 57 [01001...] 81 ec 58 02 00 00 [01001...] 8d 6c
	[..100100] 20 [01001...] 8b f2 [01001...] 8b f1 [01000...] 33 ff [01000...] 8b ef [01000...] 89 bd 80 02 00 00 
	*/
	logger << "[DBG-sigmatch] CRandomInListEffect::ExecuteActual";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["CRandomInListEffect::ExecuteActual"] = signature_search("stellaris.exe", "?? 89 54 ?? 10 55 53 56 57 ?? 54 ?? 55 ?? 56 ?? 57 ?? 81 ec 58 02 00 00 ?? 8d 6c ?? 20 ?? 8b f2 ?? 8b f1 ?? 33 ff ?? 8b ef ?? 89 bd 80 02 00 00"_sig);


	/*
	[01000...] 55 [01000...] 54 [01000...] 56 [01001...] 83 ec 40 80 3d [........] [........] [........] [........] 00 [01000...] 8b e1 
	[01001...] 8b f0 [01001...] 8b ea 0f 84 [........] [........] [........] [........] [01001...] 85 d2 0f 84 [........] [........] [........] [........] [01001...] 
	63 42 54 [01001...] 89 5c [..100100] 60 [01001...] 8b 5a 48 [01001...] 89 7c [..100100] 70 [01001...] 89 7c [..100100] 30 
	*/
	logger << "[DBG-sigmatch] COnActionDatabase::PerformEvent";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["COnActionDatabase::PerformEvent"] = signature_search("stellaris.exe", "?? 55 ?? 54 ?? 56 ?? 83 ec 40 80 3d ?? ?? ?? ?? 00 ?? 8b e1 ?? 8b f0 ?? 8b ea 0f 84 ?? ?? ?? ?? ?? 85 d2 0f 84 ?? ?? ?? ?? ?? 63 42 54 ?? 89 5c ?? 60 ?? 8b 5a 48 ?? 89 7c ?? 70 ?? 89 7c ?? 30"_sig);

	/*
	[01000...] 55 57 [01000...] 54 [01000...] 56 [01000...] 57 [01001...] 81 ec b0 00 00 00 [01001...] 8d 6c [..100100] 20 [01001...] 89 9d c8 00 00 00
	[01001...] 89 b5 d0 00 00 00 [01001...] 8b f2 [01001...] 8b f1 [01000...] 33 ff [01001...] 89 7d 08 0f 57 c0 66 0f 7f 45 10 [01001...] 8b 05
	[........] [........] [........] [........] [01001...] 89 45 20 [01001...] 8d 05 [........] [........] [........] [........] [01001...] 89 45 00
	[01001...] 8d 45 00 [01001...] 89 45 28 [01001...] 8d 45 00 [01001...] 89 45 30 [01001...] 8d 45 00 
	*/
	logger << "[DBG-sigmatch] CEveryInListEffect::ExecuteActual ";
	logger.endl();
	addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform]["CEveryInListEffect::ExecuteActual"] = signature_search("stellaris.exe", "?? 55 57 ?? 54 ?? 56 ?? 57 ?? 81 ec b0 00 00 00 ?? 8d 6c ?? 20 ?? 89 9d c8 00 00 00 ?? 89 b5 d0 00 00 00 ?? 8b f2 ?? 8b f1 ?? 33 ff ?? 89 7d 08 0f 57 c0 66 0f 7f 45 10 ?? 8b 05 ?? ?? ?? ?? ?? 89 45 20 ?? 8d 05 ?? ?? ?? ?? ?? 89 45 00 ?? 8d 45 00 ?? 89 45 28 ?? 8d 45 00 ?? 89 45 30 ?? 8d 45 00 "_sig);


	logger << "[DBG-sigmatch] Done ";
	logger.endl();

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

	addr_map[VERSION_3_7_4][OS_WINDOWS][GOG]["CShip::DailyUpdateRepair"] = 0x140868b40; // 48 89 5c 24 08 48 89 6c 24 18 48 89 74 24 20 57 41 54 41 55 41 56 41 57 48 83 ec 70 48 8b e9 45 32 e4 48 8b 15 cf 11 f2 01 48 85 d2 74 2d 44 8b 89 a8 00 00 00
	addr_map[VERSION_3_7_4][OS_WINDOWS][GOG]["CShip::CalcRegenAmount"] = 0x14087ed30; // unchanged
	addr_map[VERSION_3_7_4][OS_WINDOWS][GOG]["CAlertManager::Update_asm_target_1"] = 0x140b17714; // e8 87 ff be ff 84 c0 74 68 48 8b 45 08 48 8b 14 18 48 8b 52 18 49 8b ce
	addr_map[VERSION_3_7_4][OS_WINDOWS][GOG]["COutlinerGroupArmy::UpdateInternal_asm_target_1"] = 0x140ee2263;

	addr_map[VERSION_3_7_4][OS_WINDOWS][STEAM]["CShip::DailyUpdateRepair"] = 0x14086ada0; // 48 89 5c 24 08 48 89 6c 24 18 48 89 74 24 20 57 41 54 41 55 41 56 41 57 48 83 ec 70 48 8b e9 45 32 e4 48 8b 15 cf 11 f2 01 48 85 d2 74 2d 44 8b 89 a8 00 00 00
	addr_map[VERSION_3_7_4][OS_WINDOWS][STEAM]["CShip::CalcRegenAmount"] = 0x140880f90; // unchanged
	addr_map[VERSION_3_7_4][OS_WINDOWS][STEAM]["CAlertManager::Update_asm_target_1"] = 0x140b1a334; // e8 87 ff be ff 84 c0 74 68 48 8b 45 08 48 8b 14 18 48 8b 52 18 49 8b ce
	addr_map[VERSION_3_7_4][OS_WINDOWS][STEAM]["COutlinerGroupArmy::UpdateInternal_asm_target_1"] = 0x140ee3843; // 41 8b c4 41 0f af c4 8d 3c c5 00 00 00 00 8d 04 3b 03 c0 39 81 a0 03 00 00 0f 8c 18 04 00 00 85 c0 0f 88 10 04 00 00

}

intptr_t find_address_from_symbol(const char * symbol) {

	CLog& logger = *getLogger();

	intptr_t addr = base_offset + addr_map[VERSION_UNKNOWN][global_current_os][global_current_platform][symbol] - (intptr_t) hModule;
	logger << "find_address_from_symbol(" << symbol << ")";
	logger << " address(" << addr << ")";
	logger << " Version(" << global_current_version << ") OS(" << global_current_os << ") platform(" << global_current_platform << ")";
	logger.endl();

	if (addr == base_offset - (intptr_t)hModule) {
		return 0x0;
	}
	return addr;
}

