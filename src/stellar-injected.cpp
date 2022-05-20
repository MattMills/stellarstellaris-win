using namespace std;

#define _CRT_SECURE_NO_WARNINGS

#include "stellaris-CApplication.h"
#include "stellaris-CGameIdler.h"
#include "stellaris-CGameApplication.h"
#include "stellar-injected.h"

#include <fstream>
#include <iostream>
#include <thread>
#include <ctime>
#include <cstring>
#include <cassert>
#include <iostream>


#define DLL_NAME "stellarstellaris.dll"

CApplication * p_CApplication;

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD ul_reason_for_call, LPVOID lpvReserved) {
	if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
		
	}
	return true;
}

//https://stackoverflow.com/questions/10905892/equivalent-of-gettimeday-for-windows
// MSVC defines this in winsock2.h!?
typedef struct local_timeval {
	time_t tv_sec;
	time_t tv_usec;
} local_timeval;

int gettimeofday(struct local_timeval* tp, struct timezone* tzp) {
	// Note: some broken versions only have 8 trailing zero's, the correct epoch has 9 trailing zero's
	// This magic number is the number of 100 nanosecond intervals since January 1, 1601 (UTC)
	// until 00:00:00 January 1, 1970 
	static const uint64_t EPOCH = ((uint64_t)116444736000000000ULL);

	SYSTEMTIME  system_time;
	FILETIME    file_time;
	uint64_t    time;

	GetSystemTime(&system_time);
	SystemTimeToFileTime(&system_time, &file_time);
	time = ((uint64_t)file_time.dwLowDateTime);
	time += ((uint64_t)file_time.dwHighDateTime) << 32;

	tp->tv_sec = (time_t)((time - EPOCH) / 10000000L);
	tp->tv_usec = (time_t)(system_time.wMilliseconds * 1000);
	return 0;
}

void thread_idler_testing() {
	ofstream fh;

	
	while (1) {
		char time_buffer[26];
		int ms;

		struct local_timeval tv;
		gettimeofday(&tv, NULL);

		struct tm* timeinfo = std::localtime(&tv.tv_sec);

		//https://stackoverflow.com/questions/3673226/how-to-print-time-in-format-2009-08-10-181754-811
		ms = lrint(tv.tv_usec / 1000.0); // Round to nearest millisec
		if (ms >= 1000) { // Allow for rounding up to nearest second
			ms -= 1000;
			tv.tv_sec++;
		}
		std::strftime(time_buffer, sizeof(time_buffer), "%Y-%m-%dT%H:%M:%S", timeinfo);
		char time_buffer_with_ms[30];
		std::sprintf(time_buffer_with_ms, "%s.%03d", time_buffer, ms);
		fh.open("Z:/output.txt", std::ios_base::app);

		fh << "[" << time_buffer_with_ms << "] (" << GetCurrentProcessId() << ") ";
		fh << "stellarstellaris.dll heartbeat: frame(" << p_CApplication->_nCurrentFrame << ") pIdler(" << static_cast<qword>(p_CApplication->_pIdler) << ")";
		if (p_CApplication->_pIdler != NULL) {
			CGameIdler* p_CGameIdler = (CGameIdler *) p_CApplication->_pIdler;
			
			fh << " IdlerType(" << (int) p_CGameIdler->_eType;
			if (p_CGameIdler->_eType == IdlerType::_IDLERTYPE_FRONTEND_) {
				fh << " FRONTEND )";
			}
			else if (p_CGameIdler->_eType == IdlerType::_IDLERTYPE_INGAME_) {
				fh << " INGAME )";
			}
			else {
				fh << ") ";
			}

			
			
			//CConsole* p_Console = p_CGameIdler->_pConsole;
			
			
		}
		fh << std::endl;
		fh.close();
		Sleep(1000);
	}
	
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
