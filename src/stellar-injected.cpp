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


HANDLE hProcess;
HMODULE hModule;
CApplication * p_CApplication;
void * p_CApplication_Base;
CLog logger;


BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD ul_reason_for_call, LPVOID lpvReserved) {
	if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
		logger = CLog(log_filename);
		logger << "DLL_PROCESS_ATTACH" << std::endl;
		logger.endl();
		

		hProcess = OpenProcess(PROCESS_ALL_ACCESS, FALSE, GetCurrentProcessId());
		hModule = GetBaseModuleForProcess(hProcess);

		logger << "Base module: " << hModule << std::endl;
		logger.endl();
		
	}
	return true;
}

void(*crandominlisteffect_executeactual_trampoline)(void* ptr1, void* ptr2);
void(*ceffect_executeactual_trampoline)(void * ptr1, void* ptr2);

__declspec(noinline) void ceffect_executeactual_payload( void * ptr1, void* ptr2){
	logger << "CEffect::ExecuteActual ptr1(" << ptr1 << " ) ptr2 (" << ptr2 << ")";
	logger.endl();

	uint8_t buf[0x20+1]; // CString size
	memset(buf, 0x00, sizeof(buf));
	memcpy(&buf, (void*)(((intptr_t)ptr1) + 0x20), sizeof(buf));
	char charbuf[0x20+1];
	charbuf[0x20] = 0;
	for (uint j = 0; j < 0x10; j++)
		sprintf(&charbuf[2 * j], "%02X", buf[j]);
	
	logger << "ptr1 charbuf(" << charbuf << ")";
	logger.endl();

	void * file_location_desc = nullptr;
	void * id = nullptr;

	char* strptr = nullptr;
	memcpy(&strptr, &buf, 0x8);

	if(strptr != nullptr){
		logger << (void *) strptr;
		logger << " " << strptr;
		logger.endl();
	}
	
	/*memset(&buf, 0x00, sizeof(buf));
	memcpy(&buf, ptr2, 136);
	logger << buf;
	logger.endl();
	*/

	ceffect_executeactual_trampoline(ptr1, ptr2);
}

__declspec(noinline) void crandominlisteffect_executeactual_payload(void* ptr1, void* ptr2) {
	logger << "CRandomInListEffect::ExecuteActual ptr1(" << ptr1 << " ) ptr2 (" << ptr2 << ")";
	logger.endl();

	uint8_t buf[0x20 + 1]; // CString size
	memset(buf, 0x00, sizeof(buf));
	memcpy(&buf, (void*)(((intptr_t)ptr1) + 0x20), sizeof(buf));
	char charbuf[0x20 + 1];
	charbuf[0x20] = 0;
	for (uint j = 0; j < 0x10; j++)
		sprintf(&charbuf[2 * j], "%02X", buf[j]);

	logger << "ptr1 charbuf(" << charbuf << ")";
	logger.endl();

	void* file_location_desc = nullptr;
	void* id = nullptr;

	char* strptr = nullptr;
	memcpy(&strptr, &buf, 0x8);

	if (strptr != nullptr) {
		logger << (void*)strptr;
		logger << " " << strptr;
		logger.endl();
	}

	/*memset(&buf, 0x00, sizeof(buf));
	memcpy(&buf, ptr2, 136);
	logger << buf;
	logger.endl();
	*/

	crandominlisteffect_executeactual_trampoline(ptr1, ptr2);
}


void WriteTrampoline(void* dst, void* payloadFuncAddr, void* func2hook, uint8_t* stolenBytes, uint32_t numStolenBytes)
{

	//the trampoline consists of the stolen bytes from the target function, following by a jump back
	//to the target function + 5 bytes, in order to continue the execution of that function. This continues like
	//a normal function call
	void* trampolineJumpTarget = ((uint8_t*)func2hook + numStolenBytes);

	uint8_t* dstIter = (uint8_t*)dst;
	memcpy(dstIter, stolenBytes, numStolenBytes);
	dstIter += numStolenBytes;
	dstIter += WriteAbsoluteJump64(dstIter, trampolineJumpTarget);
}


