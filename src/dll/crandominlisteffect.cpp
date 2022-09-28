#include "dll/crandominlisteffect.h"
#include "dll/hooking_common.h"

intptr_t base_crandominlisteffect_executeactual_ptr = 0x0;


void(*crandominlisteffect_executeactual_trampoline)(void* ptr1, void* ptr2);
__declspec(noinline) void crandominlisteffect_executeactual_payload(void* ptr1, void* ptr2) {
	CLog& logger = *getLogger();
	logger << "CRandomInListEffect::ExecuteActual - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ptr2(" << ptr2 << ") ";
#endif

	uint8_t buf[0x20 + 1]; // CString size
	memset(buf, 0x00, sizeof(buf));
	memcpy(&buf, (void*)(((intptr_t)ptr1) + 0x20), sizeof(buf));
	char charbuf[0x20 + 1];
	charbuf[0x20] = 0;
	for (uint j = 0; j < 0x10; j++)
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

void crandominlisteffect_hook_init(enumPlatforms thisPlatform, intptr_t p_CApplication_Base, intptr_t base_augustus_ptr) {
	CLog& logger = *getLogger();

	
	base_crandominlisteffect_executeactual_ptr = find_address_from_symbol("CRandomInListEffect::ExecuteActual");
	
	
	intptr_t this_crandominlisteffect_executeactual_ptr = (intptr_t)p_CApplication_Base + (base_crandominlisteffect_executeactual_ptr - base_augustus_ptr);
	crandominlisteffect_executeactual_trampoline = (void(*)(void* ptr1, void* ptr2)) installHook((void*)this_crandominlisteffect_executeactual_ptr, &crandominlisteffect_executeactual_trampoline, crandominlisteffect_executeactual_payload);
}