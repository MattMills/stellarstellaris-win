
#include "stellaris/CGameApplication.h"

#include "limit_once_in_x_seconds.h"

#include <map>

extern CLog logger;
extern CApplication* p_CApplication;
const uint64_t expected_fps = 60;


intptr_t base_func_ptr = 0x0;// CPlanetView::UpdatePopulationTab(void * this)
intptr_t base_func2_ptr = 0x0; // CFleetManagerView::Update(void * this)>
intptr_t base_func3_ptr = 0x0; // CPlanetView::GetToolTip(void * this, class CGuiObject const *, class CToolTip &)
intptr_t base_func4_ptr = 0x0; // CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>
intptr_t base_func5_ptr = 0x0; // CFleetTemplateManager::CalcShipsToReinforceInternal
intptr_t base_func6_ptr = 0x0; // CCountry::GetLatestShipDesign


struct SCalcShipsToReinforceResult {
	short _nFleetsToReinforceTotal;
	short _nShipsToReinforceTotal;
	short _nShipsToReinforceTotalNavyCap;
	short _nShipsToReinforceAvailable;

	friend std::ostream& operator<<(std::ostream& o, const SCalcShipsToReinforceResult& i) {

		o << " ptr(" << &i << ")";
		o << " _nFleetsToReinforceTotal(" << i._nFleetsToReinforceTotal << ")";
		o << " _nShipsToReinforceTotal(" << i._nShipsToReinforceTotal << ")";
		o << " _nShipsToReinforceTotalNavyCap(" << i._nShipsToReinforceTotalNavyCap << ")";
		o << " _nShipsToReinforceAvailable(" << i._nShipsToReinforceAvailable << ")";

		return o;
	}
};

struct func_identifier {
	void* func_ptr = 0x0;
	void* ptr1 = 0x0;
	void* ptr2 = 0x0;
	void* ptr3 = 0x0;
	void* ptr4 = 0x0;
	void* ptr5 = 0x0;
	void* ptr6 = 0x0;
	void* ptr7 = 0x0;

	func_identifier(void* func_ptr) : func_ptr(func_ptr) {}
	func_identifier(void* func_ptr, void* ptr1) : func_ptr(func_ptr), ptr1(ptr1) {}
	func_identifier(void* func_ptr, void* ptr1, void* ptr2) : func_ptr(func_ptr), ptr1(ptr1), ptr2(ptr2) {}
	func_identifier(void* func_ptr, void* ptr1, void* ptr2, void* ptr3) : func_ptr(func_ptr), ptr1(ptr1), ptr2(ptr2), ptr3(ptr3) {}
	func_identifier(void* func_ptr, void* ptr1, void* ptr2, void* ptr3, void* ptr4) : func_ptr(func_ptr), ptr1(ptr1), ptr2(ptr2), ptr3(ptr3), ptr4(ptr4) {}
	func_identifier(void* func_ptr, void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5) : func_ptr(func_ptr), ptr1(ptr1), ptr2(ptr2), ptr3(ptr3), ptr4(ptr4), ptr5(ptr5) {}
	func_identifier(void* func_ptr, void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6) : func_ptr(func_ptr), ptr1(ptr1), ptr2(ptr2), ptr3(ptr3), ptr4(ptr4), ptr5(ptr5), ptr6(ptr6) {}
	func_identifier(void* func_ptr, void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6, void* ptr7) : func_ptr(func_ptr), ptr1(ptr1), ptr2(ptr2), ptr3(ptr3), ptr4(ptr4), ptr5(ptr5), ptr6(ptr6), ptr7(ptr7) {}

	friend std::ostream& operator<<(std::ostream& o, const func_identifier& i) {
		o << " func_ptr(" << i.func_ptr << ")";
		if (i.ptr1 != 0x0) {
			o << " ptr1(" << i.ptr1 << ")";
		}
		if (i.ptr2 != 0x0) {
			o << " ptr2(" << i.ptr2 << ")";
		}
		if (i.ptr3 != 0x0) {
			o << " ptr3(" << i.ptr3 << ")";
		}
		if (i.ptr4 != 0x0) {
			o << " ptr4(" << i.ptr4 << ")";
		}
		if (i.ptr5 != 0x0) {
			o << " ptr5(" << i.ptr5 << ")";
		}
		if (i.ptr6 != 0x0) {
			o << " ptr6(" << i.ptr6 << ")";
		}
		if (i.ptr7 != 0x0) {
			o << " ptr7(" << i.ptr7 << ")";
		}
		return o;
	}
};


