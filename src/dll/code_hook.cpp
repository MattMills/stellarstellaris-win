// code_hook.cpp : function hooks that can be installed while the game runs.
//
// The target changes in one atomic 8-byte store: its first 5 bytes become a jmp to a relay next to
// it, which jumps to the replacement. The instructions the jmp covers move unchanged to a
// trampoline, followed by a jump back to the rest of the target; the other threads keep running.
//
// A thread that is between two of the moved instructions when the jmp lands would resume in the
// middle of the jmp, so the moved instructions should be one instruction of 5 bytes or more (a
// function prologue like `mov [rsp+0x10], rbx`). Otherwise the hook still works, but only if no
// thread is there at that moment.

#include "dll/code_hook.h"
#include "hooking/windows.h"

#include <fnmatch_engine.h>

#include <cstdint>
#include <cstring>

namespace {

// How many bytes of whole instructions at the start of `code` (at `address`) cover 5 bytes, or 0.
// Instructions that transfer control or are relative to RIP cannot run from the trampoline.
size_t bytes_to_move(const uint8_t* code, size_t size, uint64_t address, const char** error) {
	size_t moved = 0;
	while (moved < 5) {
		fnme_instruction instruction{};
		const uint32_t length = fnme_decode(code + moved, size - moved, address + moved, &instruction, nullptr, 0);
		if (length == 0) {
			*error = "cannot decode the first instructions of the target";
			return 0;
		}
		if (instruction.flow != FNME_FLOW_NEXT || instruction.rip_relative) {
			*error = "the first instructions of the target are relative to RIP or transfer control";
			return 0;
		}
		moved += length;
	}
	return moved;
}

// `jmp [rip+0]` followed by the address: 14 bytes.
void write_absolute_jump(uint8_t* at, const void* to) {
	const uint8_t jmp[] = {0xFF, 0x25, 0x00, 0x00, 0x00, 0x00};
	const uint64_t target = reinterpret_cast<uint64_t>(to);
	std::memcpy(at, jmp, sizeof(jmp));
	std::memcpy(at + sizeof(jmp), &target, sizeof(target));
}

} // namespace

bool install_code_hook(void* target_pointer, void* replacement, void** original, const char** error) {
	uint8_t* target = static_cast<uint8_t*>(target_pointer);
	*error = nullptr;

	uint8_t code[32];
	SIZE_T read = 0;
	if (!ReadProcessMemory(GetCurrentProcess(), target, code, sizeof(code), &read) || read != sizeof(code)) {
		*error = "cannot read the target";
		return false;
	}
	if (code[0] == 0xE9 || code[0] == 0xEB) {
		*error = "the target starts with a jmp (hooked already?)";
		return false;
	}
	const size_t moved = bytes_to_move(code, sizeof(code), reinterpret_cast<uint64_t>(target), error);
	if (moved == 0) {
		return false;
	}

	// the 5-byte jmp has to land in one aligned 8-byte word
	uint8_t* word = reinterpret_cast<uint8_t*>(reinterpret_cast<uintptr_t>(target) & ~uintptr_t(7));
	const size_t offset = static_cast<size_t>(target - word);
	if (offset + 5 > 8) {
		*error = "the target is not aligned so that the jmp can be written at once";
		return false;
	}

	// relay at +0, trampoline at +16, in a page within reach of a rel32 jmp
	uint8_t* page = static_cast<uint8_t*>(AllocatePageNearAddress(target));
	if (page == nullptr) {
		*error = "no free page near the target";
		return false;
	}
	const int64_t distance = reinterpret_cast<int64_t>(page) - reinterpret_cast<int64_t>(target + 5);
	if (distance < INT32_MIN || distance > INT32_MAX) {
		VirtualFree(page, 0, MEM_RELEASE);
		*error = "the page near the target is out of reach";
		return false;
	}
	write_absolute_jump(page, replacement);
	uint8_t* trampoline = page + 16;
	std::memcpy(trampoline, code, moved);
	write_absolute_jump(trampoline + moved, target + moved);
	DWORD protect = 0;
	VirtualProtect(page, 4096, PAGE_EXECUTE_READ, &protect);
	FlushInstructionCache(GetCurrentProcess(), page, 4096);

	// the jmp; the replacement can run as soon as it is written
	*original = trampoline;
	if (!VirtualProtect(word, 8, PAGE_EXECUTE_READWRITE, &protect)) {
		VirtualFree(page, 0, MEM_RELEASE);
		*original = nullptr;
		*error = "VirtualProtect failed on the target";
		return false;
	}
	const int64_t before = *reinterpret_cast<volatile int64_t*>(word);
	if (std::memcmp(reinterpret_cast<const uint8_t*>(&before) + offset, code, 8 - offset) != 0) {
		DWORD ignored = 0;
		VirtualProtect(word, 8, protect, &ignored);
		VirtualFree(page, 0, MEM_RELEASE);
		*original = nullptr;
		*error = "the target changed while the hook was prepared";
		return false;
	}
	int64_t after = before;
	uint8_t* bytes = reinterpret_cast<uint8_t*>(&after) + offset;
	const int32_t rel32 = static_cast<int32_t>(distance);
	bytes[0] = 0xE9;
	std::memcpy(bytes + 1, &rel32, 4);
	const bool written = InterlockedCompareExchange64(reinterpret_cast<volatile LONG64*>(word), after, before) == before;
	DWORD ignored = 0;
	VirtualProtect(word, 8, protect, &ignored);
	FlushInstructionCache(GetCurrentProcess(), word, 8);
	if (!written) {
		VirtualFree(page, 0, MEM_RELEASE);
		*original = nullptr;
		*error = "the target changed while the hook was installed";
		return false;
	}
	return true;
}