void*  installHook(void* func2hook, void* funcTrampoline, void* funcPayload) {
	DWORD oldProtect;
	bool err = VirtualProtect(func2hook, 1024, PAGE_EXECUTE_READWRITE, &oldProtect);
	logger << "VirtualProtect(" << func2hook << ") status: " << err;
	logger.endl();

	//check(err);
	if (err == 0) {
		dword last_err = GetLastError();
		logger << last_err << " " << HRESULT_FROM_WIN32(last_err);
		logger.endl();
	}

	uint8_t stolenBytes[14];
	memcpy(stolenBytes, func2hook, sizeof(stolenBytes));

	void* trampolineMemory = AllocatePageNearAddress(func2hook);
	logger << "trampoline addr: " << trampolineMemory;
	logger.endl();

	funcTrampoline = (void(*)(void* ptr1, void* ptr2))trampolineMemory;
	WriteTrampoline(trampolineMemory, funcPayload, func2hook, stolenBytes, sizeof(stolenBytes));

	logger << "memory: ";
	logger << "func2hook(" << func2hook << ") ";
	logger << "payloadFunc(" << funcPayload << ") ";
	logger << "trampolineFunc(" << funcTrampoline << ") ";
	logger << "stolenBytes(" << sizeof(stolenBytes) << ")";
	logger.endl();

	WriteAbsoluteJump64(func2hook, funcPayload);

	return funcTrampoline;
}

void thread_idler_testing() {
	intptr_t base_offset = 0x140000000;
	intptr_t augustus_ptr = (base_offset+(intptr_t)p_CApplication_Base - (intptr_t)hModule);
	
	intptr_t base_augustus_ptr = 0x0;
	intptr_t base_ceffect_executeactual_ptr = 0x0;
	intptr_t base_crandominlisteffect_executeactual_ptr = 0x0;

	intptr_t base_steam_augustus_ptr = 0x1418f9b90;
	intptr_t base_steam_ceffect_executeactual_ptr = 0x140302b20;
	intptr_t base_steam_crandominlisteffect_executeactual_ptr = 0x140f01d40;

	intptr_t base_gog_augustus_ptr = 0x1418ed9f0;
	intptr_t base_gog_ceffect_executeactual_ptr = 0x140300eb0;
	intptr_t base_gog_crandominlisteffect_executeactual_ptr = 0x140f00720;

	if (augustus_ptr == base_steam_augustus_ptr) {
		logger << "Found correct augustus addr for steam 3.4.5";
		logger.endl();
		//TODO: less stupid
		base_augustus_ptr = base_steam_augustus_ptr;
		base_ceffect_executeactual_ptr = base_steam_ceffect_executeactual_ptr;
		base_crandominlisteffect_executeactual_ptr = base_steam_crandominlisteffect_executeactual_ptr;
	}
	else if (augustus_ptr == base_gog_augustus_ptr) {
		logger << "Found correct augustus addr for gog 3.4.5";
		logger.endl();
		base_augustus_ptr = base_gog_augustus_ptr;
		base_ceffect_executeactual_ptr = base_gog_ceffect_executeactual_ptr;
		base_crandominlisteffect_executeactual_ptr = base_gog_crandominlisteffect_executeactual_ptr;
	}
	else {
		logger << "FATAL: augustus ptr is incorrect, bailing";
		logger.endl();
		return;
	}

	intptr_t this_ceffect_executeactual_ptr = (intptr_t)p_CApplication_Base + (base_ceffect_executeactual_ptr - base_augustus_ptr);
	intptr_t this_crandominlisteffect_executeactual_ptr = (intptr_t)p_CApplication_Base + (base_crandominlisteffect_executeactual_ptr - base_augustus_ptr);
	logger << "CEffect::ExecuteActual ptr: " << (void *) this_ceffect_executeactual_ptr;
	logger.endl();

	logger << "CRandomInListEffect::ExecuteActual ptr: " << (void*)this_crandominlisteffect_executeactual_ptr;
	logger.endl();
		
	ceffect_executeactual_trampoline = (void(*)(void* ptr1, void* ptr2)) installHook((void*) this_ceffect_executeactual_ptr, &ceffect_executeactual_trampoline, ceffect_executeactual_payload);
	crandominlisteffect_executeactual_trampoline = (void(*)(void* ptr1, void* ptr2)) installHook((void*) this_crandominlisteffect_executeactual_ptr, &crandominlisteffect_executeactual_trampoline, crandominlisteffect_executeactual_payload);
		
	/*
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
		logger << std::endl;
		logger.endl();

		Sleep(1000);
	}
	*/
	//logger.close();
	return;
}



extern "C" _declspec(dllexport) void PushCApplicationPtr(void** ptr, void** ptr_Base) {
	p_CApplication = static_cast<CApplication*>(*ptr);
	memcpy(&p_CApplication_Base, (ptr) + 1, sizeof(void*));

	thread_idler_testing();
	//std::thread init_thread(thread_idler_testing);
	//init_thread.detach();

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