auto comparator = [](const func_identifier& left, const func_identifier& right) -> bool
{
	return (
			(intptr_t) left.func_ptr + 
			(intptr_t) left.ptr1 + 
			(intptr_t) left.ptr2 +
			(intptr_t) left.ptr3 + 
			(intptr_t) left.ptr4 + 
			(intptr_t) left.ptr5 +
			(intptr_t) left.ptr6 +
			(intptr_t) left.ptr7
			< 
			(intptr_t) right.func_ptr + 
			(intptr_t) right.ptr1 + 
			(intptr_t) right.ptr2 +
			(intptr_t) right.ptr3 +
			(intptr_t) right.ptr4 +
			(intptr_t) right.ptr5 + 
			(intptr_t) right.ptr6 + 
			(intptr_t) right.ptr7
		);
};

std::map<func_identifier, uint64_t, decltype(comparator)> last_frame_map(comparator);
std::map<func_identifier, std::string*, decltype(comparator)> tooltip_string_cache(comparator);
std::map<func_identifier, std::string*, decltype(comparator)> ship_reinforce_string_cache(comparator);
std::map<func_identifier, SCalcShipsToReinforceResult*, decltype(comparator)> ship_reinforce_struct_cache(comparator);
std::map<func_identifier, void*, decltype(comparator)> ccountry_getlatestshipdesign_ptr_cache(comparator);



void(*loixs_trampoline_func)(void* ptr1);
void(*loixs_trampoline_func2)(void* ptr1);
bool(*loixs_trampoline_func3)(void* ptr1, void* ptr2, void* ptr3);
void(*loixs_trampoline_func4)(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void * ptr6, void* ptr7);
SCalcShipsToReinforceResult* (*loixs_trampoline_func5)(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6, void* ptr7);
void *(*loixs_trampoline_func6)(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6);


__declspec(noinline) void limit_once_in_3_seconds_payload(void* ptr1) {
	void(*func_ptr)(void* ptr1);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;
	
	func_identifier fid((void*)func_ptr, ptr1);

	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		return;
	}
	last_frame_map[fid] = p_CApplication->_nCurrentFrame;


	logger << "LOIXS - limit(3 sec) - ";
	//#if DBG_PTR == 1
	logger << fid;
	//#endif
	logger.endl();

	return func_ptr(ptr1);
}
__declspec(noinline) void limit_once_in_3_seconds_payload(void* ptr1, void* ptr2) {
	void(*func_ptr)(void* ptr1, void* ptr2);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;

	func_identifier fid((void*)func_ptr, ptr1, ptr2);

	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		return;
	}
	last_frame_map[fid] = p_CApplication->_nCurrentFrame;


	logger << "LOIXS - limit(3 sec) - ";
	//#if DBG_PTR == 1
	logger << fid;
	//#endif
	logger.endl();

	return func_ptr(ptr1, ptr2);
}
__declspec(noinline) void limit_once_in_3_seconds_payload(void* ptr1, void* ptr2, void* ptr3) {
	void(*func_ptr)(void* ptr1, void* ptr2, void* ptr3);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;

	func_identifier fid((void*)func_ptr, ptr1, ptr2, ptr3);

	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		return;
	}
	last_frame_map[fid] = p_CApplication->_nCurrentFrame;

	
	logger << "LOIXS - limit(3 sec) - ";
//#if DBG_PTR == 1
	logger << fid;
//#endif
	logger.endl();
	
	return func_ptr(ptr1, ptr2, ptr3);
}
__declspec(noinline) void limit_once_in_3_seconds_payload(void* ptr1, void* ptr2, void* ptr3, void* ptr4) {
	void(*func_ptr)(void* ptr1, void* ptr2, void* ptr3, void* ptr4);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;

	func_identifier fid((void*)func_ptr, ptr1, ptr2, ptr3, ptr4);

	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		return;
	}
	last_frame_map[fid] = p_CApplication->_nCurrentFrame;


	logger << "LOIXS - limit(3 sec) - ";
	//#if DBG_PTR == 1
	logger << fid;
	//#endif
	logger.endl();

	return func_ptr(ptr1, ptr2, ptr3, ptr4);
}
__declspec(noinline) void limit_once_in_3_seconds_payload(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5) {
	void(*func_ptr)(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;

	func_identifier fid((void*)func_ptr, ptr1, ptr2, ptr3, ptr4, ptr5);

	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		return;
	}
	last_frame_map[fid] = p_CApplication->_nCurrentFrame;


	logger << "LOIXS - limit(3 sec) - ";
	//#if DBG_PTR == 1
	logger << fid;
	//#endif
	logger.endl();

	return func_ptr(ptr1, ptr2, ptr3, ptr4, ptr5);
}
__declspec(noinline) void limit_once_in_3_seconds_payload(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6) {
	void(*func_ptr)(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;

	func_identifier fid((void*)func_ptr, ptr1, ptr2, ptr3, ptr4, ptr5, ptr6);

	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		return;
	}
	last_frame_map[fid] = p_CApplication->_nCurrentFrame;


	logger << "LOIXS - limit(3 sec) - ";
	//#if DBG_PTR == 1
	logger << fid;
	//#endif
	logger.endl();

	return func_ptr(ptr1, ptr2, ptr3, ptr4, ptr5, ptr6);
}
__declspec(noinline) void limit_once_in_3_seconds_payload(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6, void* ptr7) {
	void(*func_ptr)(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6, void* ptr7);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;

	func_identifier fid((void* )func_ptr, ptr1, ptr2, ptr3, ptr4, ptr5, ptr6, ptr7);

	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		return;
	}
	last_frame_map[fid] = p_CApplication->_nCurrentFrame;


	logger << "LOIXS - limit(3 sec) - ";
	//#if DBG_PTR == 1
	logger << fid;
	//#endif
	logger.endl();

	return func_ptr(ptr1, ptr2, ptr3, ptr4, ptr5, ptr6, ptr7);
}

