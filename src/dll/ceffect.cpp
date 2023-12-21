
#include "dll/ceffect.h"
#include "dll/hooking_common.h"
#include "dll/ceventscope.h"

extern CLog logger;

intptr_t base_ceffect_executeactual_ptr = 0x0;

void(*ceffect_executeactual_trampoline)(void* ptr1, void* ptr2);
__declspec(noinline) void ceffect_executeactual_payload(void* ptr1, void* ptr2) {
	CLog &logger = *getLogger();
	logger << "CEffect::ExecuteActual - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ptr2(" << ptr2 << ") ";
#endif

	int32_t* escopetype = (int32_t*)(((intptr_t)ptr2) + 8);
	uint32_t* objectid = (uint32_t*)(((intptr_t)ptr2) + 12);

	logger << " " << enum_to_string_escopetype(*escopetype) << " ObjectID(" << *objectid << ")";

	//0x20 = CEvent::_FileLocationDesc
	//0x40 = CEvent::_ID
	std::string* strFileLocationDesc = (std::string*)((intptr_t)ptr1 + 0x20);
	std::string* strID = (std::string*)((intptr_t)ptr1 + 0x40);

	
	if (strFileLocationDesc != nullptr) {
#if DBG_PTR == 1
		logger << "strptr(" << (void*)strFileLocationDesc << ")";
#endif
		logger << " Desc(" << *strFileLocationDesc << ")";
	}

	if (strID != nullptr) {
#if DBG_PTR == 1
		logger << "strptr(" << (void*)strID << ")";
#endif
		logger << " ID(" << *strID << ")";
	}

	logger.endl();

	void(*func_ptr)(void* ptr1, void* ptr2);;
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, ptr2);

}

void ceffect_hook_init(enumPlatforms thisPlatform, intptr_t p_CApplication_Base, intptr_t base_augustus_ptr) {
	base_ceffect_executeactual_ptr = find_address_from_symbol("CEffect::ExecuteActual");
	
	if (base_ceffect_executeactual_ptr != 0x0) {
		intptr_t this_ceffect_executeactual_ptr = (intptr_t)p_CApplication_Base + (base_ceffect_executeactual_ptr - base_augustus_ptr);
		ceffect_executeactual_trampoline = (void(*)(void* ptr1, void* ptr2)) installHook((void*)this_ceffect_executeactual_ptr, &ceffect_executeactual_trampoline, ceffect_executeactual_payload);
	}
}