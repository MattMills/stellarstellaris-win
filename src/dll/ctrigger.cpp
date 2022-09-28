
#include "dll/ctrigger.h"
#include "dll/ceventscope.h"

extern CLog logger;

intptr_t base_ctrigger_evaluate1_ptr = 0x0;
intptr_t base_ctrigger_evaluate2_ptr = 0x0;
intptr_t base_ctrigger_evaluateextended_ptr = 0x0;


/* public: virtual bool __cdecl CTrigger::Evaluate(class CEventScope const & __ptr64)const __ptr64
   public: virtual bool __cdecl CGuiAnimationReloader::Reload(class CPdxArray<class CString,int>
   const & __ptr64) __ptr64 

   bool __thiscall CTrigger::Evaluate(CTrigger *this,CEventScope *param_1)
   */

void(*ctrigger_evaluate1_trampoline)(void* ptr1, void* ptr2);
__declspec(noinline) void ctrigger_evaluate1_payload(void* ptr1, void* ptr2) {
	CLog &logger = *getLogger();
	logger << "CTrigger::Evaluate (1) - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ptr2(" << ptr2 << ") ";
#endif

	int32_t* escopetype = (int32_t*)(((intptr_t)ptr2) + 8);
	uint32_t* objectid = (uint32_t*)(((intptr_t)ptr2) + 12);

	logger << " " << enum_to_string_escopetype(*escopetype) << " ObjectID(" << *objectid << ")";

	//0x20 = CEvent::_FileLocationDesc
	//0x40 = CEvent::_ID
	std::string* strFileLocationDesc = (std::string*)((intptr_t)ptr1 + 0x40);
	
	
	if (strFileLocationDesc != nullptr) {
#if DBG_PTR == 1
		logger << "strptr(" << (void*)strFileLocationDesc << ")";
#endif
		logger << " Desc(" << *strFileLocationDesc << ")";
	}

	logger.endl();

	void(*func_ptr)(void* ptr1, void* ptr2);
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, ptr2);

}

void(*ctrigger_evaluate2_trampoline)(void* ptr1, void* ptr2);
__declspec(noinline) void ctrigger_evaluate2_payload(void* ptr1, void* ptr2) {
	CLog& logger = *getLogger();
	logger << "CTrigger::Evaluate (2) - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ptr2(" << ptr2 << ") ";
#endif

	int32_t* escopetype = (int32_t*)(((intptr_t)ptr2) + 8);
	uint32_t* objectid = (uint32_t*)(((intptr_t)ptr2) + 12);

	logger << " " << enum_to_string_escopetype(*escopetype) << " ObjectID(" << *objectid << ")";

	//0x20 = CEvent::_FileLocationDesc
	//0x40 = CEvent::_ID
	std::string* strFileLocationDesc = (std::string*)((intptr_t)ptr1 + 0x40);


	if (strFileLocationDesc != nullptr) {
#if DBG_PTR == 1
		logger << "strptr(" << (void*)strFileLocationDesc << ")";
#endif
		logger << " Desc(" << *strFileLocationDesc << ")";
	}

	logger.endl();

	void(*func_ptr)(void* ptr1, void* ptr2);
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, ptr2);

}

void(*ctrigger_evaluateextended_trampoline)(void* ptr1, void* ptr2, void* ptr3);
__declspec(noinline) void ctrigger_evaluateextended_payload(void* ptr1, void* ptr2, void* ptr3) {
	CLog& logger = *getLogger();
	logger << "CTrigger::Evaluate (1) - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ptr2(" << ptr2 << ") ";
#endif

	int32_t* escopetype = (int32_t*)(((intptr_t)ptr2) + 8);
	uint32_t* objectid = (uint32_t*)(((intptr_t)ptr2) + 12);

	logger << " " << enum_to_string_escopetype(*escopetype) << " ObjectID(" << *objectid << ")";

	//0x20 = CEvent::_FileLocationDesc
	//0x40 = CEvent::_ID
	std::string* strFileLocationDesc = (std::string*)((intptr_t)ptr1 + 0x40);


	if (strFileLocationDesc != nullptr) {
#if DBG_PTR == 1
		logger << "strptr(" << (void*)strFileLocationDesc << ")";
#endif
		logger << " Desc(" << *strFileLocationDesc << ")";
	}

	logger.endl();

	void(*func_ptr)(void* ptr1, void* ptr2, void* ptr3);
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, ptr2, ptr2);

}




void ctrigger_hook_init(enumPlatforms thisPlatform, intptr_t p_CApplication_Base, intptr_t base_augustus_ptr) {
	
	
	base_ctrigger_evaluate1_ptr = find_address_from_symbol("CTrigger::Evaluate_1");
	base_ctrigger_evaluate2_ptr = find_address_from_symbol("CTrigger::Evaluate_2");
	base_ctrigger_evaluateextended_ptr = find_address_from_symbol("CTrigger::EvaluateExtended");
	

	intptr_t this_ctrigger_evaluate1_ptr = (intptr_t)p_CApplication_Base + (base_ctrigger_evaluate1_ptr - base_augustus_ptr);
	intptr_t this_ctrigger_evaluate2_ptr = (intptr_t)p_CApplication_Base + (base_ctrigger_evaluate2_ptr - base_augustus_ptr);
	intptr_t this_ctrigger_evaluateextended_ptr = (intptr_t)p_CApplication_Base + (base_ctrigger_evaluateextended_ptr - base_augustus_ptr);
	//TODO: Too noisy, need to have some mechanism to enable/disable as needed
	//ctrigger_evaluate1_trampoline = (void(*)(void* ptr1, void* ptr2)) installHook((void*)this_ctrigger_evaluate1_ptr, &ctrigger_evaluate1_trampoline, ctrigger_evaluate1_payload);
	//ctrigger_evaluate2_trampoline = (void(*)(void* ptr1, void* ptr2)) installHook((void*)this_ctrigger_evaluate2_ptr, &ctrigger_evaluate2_trampoline, ctrigger_evaluate2_payload);
	//ctrigger_evaluateextended_trampoline = (void(*)(void* ptr1, void* ptr2, void* ptr3)) installHook((void*)this_ctrigger_evaluateextended_ptr, &ctrigger_evaluateextended_trampoline, ctrigger_evaluateextended_payload);
}