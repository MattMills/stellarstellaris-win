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


#ifndef DBG_PTR
#define DBG_PTR 0
#endif

#define DLL_NAME "stellarstellaris.dll"

const char* log_filename = "Z:/stellarstellaris.log";


HANDLE hProcess;
HMODULE hModule;
CApplication * p_CApplication;
void * p_CApplication_Base;
CLog logger;


thread_local std::stack<uint64_t> hookJumpAddresses;

void PushAddress(uint64_t addr) //push the address of the jump target
{
	hookJumpAddresses.push(addr);
}

//we absolutely don't wnat this inlined
__declspec(noinline) void PopAddress(uint64_t trampolinePtr)
{
	uint64_t addr = hookJumpAddresses.top();
	hookJumpAddresses.pop();
	memcpy((void*)trampolinePtr, &addr, sizeof(uint64_t));
}


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

void(*cevent_execute_trampoline)(void* ptr1);
__declspec(noinline) void cevent_execute_payload(void* ptr1) {
	logger << "CEvent::Execute - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ";
#endif
	std::string* str_event_id = nullptr;
	str_event_id = (std::string *)(((intptr_t)ptr1) + 0x10);

	logger << "Event ID (" << str_event_id->c_str() << ")";
	logger.endl();

	void(*func_ptr)(void* ptr1);;
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1);

}

void(*ceffect_executeactual_trampoline)(void * ptr1, void* ptr2);
__declspec(noinline) void ceffect_executeactual_payload( void * ptr1, void* ptr2){
	logger << "CEffect::ExecuteActual - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ptr2(" << ptr2 << ") ";
#endif
	
	uint8_t buf[0x20+1]; // CString size
	memset(buf, 0x00, sizeof(buf));
	memcpy(&buf, (void*)(((intptr_t)ptr1) + 0x20), sizeof(buf));
	char charbuf[0x20+1];
	charbuf[0x20] = 0;
	for (uint j = 0; j < 0x10; j++)
		sprintf(&charbuf[2 * j], "%02X", buf[j]);
#if DBG_PTR == 1
	logger << "ptr1 charbuf(" << charbuf << ") - ";
#endif

	void * file_location_desc = nullptr;
	void * id = nullptr;

	char* strptr = nullptr;
	memcpy(&strptr, &buf, 0x8);

	if(strptr != nullptr){
#if DBG_PTR == 1
		logger << "strptr(" << (void*)strptr << ")";
#endif
		logger << " " << strptr;
	}
	
	logger.endl();
	/*memset(&buf, 0x00, sizeof(buf));
	memcpy(&buf, ptr2, 136);
	logger << buf;
	logger.endl();
	*/
	void(*func_ptr)(void* ptr1, void* ptr2);;
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, ptr2);
	
}

void(*crandominlisteffect_executeactual_trampoline)(void* ptr1, void* ptr2);
__declspec(noinline) void crandominlisteffect_executeactual_payload(void* ptr1, void* ptr2) {
	logger << "CRandomInListEffect::ExecuteActual - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ptr2(" << ptr2 << ") ";
#endif
	
	uint8_t buf[0x20 + 1]; // CString size
	memset(buf, 0x00, sizeof(buf));
	memcpy(&buf, (void*)(((intptr_t)ptr1) + 0x20), sizeof(buf));
	char charbuf[0x20 + 1];
	charbuf[0x20] = 0;
	for (uint j = 0; j < 0x10; j++)
		sprintf(&charbuf[2 * j], "%02X", buf[j]);
#if DBG_PTR == 1
	logger << "ptr1 charbuf(" << charbuf << ") - ";
#endif
	
	void* file_location_desc = nullptr;
	void* id = nullptr;

	char* strptr = nullptr;
	memcpy(&strptr, &buf, 0x8);

	if (strptr != nullptr) {
#if DBG_PTR == 1
		logger << "strptr(" << (void*)strptr << ")";
#endif
		logger << " " << strptr;
		
	}
	logger.endl();
	/*memset(&buf, 0x00, sizeof(buf));
	memcpy(&buf, ptr2, 136);
	logger << buf;
	logger.endl();
	*/

	void(*func_ptr)(void* ptr1, void* ptr2);;
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, ptr2);
}

