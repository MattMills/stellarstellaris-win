#include "dll/hooking_common.h"

const char* log_filename = "\\Documents\\Paradox Interactive\\Stellaris\\logs\\stellarstellaris-debug.log";
const char* env_profile = NULL;
char* new_filename = NULL;

thread_local std::stack<uint64_t> hookJumpAddresses;
CLog* ptr_logger = NULL;
CLog logger;

CLog* getLogger() {
	if (ptr_logger == NULL) {
		env_profile = std::getenv("USERPROFILE");
		const int64_t file_length = strlen(log_filename) + strlen(env_profile);

		new_filename = (char *) malloc(sizeof(uchar)*file_length+1);

		strcpy(new_filename, env_profile);
		strcat(new_filename, log_filename);
		new_filename[file_length] = 0x0;

		ptr_logger = new CLog(new_filename);
		CLog& logger = *ptr_logger;
	}
	return ptr_logger;
}

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


void* installHook(void* func2hook, void* funcTrampoline, void* funcPayload) {
	//SetOtherThreadsSuspended(true);
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

	//SetOtherThreadsSuspended(false);

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
