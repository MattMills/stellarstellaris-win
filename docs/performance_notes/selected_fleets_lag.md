# Selected Fleets lag

In late game modded games with a significant quantity of fleets, a substantial lag is apparent when multiple fleets are selected. The game can easily drop below 1 FPS.

This has multiple causes.

## Full fleets - no reinforcements

caused by:
```
CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>	32.41s	99.57%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\economics\economic_unit.h	708	0x7ff62ef84fd7
```

children:
```
CEconomicUnitBase<CStandardEconomicUnit<CArmyType,CArmy,CEconomicUnitScopeRef<CArmy,void> >,CEconomicUnitScope<CArmy,void> >::ApplyEconomicPerResourceMultModifiers<2,0>	20.61s	63.82%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\economics\economic_unit.h	587	0x7ff62ee5b017
CEconomicUnitBase<CStandardEconomicUnit<CArmyType,CArmy,CEconomicUnitScopeRef<CArmy,void> >,CEconomicUnitScope<CArmy,void> >::ApplyEconomicGlobalMultModifiers<2,0>	7.35s	22.76%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\economics\economic_unit.h	506	0x7ff62ee5a955
CEconomicCategory::EvalTriggeredPerResourceModifier	3.41s	10.55%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\economics\economic_category.h	300	0x7ff62edc2db0
CEconomicUnitBase<CStandardEconomicUnit<CComponentTemplate,CShipDesign,CEconomicUnitScopeRef<CShipDesign,void> >,CEconomicUnitScope<CShipDesign,void> >::AddGlobalMultModifierToTable<0>	0.93s	2.87%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\economics\economic_unit.h	890	0x7ff62edc2c3f
```

stack:

```
CEconomicCategory::EvalTriggeredPerResourceModifier	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\economics\economic_category.h	303	0x7ff62edc2e25
CEconomicUnitBase<CStandardEconomicUnit<CArmyType,CArmy,CEconomicUnitScopeRef<CArmy,void> >,CEconomicUnitScope<CArmy,void> >::ApplyEconomicPerResourceMultModifiers<2,0>	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\economics\economic_unit.h	605	0x7ff62ee5b0bd
CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\economics\economic_unit.h	718	0x7ff62ef850e6
CCountry::GetLatestShipDesign	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\country.cpp	10061	0x7ff62ef38b38
CShip::CalcLatestDesign	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\spatial_objects\ship.cpp	3661	0x7ff62f423885
CBuildableShipUpgrade::CanAnyBeUpgraded	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\construction_system\ship_buildables.cpp	1541	0x7ff62f2fd4af
CFleetActionUpgradeButton::IsValid	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_action_buttons.cpp	526	0x7ff62fa8d288
CFleetViewActionButton::OnUpdate	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_view_buttons.cpp	271	0x7ff62fa8a9f2
CFleetViewEntry::OnUpdate	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_view.cpp	1669	0x7ff62f865ebb
CFixedMaxSizeListbox<CStandardlistboxItem>::Update	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\pdx_oldgui\graphics\fixedsizelistbox.h	136	0x7ff62ffc253b
CFleetView::Update	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_view.cpp	2737	0x7ff62f86c23d
CInGameIdler::UpdateInternal	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\ingameidler.cpp	3260	0x7ff62f1e62cb
CGameIdler::Idle	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\gameidler.cpp	502	0x7ff62edd56f0
CApplication::UpdateOneFrame	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\clausewitzlib\application.cpp	521	0x7ff62fdf051b
CApplication::Run	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\clausewitzlib\application.cpp	783	0x7ff62fdf0b08
RunGame	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\main.cpp	1593	0x7ff62ecc29ea
SDL_main	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\pdx_main\main.cpp	80	0x7ff62ecbdbf5
WinMain	stellaris	[unknown]	0	0x7ff6303f0492
__scrt_common_main_seh	stellaris	d:\a01\_work\2\s\src\vctools\crt\vcstartup\src\startup\exe_common.inl	288	0x7ff6303b3886
BaseThreadInitThunk	KERNEL32	[unknown]	0	0x7ffbfb0b7034
RtlUserThreadStart	ntdll	[unknown]	0	0x7ffbfbc626a1
```

## Partial fleets - many reinforcements
This is even worse, two fleets selected, 498/1996 and 604/1996 fleet power drop FPS to < 1 FPS.

Both IsValid and CanClick are called.
```
CFleetActionReinforceButton::IsValid	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_action_buttons.cpp	757	0x7ff62fa8e991
CFleetActionReinforceButton::CanClick	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_action_buttons.cpp	789	0x7ff62fa8ed09
```

