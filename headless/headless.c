// headless.c: an LD_PRELOAD library that drives the real Stellaris 4.5.2 Linux build as a
// simulation oracle: load a save, run an exact number of ticks without rendering, write the
// gamestate, exit.
//
// Every address comes from the executable's own symbol table (it is not stripped) plus the load
// base. Nothing is hard-coded but a few field offsets, each read from the game's disassembly and
// named where it is used.
//
// Environment:
//   HEADLESS_SAVE     save to load, a path the game's file system resolves (relative to the user
//                     dir, e.g. "save games/headless/x.sav"; default "save games/headless/save.sav")
//   HEADLESS_TICKS    number of ticks to run (default 10)
//   HEADLESS_OUT      gamestate output path, relative to the game's user dir (VFS write dir)
//                     or absolute (default "headless_out.gamestate")
//   HEADLESS_MODE     "loop" (default): all ticks in one frame, the game's own tick command and
//                     session update, nothing rendered; "frame": one turn (NUM_COMMANDS_PER_TURN
//                     ticks) per frame, the main loop running as in play
//   HEADLESS_DLCS     DLC names (as in .dlc "name" and the save's required_dlcs) separated by
//                     ';'. These are owned, every other is not. Unset: every DLC is owned.
//   HEADLESS_WAIT     frames to wait in game before the first tick (default 5)
//   HEADLESS_TIMEOUT  seconds before the watchdog kills the process (default 1200)
//   HEADLESS_LOG      log file (default: stderr)
//   HEADLESS_RNG_POS  after the load, set the synchronized generator's position to this (the
//                     save's random_count, to undo the draws the load makes)
//   HEADLESS_PROFILE  call-site table (dev/callsites.py): count the generator's draws per site
//   HEADLESS_PROFILE_OUT  where the per-site table is written at the end
#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <link.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

// ---------------------------------------------------------------- log

static double g_t0;
static FILE *g_log;

