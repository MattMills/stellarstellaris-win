#define WIN32_LEAN_AND_MEAN   
#include "hooking/error.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN   
#include "hooking/windows_platform.h"
#endif

void PrintErrorMessageToConsole(DWORD errorCode) {
	char errorBuf[1024];
	FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
		NULL,
		errorCode,
		MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
		errorBuf,
		1024,
		NULL);

	printf("Error: %i : %s\n", errorCode, errorBuf);
}

BOOL GetErrorMessage(DWORD dwErrorCode, LPTSTR pBuffer, DWORD cchBufferLength) {
	if (cchBufferLength == 0) {
		return FALSE;
	}

	DWORD cchMsg = FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
		NULL,  /* (not used with FORMAT_MESSAGE_FROM_SYSTEM) */
		dwErrorCode,
		MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
		pBuffer,
		cchBufferLength,
		NULL);
	return (cchMsg > 0);
}