CFleet::CountShipsWithShipSize is consuming 77.5% exclusive
```
CFleet::CountShipsWithShipSize	46.91s	99.79%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\spatial_objects\fleet.cpp	5185	0x7ff62f447a30
CalcShipsUnderConstructionOfSize	0.10s	0.21%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\country_fleets_manager.cpp	929	0x7ff62f1c0a25
```

CFleetManager::CalcShipsToReinforceInternal is 98.1% inclusive
```
`anonymous namespace'::CanBuildShipInternal	49.05s	82.83%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\construction_system\ship_buildables.cpp	88	0x7ff62f2f6bed
CBuildableShipBase<CBuildableGalacticCommunityShipReinforcement>::CalcCost	9.53s	16.10%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\construction_system\ship_buildables.cpp	537	0x7ff62f2ff001
CFleetTemplateManager::CalcBuildLocations	0.38s	0.63%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\spatial_objects\fleet_template_manager.cpp	600	0x7ff62f52b56c
CBuildableShipBase<CBuildableColonyShip>::CalcProgressionSpeed	0.16s	0.27%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\construction_system\ship_buildables.cpp	546	0x7ff62f2ff0e0
CBuildableUpgradeBuilding::`scalar deleting destructor'	0.07s	0.12%	stellaris	[unknown]	0	0x7ff62ed0c162
operator new	0.02s	0.03%	stellaris	d:\a01\_work\2\s\src\vctools\crt\vcstartup\src\heap\new_scalar.cpp	35	0x7ff6303b392f
CBuildableShipBase<CBuildableFederationShipReinforcement>::CalcProgressionTimeNeeded	0.01s	0.01%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\construction_system\ship_buildables.cpp	574	0x7ff62f2fc580
CPdxArray<SFleetReinforcement,int>::InsertAtEmplace<CShipDesign const * &,CConstructionQueue const * &>	0.00s	0.01%	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\pdx_core\pdxarray.h	559	0x7ff62f52c66d
CBuildableShipReinforcement::CanBuild	0.00s	0.00%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\construction_system\ship_buildables.cpp	677	0x7ff62f2fa230
CFleetTemplateManager::CalcWantedShipsToReinforce	0.00s	0.00%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\spatial_objects\fleet_template_manager.cpp	574	0x7ff62f52b07d
```


Example stack
```
CFleet::CountShipsWithShipSize	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\spatial_objects\fleet.cpp	5189	0x7ff62f447ab2
CCountryFleetsManager::CalcTotalShipsOfSize	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\country_fleets_manager.cpp	1016	0x7ff62f1c100a
`anonymous namespace'::CanBuildShipInternal	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\construction_system\ship_buildables.cpp	88	0x7ff62f2f6d77
CFleetTemplateManager::CalcShipsToReinforceInternal	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\spatial_objects\fleet_template_manager.cpp	326	0x7ff62f529913
CReinforceFleetCommand::IsValid	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\commands_ship.cpp	4100	0x7ff62f2e5107
CFleetActionReinforceButton::IsValid	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_action_buttons.cpp	757	0x7ff62fa8e991
CFleetViewActionButton::OnUpdate	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_view_buttons.cpp	271	0x7ff62fa8a9f2
CFleetViewEntry::OnUpdate	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_view.cpp	1669	0x7ff62f865ebb
CFixedMaxSizeListbox<CStandardlistboxItem>::Update	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\pdx_oldgui\graphics\fixedsizelistbox.h	136	0x7ff62ffc253b
CFleetView::Update	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\fleet_view.cpp	2737	0x7ff62f86c23d
CInGameIdler::UpdateInternal	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\ingameidler.cpp	3260	0x7ff62f1e62cb
CGameIdler::Idle	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\gameidler.cpp	502	0x7ff62edd56f0
CApplication::UpdateOneFrame	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\clausewitzlib\application.cpp	521	0x7ff62fdf051b
CApplication::Run	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\clausewitzlib\application.cpp	783	0x7ff62fdf0b08
RunGame	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\main.cpp	1593	0x7ff62ecc29ea
SDL_main	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\pdx_main\main.cpp	80	0x7ff62ecbdbf5
WinMain	stellaris	[unknown]	0	0x7ff6303f0492
__scrt_common_main_seh	stellaris	d:\a01\_work\2\s\src\vctools\crt\vcstartup\src\startup\exe_common.inl	288	0x7ff6303b3886
BaseThreadInitThunk	KERNEL32	[unknown]	0	0x7ffbfb0b7034
RtlUserThreadStart	ntdll	[unknown]	0	0x7ffbfbc626a1
```