#include "dll/ctoken.h"

void(*trampoline)(void* ptr1, void* ptr2, void* ptr3);
__declspec(noinline) void payload(void* ptr1, int arg2, std::string* arg3) {
	CLog& logger = *getLogger();
	logger << "CToken::Init - this( " << ptr1 << " ) arg2( " << arg2 << " )";
	if (arg3 != nullptr) {
		logger << " arg3( " << *arg3 << " )";
	}

	logger.endl();

	void(*func_ptr)(void* ptr1, int arg2, std::string* arg3);
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, arg2, arg3);
}

void(*trampoline2)(void* ptr1, void* ptr2, void* ptr3);
__declspec(noinline) void payload2(void* ptr1, int arg2, const char* arg3) {
	CLog& logger = *getLogger();
	logger << "CToken::Init - this( " << ptr1 << " ) arg2( " << arg2 << " )";
	if (arg3 != nullptr) {
		logger << " arg3( " << *arg3 << " )";
	}

	logger.endl();

	void(*func_ptr)(void* ptr1, int arg2, const char * arg3);
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, arg2, arg3);
}


int(*trampoline3)(void* ptr1);
__declspec(noinline) int payload3(void* ptr1) {
	CLog& logger = *getLogger();
	logger << "CTextLexer::GetTok - this( " << ptr1 << " )";
	void** thisFile = (void**)(((intptr_t)ptr1) + 0x8);

	int* thisFileLineNo = (int*)(((intptr_t)*thisFile) + 0x8);
	std::string* thisFileName = (std::string*)(((intptr_t)*thisFile) + 0x18);

	logger << " CFile(" << thisFile << ")";
	if (thisFileName != nullptr) {
		logger << " FileName(" << *thisFileName << ")";
	}
	if (thisFileLineNo != nullptr) {
		logger << " LineNo(" << *thisFileLineNo << ")";
	}


	logger.endl();

	int(*func_ptr)(void* ptr1);
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1);
}

void ctoken_hook_init(enumPlatforms thisPlatform, intptr_t p_CApplication_Base, intptr_t base_augustus_ptr) {
	CLog& logger = *getLogger();

	intptr_t base_ptr = 0x0;
	intptr_t this_ptr = 0x0;

	base_ptr = find_address_from_symbol("CToken::Init");
	this_ptr = (intptr_t)p_CApplication_Base + (base_ptr - base_augustus_ptr);
	trampoline = (void(*)(void* ptr1, void* ptr2, void* ptr3)) installHook((void*)this_ptr, &trampoline, payload);

	base_ptr = find_address_from_symbol("CToken::Init_2");
	this_ptr = (intptr_t)p_CApplication_Base + (base_ptr - base_augustus_ptr);
	trampoline2 = (void(*)(void* ptr1, void* ptr2, void* ptr3)) installHook((void*)this_ptr, &trampoline2, payload2);

	base_ptr = find_address_from_symbol("CTextLexer::GetTok");
	this_ptr = (intptr_t)p_CApplication_Base + (base_ptr - base_augustus_ptr);
	trampoline3 = (int(*)(void* ptr1)) installHook((void*)this_ptr, &trampoline3, payload3);
}