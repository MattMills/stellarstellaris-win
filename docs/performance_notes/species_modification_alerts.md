# Species Modification Alerts
NSpeciesModification::CanCreateTemplateFrom	within CAlertManager::Update is causing large frame lag spikes in paused test game, xeno compatibility on.

NOP'ing out the relevant function call in CAlertManager::Update completely eliminates the lag spike



(As a percentage of CInGameIdler::UpdateInternal time)
CAlertManager::Update	23.71s	53.52%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\alertmanager.cpp	424	0x7ff62f69b955
CGraphicalMap::UpdateShips	9.79s	22.10%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\graphicalmap.cpp	1147	0x7ff62f5bb93a
CMainGui::PostCameraUpdate	6.35s	14.33%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\maingui.cpp	985	0x7ff62f75c962
COutliner::InternalUpdate	1.12s	2.52%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\outliner.cpp	1430	0x7ff62f8a5937
CInGameIdler::UpdateCursor	1.02s	2.30%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\ingameidler.cpp	2861	0x7ff62f1e498b
CGraphicalMap::Update	0.85s	1.92%	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\graphicalmap.cpp	555	0x7ff62f5b8f80


# Stack

NListSpecies::PlanetContainsSpeciesWithIdentity<SBaseSpeciesComp>	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\list_species.cpp	261	0x7ff62f2f63b9
NSpeciesModification::CanCreateTemplateFrom	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\species_modification.cpp	172	0x7ff62f2c17be
CAlertManager::Update	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\graphics\alertmanager.cpp	915	0x7ff62f69d038
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
