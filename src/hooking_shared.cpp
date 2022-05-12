
#include "hooking_shared.h"

bool IsProcess64Bit(HANDLE process) {
	BOOL isWow64 = false;
	IsWow64Process(process, &isWow64);

	if (isWow64) {
		//process is 32 bit, running on 64 bit machine
		return false;
	}
	else {
		SYSTEM_INFO sysInfo;
		GetSystemInfo(&sysInfo);
		return sysInfo.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64;
	}
}