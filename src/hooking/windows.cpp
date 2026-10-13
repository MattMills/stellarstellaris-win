
//using namespace std;

#define WIN32_LEAN_AND_MEAN   
#include "hooking/windows.h"



//Contents from here down borrowed from https://github.com/khalladay/hooking-by-example/blob/master/hooking-by-example/hooking_common.h as it is all useful




void* AllocatePageNearAddressRemote(HANDLE handle, void* targetAddr) {
	check(IsProcess64Bit(handle));

	SYSTEM_INFO sysInfo;
	GetSystemInfo(&sysInfo);
	const uint64_t PAGE_SIZE = sysInfo.dwPageSize;

	uint64_t startAddr = (uint64_t(targetAddr) & ~(PAGE_SIZE - 1)); //round down to nearest page boundary
	uint64_t minAddr = min(startAddr - 0x7FFFFF00, (uint64_t)sysInfo.lpMinimumApplicationAddress);
	uint64_t maxAddr = max(startAddr + 0x7FFFFF00, (uint64_t)sysInfo.lpMaximumApplicationAddress);

	uint64_t startPage = (startAddr - (startAddr % PAGE_SIZE));

	uint64_t pageOffset = 1;
	while (1) {
		uint64_t byteOffset = pageOffset * PAGE_SIZE;
		uint64_t highAddr = startPage + byteOffset;
		uint64_t lowAddr = (startPage > byteOffset) ? startPage - byteOffset : 0;

		bool needsExit = highAddr > maxAddr && lowAddr < minAddr;

		if (highAddr < maxAddr) {
			void* outAddr = VirtualAllocEx(handle, (void*)highAddr, (size_t)PAGE_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
			if (outAddr)
				return outAddr;
		}

		if (lowAddr > minAddr) {
			void* outAddr = VirtualAllocEx(handle, (void*)lowAddr, (size_t)PAGE_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
			if (outAddr != nullptr)
				return outAddr;
		}

		pageOffset++;

		if (needsExit) {
			break;
		}
	}

	return nullptr;
}

void* AllocatePageNearAddress(void* targetAddr) {
	return AllocatePageNearAddressRemote(GetCurrentProcess(), targetAddr);
}

//I use subst to alias my development folder to W: 
//this will rebase any virtual drives made by subst to
//their actual drive equivalent, to prevent conflicts. Likely
//not important for most people and can be ignored
void RebaseVirtualDrivePath(const char* path, char* outBuff, size_t outBuffSize) {
	memset(outBuff, 0, outBuffSize);

	char driveLetter[3] = { 0 };
	memcpy(driveLetter, path, 2);

	char deviceDrive[512];
	QueryDosDevice(driveLetter, deviceDrive, 512);

	const char* virtualDrivePrefix = "\\??\\";
	char* prefix = strstr(deviceDrive, virtualDrivePrefix);
	if (prefix) {
		size_t replacementLen = strlen(deviceDrive) - strlen(virtualDrivePrefix);
		size_t rebasedPathLen = replacementLen + strlen(path) - 2;
		check(rebasedPathLen < outBuffSize);
		memcpy(outBuff, deviceDrive + strlen(virtualDrivePrefix), replacementLen);
		memcpy(outBuff + replacementLen, &path[2], strlen(path) - 2);
	}
	else {
		check(strlen(path) < outBuffSize);
		memcpy(outBuff, path, strlen(path));
	}
}

HMODULE GetBaseModuleForProcess(HANDLE process) {
	HMODULE remoteProcessModules[1024];
	DWORD numBytesWrittenInModuleArray = 0;
	BOOL success = EnumProcessModules(process, remoteProcessModules, sizeof(HMODULE) * 1024, &numBytesWrittenInModuleArray);

	if (!success) {
		fprintf(stderr, "Error enumerating modules on target process. Error Code %lu \n", GetLastError());
		//DebugBreak();
		return NULL;
	}

	DWORD numRemoteModules = numBytesWrittenInModuleArray / sizeof(HMODULE);
	CHAR remoteProcessName[256];
	GetModuleFileNameEx(process, NULL, remoteProcessName, 256); //a null module handle gets the process name
	_strlwr_s(remoteProcessName, 256);

	MODULEINFO remoteProcessModuleInfo;
	HMODULE remoteProcessModule = 0; //An HMODULE is just the DLL's base address 

	for (DWORD i = 0; i < numRemoteModules; ++i) {
		CHAR moduleName[256];
		CHAR absoluteModuleName[256];
		CHAR rebasedPath[256] = { 0 };
		GetModuleFileNameEx(process, remoteProcessModules[i], moduleName, 256);

		//the following string operations are to account for cases where GetModuleFileNameEx
		//returns a relative path rather than an absolute one, the path we get to the module
		//is using a virtual drive letter (ie: one created by subst) rather than a real drive
		char* err = _fullpath(absoluteModuleName, moduleName, 256);
		check(err);

		RebaseVirtualDrivePath(absoluteModuleName, rebasedPath, 256);
		_strlwr_s(rebasedPath, 256);

		if (strcmp(remoteProcessName, rebasedPath) == 0) {
			remoteProcessModule = remoteProcessModules[i];

			success = GetModuleInformation(process, remoteProcessModules[i], &remoteProcessModuleInfo, sizeof(MODULEINFO));
			if (!success) {
				fprintf(stderr, "Error getting module information for remote process module\n");
				DebugBreak();
			}
			break;
		}
	}

	return remoteProcessModule;
}

DWORD FindPidByName(const char* name) {
	HANDLE h;
	PROCESSENTRY32 singleProcess;
	h = CreateToolhelp32Snapshot( //takes a snapshot of specified processes
		TH32CS_SNAPPROCESS, //get all processes
		0); //ignored for SNAPPROCESS

	singleProcess.dwSize = sizeof(PROCESSENTRY32);

	do {

		if (strcmp(singleProcess.szExeFile, name) == 0) {
			DWORD pid = singleProcess.th32ProcessID;
			CloseHandle(h);
			return pid;
		}

	} while (Process32Next(h, &singleProcess));

	CloseHandle(h);

	return 0;
}

HMODULE FindModuleBaseAddress(HANDLE process, const char* targetModule) {
	HMODULE hMods[1024];
	DWORD cbNeeded;

	if (EnumProcessModules(process, hMods, sizeof(hMods), &cbNeeded)) {
		for (uint32_t i = 0; i < (cbNeeded / sizeof(HMODULE)); i++) {
			TCHAR moduleName[MAX_PATH];

			// Get the full path to the module's file.

			if (GetModuleFileNameEx(process, hMods[i], moduleName,
				sizeof(moduleName) / sizeof(TCHAR))) {
				// Print the module name and handle value.
				if (strstr(moduleName, targetModule) != nullptr) {
					return hMods[i];
				}
			}
		}
	}

	return NULL;
}

void* FindAddressOfRemoteDLLFunction(HANDLE process, const char* dllName, const char* funcName) {
	//first, load the dll into this process so we can use GetProcAddress to determine the offset
	//of the target function from the DLL base address (without running its DllMain here, which
	//would open the game's log again)
	HMODULE localDLL = LoadLibraryEx(dllName, NULL, DONT_RESOLVE_DLL_REFERENCES);
	check(localDLL);
	void* localHookFunc = GetProcAddress(localDLL, funcName);
	check(localHookFunc);

	uint64_t offsetOfHookFunc = (uint64_t)localHookFunc - (uint64_t)localDLL;
	FreeLibrary(localDLL); //free the library, we don't need it anymore.

	//Technically, we could just use the result of GetProcAddress, since in 99% of cases, the base address of the dll
	//in the two processes will be shared thanks to ASLR, but just in case the remote process has relocated the dll, 
	//I'm getting it here separately.

	HMODULE remoteModuleBase = FindModuleBaseAddress(process, dllName);

	return (void*)((uint64_t)remoteModuleBase + offsetOfHookFunc);
}

void SetOtherThreadsSuspended(bool suspend) {
	HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
	if (hSnapshot != INVALID_HANDLE_VALUE) {
		THREADENTRY32 te;
		te.dwSize = sizeof(THREADENTRY32);
		if (Thread32First(hSnapshot, &te)) {
			do {
				if (te.dwSize >= (FIELD_OFFSET(THREADENTRY32, th32OwnerProcessID) + sizeof(DWORD))
					&& te.th32OwnerProcessID == GetCurrentProcessId()
					&& te.th32ThreadID != GetCurrentThreadId()) {

					HANDLE thread = ::OpenThread(THREAD_ALL_ACCESS, FALSE, te.th32ThreadID);
					if (thread != NULL) {
						if (suspend) {
							SuspendThread(thread);
						}
						else {
							ResumeThread(thread);
						}
						CloseHandle(thread);
					}
				}
			} while (Thread32Next(hSnapshot, &te));
		}
	}
}


// Loads the DLL into the process (LoadLibraryA, in a thread of the process), then runs its
// stellar_start export in another thread.
void InjectPayload(HANDLE process, const char* pathToPayloadDLL) {
	//write the name of our dll to the target process' memory
	size_t dllPathLen = strlen(pathToPayloadDLL) + 1;
	void* dllPathRemote = VirtualAllocEx(
		process,
		NULL, //let the system decide where to allocate the memory
		dllPathLen,
		MEM_COMMIT, //actually commit the virtual memory
		PAGE_READWRITE); //mem access for committed page

	check(dllPathRemote);

	BOOL writeSucceeded = WriteProcessMemory(
		process,
		dllPathRemote,
		pathToPayloadDLL,
		dllPathLen,
		NULL);

	check(writeSucceeded);

	PTHREAD_START_ROUTINE loadLibraryFunc = (PTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandle(TEXT("Kernel32.dll")), "LoadLibraryA");
	check(loadLibraryFunc);

	//create a thread in remote process that loads our target dll using LoadLibraryA
	HANDLE remoteThread = CreateRemoteThread(
		process,
		NULL, //default thread security
		0, //stack size for thread
		loadLibraryFunc, //pointer to start of thread function (for us, LoadLibraryA)
		dllPathRemote, //pointer to variable being passed to thread function
		0, //0 means the thread runs immediately after creation
		NULL); //we don't care about getting back the thread identifier

	check(remoteThread);

	// Wait for the remote thread to terminate
	WaitForSingleObject(remoteThread, INFINITE);

	PTHREAD_START_ROUTINE start = (PTHREAD_START_ROUTINE)FindAddressOfRemoteDLLFunction(process, TEXT(PAYLOAD_DLL_NAME), TEXT("stellar_start"));
	std::cout << "Found remote start function: " << start << std::endl;
	check(start);

	HANDLE remoteThread2 = CreateRemoteThread(process, NULL, 0, start, NULL, 0, NULL);
	check(remoteThread2);
	WaitForSingleObject(remoteThread2, INFINITE);

	//once we're done, free the memory we allocated in the remote process for the dllPathname, and shut down
	VirtualFreeEx(process, dllPathRemote, 0, MEM_RELEASE);
	CloseHandle(remoteThread);
	CloseHandle(remoteThread2);
}

//hacky way to get the path to the correct payload for
//whatever the active build config is... saves having to 
//provide the path on the command line, but is otherwise
//not particularly important
void GetPathToPayloadDLL(char* outBuff) {
	char relPath[1024];
	char thisAppName[1024];
	GetModuleFileName(NULL, relPath, 1024);
	GetModuleBaseName(GetCurrentProcess(), NULL, thisAppName, 1024);
	char* replaceStart = strstr(relPath, thisAppName);
	const char* payloadDLLName = PAYLOAD_DLL_NAME;
	memcpy(replaceStart, payloadDLLName, strlen(payloadDLLName));
	memset(replaceStart + strlen(payloadDLLName), '\0', &relPath[1024] - (replaceStart + strlen(payloadDLLName)));

	_fullpath(outBuff, relPath, 1024);
}
