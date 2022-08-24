
#include "dll/ceffect.h"
#include "dll/hooking_common.h"

extern CLog logger;

intptr_t base_ceffect_executeactual_ptr = 0x0;
intptr_t base_steam_ceffect_executeactual_ptr = 0x140302b20;
intptr_t base_gog_ceffect_executeactual_ptr = 0x140300eb0;

void(*ceffect_executeactual_trampoline)(void* ptr1, void* ptr2);
__declspec(noinline) void ceffect_executeactual_payload(void* ptr1, void* ptr2) {
	CLog &logger = *getLogger();
	logger << "CEffect::ExecuteActual - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ptr2(" << ptr2 << ") ";
#endif

	uint8_t buf[0x20 + 1]; // CString size
	memset(buf, 0x00, sizeof(buf));
	memcpy(&buf, (void*)(((intptr_t)ptr1) + 0x20), sizeof(buf));
	char charbuf[0x20 + 1];
	charbuf[0x20] = 0;
	for (unsigned int j = 0; j < 0x10; j++)
		sprintf(&charbuf[2 * j], "%02X", buf[j]);
#if DBG_PTR == 1
	logger << "ptr1 charbuf(" << charbuf << ") - ";
#endif

	void* file_location_desc = nullptr;
	void* id = nullptr;

	char* strptr = nullptr;
	memcpy(&strptr, &buf, 0x8);

	if (strptr != nullptr) {
#if DBG_PTR == 1
		logger << "strptr(" << (void*)strptr << ")";
#endif
		logger << " " << strptr;
	}

	logger.endl();
	/*memset(&buf, 0x00, sizeof(buf));
	memcpy(&buf, ptr2, 136);
	logger << buf;
	logger.endl();
	*/
	void(*func_ptr)(void* ptr1, void* ptr2);;
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, ptr2);

}

void ceffect_hook_init(enumPlatforms thisPlatform, intptr_t p_CApplication_Base, intptr_t base_augustus_ptr) {
	
	if(thisPlatform == STEAM){
		base_ceffect_executeactual_ptr = base_steam_ceffect_executeactual_ptr;
	}else if (thisPlatform == GOG) {
		base_ceffect_executeactual_ptr = base_gog_ceffect_executeactual_ptr;
	}

	intptr_t this_ceffect_executeactual_ptr = (intptr_t)p_CApplication_Base + (base_ceffect_executeactual_ptr - base_augustus_ptr);
	ceffect_executeactual_trampoline = (void(*)(void* ptr1, void* ptr2)) installHook((void*)this_ceffect_executeactual_ptr, &ceffect_executeactual_trampoline, ceffect_executeactual_payload);
}