__declspec(noinline) void* loixs_ccountry_getlatestshipdesign(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6) {
	void*(*func_ptr)(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;

	func_identifier fid((void*)func_ptr, ptr1, ptr2, ptr3, ptr4, ptr5, ptr6);

	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		return ccountry_getlatestshipdesign_ptr_cache[fid];
	}
	last_frame_map[fid] = p_CApplication->_nCurrentFrame;
	
	
	void * ret = func_ptr(ptr1, ptr2, ptr3, ptr4, ptr5, ptr6);

	//if (ccountry_getlatestshipdesign_ptr_cache[fid] != nullptr) {
		//free(ccountry_getlatestshipdesign_ptr_cache[fid]);
	//}


	ccountry_getlatestshipdesign_ptr_cache[fid] = ret;
	//memset(ccountry_getlatestshipdesign_ptr_cache[fid], 0x0, sizeof(sizeof(void *)));
	//memcpy(ccountry_getlatestshipdesign_ptr_cache[fid], &ret, sizeof(void *));
	
	logger << "LOIXS - CCountry::GetLatestShipDesign - limit(3 sec) - ";
	//#if DBG_PTR == 1
	logger << fid;
	//#endif
	logger.endl();

	return ret;
}

__declspec(noinline) SCalcShipsToReinforceResult* loixs_calcshipstoreinforce(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6, void* ptr7) {
	SCalcShipsToReinforceResult*(*func_ptr)(void* ptr1, void* ptr2, void* ptr3, void* ptr4, void* ptr5, void* ptr6, void* ptr7);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;

	func_identifier fid((void*)func_ptr, ptr1, ptr2, ptr3, ptr4, ptr5, ptr6);
	logger << "LOIXS - calcshiptoreinforce - limit(3 sec) - ";
	//#if DBG_PTR == 1
	logger << fid;
	logger << " ptr7(" << ptr7 << ")";
	//#endif
	
	std::string* strReinforce = nullptr;
	if (ptr7 != nullptr) {
		strReinforce = (std::string*)((intptr_t)ptr7);
	}



	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		logger << " [CACHE HIT] ";
		if (ship_reinforce_string_cache[fid] != nullptr && ptr7 != nullptr) {
			std::string* strNew = new std::string(*ship_reinforce_string_cache[fid]);
			*strReinforce = *strNew;

			if (strNew != nullptr) {
				logger << " str(" << *strNew << ")";
			}
		}

		if (ship_reinforce_struct_cache[fid] != nullptr) {
			logger << " ret(" << *ship_reinforce_struct_cache[fid] << ")";
		}

		logger.endl();

		return ship_reinforce_struct_cache[fid];
	}
		

	SCalcShipsToReinforceResult* ret = func_ptr(ptr1, ptr2, ptr3, ptr4, ptr5, ptr6, ptr7);
	
	
	/*if (ptr4 == nullptr) {
		logger << " [CACHE IGNORE] ";
		logger << " ret(" << *ret << ")";
		logger.endl();
		return ret;
	}*/
	logger << " [CACHE MISS] ";

	last_frame_map[fid] = p_CApplication->_nCurrentFrame;

	if (ship_reinforce_string_cache[fid] != nullptr) {
		free(ship_reinforce_string_cache[fid]);
		free(ship_reinforce_struct_cache[fid]);
	}


	ship_reinforce_string_cache[fid] = (std::string*) malloc(sizeof(std::string));
	ship_reinforce_struct_cache[fid] = (SCalcShipsToReinforceResult *) malloc(sizeof(SCalcShipsToReinforceResult));

	memset(ship_reinforce_string_cache[fid], 0x0, sizeof(sizeof(std::string)));
	memset(ship_reinforce_struct_cache[fid], 0x0, sizeof(SCalcShipsToReinforceResult));

	if (strReinforce != nullptr) {
		//memcpy(ship_reinforce_string_cache[fid], strReinforce, sizeof(std::string));
		ship_reinforce_string_cache[fid] = new std::string(*strReinforce);
	}
	memcpy(ship_reinforce_struct_cache[fid], ret, sizeof(SCalcShipsToReinforceResult));

	logger << " ret(" << *ret << ")";
	if (strReinforce != nullptr) {
		logger << " str(" << *strReinforce << ")";
	}
	logger.endl();
	return ret;
}


