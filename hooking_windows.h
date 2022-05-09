#pragma once 

#define UMDF_USING_NTSTATUS
#include <windows.h>
#include <memoryapi.h>
#include <wow64apiset.h> // for checking is process is 64 bit
#include <TlHelp32.h> //for PROCESSENTRY32, needs to be included after windows.h
#include <winternl.h>
#include <ntstatus.h>

#include <process.h>
#include <WinUser.h>

#include <strsafe.h>
#include <amsi.h>
#include <psapi.h>
#include <stdint.h>
#include <stdio.h>
#include <string>
#include <iostream>

//#include <subauth.h>



#pragma comment(lib, "psapi.lib")
#pragma comment(lib, "ntdll.lib")


//For memory searching
#define SEARCH_CHUNK_SIZE 0x80000
#define MAX_ADDRESS 0x7ffffff




#define check(expr) if (!(expr)){PrintErrorMessageToConsole(GetLastError()); DebugBreak(); exit(-1); }

#if _WIN64
typedef uint64_t addr_t;
#else 
typedef uint32_t addr_t;
#endif


NTSTATUS GetProcessIdByName(PUNICODE_STRING ImageName, HANDLE& UniqueProcessId);
unsigned char* searchMemory(HANDLE hProcess, const char search_value[]);

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

//TODO: I think all this stuff is generic non-windows specific assembly, should check and migrate to platform independent area.
uint32_t WriteMovToRCX(uint8_t * dst, uint64_t val);
uint32_t WriteSaveArgumentRegisters(uint8_t * dst);
uint32_t WriteRestoreArgumentRegisters(uint8_t * dst);
uint32_t WriteAddRSP32(uint8_t * dst);
uint32_t WriteSubRSP32(uint8_t * dst);
uint32_t WriteAbsoluteCall64(uint8_t * dst, void* funcToCall);
uint32_t WriteAbsoluteJump64(void* absJumpMemory, void* addrToJumpTo);
uint32_t WriteAbsoluteJump64(HANDLE process, void* absJumpMemory, void* addrToJumpTo);
uint32_t WriteRelativeJump(void* func2hook, void* jumpTarget);
uint32_t WriteRelativeJump(void* func2hook, void* jumpTarget, uint8_t numTrailingNOPs);
uint32_t WriteRelativeJump(HANDLE process, void* func2hook, void* jumpTarget);
// /TODO

HMODULE FindModuleBaseAddress(HANDLE process, const char* targetModule);
void* FindAddressOfRemoteDLLFunction(HANDLE process, const char* dllName, const char* funcName);
void SetOtherThreadsSuspended(bool suspend);