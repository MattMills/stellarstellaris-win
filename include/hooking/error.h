#pragma once

#ifdef _WIN32
#include "hooking/windows_platform.h"
#endif



#define check(expr) if (!(expr)){PrintErrorMessageToConsole(GetLastError()); DebugBreak(); exit(-1); }

void PrintErrorMessageToConsole(DWORD errorCode);
BOOL GetErrorMessage(DWORD dwErrorCode, LPTSTR pBuffer, DWORD cchBufferLength);