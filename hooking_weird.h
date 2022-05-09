#pragma once


typedef void (NTAPI* _RtlInitUnicodeString)(
    PUNICODE_STRING DestinationString,
    PCWSTR SourceString
    );


typedef NTSYSAPI BOOLEAN(NTAPI* _RtlEqualUnicodeString)(
    PUNICODE_STRING String1,
    PUNICODE_STRING String2,
    BOOLEAN CaseInsetive
    );
typedef CONST UNICODE_STRING* PCUNICODE_STRING;

//extern _RtlInitUnicodeString RtlInitUnicodeString = (_RtlInitUnicodeString)GetProcAddress(GetModuleHandle("ntdll.dll"), "RtlInitUnicodeString");
extern _RtlEqualUnicodeString RtlEqualUnicodeString = (_RtlEqualUnicodeString)GetProcAddress(GetModuleHandle("ntdll.dll"), "RtlEqualUnicodeString");

