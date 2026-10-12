//using namespace std;

#define _CRT_SECURE_NO_WARNINGS

#include "stellaris/CApplication.h"
#include "stellaris/CGameIdler.h"
#include "stellaris/CGameApplication.h"


#include "dll/dllmain.h"
#include "dll/lua_runtime.h"
#include "git_version.h"


#include <thread>
#include <ctime>
#include <chrono>
#include <cstring>
#include <cassert>

#include <zmq.h>



//intptr_t base_steam_augustus_ptr = 0x1418f9b90; // 3.4.5
//intptr_t base_gog_augustus_ptr = 0x1418ed9f0; // 3.4.5

//intptr_t base_steam_augustus_ptr = 0x14197d9d8; // 3.5.2
//intptr_t base_gog_augustus_ptr = 0x141971838; // 3.5.2

//intptr_t base_steam_augustus_ptr = 0x1419f0d20; // 3.6.1
//intptr_t base_gog_augustus_ptr = 0x1419e4b60; // 3.6.1

intptr_t base_steam_augustus_ptr = 0x141a58218; // 3.7.4
intptr_t base_gog_augustus_ptr = 0x141a4c058; // 3.7.4



intptr_t augustus_ptr = 0x0;

// Reads memory that may not be mapped.
template <class T>
bool checked_read(const void* address, T* out) {
	SIZE_T read = 0;
	return ReadProcessMemory(GetCurrentProcess(), address, out, sizeof(T), &read) && read == sizeof(T);
}


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
	
	
	logger << "Found augustus ptr at " << augustus_ptr;
	logger.endl();
	logger << "IN MULTI_VERSION SIGMATCH MODE!";
	logger.endl();

	//TODO: less stupid
	//TODO: assuming platform as steam because we dont have a way to identify it right now and I don't think it matters in sigmatch...
	base_augustus_ptr = augustus_ptr;
	thisPlatform = STEAM;
	global_current_platform = STEAM;
	global_current_version = VERSION_UNKNOWN;
	global_current_os = OS_WINDOWS;
	

	//Try to delay so we don't deadlock all the threads...
	std::this_thread::sleep_for(std::chrono::milliseconds(3000));

	//TODO: This is stupidly slow (4+ sec)
	logger << "Pausing threads for hook init";
	logger.endl();
	SetOtherThreadsSuspended(true);
	init_address_map();

	// Logging Hooks:
	//ceffect_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	//cevent_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	//crandominlisteffect_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	//conactiondatabase_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	//ceveryinlisteffect_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	
	 
	//Extremely verbose logging Hooks:
	//ctrigger_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	//ctoken_hook_init(thisPlatform, (intptr_t)p_CApplication_Base, base_augustus_ptr);

	// Fixes things hooks:
	//limit_once_in_x_seconds_hook_init(thisPlatform, (intptr_t) p_CApplication_Base, base_augustus_ptr);
	cship_hook_init(thisPlatform, (intptr_t)p_CApplication_Base, base_augustus_ptr);
	//assembly_patches_init(thisPlatform, (intptr_t)p_CApplication_Base, base_augustus_ptr);

	logger << "Hook init complete, unpausing threads";
	SetOtherThreadsSuspended(false);
	std::this_thread::sleep_for(std::chrono::milliseconds(100));
	SetOtherThreadsSuspended(false);
	std::this_thread::sleep_for(std::chrono::milliseconds(100));
	SetOtherThreadsSuspended(false);
	
	logger.endl();

	// Lua scripts (lua/init.lua next to this DLL), after the C++ hooks
	stellar_lua_start();

	while (1) {
		// The CApplication / CGameIdler layouts (include/stellaris, from 3.7.4) do not match current
		// versions, so these fields are read with checked reads: a wrong offset gives a wrong value,
		// not a crash.
		uint64_t frame = 0;
		checked_read(&p_CApplication->_nCurrentFrame, &frame);
		logger << PAYLOAD_DLL_NAME << " heartbeat: frame(" << frame << ") ";
		qword idler = 0;
		checked_read(&p_CApplication->_pIdler, &idler);
#if DBG_PTR == 1
		logger << "pIdler(" << idler << ") ";
#endif
		if (idler != NULL) {
			CGameIdler* p_CGameIdler = (CGameIdler *) idler;
			decltype(p_CGameIdler->_eType) type;
			if (checked_read(&p_CGameIdler->_eType, &type)) {
				logger << " IdlerType(" << (int) type;
				if (type == IdlerType::_IDLERTYPE_FRONTEND_) {
					logger << " FRONTEND )";
				}
				else if (type == IdlerType::_IDLERTYPE_INGAME_) {
					logger << " INGAME )";
				}
				else {
					logger << ") ";
				}
			}
			else {
				logger << " IdlerType(unreadable) ";
			}
		}

		logger.endl();

		stellar_lua_heartbeat(frame);

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