__declspec(noinline) bool tooltip_payload(void* ptr1, void* ptr2, void* ptr3) {
	bool(*func_ptr)(void* ptr1, void* ptr2, void* ptr3);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint64_t limit_seconds = 3;
	const uint64_t limit_frames = limit_seconds * expected_fps;

	func_identifier fid((void*)func_ptr, ptr1, ptr2, ptr3);
	std::string* strTooltip = (std::string*)((intptr_t)ptr3);

	if (p_CApplication->_nCurrentFrame - last_frame_map[fid] < limit_frames) {
		std::string* strNew = new std::string(*tooltip_string_cache[fid]);
		*strTooltip = *strNew;

		return 1;
	}

	bool ret = func_ptr(ptr1, ptr2, ptr3);

	last_frame_map[fid] = p_CApplication->_nCurrentFrame;

	logger << "Tooltip - limit(3 sec) - ";
	
	logger << fid;
		
	if (tooltip_string_cache[fid] != nullptr) {
		free(tooltip_string_cache[fid]);
	}

	tooltip_string_cache[fid] = (std::string*) malloc(sizeof(*strTooltip));
	memcpy(tooltip_string_cache[fid], strTooltip, sizeof(*strTooltip));
	
	return ret;
}



//.text:00007FF766B63190 stellaris.exe:$B13190 #B12590 <private: void __cdecl CPlanetView::UpdatePopulationTab(void)>
//.text:00007FF766B4E490 stellaris.exe:$AFE490 #AFD890 <public: virtual void __cdecl CFleetManagerView::Update(void)>
//.text:00007FF766B6E750 stellaris.exe:$B1E750 #B1DB50 <public: virtual bool __cdecl CPlanetView::GetToolTip(class CGuiObject const *, class CToolTip &) const>

void limit_once_in_x_seconds_hook_init(enumPlatforms thisPlatform, intptr_t p_CApplication_Base, intptr_t base_augustus_ptr) {
	CLog& logger = *getLogger();

	base_func_ptr = find_address_from_symbol("CPlanetView::UpdatePopulationTab");
	base_func2_ptr = find_address_from_symbol("CFleetManagerView::Update");
	base_func3_ptr = find_address_from_symbol("CPlanetView::GetToolTip");
	base_func4_ptr = find_address_from_symbol("CEconomicUnitBase<CShipDesignEconomicUnit,CEconomicUnitScope<CShipDesign,void> >::ApplyModifiersToValue<2,0>");
	base_func5_ptr = find_address_from_symbol("CFleetTemplateManager::CalcShipsToReinforceInternal");
	base_func6_ptr = find_address_from_symbol("CCountry::GetLatestShipDesign");
	

	intptr_t this_func_ptr = (intptr_t)p_CApplication_Base + (base_func_ptr - base_augustus_ptr);
	intptr_t this_func2_ptr = (intptr_t)p_CApplication_Base + (base_func2_ptr - base_augustus_ptr);
	intptr_t this_func3_ptr = (intptr_t)p_CApplication_Base + (base_func3_ptr - base_augustus_ptr);
	intptr_t this_func4_ptr = (intptr_t)p_CApplication_Base + (base_func4_ptr - base_augustus_ptr);
	intptr_t this_func5_ptr = (intptr_t)p_CApplication_Base + (base_func5_ptr - base_augustus_ptr);
	intptr_t this_func6_ptr = (intptr_t)p_CApplication_Base + (base_func6_ptr - base_augustus_ptr);

	installHook((void*)this_func_ptr,  &loixs_trampoline_func,  static_cast<void (*)(void *)>(limit_once_in_3_seconds_payload));
	installHook((void*)this_func2_ptr, &loixs_trampoline_func2, static_cast<void (*)(void *)>(limit_once_in_3_seconds_payload));
	installHook((void*)this_func3_ptr, &loixs_trampoline_func3, tooltip_payload);
	installHook((void*)this_func4_ptr, &loixs_trampoline_func4, static_cast<void (*)(void*, void*, void*, void*, void*, void* , void*)>(limit_once_in_3_seconds_payload));
	installHook((void*)this_func5_ptr, &loixs_trampoline_func5, loixs_calcshipstoreinforce);
	//installHook((void*)this_func6_ptr, &loixs_trampoline_func6, loixs_ccountry_getlatestshipdesign);
}