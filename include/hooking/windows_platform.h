#pragma once

#define UMDF_USING_NTSTATUS

#ifndef _AFXDLL
#include <windows.h>
#endif
#include <memoryapi.h>
#include <wow64apiset.h> // for checking is process is 64 bit
#include <TlHelp32.h> //for PROCESSENTRY32, needs to be included after windows.h
#ifndef _NTSTATUS_
#include <winternl.h>


#include <ntstatus.h>
#endif

#include <process.h>
#include <WinUser.h>

#include <strsafe.h>
#include <amsi.h>
#include <psapi.h>

#pragma comment(lib, "psapi.lib")
#pragma comment(lib, "ntdll.lib")