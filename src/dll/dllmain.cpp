using namespace std;

#define _CRT_SECURE_NO_WARNINGS

#include "stellaris/CApplication.h"
#include "stellaris/CGameIdler.h"
#include "stellaris/CGameApplication.h"


#include "dll/dllmain.h"
#include "git_version.h"


#include <thread>
#include <ctime>
#include <chrono>
#include <cstring>
#include <cassert>

#include <zmq.h>


intptr_t base_augustus_ptr = 0x0;
intptr_t base_steam_augustus_ptr = 0x1418f9b90;
intptr_t base_gog_augustus_ptr = 0x1418ed9f0;

intptr_t base_offset = 0x140000000;

intptr_t augustus_ptr = 0x0;


BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD ul_reason_for_call, LPVOID lpvReserved) {
	if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
		CLog& logger = *getLogger();

		logger << "StellarStellaris initialization git hash - " << kGitHash;
		logger.endl();

		logger << "DLL_PROCESS_ATTACH" << std::endl;
		logger.endl();
		

		hProcess = OpenProcess(PROCESS_ALL_ACCESS, FALSE, GetCurrentProcessId());
		hModule = GetBaseModuleForProcess(hProcess);

		logger << "Base module: " << hModule << std::endl;
		logger.endl();
		
	}
	return true;
}
void thread_idler_testing() {
	CLog& logger = *getLogger();
	augustus_ptr = (base_offset+(intptr_t)p_CApplication_Base - (intptr_t)hModule);
	
	if (augustus_ptr == base_steam_augustus_ptr) {
		logger << "Found correct augustus addr for steam 3.4.5";
		logger.endl();

		//TODO: less stupid
		base_augustus_ptr = base_steam_augustus_ptr;
		thisPlatform = STEAM;
	}
	else if (augustus_ptr == base_gog_augustus_ptr) {
		logger << "Found correct augustus addr for gog 3.4.5";
		logger.endl();
		base_augustus_ptr = base_gog_augustus_ptr;
		thisPlatform = GOG;
	}
	else {
		logger << "FATAL: augustus ptr is incorrect, bailing";
		logger.endl();
		thisPlatform = NULL_ERR;
		return;
	}

	//Try to delay so we don't deadlock all the threads...
	std::this_thread::sleep_for(std::chrono::milliseconds(3000));

	//TODO: This is stupidly slow (4+ sec)
	logger << "Pausing threads for hook init";
	logger.endl();
	SetOtherThreadsSuspended(true);

	ceffect_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	cevent_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	crandominlisteffect_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	conactiondatabase_hook_init(thisPlatform, (intptr_t)p_CApplication_Base, base_augustus_ptr);
	ceveryinlisteffect_hook_init(thisPlatform, (intptr_t)p_CApplication_Base, base_augustus_ptr);
	cship_hook_init(thisPlatform, (intptr_t)p_CApplication_Base, base_augustus_ptr);
	logger << "Hook init complete, unpausing threads";
	SetOtherThreadsSuspended(false);
	std::this_thread::sleep_for(std::chrono::milliseconds(100));
	SetOtherThreadsSuspended(false);
	std::this_thread::sleep_for(std::chrono::milliseconds(100));
	SetOtherThreadsSuspended(false);
	
	logger.endl();

	while (1) {
		logger << PAYLOAD_DLL_NAME << " heartbeat: frame(" << p_CApplication->_nCurrentFrame << ") ";
#if DBG_PTR == 1
		logger << "pIdler(" << static_cast<qword>(p_CApplication->_pIdler) << ") ";
#endif
		if (p_CApplication->_pIdler != NULL) {
			CGameIdler* p_CGameIdler = (CGameIdler *) p_CApplication->_pIdler;
			
			logger << " IdlerType(" << (int) p_CGameIdler->_eType;
			if (p_CGameIdler->_eType == IdlerType::_IDLERTYPE_FRONTEND_) {
				logger << " FRONTEND )";
			}
			else if (p_CGameIdler->_eType == IdlerType::_IDLERTYPE_INGAME_) {
				logger << " INGAME )";
			}
			else {
				logger << ") ";
			}

		}
		
		logger.endl();

		Sleep(1000);
	}
	
	logger.close();
	return;
}



extern "C" _declspec(dllexport) void PushCApplicationPtr(void** ptr, void** ptr_Base) {
	

	p_CApplication = static_cast<CApplication*>(*ptr);
	memcpy(&p_CApplication_Base, (ptr) + 1, sizeof(void*));

	std::thread init_thread(thread_idler_testing);
	init_thread.detach();

	return;
}