static double now(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void hlog(const char *fmt, ...) {
	FILE *f = g_log ? g_log : stderr;
	va_list ap;
	va_start(ap, fmt);
	fprintf(f, "[headless %9.3f] ", now() - g_t0);
	vfprintf(f, fmt, ap);
	fputc('\n', f);
	fflush(f);
	va_end(ap);
}

static void die(int code, const char *msg) {
	hlog("FATAL: %s", msg);
	_exit(code);
}

// ---------------------------------------------------------------- symbols

static uintptr_t g_base;

static int base_cb(struct dl_phdr_info *info, size_t size, void *data) {
	(void)size;
	if (info->dlpi_name == NULL || info->dlpi_name[0] == 0) {
		*(uintptr_t *)data = info->dlpi_addr;
		return 1;
	}
	return 0;
}

struct symreq {
	const char *name;
	uintptr_t *out;
};

// One pass over the executable's .symtab: each requested (mangled) name gets base + value.
static int resolve(struct symreq *reqs) {
	int fd = open("/proc/self/exe", O_RDONLY);
	if (fd < 0) return -1;
	struct stat st;
	fstat(fd, &st);
	uint8_t *m = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (m == MAP_FAILED) return -1;
	Elf64_Ehdr *eh = (Elf64_Ehdr *)m;
	Elf64_Shdr *sh = (Elf64_Shdr *)(m + eh->e_shoff);
	int missing = 0;
	for (int i = 0; i < eh->e_shnum; i++) {
		if (sh[i].sh_type != SHT_SYMTAB) continue;
		Elf64_Sym *syms = (Elf64_Sym *)(m + sh[i].sh_offset);
		size_t n = sh[i].sh_size / sizeof(Elf64_Sym);
		const char *strtab = (const char *)(m + sh[sh[i].sh_link].sh_offset);
		for (size_t k = 0; k < n; k++) {
			if (syms[k].st_value == 0) continue;
			const char *name = strtab + syms[k].st_name;
			for (struct symreq *r = reqs; r->name; r++)
				if (*r->out == 0 && strcmp(name, r->name) == 0) *r->out = g_base + syms[k].st_value;
		}
	}
	for (struct symreq *r = reqs; r->name; r++)
		if (*r->out == 0) {
			hlog("symbol not found: %s", r->name);
			missing++;
		}
	munmap(m, st.st_size);
	return missing;
}

// Overwrites a function's first 12 bytes with `movabs rax, to; jmp rax`. The original is never
// called again (every hook here replaces its function).
static void detour(uintptr_t at, void *to) {
	uint8_t code[12] = {0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0};
	memcpy(code + 2, &to, 8);
	uintptr_t page = at & ~(uintptr_t)0xfff;
	size_t len = ((at + sizeof code + 0xfff) & ~(uintptr_t)0xfff) - page;
	if (mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) die(2, "mprotect");
	memcpy((void *)at, code, sizeof code);
	mprotect((void *)page, len, PROT_READ | PROT_EXEC);
	__builtin___clear_cache((char *)at, (char *)at + sizeof code);
}

// ---------------------------------------------------------------- the game's functions and data

static uintptr_t a_VerifyAllDLCOwnership;   // CDLCManager::VerifyAllDLCOwnership(bool)
static uintptr_t a_CheckTick;               // CInGameIdler::CheckTick(float)
static uintptr_t a_PostCommandToSession;    // PostCommandToSession(CCommand*, bool)
static uintptr_t a_GameApplicationUpdate;   // CGameApplication::Update()
static uintptr_t a_AccessApplication;       // CApplication::AccessInstance()
static uintptr_t a_GetTotalTicks;           // CGameState::GetTotalTicks() const
static uintptr_t a_SaveGameCheckMakeSave;   // SaveGameCheckMakeSave(CString)
static uintptr_t a_CStringCtor;             // CString::CString(char const*)
static uintptr_t a_vt_TurnTickCommand;      // vtable for CTurnTickCommand
static uintptr_t a_vt_ArrayULL;             // vtable for CPdxArray<unsigned long long, int>
static uintptr_t a_vt_ArrayPlayerTick;      // vtable for CPdxArray<CTurnTickCommand::CPlayerCurrentTick, int>
static uintptr_t a_g_CurrentGameState;      // CGameState*
static uintptr_t a_g_bFrameSmoothing;       // bool
static uintptr_t a_g_AllowGetPlayer;        // bool
static uintptr_t a_g_AllowGlobalGameStateAccess; // bool
static uintptr_t a_g_AllowPostCommandToSession;  // bool
static uintptr_t a_NUM_COMMANDS_PER_TURN;   // NDefines::NGameplay::NUM_COMMANDS_PER_TURN (int)
static uintptr_t a_LaunchSave;              // CFrontEndIdler::LaunchSave(CString const&, bool, CMultiplayerConfiguration const&)
static uintptr_t a_FrontendDlcViewUpdate;   // CFrontendDlcView::Update()
static uintptr_t a_g_CurrentFrontEndIdler;  // CFrontEndIdler*
static uintptr_t a_InGameRenderInternal;   // CInGameIdler::RenderInternal(bool)
static uintptr_t a_Random;                  // CRandom::_Random: CNoiseRandom { uint32 position; uint32 seed }
static uintptr_t a_nRandomCount;            // CSystem::_nRandomCount (the position CSetRandomSeed syncs from)
static uintptr_t a_EnableTaskThreads;       // NPdxThreadUtilDetail::g_bEnableTaskThreads

static struct symreq g_syms[] = {
	{"_ZN11CDLCManager21VerifyAllDLCOwnershipEb", &a_VerifyAllDLCOwnership},
	{"_ZN12CInGameIdler9CheckTickEf", &a_CheckTick},
	{"_Z20PostCommandToSessionP8CCommandb", &a_PostCommandToSession},
	{"_ZN16CGameApplication6UpdateEv", &a_GameApplicationUpdate},
	{"_ZN12CApplication14AccessInstanceEv", &a_AccessApplication},
	{"_ZNK10CGameState13GetTotalTicksEv", &a_GetTotalTicks},
	{"_Z21SaveGameCheckMakeSave7CString", &a_SaveGameCheckMakeSave},
	{"_ZN7CStringC1EPKc", &a_CStringCtor},
	{"_ZTV16CTurnTickCommand", &a_vt_TurnTickCommand},
	{"_ZTV9CPdxArrayIyiE", &a_vt_ArrayULL},
	{"_ZTV9CPdxArrayIN16CTurnTickCommand18CPlayerCurrentTickEiE", &a_vt_ArrayPlayerTick},
	{"g_CurrentGameState", &a_g_CurrentGameState},
	{"g_bFrameSmoothing", &a_g_bFrameSmoothing},
	{"g_AllowGetPlayer", &a_g_AllowGetPlayer},
	{"g_AllowGlobalGameStateAccess", &a_g_AllowGlobalGameStateAccess},
	{"g_AllowPostCommandToSession", &a_g_AllowPostCommandToSession},
	{"_ZN8NDefines9NGameplay21NUM_COMMANDS_PER_TURNE", &a_NUM_COMMANDS_PER_TURN},
	{"_ZN14CFrontEndIdler10LaunchSaveERK7CStringbRK25CMultiplayerConfiguration", &a_LaunchSave},
	{"_ZN16CFrontendDlcView6UpdateEv", &a_FrontendDlcViewUpdate},
	{"g_CurrentFrontEndIdler", &a_g_CurrentFrontEndIdler},
	{"_ZN12CInGameIdler14RenderInternalEb", &a_InGameRenderInternal},
	{"_ZN7CRandom7_RandomE", &a_Random},
	{"_ZN7CSystem13_nRandomCountE", &a_nRandomCount},
	{"_ZN20NPdxThreadUtilDetail20g_bEnableTaskThreadsE", &a_EnableTaskThreads},
	{NULL, NULL},
};

#define U8(a) (*(volatile uint8_t *)(a))
#define I32(a) (*(volatile int32_t *)(a))

static void *game_state(void) { return *(void **)a_g_CurrentGameState; }

static int total_ticks(void *gs) { return ((int (*)(void *))a_GetTotalTicks)(gs); }

// CString (0x30 bytes): +0 int, +8 qword, +0x10 std::string with CPdxCommonStringAllocator
// (+0x10 char*, +0x18 size, +0x20 local buffer).
static const char *cstring_ptr(const void *s, size_t *len) {
	*len = *(const size_t *)((const char *)s + 0x18);
	return *(const char *const *)((const char *)s + 0x10);
}

// ---------------------------------------------------------------- random-draw profiler
//
// HEADLESS_PROFILE=<sites.tsv> (from dev/callsites.py): each listed `call rel32` / `jmp rel32`
// site is redirected to a small stub near the executable (`mov r11d, site; jmp hk_entry`).
// hk_entry records the synchronized generator's position (CRandom::_Random+0), swaps the return
// address for hk_post and jumps to the original target with the stack and argument registers
// untouched (so stack-passed arguments still work); hk_post adds the position delta to the site
// and returns to the real return address. The table (inclusive draws per call site) goes to
// HEADLESS_PROFILE_OUT at the end of the run.

// Three more uses of the same hook, for tracing where the random pools go:
//
// HEADLESS_OVERRIDE="<site>=<mode>[,...]": after the call at <site> (hex offset) returns, replace
//   the values it produced: for CRandom::GetIntegersForMacro(name, line, int *out, count) the
//   `count` ints at `out`, for any other callee the int it returns. Modes: zero, xor (each value
//   ^ 0x5bd1e995), const:N. The generator itself advances as usual.
// HEADLESS_TICKLOG=<file>, HEADLESS_WATCH="<site>,...": one line per tick (at the return of
//   HandleTurnTick): the tick, the draws in it, and how many times each watched site was called.
// HEADLESS_POOLTRACK=<file>: counts the reads of the daily pool (the 1,000 values DailyUpdate
//   draws at HEADLESS_POOL_DAILY, default 1b1c948, kept at rbp-0x2420 of DailyUpdate's frame and
//   copied to rbp-0x1478 for the pop groups) and of the monthly pool (the buffer of the
//   GetIntegersForMacro at HEADLESS_POOL_MONTHLY, default 1b2d746). The values are mirrored into
//   a page of our own (a memfd mapped twice: one view to write, one kept PROT_NONE); at every
//   instrumented call an argument register that points into a live pool is switched to the
//   mirror, so the callee and everything below it read the mirror: each read faults, is counted
//   (by consumer site, by instruction, by index), and is single-stepped with the page open. Task
//   threads are turned off (g_bEnableTaskThreads) so the reads happen on the main thread.

struct site {
	uintptr_t addr, target;
	char *caller, *callee, kind[8];
	int override_mode, override_const, pool_kind; // pool_kind: 1 daily fill, 2 monthly fill
	int consumer;                                 // the callee takes an `int const*` / `int*`
	uint64_t calls, draws;
	uint64_t pool_reads[2], swapped_calls;
};
enum { OV_NONE, OV_ZERO, OV_XOR, OV_CONST };
static struct site *g_sites;
static int g_nsites;
static int g_prof_on;
static int g_site_htt = -1; // the tick: CTurnTickCommand::Execute's tail jump to HandleTurnTick
struct pframe {
	void *ret;
	uint32_t pos;
	int site;
	uint64_t a2, a3; // rdx, rcx at the call
	int swapped;
};
static __thread struct pframe t_frames[256];
static __thread int t_depth;

static inline uint32_t rng_pos(void) { return *(volatile uint32_t *)a_Random; }
static inline uint32_t rng_seed(void) { return *(volatile uint32_t *)(a_Random + 4); }

// --- pool tracking state
#define NSLOT 2 // 0 the daily pool, 1 the monthly pool
static int g_track;
static uint8_t *g_rw, *g_view; // the two views of the mirror, NSLOT pages each
struct prange {
	uintptr_t base;
	size_t len;
	int slot;
};
static struct prange g_ranges[4];
static int g_nranges;
static uint32_t g_daily_k;
static volatile int g_trk_lock;
static __thread int t_stepping;
static __thread int t_cons[64];
static __thread int t_ncons;
static uint64_t g_reads[NSLOT], g_writes[NSLOT], g_unattributed[NSLOT];
static uint8_t g_seen[NSLOT][1024];
static uint64_t g_distinct_sum[NSLOT], g_distinct_max[NSLOT];
static int g_periods[NSLOT];
#define NPC 4096
static uintptr_t g_pc_key[NPC];
static uint64_t g_pc_reads[NPC][NSLOT];

static FILE *g_ticklog;
static int g_watch[32], g_nwatch;
static uint64_t g_watch_prev[32];
static uint32_t g_tick_pos;
// HEADLESS_TRACE=<from>-<to> (total ticks), HEADLESS_TRACE_OUT=<file>: every instrumented call
// that draws, in the turns that start in that range, in order: the order of the draws in a tick.
static long g_trace_from = -1, g_trace_to = -1;
static FILE *g_trace;
static int g_trace_turn, g_trace_tick;

static void period_close(int slot) {
	int n = 0;
	for (int i = 0; i < 1024; i++) n += g_seen[slot][i];
	if (g_periods[slot] || n) {
		g_distinct_sum[slot] += n;
		if ((uint64_t)n > g_distinct_max[slot]) g_distinct_max[slot] = n;
	}
	memset(g_seen[slot], 0, sizeof g_seen[slot]);
}

static void ranges_drop(int slot) {
	int j = 0;
	for (int i = 0; i < g_nranges; i++)
		if (g_ranges[i].slot != slot) g_ranges[j++] = g_ranges[i];
	g_nranges = j;
}

static void range_add(uintptr_t base, size_t len, int slot) {
	if (len > 4096) len = 4096;
	if (g_nranges < 4) g_ranges[g_nranges++] = (struct prange){base, len, slot};
}

#define HIDDEN __attribute__((visibility("hidden")))
HIDDEN void hk_entry(void);
HIDDEN void hk_post(void);
HIDDEN void *hk_before(long site, void **retslot, uintptr_t rbp);
HIDDEN void *hk_after(uint64_t *rax_slot);

void *hk_before(long site, void **retslot, uintptr_t rbp) {
	if (t_depth >= 256) die(5, "profiler: call depth");
	struct pframe *f = &t_frames[t_depth++];
	uintptr_t *regs = (uintptr_t *)retslot; // saved by hk_entry: [-1] rdi [-2] rsi [-3] rdx [-4] rcx [-5] r8 [-6] r9
	f->ret = *retslot;
	f->pos = rng_pos();
	f->site = (int)site;
	f->a2 = regs[-3];
	f->a3 = regs[-4];
	f->swapped = 0;
	struct site *s = &g_sites[site];
	if (g_track && g_prof_on) {
		if (s->pool_kind == 1) {
			if (g_daily_k == 0) { // the first of the day's 1,000
				period_close(0);
				g_periods[0]++;
				ranges_drop(0);
				range_add(rbp - 0x2420, 4000, 0); // the pool, in DailyUpdate's frame
				range_add(rbp - 0x1478, 4000, 0); // its copy in the pop groups' functor (memcpy at 0x1b21e6a)
			}
		} else if (s->pool_kind == 2) {
			period_close(1);
			g_periods[1]++;
			ranges_drop(1);
			range_add(regs[-3], (size_t)(uint32_t)regs[-4] * 4, 1);
		} else if (g_nranges && s->consumer) {
			// Only calls to functions that take an int pointer: elsewhere a pointer into the
			// pool's stack range may be another object that reuses the slot.
			for (int r = 1; r <= 6; r++) {
				uintptr_t v = regs[-r];
				for (int k = 0; k < g_nranges; k++)
					if (v >= g_ranges[k].base && v < g_ranges[k].base + g_ranges[k].len) {
						regs[-r] = (uintptr_t)g_view + g_ranges[k].slot * 4096 + (v - g_ranges[k].base);
						f->swapped = 1;
						break;
					}
			}
			if (f->swapped) {
				if (t_ncons < 64) t_cons[t_ncons++] = (int)site;
				__atomic_add_fetch(&s->swapped_calls, 1, __ATOMIC_RELAXED);
			}
		}
	}
	if (g_trace_turn && (int)site == g_site_htt) {
		g_trace_tick = total_ticks(game_state());
		fprintf(g_trace, "%d\t%u\t-\t%d\tHandleTurnTick begins\t\n", g_trace_tick, f->pos, t_depth - 1);
	}
	*retslot = (void *)hk_post;
	return (void *)s->target;
}

static long g_override_from = -1; // HEADLESS_OVERRIDE_FROM: only from this total tick count on

static void apply_override(struct pframe *f, uint64_t *rax_slot) {
	struct site *s = &g_sites[f->site];
	if (g_override_from >= 0 && total_ticks(game_state()) < g_override_from) return;
	int is_array = strstr(s->callee, "GetIntegersForMacro") != NULL;
	int32_t *v = is_array ? (int32_t *)f->a2 : (int32_t *)rax_slot;
	uint32_t n = is_array ? (uint32_t)f->a3 : 1;
	for (uint32_t i = 0; i < n; i++) {
		if (s->override_mode == OV_ZERO) v[i] = 0;
		else if (s->override_mode == OV_XOR) v[i] ^= 0x5bd1e995;
		else if (s->override_mode == OV_CONST) v[i] = s->override_const;
	}
}

void *hk_after(uint64_t *rax_slot) {
	struct pframe *f = &t_frames[--t_depth];
	struct site *s = &g_sites[f->site];
	if (g_prof_on) {
		__atomic_add_fetch(&s->calls, 1, __ATOMIC_RELAXED);
		__atomic_add_fetch(&s->draws, (uint32_t)(rng_pos() - f->pos), __ATOMIC_RELAXED);
		if (s->override_mode) apply_override(f, rax_slot);
		if (g_track) {
			if (s->pool_kind == 1) {
				((uint32_t *)g_rw)[g_daily_k] = (uint32_t)*rax_slot; // the value the caller stores
				g_daily_k = (g_daily_k + 1) % 1000;
			} else if (s->pool_kind == 2) {
				uint32_t n = (uint32_t)f->a3;
				memcpy(g_rw + 4096, (void *)f->a2, n * 4 > 4096 ? 4096 : n * 4);
			} else if (strstr(s->callee, "CGameState::DailyUpdate()") == s->callee) {
				ranges_drop(0); // DailyUpdate's frame is gone
			} else if (strstr(s->callee, "CGameState::MonthlyUpdate()") == s->callee) {
				ranges_drop(1);
			}
			if (f->swapped && t_ncons) t_ncons--;
		}
		if (g_trace_turn) {
			uint32_t d = rng_pos() - f->pos;
			if (d || f->site == g_site_htt)
				fprintf(g_trace, "%d\t%u\t%u\t%d\t%s\t%s\n", g_trace_tick, f->pos, d, t_depth, s->caller, s->callee);
		}
		if (f->site == g_site_htt && g_ticklog) {
			void *gs = game_state();
			uint32_t p = rng_pos();
			fprintf(g_ticklog, "%d\t%u", total_ticks(gs), p - g_tick_pos);
			g_tick_pos = p;
			for (int i = 0; i < g_nwatch; i++) {
				uint64_t c = g_sites[g_watch[i]].calls;
				fprintf(g_ticklog, "\t%llu", (unsigned long long)(c - g_watch_prev[i]));
				g_watch_prev[i] = c;
			}
			fputc('\n', g_ticklog);
		}
	}
	return f->ret;
}

// A read (or write) of the mirror: count it, open the page, single-step the instruction.
static struct sigaction g_old_segv, g_old_trap;

static void chain(struct sigaction *old, int sig, siginfo_t *si, void *ctx) {
	if (old->sa_flags & SA_SIGINFO) {
		if (old->sa_sigaction) old->sa_sigaction(sig, si, ctx);
	} else if (old->sa_handler == SIG_DFL || old->sa_handler == SIG_IGN) {
		sigaction(sig, old, NULL); // returns, faults again, and the default action happens
	} else {
		old->sa_handler(sig);
	}
}

static void segv_handler(int sig, siginfo_t *si, void *ctx) {
	uintptr_t a = (uintptr_t)si->si_addr;
	if (g_view && a >= (uintptr_t)g_view && a < (uintptr_t)g_view + NSLOT * 4096) {
		ucontext_t *uc = ctx;
		while (__atomic_exchange_n(&g_trk_lock, 1, __ATOMIC_ACQUIRE))
			;
		int slot = (int)((a - (uintptr_t)g_view) / 4096);
		int idx = (int)(((a - (uintptr_t)g_view) % 4096) / 4);
		if (uc->uc_mcontext.gregs[REG_ERR] & 2) g_writes[slot]++;
		else g_reads[slot]++;
		if (idx < 1024) g_seen[slot][idx] = 1;
		if (t_ncons) g_sites[t_cons[t_ncons - 1]].pool_reads[slot]++;
		else g_unattributed[slot]++;
		uintptr_t pc = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP] - g_base;
		for (uint32_t h = (uint32_t)(pc * 2654435761u) % NPC, n = 0; n < NPC; n++, h = (h + 1) % NPC)
			if (g_pc_key[h] == pc || g_pc_key[h] == 0) {
				g_pc_key[h] = pc;
				g_pc_reads[h][slot]++;
				break;
			}
		mprotect(g_view, NSLOT * 4096, PROT_READ | PROT_WRITE);
		uc->uc_mcontext.gregs[REG_EFL] |= 0x100; // trap after this instruction
		t_stepping = 1;
		return;
	}
	chain(&g_old_segv, sig, si, ctx);
}

