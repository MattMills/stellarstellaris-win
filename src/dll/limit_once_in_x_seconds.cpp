
#include "limit_once_in_x_seconds.h"

#include <map>

extern CLog logger;

intptr_t base_func_ptr = 0x0;// CPlanetView::UpdatePopulationTab(void * this)
intptr_t base_steam_func_ptr = 0x140b19f80;
intptr_t base_gog_func_ptr = 0x140B13190; 

intptr_t base_func2_ptr = 0x0; // CFleetManagerView::Update(void * this)>
intptr_t base_steam_func2_ptr = 0x0;
intptr_t base_gog_func2_ptr = 0x140AFE490;

intptr_t base_func3_ptr = 0x0; // CPlanetView::GetToolTip(void * this, class CGuiObject const *, class CToolTip &)
intptr_t base_steam_func3_ptr = 0x140b25540;
intptr_t base_gog_func3_ptr = 0x140B1E750;

intptr_t base_func4_ptr = 0x0;
intptr_t base_steam_func4_ptr = 0x0;
intptr_t base_gog_func4_ptr = 0x140298750;

intptr_t base_func5_ptr = 0x0;
intptr_t base_steam_func5_ptr = 0x0;
intptr_t base_gog_func5_ptr = 0x140498310;


struct func_identifier {
	void* func_ptr = 0x0;
	void* ptr1 = 0x0;
	void* ptr2 = 0x0;
	void* ptr3 = 0x0;

	func_identifier(void* func_ptr) : func_ptr(func_ptr) {}
	func_identifier(void* func_ptr, void* ptr1) : func_ptr(func_ptr), ptr1(ptr1) {}
	func_identifier(void* func_ptr, void* ptr1, void* ptr2) : func_ptr(func_ptr), ptr1(ptr1), ptr2(ptr2) {}
	func_identifier(void* func_ptr, void* ptr1, void* ptr2, void* ptr3) : func_ptr(func_ptr), ptr1(ptr1), ptr2(ptr2), ptr3(ptr3) {}

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

		return o;
	}
};

auto comparator = [](const func_identifier& left, const func_identifier& right) -> bool
{
	return (
			(intptr_t) left.func_ptr + 
			(intptr_t) left.ptr1 + 
			(intptr_t) left.ptr2 +
			(intptr_t) left.ptr3
			< 
			(intptr_t) right.func_ptr + 
			(intptr_t) right.ptr1 + 
			(intptr_t) right.ptr2 +
			(intptr_t) right.ptr3
		);
};

std::map<func_identifier, uint64_t, decltype(comparator)> last_timestamp_map(comparator);
std::map<func_identifier, std::string*, decltype(comparator)> tooltip_string_cache(comparator);



void(*loixs_trampoline_func)(void* ptr1);
void(*loixs_trampoline_func2)(void* ptr1);
bool(*loixs_trampoline_func3)(void* ptr1, void* ptr2, void* ptr3);
void(*loixs_trampoline_func4)(void* ptr1, void* ptr2, void* ptr3);
void(*loixs_trampoline_func5)(void* ptr1, void* ptr2, void* ptr3);


__declspec(noinline) void limit_once_in_3_seconds_payload(void* ptr1) {
	void(*func_ptr)(void* ptr1);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint32_t limit_ms = 3000;

	func_identifier fid((void*)func_ptr, ptr1);

	if (logger.get_timestamp() - last_timestamp_map[fid] < logger.ONE_MILLISECOND * limit_ms) {
		return;
	}
	last_timestamp_map[fid] = logger.get_timestamp();


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

	const uint32_t limit_ms = 3000;

	func_identifier fid((void*)func_ptr, ptr1, ptr2);

	if (logger.get_timestamp() - last_timestamp_map[fid] < logger.ONE_MILLISECOND * limit_ms) {
		return;
	}
	last_timestamp_map[fid] = logger.get_timestamp();


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

	const uint32_t limit_ms = 3000;

	func_identifier fid((void*)func_ptr, ptr1, ptr2, ptr3);

	if (logger.get_timestamp() - last_timestamp_map[fid] < logger.ONE_MILLISECOND*limit_ms) {
		return;
	}
	last_timestamp_map[fid] = logger.get_timestamp();

	
	logger << "LOIXS - limit(3 sec) - ";
//#if DBG_PTR == 1
	logger << fid;
//#endif
	logger.endl();
	
	return func_ptr(ptr1, ptr2, ptr3);
}


__declspec(noinline) bool tooltip_payload(void* ptr1, void* ptr2, void* ptr3) {
	bool(*func_ptr)(void* ptr1, void* ptr2, void* ptr3);
	PopAddress(uint64_t(&func_ptr));
	CLog& logger = *getLogger();

	const uint32_t limit_ms = 3000;

	func_identifier fid((void*)func_ptr, ptr1, ptr2, ptr3);
	std::string* strTooltip = (std::string*)((intptr_t)ptr3);

	if (last_timestamp_map.count(fid) > 0 && logger.get_timestamp() - last_timestamp_map[fid] < logger.ONE_MILLISECOND * limit_ms) {
		std::string* strNew = new std::string(*tooltip_string_cache[fid]);
		*strTooltip = *strNew;

		return 1;
	}

	bool ret = func_ptr(ptr1, ptr2, ptr3);

	last_timestamp_map[fid] = logger.get_timestamp();

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
	if (thisPlatform == STEAM) {
		base_func_ptr = base_steam_func_ptr;
		base_func2_ptr = base_steam_func2_ptr;
		base_func3_ptr = base_steam_func3_ptr;
		base_func4_ptr = base_steam_func4_ptr;
		base_func5_ptr = base_steam_func5_ptr;
	}
	else if (thisPlatform == GOG) {
		base_func_ptr = base_gog_func_ptr;
		base_func2_ptr = base_gog_func2_ptr;
		base_func3_ptr = base_gog_func3_ptr;
		base_func4_ptr = base_gog_func4_ptr;
		base_func5_ptr = base_gog_func5_ptr;
	}

	intptr_t this_func_ptr = (intptr_t)p_CApplication_Base + (base_func_ptr - base_augustus_ptr);
	intptr_t this_func2_ptr = (intptr_t)p_CApplication_Base + (base_func2_ptr - base_augustus_ptr);
	intptr_t this_func3_ptr = (intptr_t)p_CApplication_Base + (base_func3_ptr - base_augustus_ptr);
	//intptr_t this_func4_ptr = (intptr_t)p_CApplication_Base + (base_func4_ptr - base_augustus_ptr);
	//intptr_t this_func5_ptr = (intptr_t)p_CApplication_Base + (base_func5_ptr - base_augustus_ptr);

	installHook((void*)this_func_ptr,  &loixs_trampoline_func,  static_cast<void (*)(void *)>(limit_once_in_3_seconds_payload));
	installHook((void*)this_func2_ptr, &loixs_trampoline_func2, static_cast<void (*)(void*)>(limit_once_in_3_seconds_payload));
	installHook((void*)this_func3_ptr, &loixs_trampoline_func3, tooltip_payload);
	//installHook((void*)this_func4_ptr, &loixs_trampoline_func4, limit_once_in_3_seconds_payload);
	//installHook((void*)this_func5_ptr, &loixs_trampoline_func5, limit_once_in_3_seconds_payload);
}