void*  installHook(void* func2hook, void* funcTrampoline, void* funcPayload) {
	SetOtherThreadsSuspended(true);
	DWORD oldProtect;
	bool err = VirtualProtect(func2hook, 1024, PAGE_EXECUTE_READWRITE, &oldProtect);

	//check(err);
	if (err == 0) {
		dword last_err = GetLastError();

		logger << "VirtualProtect(" << func2hook << ") status: " << err << " GetLastError(";
		logger << last_err << ") HRESULT(" << HRESULT_FROM_WIN32(last_err) << ")";
		logger.endl();
	}

	uint8_t stolenBytes[14];
	memcpy(stolenBytes, func2hook, sizeof(stolenBytes));

	//102 is the size of the "pre-payload" instructions that are written below
	//the trampoline will be located after these instructions in memory
	void* hookMemory = AllocatePageNearAddress(func2hook);
	uint32_t trampolineSize = BuildTrampoline(func2hook, (void*)((char*)hookMemory + 102));
	uint8_t* memoryIter = (uint8_t*)hookMemory;
	uint64_t trampolineAddress = (uint64_t)(memoryIter)+102;
	memoryIter += WriteSaveArgumentRegisters(memoryIter);
	memoryIter += WriteMovToRCX(memoryIter, trampolineAddress);
	memoryIter += WriteSubRSP32(memoryIter); //allocate home space for function call
	memoryIter += WriteAbsoluteCall64(memoryIter, &PushAddress);
	memoryIter += WriteAddRSP32(memoryIter);
	memoryIter += WriteRestoreArgumentRegisters(memoryIter);
	memoryIter += WriteAbsoluteJump64(memoryIter, funcPayload);

	//create the relay function
	void* relayFuncMemory = memoryIter + trampolineSize;
	WriteAbsoluteJump64(relayFuncMemory, hookMemory); //write relay func instructions

	//install the hook
	uint8_t jmpInstruction[5] = { 0xE9, 0x0, 0x0, 0x0, 0x0 };
	const int32_t relAddr = int32_t((int64_t)relayFuncMemory - ((int64_t)func2hook + sizeof(jmpInstruction)));
	memcpy(jmpInstruction + 1, &relAddr, 4);
	memcpy(func2hook, jmpInstruction, sizeof(jmpInstruction));

	SetOtherThreadsSuspended(false);

#if DBG_PTR == 1
	logger << "memory: ";
	logger << "func2hook(" << func2hook << ") ";
	logger << "payloadFunc(" << funcPayload << ") ";
	logger << "trampolineFunc(" << funcTrampoline << ") ";
	logger << "stolenBytes(" << sizeof(stolenBytes) << ")";
	logger.endl();
#endif
	return funcTrampoline;
}

void thread_idler_testing() {
	intptr_t base_offset = 0x140000000;
	intptr_t augustus_ptr = (base_offset+(intptr_t)p_CApplication_Base - (intptr_t)hModule);
	
	intptr_t base_augustus_ptr = 0x0;
	intptr_t base_ceffect_executeactual_ptr = 0x0;
	intptr_t base_crandominlisteffect_executeactual_ptr = 0x0;
	intptr_t base_cevent_execute_ptr = 0x0;

	intptr_t base_steam_augustus_ptr = 0x1418f9b90;
	intptr_t base_steam_ceffect_executeactual_ptr = 0x140302b20;
	intptr_t base_steam_crandominlisteffect_executeactual_ptr = 0x140f01d40;
	intptr_t base_steam_cevent_execute_ptr = 0x1402df460;

	intptr_t base_gog_augustus_ptr = 0x1418ed9f0;
	intptr_t base_gog_ceffect_executeactual_ptr = 0x140300eb0;
	intptr_t base_gog_crandominlisteffect_executeactual_ptr = 0x140f00720;
	intptr_t base_gog_cevent_execute_ptr = 0x1402dd7f0;

	if (augustus_ptr == base_steam_augustus_ptr) {
		logger << "Found correct augustus addr for steam 3.4.5";
		logger.endl();
		//TODO: less stupid
		base_augustus_ptr = base_steam_augustus_ptr;
		base_ceffect_executeactual_ptr = base_steam_ceffect_executeactual_ptr;
		base_crandominlisteffect_executeactual_ptr = base_steam_crandominlisteffect_executeactual_ptr;
		base_cevent_execute_ptr = base_steam_cevent_execute_ptr;
	}
	else if (augustus_ptr == base_gog_augustus_ptr) {
		logger << "Found correct augustus addr for gog 3.4.5";
		logger.endl();
		base_augustus_ptr = base_gog_augustus_ptr;
		base_ceffect_executeactual_ptr = base_gog_ceffect_executeactual_ptr;
		base_crandominlisteffect_executeactual_ptr = base_gog_crandominlisteffect_executeactual_ptr;
		base_cevent_execute_ptr = base_gog_cevent_execute_ptr;
	}
	else {
		logger << "FATAL: augustus ptr is incorrect, bailing";
		logger.endl();
		return;
	}

	intptr_t this_ceffect_executeactual_ptr = (intptr_t)p_CApplication_Base + (base_ceffect_executeactual_ptr - base_augustus_ptr);
	intptr_t this_crandominlisteffect_executeactual_ptr = (intptr_t)p_CApplication_Base + (base_crandominlisteffect_executeactual_ptr - base_augustus_ptr);
	intptr_t this_cevent_execute_ptr = (intptr_t)p_CApplication_Base + (base_cevent_execute_ptr - base_augustus_ptr);
		
	ceffect_executeactual_trampoline = (void(*)(void* ptr1, void* ptr2)) installHook((void*) this_ceffect_executeactual_ptr, &ceffect_executeactual_trampoline, ceffect_executeactual_payload);
	crandominlisteffect_executeactual_trampoline = (void(*)(void* ptr1, void* ptr2)) installHook((void*) this_crandominlisteffect_executeactual_ptr, &crandominlisteffect_executeactual_trampoline, crandominlisteffect_executeactual_payload);
	cevent_execute_trampoline = (void(*)(void* ptr1)) installHook((void*)this_cevent_execute_ptr, &cevent_execute_trampoline, cevent_execute_payload);
	
	while (1) {
		logger << "stellarstellaris.dll heartbeat: frame(" << p_CApplication->_nCurrentFrame << ") ";
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