static void trap_handler(int sig, siginfo_t *si, void *ctx) {
	if (t_stepping) {
		ucontext_t *uc = ctx;
		mprotect(g_view, NSLOT * 4096, PROT_NONE);
		uc->uc_mcontext.gregs[REG_EFL] &= ~0x100;
		t_stepping = 0;
		__atomic_store_n(&g_trk_lock, 0, __ATOMIC_RELEASE);
		return;
	}
	chain(&g_old_trap, sig, si, ctx);
}

static void track_start(void) {
	int fd = memfd_create("headless_pools", 0);
	if (fd < 0 || ftruncate(fd, NSLOT * 4096) != 0) die(2, "pooltrack: memfd");
	g_rw = mmap(NULL, NSLOT * 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	g_view = mmap(NULL, NSLOT * 4096, PROT_NONE, MAP_SHARED, fd, 0);
	if (g_rw == MAP_FAILED || g_view == MAP_FAILED) die(2, "pooltrack: mmap");
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_flags = SA_SIGINFO | SA_NODEFER;
	sigemptyset(&sa.sa_mask);
	sa.sa_sigaction = segv_handler;
	sigaction(SIGSEGV, &sa, &g_old_segv);
	sa.sa_sigaction = trap_handler;
	sigaction(SIGTRAP, &sa, &g_old_trap);
	U8(a_EnableTaskThreads) = 0;
	g_track = 1;
	hlog("pooltrack: mirror at %p, task threads off", (void *)g_view);
}

static void track_write(const char *path, int ticks) {
	FILE *f = fopen(path, "w");
	if (!f) return;
	const char *name[NSLOT] = {"daily", "monthly"};
	for (int s = 0; s < NSLOT; s++) {
		period_close(s);
		fprintf(f, "# %s pool: %d fills, %llu reads (%.1f a fill), %llu writes, %llu reads outside an "
		           "instrumented call; distinct values read a fill: %.1f average, %llu max (of 1000)\n",
		        name[s], g_periods[s], (unsigned long long)g_reads[s],
		        g_periods[s] ? (double)g_reads[s] / g_periods[s] : 0.0, (unsigned long long)g_writes[s],
		        (unsigned long long)g_unattributed[s], g_periods[s] ? (double)g_distinct_sum[s] / g_periods[s] : 0.0,
		        (unsigned long long)g_distinct_max[s]);
	}
	fprintf(f, "# over %d ticks\n#\n# reads by consumer (the instrumented call the pointer went through)\n", ticks);
	fprintf(f, "# (consumer sites called with no pool pointer are listed with 0 reads: they read a copy\n"
	           "# this does not follow, or were called outside DailyUpdate / MonthlyUpdate)\n");
	fprintf(f, "consumer_site\tcaller\tcallee\tcalls\tcalls_with_pool\tdaily_reads\tmonthly_reads\n");
	for (int i = 0; i < g_nsites; i++)
		if (g_sites[i].consumer && g_sites[i].calls)
			fprintf(f, "%lx\t%s\t%s\t%llu\t%llu\t%llu\t%llu\n", (unsigned long)(g_sites[i].addr - g_base),
			        g_sites[i].caller, g_sites[i].callee, (unsigned long long)g_sites[i].calls,
			        (unsigned long long)g_sites[i].swapped_calls, (unsigned long long)g_sites[i].pool_reads[0],
			        (unsigned long long)g_sites[i].pool_reads[1]);
	fprintf(f, "#\n# reads by instruction (offset in the executable)\npc\tdaily_reads\tmonthly_reads\n");
	for (int h = 0; h < NPC; h++)
		if (g_pc_key[h])
			fprintf(f, "%lx\t%llu\t%llu\n", (unsigned long)g_pc_key[h], (unsigned long long)g_pc_reads[h][0],
			        (unsigned long long)g_pc_reads[h][1]);
	fclose(f);
}

// Entered by jmp from a site stub with r11 = site and [rsp] = the return address (rsp = 8 mod 16).
__asm__(".text\n"
        ".globl hk_entry\n"
        ".hidden hk_entry\n"
        ".type hk_entry,@function\n"
        "hk_entry:\n"
        "  push %rdi\n  push %rsi\n  push %rdx\n  push %rcx\n"
        "  push %r8\n  push %r9\n  push %rax\n  push %r11\n"
        "  sub $136, %rsp\n"
        "  movdqu %xmm0, 0(%rsp)\n  movdqu %xmm1, 16(%rsp)\n  movdqu %xmm2, 32(%rsp)\n"
        "  movdqu %xmm3, 48(%rsp)\n  movdqu %xmm4, 64(%rsp)\n  movdqu %xmm5, 80(%rsp)\n"
        "  movdqu %xmm6, 96(%rsp)\n  movdqu %xmm7, 112(%rsp)\n"
        "  mov %r11, %rdi\n"
        "  lea 200(%rsp), %rsi\n"
        "  mov %rbp, %rdx\n"
        "  call hk_before\n"
        "  mov %rax, 136(%rsp)\n"
        "  movdqu 0(%rsp), %xmm0\n  movdqu 16(%rsp), %xmm1\n  movdqu 32(%rsp), %xmm2\n"
        "  movdqu 48(%rsp), %xmm3\n  movdqu 64(%rsp), %xmm4\n  movdqu 80(%rsp), %xmm5\n"
        "  movdqu 96(%rsp), %xmm6\n  movdqu 112(%rsp), %xmm7\n"
        "  add $136, %rsp\n"
        "  pop %r11\n  pop %rax\n  pop %r9\n  pop %r8\n"
        "  pop %rcx\n  pop %rdx\n  pop %rsi\n  pop %rdi\n"
        "  jmp *%r11\n"
        ".globl hk_post\n"
        ".hidden hk_post\n"
        ".type hk_post,@function\n"
        "hk_post:\n"
        "  push %rax\n  push %rdx\n"
        "  sub $32, %rsp\n"
        "  movdqu %xmm0, 0(%rsp)\n  movdqu %xmm1, 16(%rsp)\n"
        "  lea 40(%rsp), %rdi\n" // the saved rax, which an override may change
        "  call hk_after\n"
        "  mov %rax, %r11\n"
        "  movdqu 0(%rsp), %xmm0\n  movdqu 16(%rsp), %xmm1\n"
        "  add $32, %rsp\n"
        "  pop %rdx\n  pop %rax\n"
        "  jmp *%r11\n");

static uint8_t *alloc_near(size_t len) {
	for (uintptr_t k = 1; k < 64; k++) {
		uintptr_t hint = (g_base - k * 0x1000000UL) & ~(uintptr_t)0xfff;
		void *p = mmap((void *)hint, len, PROT_READ | PROT_WRITE | PROT_EXEC,
		               MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
		if (p != MAP_FAILED) return p;
	}
	return NULL;
}

static void profile_install(const char *path) {
	FILE *f = fopen(path, "r");
	if (!f) die(2, "HEADLESS_PROFILE: cannot open the site table");
	char line[4096];
	int cap = 4096;
	g_sites = calloc(cap, sizeof *g_sites);
	while (fgets(line, sizeof line, f)) {
		char *fld[5], *s = line;
		int n = 0;
		for (; n < 5; n++) {
			fld[n] = strsep(&s, "\t\n");
			if (!fld[n]) break;
		}
		if (n < 5) continue;
		if (g_nsites == cap) g_sites = realloc(g_sites, (cap *= 2) * sizeof *g_sites);
		struct site *st = &g_sites[g_nsites];
		memset(st, 0, sizeof *st);
		st->addr = g_base + strtoul(fld[0], NULL, 16);
		st->target = g_base + strtoul(fld[1], NULL, 16);
		snprintf(st->kind, sizeof st->kind, "%s", fld[2]);
		st->caller = strdup(fld[3]);
		st->callee = strdup(fld[4]);
		uint8_t op = *(uint8_t *)st->addr;
		int32_t rel = *(int32_t *)(st->addr + 1);
		if ((op != 0xE8 && op != 0xE9) || st->addr + 5 + rel != st->target) {
			hlog("profile: site %s+%#lx does not call %s; skipped", st->caller, (unsigned long)(st->addr - g_base),
			     st->callee);
			continue;
		}
		if (strstr(st->caller, "CTurnTickCommand::Execute") && strstr(st->callee, "HandleTurnTick"))
			g_site_htt = g_nsites;
		st->consumer = (strstr(st->callee, "int const*") || strstr(st->callee, "int*")) && !strstr(st->callee, "ForMacro");
		g_nsites++;
	}
	fclose(f);

	// HEADLESS_OVERRIDE, HEADLESS_WATCH, HEADLESS_POOL_DAILY / _MONTHLY: sites by hex offset.
	const char *e;
	unsigned long daily = 0x1b1c948, monthly = 0x1b2d746;
	if ((e = getenv("HEADLESS_POOL_DAILY"))) daily = strtoul(e, NULL, 16);
	if ((e = getenv("HEADLESS_POOL_MONTHLY"))) monthly = strtoul(e, NULL, 16);
	for (int i = 0; i < g_nsites; i++) {
		unsigned long off = g_sites[i].addr - g_base;
		if (off == daily) g_sites[i].pool_kind = 1;
		if (off == monthly) g_sites[i].pool_kind = 2;
	}
	if ((e = getenv("HEADLESS_OVERRIDE"))) {
		char *spec = strdup(e), *tok, *save = NULL;
		for (tok = strtok_r(spec, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
			char *eq = strchr(tok, '=');
			if (!eq) continue;
			*eq = 0;
			unsigned long off = strtoul(tok, NULL, 16);
			int mode = !strcmp(eq + 1, "zero") ? OV_ZERO : !strcmp(eq + 1, "xor") ? OV_XOR
			           : !strncmp(eq + 1, "const:", 6) ? OV_CONST : OV_NONE;
			int found = 0;
			for (int i = 0; i < g_nsites; i++)
				if (g_sites[i].addr - g_base == off) {
					g_sites[i].override_mode = mode;
					if (mode == OV_CONST) g_sites[i].override_const = atoi(eq + 7);
					found = 1;
					hlog("override: %lx (%s) -> %s", off, g_sites[i].callee, eq + 1);
				}
			if (!found) hlog("override: site %lx is not in the table", off);
		}
	}
	if ((e = getenv("HEADLESS_OVERRIDE_FROM")) && *e) g_override_from = atol(e);
	if ((e = getenv("HEADLESS_TRACE")) && *e && sscanf(e, "%ld-%ld", &g_trace_from, &g_trace_to) == 2) {
		const char *o = getenv("HEADLESS_TRACE_OUT");
		g_trace = o ? fopen(o, "w") : stderr;
		if (g_trace)
			fprintf(g_trace, "tick\tposition_before\tdraws\tdepth\tcaller\tcallee\n");
	}
	if ((e = getenv("HEADLESS_WATCH"))) {
		char *spec = strdup(e), *tok, *save = NULL;
		for (tok = strtok_r(spec, ",", &save); tok && g_nwatch < 32; tok = strtok_r(NULL, ",", &save)) {
			unsigned long off = strtoul(tok, NULL, 16);
			for (int i = 0; i < g_nsites; i++)
				if (g_sites[i].addr - g_base == off) {
					g_watch[g_nwatch++] = i;
					break;
				}
		}
	}
	if ((e = getenv("HEADLESS_TICKLOG")) && *e) {
		g_ticklog = fopen(e, "w");
		if (g_ticklog) {
			fprintf(g_ticklog, "total_ticks\tdraws");
			for (int i = 0; i < g_nwatch; i++)
				fprintf(g_ticklog, "\t%lx", (unsigned long)(g_sites[g_watch[i]].addr - g_base));
			fputc('\n', g_ticklog);
		}
	}
	size_t stub = 32, len = ((size_t)g_nsites * stub + 0xfff) & ~(size_t)0xfff;
	uint8_t *mem = alloc_near(len);
	if (!mem) die(2, "profile: no memory near the executable");
	for (int i = 0; i < g_nsites; i++) {
		uint8_t *p = mem + i * stub;
		void *entry = (void *)hk_entry;
		p[0] = 0x41, p[1] = 0xBB; // mov r11d, imm32
		memcpy(p + 2, &i, 4);
		p[6] = 0xFF, p[7] = 0x25; // jmp [rip+0]
		memset(p + 8, 0, 4);
		memcpy(p + 12, &entry, 8);
		intptr_t rel = (intptr_t)p - (intptr_t)(g_sites[i].addr + 5);
		if (rel != (int32_t)rel) die(2, "profile: stub out of range");
		uintptr_t page = g_sites[i].addr & ~(uintptr_t)0xfff;
		mprotect((void *)page, 0x2000, PROT_READ | PROT_WRITE | PROT_EXEC);
		int32_t r32 = (int32_t)rel;
		memcpy((void *)(g_sites[i].addr + 1), &r32, 4);
		mprotect((void *)page, 0x2000, PROT_READ | PROT_EXEC);
	}
	__builtin___clear_cache((char *)mem, (char *)mem + len);
	hlog("profile: %d call sites instrumented", g_nsites);
}

static void profile_write(const char *path, uint64_t total_draws, int ticks) {
	FILE *f = fopen(path, "w");
	if (!f) return;
	double days = ticks / 10.0;
	uint64_t htt = g_site_htt >= 0 ? g_sites[g_site_htt].draws : 0;
	fprintf(f, "# total draws %llu over %d ticks (%.1f/day); in HandleTurnTick %llu; outside it (commands "
	           "executed between ticks) %llu\n",
	        (unsigned long long)total_draws, ticks, days ? (double)total_draws / days : 0.0,
	        (unsigned long long)htt, (unsigned long long)(total_draws - htt));
	fprintf(f, "site\tcaller\tcallee\tcalls\tdraws\tdraws_per_day\n");
	for (int i = 0; i < g_nsites; i++) {
		struct site *s = &g_sites[i];
		if (!s->calls) continue;
		fprintf(f, "%lx\t%s\t%s\t%llu\t%llu\t%.1f\n", (unsigned long)(s->addr - g_base), s->caller, s->callee,
		        (unsigned long long)s->calls, (unsigned long long)s->draws, days ? (double)s->draws / days : 0.0);
	}
	fclose(f);
}

// ---------------------------------------------------------------- DLC ownership

// Without Steam the store has no items and no DLC is owned. CDLCManager keeps its descriptors in
// a std::map<CString, CDLCDescriptor> (header at +0xd8, leftmost node at +0xe8); a node's
// descriptor is at +0x50 (its name CString at descriptor +8) and the "verified" flag that
// VerifyAllDLCOwnership sets is the node's byte +0x40c (AcceptAllDLC sets the same byte).
static char *g_dlcs; // ";name;name;" or NULL for all

static int dlc_allowed(const char *name, size_t len) {
	if (!g_dlcs) return 1;
	char buf[512];
	if (len + 3 > sizeof buf) return 0;
	buf[0] = ';';
	memcpy(buf + 1, name, len);
	buf[len + 1] = ';';
	buf[len + 2] = 0;
	return strstr(g_dlcs, buf) != NULL;
}

static int my_VerifyAllDLCOwnership(void *mgr, int b) {
	(void)b;
	typedef void *(*inc_fn)(void *);
	inc_fn inc = (inc_fn)dlsym(RTLD_DEFAULT, "_ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base");
	if (!inc) die(2, "_Rb_tree_increment not found");
	char *header = (char *)mgr + 0xd8;
	int owned = 0, total = 0;
	for (char *node = *(char **)((char *)mgr + 0xe8); node != header; node = inc(node)) {
		size_t len;
		const char *name = cstring_ptr(node + 0x50 + 8, &len);
		int ok = dlc_allowed(name, len);
		U8(node + 0x40c) = (uint8_t)ok;
		total++;
		owned += ok;
		hlog("DLC %-3s %.*s", ok ? "on" : "off", (int)len, name);
	}
	hlog("DLC ownership: %d of %d owned", owned, total);
	return 0;
}

// ---------------------------------------------------------------- loading the save

// Replaces CFrontendDlcView::Update(), which CFrontEndIdler::UpdateInternal calls once a frame on
// the main thread while the main menu is up (the menu's DLC list is not updated). A few frames in,
// it launches the save the way the load-game view does: CFrontEndIdler::LaunchSave(path, cloud =
// false, the front end's CMultiplayerConfiguration at +0x250, as the -continuelastsave path passes).
static const char *g_save = "save games/headless/save.sav";
static int g_menu_frames, g_launched;
static double g_menu_at;

static void my_FrontendDlcViewUpdate(void *view) {
	(void)view;
	if (g_launched) return;
	if (g_menu_frames++ == 0) {
		g_menu_at = now() - g_t0;
		hlog("main menu after %.3f s", g_menu_at);
	}
	if (g_menu_frames < 3) return;
	void *fe = *(void **)a_g_CurrentFrontEndIdler;
	if (!fe) return;
	g_launched = 1;
	_Alignas(16) uint8_t path[0x30];
	((void (*)(void *, const char *))a_CStringCtor)(path, g_save);
	hlog("LaunchSave(\"%s\")", g_save);
	((void (*)(void *, const void *, int, const void *))a_LaunchSave)(fe, path, 0, (char *)fe + 0x250);
	hlog("LaunchSave returned after %.3f s", now() - g_t0 - g_menu_at);
}

// ---------------------------------------------------------------- driving the ticks

enum { ST_WAIT, ST_RUN, ST_DONE };
static int g_state = ST_WAIT;
static int g_ticks = 10;
static int g_wait_frames = 5;
static int g_frames_ready;
static int g_frame_mode;
static int g_start_total;
static int g_posted;
static const char *g_out = "headless_out.gamestate";
static const char *g_profile_out;
static double g_run_t0, g_boot_done;
static long long g_rng_pos_set = -1; // HEADLESS_RNG_POS
static uint32_t g_pos0;

// The tick command, built as CInGameIdler::CheckTick builds it (operator new(0x50), the fields
// set inline), then posted to the session.
static void post_tick(void) {
	void *(*op_new)(size_t) = (void *(*)(size_t))dlsym(RTLD_DEFAULT, "_Znwm");
	uint8_t *p = op_new(0x50);
	memset(p, 0, 0x50);
	*(uint64_t *)(p + 0x08) = 0xffffffffu;
	*(uint16_t *)(p + 0x12) = 0xffff;
	p[0x15] = 0;
	*(uint32_t *)(p + 0x18) = 0;
	*(uintptr_t *)(p + 0x00) = a_vt_TurnTickCommand + 0x10;
	*(uintptr_t *)(p + 0x20) = a_vt_ArrayULL + 0x10;
	*(uintptr_t *)(p + 0x38) = a_vt_ArrayPlayerTick + 0x10;
	((void (*)(void *, int))a_PostCommandToSession)(p, 0);
	g_posted++;
}

// CGameApplication::Update: the frame's session update (ProcessSynchronousCommands with the
// game state's callbacks), run here as the main loop runs it.
static void app_update(void) {
	void *app = ((void *(*)(void))a_AccessApplication)();
	((void (*)(void *))a_GameApplicationUpdate)(app);
}

static int per_turn(void) {
	int n = I32(a_NUM_COMMANDS_PER_TURN);
	if (n > 10) n = 10;
	if (n < 1) n = 1;
	return n;
}

static void write_gamestate_and_exit(void *gs) {
	double t_ticks = now() - g_run_t0;
	int done = total_ticks(gs) - g_start_total;
	g_prof_on = 0;
	uint32_t draws = rng_pos() - g_pos0;
	hlog("ran %d ticks in %.3f s (%.2f ms/day); now tick=%d days=%d date=%d", done, t_ticks,
	     done > 0 ? t_ticks * 1000.0 * 10 / done : 0.0, I32((char *)gs + 8), I32((char *)gs + 0xc4),
	     I32((char *)gs + 0xc0));
	hlog("random: seed %d position %u, %u draws in the run (%.1f a day)", (int)rng_seed(), rng_pos(), draws,
	     done ? draws * 10.0 / done : 0.0);
	if (g_nsites && g_profile_out) {
		profile_write(g_profile_out, draws, done);
		hlog("profile -> %s", g_profile_out);
	}
	if (g_ticklog) fclose(g_ticklog), g_ticklog = NULL;
	if (g_trace && g_trace != stderr) fclose(g_trace), g_trace = NULL;
	const char *pt = getenv("HEADLESS_POOLTRACK");
	if (g_track && pt) {
		g_track = 0;
		track_write(pt, done);
		hlog("pooltrack: daily %llu reads in %d fills, monthly %llu reads in %d fills -> %s",
		     (unsigned long long)g_reads[0], g_periods[0], (unsigned long long)g_reads[1], g_periods[1], pt);
	}
	// SaveGameCheckMakeSave(CString) writes CWriter::WriteTopLevelList(*g_CurrentGameState) to a
	// CArchiveFile: the game's own gamestate writer, on this thread.
	_Alignas(16) uint8_t path[0x30];
	((void (*)(void *, const char *))a_CStringCtor)(path, g_out);
	double t1 = now();
	U8(a_g_AllowGlobalGameStateAccess) = 1;
	int ok = ((int (*)(void *))a_SaveGameCheckMakeSave)(path) & 1;
	hlog("SaveGameCheckMakeSave(\"%s\") -> %d in %.3f s", g_out, ok, now() - t1);
	hlog("total %.3f s (boot+load %.3f s)", now() - g_t0, g_boot_done);
	fflush(NULL);
	_exit(ok ? 0 : 1);
}

static void no_render(void *idler, int b) {
	(void)idler;
	(void)b;
}

static void start_run(void *gs) {
	g_state = ST_RUN;
	if (g_frame_mode && !getenv("HEADLESS_RENDER")) {
		// The in-game frame is not drawn from here on (llvmpipe takes seconds a frame). Patched
		// from the update, on the main thread that also renders.
		detour(a_InGameRenderInternal, (void *)no_render);
		hlog("in-game rendering off");
	}
	g_boot_done = now() - g_t0;
	g_start_total = total_ticks(gs);
	hlog("in game after %.3f s: tick=%d days=%d date=%d total=%d; running %d ticks (%s mode, %d per turn)",
	     g_boot_done, I32((char *)gs + 8), I32((char *)gs + 0xc4), I32((char *)gs + 0xc0), g_start_total,
	     g_ticks, g_frame_mode ? "frame" : "loop", per_turn());
	U8(a_g_bFrameSmoothing) = 0; // no frames rendered from inside the tick
	hlog("random after load: seed %d position %u", (int)rng_seed(), rng_pos());
	if (g_rng_pos_set >= 0) {
		// The load itself draws (112 for the 2210 saves): put the position back where the save
		// left it, as if the session had gone on instead of reloading.
		*(volatile uint32_t *)a_Random = (uint32_t)g_rng_pos_set;
		*(volatile uint32_t *)a_nRandomCount = (uint32_t)g_rng_pos_set;
		hlog("random position set to %u", rng_pos());
	}
	g_pos0 = rng_pos();
	g_tick_pos = g_pos0;
	const char *pt = getenv("HEADLESS_POOLTRACK");
	if (pt && *pt && g_nsites) track_start();
	g_prof_on = 1;
	g_run_t0 = now();
}

static void progress(void *gs) {
	static int last_day = -1;
	int day = I32((char *)gs + 0xc4);
	if (day != last_day && day % 30 == 0) {
		int done = total_ticks(gs) - g_start_total;
		hlog("  day %d: %d ticks, %.3f s", day, done, now() - g_run_t0);
	}
	last_day = day;
}

// Replaces CInGameIdler::CheckTick(float), called once a frame by CInGameIdler::UpdateInternal on
// the main thread: the game's own ticks never start (the game stays paused), these do.
static _Bool my_CheckTick(void *idler, float dt) {
	(void)idler;
	(void)dt;
	void *gs = game_state();
	if (!gs || !U8((char *)gs + 0xa0)) return 0; // no game, or not started
	if (g_state == ST_DONE) return 0;
	if (g_state == ST_WAIT) {
		if (++g_frames_ready < g_wait_frames) return 0;
		start_run(gs);
	}
	int target = g_start_total + g_ticks;
	if (!g_frame_mode) {
		uint8_t s_ggs = U8(a_g_AllowGlobalGameStateAccess), s_gp = U8(a_g_AllowGetPlayer),
		        s_pc = U8(a_g_AllowPostCommandToSession);
		int stalls = 0;
		while (total_ticks(gs) < target) {
			int before = total_ticks(gs);
			int k = per_turn();
			int left = target - g_start_total - g_posted;
			if (k > left) k = left;
			U8(a_g_AllowPostCommandToSession) = 1;
			for (int i = 0; i < k; i++) post_tick();
			g_trace_turn = g_trace && before >= g_trace_from && before < g_trace_to;
			if (g_trace_turn)
				fprintf(g_trace, "%d\t%u\t-\t-\tturn begins (session update: commands, then %d ticks)\t\n", before,
				        rng_pos(), k);
			app_update();
			if (g_trace_turn) fprintf(g_trace, "%d\t%u\t-\t-\tturn ends\t\n", total_ticks(gs), rng_pos());
			g_trace_turn = 0;
			progress(gs);
			if (total_ticks(gs) == before && ++stalls > 100) die(4, "ticks do not advance");
		}
		U8(a_g_AllowGlobalGameStateAccess) = s_ggs;
		U8(a_g_AllowGetPlayer) = s_gp;
		U8(a_g_AllowPostCommandToSession) = s_pc;
		g_state = ST_DONE;
		write_gamestate_and_exit(gs);
	} else {
		int cur = total_ticks(gs);
		progress(gs);
		if (cur >= target) {
			g_state = ST_DONE;
			write_gamestate_and_exit(gs);
		}
		int k = per_turn();
		int left = g_ticks - g_posted;
		if (k > left) k = left;
		uint8_t s_pc = U8(a_g_AllowPostCommandToSession);
		U8(a_g_AllowPostCommandToSession) = 1;
		for (int i = 0; i < k; i++) post_tick();
		U8(a_g_AllowPostCommandToSession) = s_pc;
	}
	return 0;
}

// ---------------------------------------------------------------- start

static int g_timeout = 1200;

static void *watchdog(void *arg) {
	(void)arg;
	sleep(g_timeout);
	hlog("watchdog: %d s, state %d, posted %d; exiting", g_timeout, g_state, g_posted);
	_exit(3);
	return NULL;
}

__attribute__((constructor)) static void headless_init(void) {
	// Only the game itself: not xvfb-run, gdb, or other processes the env reaches.
	char exe[512];
	ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	if (n <= 0) return;
	exe[n] = 0;
	const char *base = strrchr(exe, '/');
	if (!base || strcmp(base + 1, "stellaris") != 0) return;

	g_t0 = now();
	const char *e;
	if ((e = getenv("HEADLESS_LOG"))) g_log = fopen(e, "a");
	if ((e = getenv("HEADLESS_TICKS"))) g_ticks = atoi(e);
	if ((e = getenv("HEADLESS_OUT"))) g_out = e;
	if ((e = getenv("HEADLESS_SAVE"))) g_save = e;
	if ((e = getenv("HEADLESS_RNG_POS")) && *e) g_rng_pos_set = strtoll(e, NULL, 10);
	if ((e = getenv("HEADLESS_PROFILE_OUT"))) g_profile_out = e;
	if ((e = getenv("HEADLESS_WAIT"))) g_wait_frames = atoi(e);
	if ((e = getenv("HEADLESS_TIMEOUT"))) g_timeout = atoi(e);
	if ((e = getenv("HEADLESS_MODE"))) g_frame_mode = strcmp(e, "frame") == 0;
	if ((e = getenv("HEADLESS_DLCS"))) {
		g_dlcs = malloc(strlen(e) + 3);
		sprintf(g_dlcs, ";%s;", e);
	}

	dl_iterate_phdr(base_cb, &g_base);
	if (!g_base) die(2, "no load base");
	if (resolve(g_syms) != 0) die(2, "missing symbols");
	hlog("stellaris at %#lx; %d ticks -> %s", (unsigned long)g_base, g_ticks, g_out);

	detour(a_VerifyAllDLCOwnership, (void *)my_VerifyAllDLCOwnership);
	detour(a_CheckTick, (void *)my_CheckTick);
	detour(a_FrontendDlcViewUpdate, (void *)my_FrontendDlcViewUpdate);
	if ((e = getenv("HEADLESS_PROFILE")) && *e) profile_install(e);

	pthread_t t;
	pthread_create(&t, NULL, watchdog, NULL);
	pthread_detach(t);
}
