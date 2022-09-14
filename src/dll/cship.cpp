#include "dll/cship.h"
#include "dll/hooking_common.h"

intptr_t base_cship_dailyupdaterepair_ptr = 0x0;
intptr_t base_steam_cship_dailyupdaterepair_ptr = 0x1407bc4e0;
intptr_t base_gog_cship_dailyupdaterepair_ptr = 0x1407ba2b0;


intptr_t base_cship_calcregenamount_ptr = 0x0;
intptr_t base_steam_cship_calcregenamount_ptr = 0x1407CFC20;
intptr_t base_gog_cship_calcregenamount_ptr = 0x1407cd9f0;

/*
void __thiscall CShip::DailyUpdateRepair(CShip *this)
*/

void(*cship_dailyupdaterepair_trampoline)(void* ptr1);
__declspec(noinline) void cship_dailyupdaterepair_payload(void* ptr1) {
	CLog& logger = *getLogger();
	logger << "CShip::DailyUpdateRepair - ";
#if DBG_PTR == 1
	logger << "ptr1(" << ptr1 << ") ";
#endif


	std::string* strPersistentName = (std::string*)((intptr_t)ptr1 + 0x68);
	uint32_t* uint32_FleetID = (uint32_t*)((intptr_t)ptr1 + 0xa8);
	int64_t* int64_vHitPoints = (int64_t*)((intptr_t)ptr1 + 0x150);
	int64_t* int64_vShieldHitPoints = (int64_t*)((intptr_t)ptr1 + 0x158);
	int64_t* int64_vArmorHitPoints = (int64_t*)((intptr_t)ptr1 + 0x160);

	int64_t* int64_vCachedMaxHitPoints = (int64_t*)((intptr_t)ptr1 + 0x7d0);
	int64_t* int64_vCachedMaxShieldHitPoints = (int64_t*)((intptr_t)ptr1 + 0x7d8);
	int64_t* int64_vCachedMaxArmorHitPoints = (int64_t*)((intptr_t)ptr1 + 0x7e0);

	int64_t* int64_vCachedHullRegen = (int64_t*)((intptr_t)ptr1 + 0x808);
	int64_t* int64_vCachedArmorRegen = (int64_t*)((intptr_t)ptr1 + 0x810);
	int64_t* int64_vCachedShieldRegen = (int64_t*)((intptr_t)ptr1 + 0x818);

	if (strPersistentName != nullptr) {
#if DBG_PTR == 1
		logger << " strptr(" << (void*)strPersistentName << ")";
#endif
		logger << " Name(" << *strPersistentName << ")";
	}

	if (uint32_FleetID != nullptr) {
#if DBG_PTR == 1
		logger << " idptr(" << (void*)uint32_FleetID << ")";
#endif
		logger << " TPdxRef<CFleet>->_nID(" << *uint32_FleetID << ")";
	}
	
	logger << " vHitPoints(" << *int64_vHitPoints << ")";
	logger << " vShieldHitPoints(" << *int64_vShieldHitPoints << ")";
	logger << " vArmorHitPoints(" << *int64_vArmorHitPoints << ")";

	logger << " vCachedMaxHitPoints(" << *int64_vCachedMaxHitPoints << ")";
	logger << " vCachedMaxShieldHitPoints(" << *int64_vCachedMaxShieldHitPoints << ")";
	logger << " vCachedMaxArmorHitPoints(" << *int64_vCachedMaxArmorHitPoints << ")";

	logger << " vCachedHullRegen(" << *int64_vCachedHullRegen << ")";
	logger << " vCachedArmorRegen(" << *int64_vCachedArmorRegen << ")";
	logger << " vCachedShieldRegen(" << *int64_vCachedShieldRegen << ")";

	logger.endl();
	
	void(*func_ptr)(void* ptr1);;
	PopAddress(uint64_t(&func_ptr));
	return func_ptr(ptr1);
}


/*
* CFixedPoint __thiscall CShip::CalcRegenAmount(CShip *this,CFixedPoint param_1,CFixedPoint param_2,CFixedPoint param_3)
*/

int64_t* (*cship_calcregenamount_trampoline)(void* ptr1, int64_t param_1, int64_t param_2, int64_t param_3);
__declspec(noinline) int64_t* cship_calcregenamount_payload(void* ptr1, int64_t param_1, int64_t param_2, int64_t param_3) {
	//TODO: this logging is very noisy, so removing it while leaving the patch in place.
	//CLog& logger = *getLogger();
	//logger << "CShip::CalcRegenAmount - ";
	//#if DBG_PTR == 1
	//logger << "ptr1(" << ptr1 << ") ";
	//#endif
		
	//logger << " param_1(" << param_1 << ")";
	//logger << " param_2(" << param_2 << ")";
	//logger << " param_3(" << param_3 << ")";
		
	double result;
	double dbl_max_hp = (double)param_1;
	double dbl_multiplier = (double)param_2;
	int64_t static_add = param_3;
	dbl_multiplier /= 10000000;

	result = (dbl_max_hp * dbl_multiplier) + static_add;
	if ((int64_t)result < 0) {
		result = (double) INT64_MAX/2; //surely this is high enough :|
	}
		
	int64_t*(*func_ptr)(void* ptr1, int64_t param_1, int64_t param_2, int64_t param_3);
	PopAddress(uint64_t(&func_ptr));
	//int64_t* result_orig;
	//result_orig = func_ptr(ptr1, param_1, param_2, param_3);

	//logger << " result(" << (int64_t)result << " )";
	
	
	//logger << " ptr_game_result(" << result_orig << ")";
	//logger << " game_result(" << *result_orig << ")";
	//logger.endl();

	*((int64_t*)ptr1) = (int64_t)result;
	return  (int64_t*)ptr1;

}

void cship_hook_init(enumPlatforms thisPlatform, intptr_t p_CApplication_Base, intptr_t base_augustus_ptr) {
	CLog& logger = *getLogger();

	if (thisPlatform == STEAM) {
		base_cship_dailyupdaterepair_ptr = base_steam_cship_dailyupdaterepair_ptr;
		base_cship_calcregenamount_ptr = base_steam_cship_calcregenamount_ptr;
	}
	else if (thisPlatform == GOG) {
		base_cship_dailyupdaterepair_ptr = base_gog_cship_dailyupdaterepair_ptr;
		base_cship_calcregenamount_ptr = base_gog_cship_calcregenamount_ptr;
	}
	
	//TODO: performance penalty, enable/disable
	//intptr_t this_cship_dailyupdaterepair_ptr = (intptr_t)p_CApplication_Base + (base_cship_dailyupdaterepair_ptr - base_augustus_ptr);
	//cship_dailyupdaterepair_trampoline = (void(*)(void* ptr1)) installHook((void*)this_cship_dailyupdaterepair_ptr, &cship_dailyupdaterepair_trampoline, cship_dailyupdaterepair_payload);

	intptr_t this_cship_calcregenamount_ptr = (intptr_t)p_CApplication_Base + (base_cship_calcregenamount_ptr - base_augustus_ptr);
	cship_calcregenamount_trampoline = (int64_t*(*)(void* ptr1, int64_t param_1, int64_t param_2, int64_t param_3)) installHook((void*)this_cship_calcregenamount_ptr, &cship_calcregenamount_trampoline, cship_calcregenamount_payload);
}