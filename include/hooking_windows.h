#pragma once 

#include <stdint.h>
#include <stdio.h>
#include <string>
#include <iostream>

//#include <subauth.h>

#include "hooking_asm.h"

#ifdef _WIN32
#include "hooking_windows_platform.h"
#endif

#include "hooking_error.h"
#include "hooking_shared.h"


#define check(expr) if (!(expr)){PrintErrorMessageToConsole(GetLastError()); DebugBreak(); exit(-1); }

#if _WIN64
typedef uint64_t addr_t;
#else 
typedef uint32_t addr_t;
#endif


//For memory searching
#define SEARCH_CHUNK_SIZE 0x80000
#define MAX_ADDRESS 0x7ffffff







unsigned char* searchMemory(HANDLE hProcess, const char search_value[], DWORD bufferType);

void PrintModulesForProcess(HANDLE process);
void PrintErrorMessageToConsole(DWORD errorCode);
BOOL GetErrorMessage(DWORD dwErrorCode, LPTSTR pBuffer, DWORD cchBufferLength);
bool IsProcess64Bit(HANDLE process);
void* AllocPageInTargetProcess(HANDLE process);
void* AllocPage();
void* AllocatePageNearAddressRemote(HANDLE handle, void* targetAddr);
void* AllocatePageNearAddress(void* targetAddr);
void RebaseVirtualDrivePath(const char* path, char* outBuff, size_t outBuffSize);
HMODULE FindModuleInProcess(HANDLE process, const char* name);
void PrintModulesForProcess(HANDLE process);
HMODULE GetBaseModuleForProcess(HANDLE process);
DWORD FindPidByName(const char* name);

HMODULE FindModuleBaseAddress(HANDLE process, const char* targetModule);
void* FindAddressOfRemoteDLLFunction(HANDLE process, const char* dllName, const char* funcName);
void SetOtherThreadsSuspended(bool suspend);

void InjectPayload(HANDLE process, const char* pathToPayloadDLL, void* ptr, void* ptr2);
void GetPathToPayloadDLL(char* outBuff);