using namespace std;

#define _CRT_SECURE_NO_WARNINGS

#include "stellaris-CApplication.h"
#include "stellaris-CGameIdler.h"
#include "stellaris-CGameApplication.h"
#include "stellar-injected.h"
#include "logging.h"



#include <thread>
#include <ctime>
#include <cstring>
#include <cassert>


#include <zmq.h>


#define DLL_NAME "stellarstellaris.dll"

const char* log_filename = "Z:/stellarstellaris.log";


CApplication * p_CApplication;
CLog logger;


BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD ul_reason_for_call, LPVOID lpvReserved) {
	if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
		logger = CLog(log_filename);
		logger << "DLL_PROCESS_ATTACH";
		logger.endl();
		
	}
	return true;
}


void thread_idler_testing() {
	while (1) {
		logger << "stellarstellaris.dll heartbeat: frame(" << p_CApplication->_nCurrentFrame << ") pIdler(" << static_cast<qword>(p_CApplication->_pIdler) << ")";
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


extern "C" _declspec(dllexport) void PushCApplicationPtr(void** ptr) {
	p_CApplication = (CApplication *) malloc(sizeof(void*));
	p_CApplication = static_cast<CApplication *>(*ptr);

	std::thread init_thread(thread_idler_testing);
	init_thread.detach();

	return;
}




int lua_testing() {
	lua_State* L = luaL_newstate();
	std::string cmd = "print('[LUA] hello world!')";

	int r = luaL_dostring(L, cmd.c_str());
	if (r == LUA_OK) {
		lua_getglobal(L, "a");
		if (lua_isnumber(L, -1)) {
			float a_in_cpp = (float)lua_tonumber(L, -1);

			std::cout << "a = " << a_in_cpp << std::endl;
		}
	}
	else {
		std::string errormsg = lua_tostring(L, -1);
		std::cout << errormsg << std::endl;
	}
	cout << "Hello CMake." << endl;

	lua_close(L);
	return 0;
}
