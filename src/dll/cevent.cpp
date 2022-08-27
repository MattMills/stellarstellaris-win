#include "dll/cevent.h"
#include "dll/ceventscope.h"

extern CLog logger;

intptr_t base_cevent_execute_ptr = 0x0;
intptr_t base_steam_cevent_execute_ptr = 0x1402df460;
intptr_t base_gog_cevent_execute_ptr = 0x1402dd7f0;

intptr_t base_cevent_performimmediate_ptr = 0x0;
intptr_t base_steam_cevent_performimmediate_ptr = 0x1402df290;
intptr_t base_gog_cevent_performimmediate_ptr = 0x1402dd620;


void(*cevent_execute_trampoline)(void* ptr1, void* arg2, void* arg3, void* arg4, void* arg5);
__declspec(noinline) void cevent_execute_payload(void* ptr1, void* arg2, void* arg3, void * arg4, void* arg5) {
	CLog& logger = *getLogger();
	logger << "CEvent::Execute - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ";
#endif


	int32_t* escopetype = (int32_t*)(((intptr_t)ptr1) + 0x30);
	uint32_t* objectid = (uint32_t*)(((intptr_t)ptr1) + 0x34);

	logger << " " << enum_to_string_escopetype(*escopetype) << " ObjectID(" << *objectid << ")";

	std::string* str_event_id = nullptr;
	str_event_id = (std::string*)(((intptr_t)ptr1) + 0x10);

	logger << " EventID(" << str_event_id->c_str() << ")";
	logger.endl();

	void(*func_ptr)(void* ptr1, void* arg2, void* arg3, void* arg4, void* arg5);
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1, arg2, arg3, arg4, arg5);

}

/*
void __thiscall
CEvent::PerformImmediate
		  (CEvent *this,CEventScope *param_1,EEventExecutionMode param_2,
		  CPdxUnorderedMap<enum_EEffectUserDataKey,unsigned___int64,struct_SPdxHash<enum_EEffectUser DataKey>,struct_std::equal_to<enum_EEffectUserDataKey>,0>
		  *param_3)
		  */
void(*cevent_performimmediate_trampoline)(void* arg1, void* arg2, void* arg3, void* arg4);
__declspec(noinline) void cevent_performimmediate_payload(void* arg1, void* arg2, void* arg3, void* arg4) {
	CLog& logger = *getLogger();
	logger << "CEvent::PerformImmediate - ";
#if DBG_PTR == 1
	logger << "ptrEvent(" << arg1 << ") ";
	logger << "ptrEventScope(" << arg2 << ") ";
	logger << "EEventExecutionMode(" << arg3 << ") ";
	logger << "ptrUserDataUnorderedMap(" << arg4 << ") ";
#endif


	int32_t* escopetype = (int32_t*)(((intptr_t)arg2) + 8);
	uint32_t* objectid = (uint32_t*)(((intptr_t)arg2) + 12);

	logger << " " << enum_to_string_escopetype(*escopetype) << " ObjectID(" << *objectid << ")";

	std::string* str_event_id = nullptr;
	str_event_id = (std::string*)(((intptr_t)arg1) + 0x10);

	logger << " EventID(" << str_event_id->c_str() << ")";
	logger.endl();

	void(*func_ptr)(void* arg1, void* arg2, void* arg3, void* arg4);
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(arg1, arg2, arg3, arg4);

}


void cevent_hook_init(enumPlatforms thisPlatform, intptr_t p_CApplication_Base, intptr_t base_augustus_ptr) {
	CLog& logger = *getLogger();
	if (thisPlatform == STEAM) {
		base_cevent_execute_ptr = base_steam_cevent_execute_ptr;
		base_cevent_performimmediate_ptr = base_steam_cevent_performimmediate_ptr;
	}
	else if (thisPlatform == GOG) {
		base_cevent_execute_ptr = base_gog_cevent_execute_ptr;
		base_cevent_performimmediate_ptr = base_gog_cevent_performimmediate_ptr;
	}

	intptr_t this_cevent_execute_ptr = (intptr_t)p_CApplication_Base + (base_cevent_execute_ptr - base_augustus_ptr);
	intptr_t this_cevent_performimmediate_ptr = (intptr_t)p_CApplication_Base + (base_cevent_performimmediate_ptr - base_augustus_ptr);
	cevent_execute_trampoline = (void(*)(void* ptr1, void* arg2, void* arg3, void* arg4, void* arg5)) installHook((void*)this_cevent_execute_ptr, &cevent_execute_trampoline, cevent_execute_payload);
	cevent_performimmediate_trampoline = (void(*)(void* arg1, void* arg2, void* arg3, void* arg4)) installHook((void*)this_cevent_performimmediate_ptr, &cevent_performimmediate_trampoline, cevent_performimmediate_payload);
	
}