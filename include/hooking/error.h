#pragma once


#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN   
#include "hooking/windows_platform.h"
#endif



#define check(expr) if (!(expr)){PrintErrorMessageToConsole(GetLastError()); DebugBreak(); exit(-1); }

void PrintErrorMessageToConsole(DWORD errorCode);
BOOL GetErrorMessage(DWORD dwErrorCode, LPTSTR pBuffer, DWORD cchBufferLength);