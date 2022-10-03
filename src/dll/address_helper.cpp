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
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["COutlinerGroupArmy::UpdateInternal_mid_asm"] = 0x140e280c6;
	addr_map[VERSION_3_5_2][OS_WINDOWS][STEAM]["CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>"] = 0x140366cf0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CCountry::GetLatestShipDesign"] = 0x14031a3f0;

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
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["COutlinerGroupArmy::UpdateInternal_mid_asm"] = 0x140e26ad6;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>"] = 0x140364FB0;
	addr_map[VERSION_3_5_2][OS_WINDOWS][GOG]["CCountry::GetLatestShipDesign"] = 0x140318690;
}

intptr_t find_address_from_symbol(const char * symbol) {
	CLog& logger = *getLogger();
	logger << "find_address_from_symbol(" << symbol << ")";
	logger << " address(" << addr_map[global_current_version][global_current_os][global_current_platform][symbol] << ")";
	logger << " Version(" << global_current_version << ") OS(" << global_current_os << ") platform(" << global_current_platform << ")";
	logger.endl();

	return addr_map[global_current_version][global_current_os][global_current_platform][symbol];
}

