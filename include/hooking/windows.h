#pragma once

#include <stdint.h>
#include <stdio.h>
#include <string>
#include <iostream>

#define WIN32_LEAN_AND_MEAN

#ifdef _WIN32
#include "hooking/windows_platform.h"
#endif

#include "hooking/error.h"
#include "hooking/shared.h"

#define PAYLOAD_DLL_NAME "stellar-injected.dll"

#define check(expr) if (!(expr)){PrintErrorMessageToConsole(GetLastError()); DebugBreak(); exit(-1); }

void PrintErrorMessageToConsole(DWORD errorCode);
BOOL GetErrorMessage(DWORD dwErrorCode, LPTSTR pBuffer, DWORD cchBufferLength);
bool IsProcess64Bit(HANDLE process);
void* AllocatePageNearAddressRemote(HANDLE handle, void* targetAddr);
void* AllocatePageNearAddress(void* targetAddr);
void RebaseVirtualDrivePath(const char* path, char* outBuff, size_t outBuffSize);
HMODULE GetBaseModuleForProcess(HANDLE process);
DWORD FindPidByName(const char* name);

HMODULE FindModuleBaseAddress(HANDLE process, const char* targetModule);
void* FindAddressOfRemoteDLLFunction(HANDLE process, const char* dllName, const char* funcName);
void SetOtherThreadsSuspended(bool suspend);

// Loads stellar-injected.dll into the process and runs its stellar_start export there.
void InjectPayload(HANDLE process, const char* pathToPayloadDLL);
void GetPathToPayloadDLL(char* outBuff);
