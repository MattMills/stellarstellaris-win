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
//   HEADLESS_AUTOSAVE     1: serve the game's own autosave requests (the interval is the settings'
//                     `autosave`); HEADLESS_AUTOSAVE_DIR: move each autosave there when written
//   HEADLESS_NO_TASK_THREADS  1: the game's parallel-fors run inline on the main thread
//   (the profiler's other options are described at the profiler below)
//   HEADLESS_MODE=view: the game's own frames, driven by commands (HEADLESS_LISTEN,
//                     HEADLESS_SCRIPT; see "view mode" below and view.sh)
#define _GNU_SOURCE
#include <dirent.h>
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
// view mode (below): types only, the functions are looked up at run time (no new link flags)
#include <X11/Xlib.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <zlib.h>

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
static uintptr_t a_g_CurrentInGameIdler;    // CInGameIdler*
static uintptr_t a_PostRenderUpdate;        // CInGameIdler::PostRenderUpdate()
static uintptr_t a_SaveTaskUpdate;          // CSaveGameTaskManager::Update(bool)
static uintptr_t a_DeleteSaveGameFile;      // DeleteSaveGameFile(SSaveGameFile const&)

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
	{"g_CurrentInGameIdler", &a_g_CurrentInGameIdler},
	{"_ZN12CInGameIdler16PostRenderUpdateEv", &a_PostRenderUpdate},
	{"_ZN20CSaveGameTaskManager6UpdateEb", &a_SaveTaskUpdate},
	{"_Z18DeleteSaveGameFileRK13SSaveGameFile", &a_DeleteSaveGameFile},
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

// view mode (below)
static int g_viewmode;
static int g_view_autoload;
static void view_menu(void);
static void view_game(void *gs);
static void view_command(void *gs);

static void my_FrontendDlcViewUpdate(void *view) {
	(void)view;
	if (g_launched) return;
	if (g_menu_frames++ == 0) {
		g_menu_at = now() - g_t0;
		hlog("main menu after %.3f s", g_menu_at);
	}
	if (g_viewmode && !g_view_autoload) {
		// the save comes with a `load` command
		if (g_menu_frames >= 3) view_menu();
		return;
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

// ---------------------------------------------------------------- the game's autosaves
//
// HEADLESS_AUTOSAVE=1: the game's own autosaves, at the interval its settings give (run.sh writes
// `autosave=<level>` to settings.txt: 2 monthly, 3 quarterly, 4 half-yearly, 5 yearly).
// HandleTurnTick posts a CAutosave command when the day's date change reaches the level;
// CAutosave::Execute only raises the in-game idler's request flag (+0xab0), which the main loop
// serves after the frame: CInGameIdler::PostRenderUpdate -> AutoSave() (names the file
// autosave_<date>, deletes the oldest autosaves past the limit, starts the save task), and at the
// next frame CSaveGameTaskManager::Update(true) (CInGameIdler::PrepareUpdateInternal) does the
// save. Our loop never returns to the main loop, so after each session update it does the same two
// calls, with task threads off so that Update saves on this thread (CreateMemoryFiles,
// ZipAndWrite) and the file is complete when it returns. DeleteSaveGameFile is replaced by a no-op
// so that every autosave is kept.
static int g_autosave, g_autosaves;
static const char *g_autosave_dir; // HEADLESS_AUTOSAVE_DIR

static void no_delete(void *file) { (void)file; }

// The save task refuses to write once a save folder holds 100 saves (CountSaveGames in
// StartSaveToPath), so each autosave is moved to HEADLESS_AUTOSAVE_DIR as soon as it is written.
static void move_file(const char *src, const char *dst) {
	if (rename(src, dst) == 0) return;
	FILE *in = fopen(src, "rb"), *out = in ? fopen(dst, "wb") : NULL;
	char buf[65536];
	size_t n;
	if (in && out) {
		while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
		fclose(out);
		fclose(in);
		unlink(src);
	} else {
		if (in) fclose(in);
		hlog("cannot move %s to %s", src, dst);
	}
}

static void move_autosaves(void) {
	const char *home = getenv("HOME");
	char base[1024], sub[2048], src[3072], dst[3072];
	snprintf(base, sizeof base, "%s/.local/share/Paradox Interactive/Stellaris/save games", home ? home : ".");
	DIR *d = opendir(base);
	if (!d) return;
	for (struct dirent *e; (e = readdir(d));) {
		if (e->d_name[0] == '.') continue;
		snprintf(sub, sizeof sub, "%s/%s", base, e->d_name);
		DIR *s = opendir(sub);
		if (!s) continue;
		for (struct dirent *f; (f = readdir(s));) {
			size_t n = strlen(f->d_name);
			if (strncmp(f->d_name, "autosave_", 9) || n < 4 || strcmp(f->d_name + n - 4, ".sav")) continue;
			snprintf(src, sizeof src, "%s/%s", sub, f->d_name);
			snprintf(dst, sizeof dst, "%s/%s", g_autosave_dir, f->d_name);
			move_file(src, dst);
		}
		closedir(s);
	}
	closedir(d);
}

static void handle_autosave(void *gs) {
	void *idler = *(void **)a_g_CurrentInGameIdler;
	if (!idler || !U8((char *)idler + 0xab0)) return;
	uint32_t pos = rng_pos();
	double t = now();
	uint8_t s_ggs = U8(a_g_AllowGlobalGameStateAccess);
	((void (*)(void *))a_PostRenderUpdate)(idler);
	void *mgr = *(void **)((char *)idler + 0xf90);
	uint8_t s_tt = U8(a_EnableTaskThreads);
	U8(a_EnableTaskThreads) = 0;
	((void (*)(void *, int))a_SaveTaskUpdate)(mgr, 1);
	U8(a_EnableTaskThreads) = s_tt;
	U8(a_g_AllowGlobalGameStateAccess) = s_ggs;
	if (g_autosave_dir) move_autosaves();
	g_autosaves++;
	hlog("autosave %d: tick=%d days=%d total=%d, %.3f s%s", g_autosaves, I32((char *)gs + 8), I32((char *)gs + 0xc4),
	     total_ticks(gs), now() - t, rng_pos() != pos ? " (the save drew random values!)" : "");
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
	if (g_autosave) hlog("%d autosaves", g_autosaves);
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
	if (getenv("HEADLESS_NO_TASK_THREADS") && *getenv("HEADLESS_NO_TASK_THREADS") == '1') {
		// every parallel-for of the game runs inline, on this thread, in index order
		U8(a_EnableTaskThreads) = 0;
		hlog("task threads off");
	}
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
	if (g_viewmode) {
		view_game(gs);
		return 0;
	}
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
			if (g_autosave) handle_autosave(gs);
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

// ---------------------------------------------------------------- view mode
//
// HEADLESS_MODE=view: the game stays up, never ticking on its own, and renders its frames (Xvfb,
// Mesa llvmpipe) while it runs commands, from HEADLESS_SCRIPT (a file, one command a line, `#`
// comments; the replies go to HEADLESS_REPLIES or the log) and then from HEADLESS_LISTEN
// ([addr:]port, 127.0.0.1 by default; one client at a time). One reply per command, sent when the
// command is complete. The protocol is the renderer's (sim/render/src/engine.rs, docs/render.md),
// so sim/render/tools/ctl.py drives both:
//
//   load PATH          the save (copied into the user dir, then CFrontEndIdler::LaunchSave), from
//                      the main menu: one save per game run (the reply waits until the game is in)
//   pause              the game is always paused here (ticks only come from `step`): ok
//   step DAYS          runs ticks until the date moved DAYS days (loop mode, nothing rendered)
//   view galaxy        CGameCamera::LeaveSystem;  view system ID: CGameCamera::EnterSystem
//   focus system ID    the galaxy camera's target over the system
//   camera X Y Z YAW PITCH DISTANCE   the game camera's orientation, set every frame from then
//                      on (`camera off` lets it go): the target (X, Z) on the plane in map units
//                      (the save's coordinates: the game's world is them x GALAXY_SPACE_SCALE_MULT
//                      = 2 on the galaxy, x SYSTEM_SPACE_SCALE_MULT = 10 in a system), DISTANCE in
//                      map units, YAW and PITCH in degrees as the game keeps them (CGameCamera +0x22c,
//                      +0x228: the eye is target + distance (-cos p sin y, sin p, cos p cos y))
//   resize W H         the window is fixed at start (view.sh --size): ok if it is W x H
//   gui off|on         g_bNoGUI (the hide-GUI key's flag)
//   observe            the console's `observe` (OnExecute_Observe: posts CAddCountryControllerCommand
//                      giving the local human no country): the player becomes an observer, who
//                      knows the whole galaxy (no terra incognita) and sees every country's
//                      borders; the reply is the console's text, the command runs with the frame
//   frame PATH.png     waits for the picture to settle (from HEADLESS_FRAME_WAIT seconds, 2, and
//                      HEADLESS_FRAME_MIN frames, 10, on: two captures in a row nearly equal, or
//                      HEADLESS_FRAME_TIMEOUT seconds, 30), captures the window (X11 XGetImage),
//                      writes the PNG: `ok frame PATH W H MS FRAMES` ("unsettled" if timed out)
//   frame -            the same, the PNG's bytes after `ok frame - W H MS BYTES` (listener only)
//   frame PATH now     the frame as the input left it (the camera's update not run while waiting)
//   key CHORD [down|up|tap], hold CHORD DURATION, mouse X Y [BUTTON [down|up]], move X Y,
//   button BUTTON down|up [X Y], click X Y [BUTTON] [double], wheel NOTCHES [X Y] (scroll),
//   drag BUTTON X0 Y0 X1 Y1 [STEPS [FRAMES]]
//                      real input by XTest ("input" below)
//   timestep MS|off    lockstep: the camera's frame time MS, no frame between commands
//   tick N, wait S     N frames run (frames N); S seconds of frames (with a timestep, S / MS frames)
//   state [planet ID]  JSON: the date, the view, the clock and the input, the camera (its
//                      orientation, eye, look-at, up, FOV, aspect, near, far, the view and
//                      projection matrices as the game keeps them: column-major, left-handed);
//                      with a planet, its entity scale (CPlanet::CalcCurrentEntityScale), display
//                      size and world transform
//   quit               exits (no gamestate written)
//
// The layouts used (4.5.2 Linux, read from the code):
//   CInGameIdler +0x218: its CGameCamera (CInGameIdler::CInGameIdler); CGameCamera starts with a
//   CCamera: +0x00 view matrix (MatrixLookAtLH), +0x40 projection (UpdateMatrices: x scale, y scale
//   1/tan(fov/2), z f/(f-n), w = z), +0x180 eye, +0x18c look-at, +0x198 up, +0x1a4 vertical FOV
//   (radians), +0x1a8 aspect, +0x1ac near, +0x1b0 far. CGameCamera +0x218 the current orientation
//   {x, y, z, distance, pitch, yaw}, +0x230 the target one (UpdateOrientation smooths the first
//   toward the second), +0x26c a lock flag, +0x274 the system it is in (-1 the galaxy).
//   Planets: CGameState +0x918 the planet manager, its +0xdc0 entries of 16 bytes (+8 the CPlanet),
//   +0xdc8 their count (GetPlanetFromIndex); CPlanet +0x18 its id, +0x150 its size, +0xc20 its
//   entity instance (GetDisplaySize). Systems: TPdxRef<CGalacticObject>::_pDatabase +0x18 entries
//   of 16 bytes (+8 the object, whose +8 is its id), +0x20 their count (GetCurrentSystem).

static uintptr_t a_GameCameraUpdate;      // CGameCamera::Update(CKeyBoard const*, CMouse*, CPdxGameController const*, CList<CInputEvent>&, float)
static uintptr_t a_UpdateInternalCamera;  // CGameCamera::UpdateInternalCamera()
static uintptr_t a_EnterSystem;           // CGameCamera::EnterSystem(CGalacticObject const*)
static uintptr_t a_LeaveSystem;           // CGameCamera::LeaveSystem()
static uintptr_t a_InGameUpdateInternal;  // CInGameIdler::UpdateInternal(bool): calls CGameCamera::Update
static uintptr_t a_PlanetEntityScale;     // CPlanet::CalcCurrentEntityScale() const
static uintptr_t a_PlanetDisplaySize;     // CPlanet::GetDisplaySize() const
static uintptr_t a_EntityWorldTransform;  // EntityInstanceGetWorldTransform
static uintptr_t a_g_bNoGUI;              // bool
static uintptr_t a_GalacticObjectDb;      // TPdxRef<CGalacticObject>::_pDatabase
static uintptr_t a_GalaxyScaleMult;       // NDefines::NCamera::GALAXY_SPACE_SCALE_MULT
static uintptr_t a_SystemScaleMult;       // NDefines::NCamera::SYSTEM_SPACE_SCALE_MULT
static uintptr_t a_ExecuteObserve;        // OnExecute_Observe(CPdxArray<CString, int> const&)
static uintptr_t a_g_CurrentIdler;        // CGameIdler* (+0xe0: the frame's time, CGameCamera::UpdateZoom's keys)
static uintptr_t a_SDL_AddEventWatch;     // SDL_AddEventWatch (SDL2 is linked in)

static struct symreq g_view_syms[] = {
	{"_ZN11CGameCamera6UpdateEPK9CKeyBoardP6CMousePK18CPdxGameControllerR5CListI11CInputEventEf", &a_GameCameraUpdate},
	{"_ZN11CGameCamera20UpdateInternalCameraEv", &a_UpdateInternalCamera},
	{"_ZN11CGameCamera11EnterSystemEPK15CGalacticObject", &a_EnterSystem},
	{"_ZN11CGameCamera11LeaveSystemEv", &a_LeaveSystem},
	{"_ZN12CInGameIdler14UpdateInternalEb", &a_InGameUpdateInternal},
	{"_ZNK7CPlanet22CalcCurrentEntityScaleEv", &a_PlanetEntityScale},
	{"_ZNK7CPlanet14GetDisplaySizeEv", &a_PlanetDisplaySize},
	{"EntityInstanceGetWorldTransform", &a_EntityWorldTransform},
	{"g_bNoGUI", &a_g_bNoGUI},
	{"_ZN7TPdxRefI15CGalacticObjectE10_pDatabaseE", &a_GalacticObjectDb},
	{"_ZN8NDefines7NCamera23GALAXY_SPACE_SCALE_MULTE", &a_GalaxyScaleMult},
	{"_ZN8NDefines7NCamera23SYSTEM_SPACE_SCALE_MULTE", &a_SystemScaleMult},
	{"_Z17OnExecute_ObserveRK9CPdxArrayI7CStringiE", &a_ExecuteObserve},
	{"g_CurrentIdler", &a_g_CurrentIdler},
	{"SDL_AddEventWatch", &a_SDL_AddEventWatch},
	{NULL, NULL},
};

#define F32(a) (*(volatile float *)(a))

static void *camera(void) {
	void *idler = *(void **)a_g_CurrentInGameIdler;
	return idler ? (char *)idler + 0x218 : NULL;
}

static int camera_system(void *cam) { return I32((char *)cam + 0x274); }

static float space_scale(void *cam) {
	return camera_system(cam) == -1 ? F32(a_GalaxyScaleMult) : F32(a_SystemScaleMult);
}

static void *galactic_object(int id) {
	char *db = *(char **)a_GalacticObjectDb;
	if (!db || id < 0) return NULL;
	uint32_t i = (uint32_t)id & 0xffffff;
	if (i >= *(uint32_t *)(db + 0x20)) return NULL;
	char *o = *(char **)(*(char **)(db + 0x18) + 16 * (size_t)i + 8);
	return o && I32(o + 8) == id ? o : NULL;
}

static void *planet(void *gs, int id) {
	char *mgr = *(char **)((char *)gs + 0x918);
	if (!mgr) return NULL;
	uint32_t n = *(uint32_t *)(mgr + 0xdc8);
	char *arr = *(char **)(mgr + 0xdc0);
	for (uint32_t i = 0; i < n; i++) {
		char *p = *(char **)(arr + 16 * (size_t)i + 8);
		if (p && I32(p + 0x18) == id) return p;
	}
	return NULL;
}

// --- the camera, set every frame after the game's own update (CGameCamera::Update is called from
// CInGameIdler::UpdateInternal after CheckTick and before the frame is drawn: that call is sent
// through cam_update, which calls it and then puts our orientation back)

static int g_cam_set;
static float g_cam[6]; // the game's world units and radians: x y z distance pitch yaw
static float g_timestep; // `timestep MS`: the camera's frame time in seconds (0: the frame's own)
static int g_cam_freeze;  // `frame PATH now` waits for the picture: the camera's update not run
static int g_cam_held;    // a frame held for the input's delivery (below): the camera's update not run

static void apply_camera(void *cam) {
	float *cur = (float *)((char *)cam + 0x218), *tgt = (float *)((char *)cam + 0x230);
	for (int i = 0; i < 6; i++) cur[i] = tgt[i] = g_cam[i];
	((void (*)(void *))a_UpdateInternalCamera)(cam);
}

// With a timestep the camera's update gets it as the frame's time (CGameIdler::Idle's real one,
// at most 0.1 s, otherwise), and so does the idler's own (g_CurrentIdler +0xe0, which
// UpdateZoom @0x2e664f8 multiplies Page Up and Page Down's KEYBOARD_ZOOM_RATE by): the held
// keys' scrolling and zoom and the camera's smoothing are then the same a frame however long the
// frame took.
static void cam_update(void *cam, void *kb, void *mouse, void *pad, void *events, float dt) {
	if (g_cam_freeze || g_cam_held) return;
	if (g_timestep > 0) {
		dt = g_timestep;
		char *idler = *(char **)a_g_CurrentIdler;
		if (idler) F32(idler + 0xe0) = g_timestep;
	}
	((void (*)(void *, void *, void *, void *, void *, float))a_GameCameraUpdate)(cam, kb, mouse, pad, events, dt);
	if (g_cam_set) apply_camera(cam);
}

static void hook_camera_update(void) {
	// the `call rel32` to CGameCamera::Update inside CInGameIdler::UpdateInternal
	uint8_t *p = (uint8_t *)a_InGameUpdateInternal, *site = NULL;
	for (int i = 0; i < 0x2000; i++)
		if (p[i] == 0xE8 && (uintptr_t)(p + i + 5) + *(int32_t *)(p + i + 1) == a_GameCameraUpdate) {
			site = p + i;
			break;
		}
	if (!site) die(2, "view: no call to CGameCamera::Update in CInGameIdler::UpdateInternal");
	uint8_t *thunk = alloc_near(4096);
	if (!thunk) die(2, "view: no memory near the executable");
	uint8_t code[12] = {0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0};
	void *to = (void *)cam_update;
	memcpy(code + 2, &to, 8);
	memcpy(thunk, code, sizeof code);
	int32_t rel = (int32_t)((intptr_t)thunk - (intptr_t)(site + 5));
	uintptr_t page = (uintptr_t)site & ~(uintptr_t)0xfff;
	if (mprotect((void *)page, 0x2000, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) die(2, "mprotect");
	memcpy(site + 1, &rel, 4);
	mprotect((void *)page, 0x2000, PROT_READ | PROT_EXEC);
	hlog("view: CGameCamera::Update call at +%#lx sent through the camera hook", (unsigned long)(site - (uint8_t *)g_base));
}

// --- the window, captured from the X server (Xvfb) after the game presented its frame

struct xfns {
	Display *(*open)(const char *);
	Window (*root)(Display *);
	Status (*tree)(Display *, Window, Window *, Window *, Window **, unsigned int *);
	Status (*attrs)(Display *, Window, XWindowAttributes *);
	XImage *(*image)(Display *, Drawable, int, int, unsigned int, unsigned int, unsigned long, int);
	int (*sync)(Display *, Bool);
	int (*xfree)(void *);
	// input (below): the keys' codes, the focus, the window's place
	KeySym (*string_to_keysym)(const char *);
	KeyCode (*keysym_to_keycode)(Display *, KeySym);
	int (*set_input_focus)(Display *, Window, int, Time);
	Bool (*translate)(Display *, Window, Window, int, int, int *, int *, Window *);
	int (*autorepeat_off)(Display *);
	Bool (*query_pointer)(Display *, Window, Window *, Window *, int *, int *, int *, int *, unsigned int *);
	// libXtst (XTest), real input as the X server's own devices make it
	Bool (*xtest_query)(Display *, int *, int *, int *, int *);
	int (*fake_key)(Display *, unsigned int, Bool, unsigned long);
	int (*fake_button)(Display *, unsigned int, Bool, unsigned long);
	int (*fake_motion)(Display *, int, int, int, unsigned long);
};
static struct xfns X;
static Display *g_dpy;
static int (*z_compress2)(Bytef *, uLongf *, const Bytef *, uLong, int);
static uLong (*z_bound)(uLong);
static uLong (*z_crc32)(uLong, const Bytef *, uInt);

static int view_libs(void) {
	void *x = dlopen("libX11.so.6", RTLD_NOW | RTLD_GLOBAL), *z = dlopen("libz.so.1", RTLD_NOW);
	if (!x || !z) return -1;
	X.open = dlsym(x, "XOpenDisplay");
	X.root = dlsym(x, "XDefaultRootWindow");
	X.tree = dlsym(x, "XQueryTree");
	X.attrs = dlsym(x, "XGetWindowAttributes");
	X.image = dlsym(x, "XGetImage");
	X.sync = dlsym(x, "XSync");
	X.xfree = dlsym(x, "XFree");
	X.string_to_keysym = dlsym(x, "XStringToKeysym");
	X.keysym_to_keycode = dlsym(x, "XKeysymToKeycode");
	X.set_input_focus = dlsym(x, "XSetInputFocus");
	X.translate = dlsym(x, "XTranslateCoordinates");
	X.autorepeat_off = dlsym(x, "XAutoRepeatOff");
	X.query_pointer = dlsym(x, "XQueryPointer");
	void *t = dlopen("libXtst.so.6", RTLD_NOW);
	if (t) {
		X.xtest_query = dlsym(t, "XTestQueryExtension");
		X.fake_key = dlsym(t, "XTestFakeKeyEvent");
		X.fake_button = dlsym(t, "XTestFakeButtonEvent");
		X.fake_motion = dlsym(t, "XTestFakeMotionEvent");
	}
	if (!X.fake_key || !X.fake_button || !X.fake_motion || !X.xtest_query)
		hlog("view: libXtst.so.6 not found: no input commands (key, mouse, wheel, drag)");
	z_compress2 = dlsym(z, "compress2");
	z_bound = dlsym(z, "compressBound");
	z_crc32 = dlsym(z, "crc32");
	return X.open && X.root && X.tree && X.attrs && X.image && X.sync && X.xfree && X.string_to_keysym &&
	               X.keysym_to_keycode && X.set_input_focus && X.translate && X.autorepeat_off && z_compress2 && z_bound &&
	               z_crc32
	           ? 0
	           : -1;
}

// The game's window: the largest mapped top-level window (0 if none), its size.
static Window game_window(int *w, int *h) {
	if (!g_dpy && !(g_dpy = X.open(NULL))) return 0;
	Window root = X.root(g_dpy), r, parent, *kids = NULL, best = 0;
	unsigned int n = 0;
	long area = 0;
	XWindowAttributes a;
	if (X.tree(g_dpy, root, &r, &parent, &kids, &n)) {
		for (unsigned int i = 0; i < n; i++)
			if (X.attrs(g_dpy, kids[i], &a) && a.map_state == IsViewable && (long)a.width * a.height > area) {
				area = (long)a.width * a.height;
				best = kids[i];
				if (w) *w = a.width;
				if (h) *h = a.height;
			}
		if (kids) X.xfree(kids);
	}
	return best;
}

// The game's window captured: RGB rows into *out (malloc'd).
static int capture(uint8_t **out, int *w, int *h) {
	if (!g_dpy && !(g_dpy = X.open(NULL))) return -1;
	X.sync(g_dpy, False);
	Window best = game_window(NULL, NULL);
	XWindowAttributes a;
	if (!best) best = X.root(g_dpy);
	if (!X.attrs(g_dpy, best, &a)) return -1;
	XImage *im = X.image(g_dpy, best, 0, 0, a.width, a.height, AllPlanes, ZPixmap);
	if (!im) return -1;
	if (im->bits_per_pixel != 32) {
		im->f.destroy_image(im);
		return -1;
	}
	*w = im->width;
	*h = im->height;
	*out = malloc((size_t)im->width * im->height * 3);
	int rs = __builtin_ctzl(im->red_mask), gs = __builtin_ctzl(im->green_mask), bs = __builtin_ctzl(im->blue_mask);
	for (int y = 0; y < im->height; y++) {
		uint32_t *row = (uint32_t *)(im->data + (size_t)y * im->bytes_per_line);
		uint8_t *o = *out + (size_t)y * im->width * 3;
		for (int x = 0; x < im->width; x++) {
			uint32_t v = row[x];
			o[3 * x] = v >> rs;
			o[3 * x + 1] = v >> gs;
			o[3 * x + 2] = v >> bs;
		}
	}
	im->f.destroy_image(im);
	return 0;
}

static void be32(uint8_t *p, uint32_t v) {
	p[0] = v >> 24;
	p[1] = v >> 16;
	p[2] = v >> 8;
	p[3] = v;
}

// An RGB PNG in memory (zlib's compress2 makes the IDAT stream).
static uint8_t *png_encode(const uint8_t *rgb, int w, int h, size_t *len) {
	size_t raw_len = (size_t)(w * 3 + 1) * h;
	uint8_t *raw = malloc(raw_len);
	for (int y = 0; y < h; y++) {
		raw[(size_t)y * (w * 3 + 1)] = 0;
		memcpy(raw + (size_t)y * (w * 3 + 1) + 1, rgb + (size_t)y * w * 3, (size_t)w * 3);
	}
	uLongf zlen = z_bound(raw_len);
	uint8_t *out = malloc(zlen + 64);
	static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
	memcpy(out, sig, 8);
	size_t o = 8;
	// IHDR
	be32(out + o, 13);
	memcpy(out + o + 4, "IHDR", 4);
	be32(out + o + 8, w);
	be32(out + o + 12, h);
	out[o + 16] = 8, out[o + 17] = 2, out[o + 18] = 0, out[o + 19] = 0, out[o + 20] = 0;
	be32(out + o + 21, z_crc32(0, out + o + 4, 17));
	o += 25;
	// IDAT
	z_compress2(out + o + 8, &zlen, raw, raw_len, 3);
	be32(out + o, zlen);
	memcpy(out + o + 4, "IDAT", 4);
	be32(out + o + 8 + zlen, z_crc32(0, out + o + 4, zlen + 4));
	o += 12 + zlen;
	// IEND
	be32(out + o, 0);
	memcpy(out + o + 4, "IEND", 4);
	be32(out + o + 8, z_crc32(0, out + o + 4, 4));
	o += 12;
	free(raw);
	*len = o;
	return out;
}

// --- commands: from the script, then the listener

struct reply {
	char line[65536];
	uint8_t *bytes;
	size_t nbytes;
	int quit;
};

static int g_in_game; // the in-game frames run commands (view_game)
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static char *g_inbox;            // a listener's command waiting for the main thread
static struct reply *g_outbox;   // its reply
static FILE *g_script, *g_replies;

struct cmd {
	int active, from_listener;
	char line[1024];
	int frames;    // frames since it started
	double t0;
	uint8_t *prev; // the last capture (frame)
	int pw, ph;
	int stage;
	// the input commands that take frames (hold, drag, tick, wait): frames (or seconds) to wait,
	// the step, the chord or button, the path
	int n, step, steps, button;
	double secs;
	char chord[64];
	int path[4];
};
static struct cmd C;

static void reply_done(struct reply *r) {
	if (C.from_listener) {
		pthread_mutex_lock(&g_mx);
		g_outbox = r;
		pthread_cond_broadcast(&g_cv);
		pthread_mutex_unlock(&g_mx);
	} else {
		FILE *f = g_replies ? g_replies : stdout;
		fprintf(f, "> %s\n%s\n", C.line, r->line);
		fflush(f);
		hlog("%s -> %s", C.line, r->line);
		int quit = r->quit;
		free(r->bytes);
		free(r);
		if (quit) {
			fflush(NULL);
			_exit(0);
		}
	}
	free(C.prev);
	memset(&C, 0, sizeof C);
}

static void reply_fmt(const char *fmt, ...) {
	struct reply *r = calloc(1, sizeof *r);
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(r->line, sizeof r->line, fmt, ap);
	va_end(ap);
	reply_done(r);
}

// The next command, if none is running: the script's next line, else the listener's.
static int next_command(void) {
	if (C.active) return 1;
	if (g_script) {
		char line[1024];
		while (fgets(line, sizeof line, g_script)) {
			char *s = line;
			while (*s == ' ' || *s == '\t') s++;
			s[strcspn(s, "\r\n")] = 0;
			if (!*s || *s == '#') continue;
			memset(&C, 0, sizeof C);
			snprintf(C.line, sizeof C.line, "%s", s);
			C.active = 1;
			C.t0 = now();
			return 1;
		}
		fclose(g_script);
		g_script = NULL;
		if (!getenv("HEADLESS_LISTEN") || !*getenv("HEADLESS_LISTEN")) {
			hlog("view: the script is done");
			fflush(NULL);
			_exit(0);
		}
	}
	pthread_mutex_lock(&g_mx);
	// lockstep (a timestep set, in game): no frame runs between commands, the main thread waits
	// here for the next one
	while (g_timestep > 0 && g_in_game && !g_inbox) pthread_cond_wait(&g_cv, &g_mx);
	if (g_inbox) {
		memset(&C, 0, sizeof C);
		snprintf(C.line, sizeof C.line, "%s", g_inbox);
		free(g_inbox);
		g_inbox = NULL;
		C.active = C.from_listener = 1;
		C.t0 = now();
	}
	pthread_mutex_unlock(&g_mx);
	return C.active;
}

static void *listener(void *arg) {
	const char *spec = arg;
	char host[256] = "127.0.0.1";
	int port;
	const char *colon = strrchr(spec, ':');
	if (colon) {
		snprintf(host, sizeof host, "%.*s", (int)(colon - spec), spec);
		port = atoi(colon + 1);
	} else {
		port = atoi(spec);
	}
	int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	struct sockaddr_in sa = {.sin_family = AF_INET, .sin_port = htons(port)};
	inet_pton(AF_INET, host, &sa.sin_addr);
	if (bind(s, (struct sockaddr *)&sa, sizeof sa) || listen(s, 1)) {
		hlog("view: cannot listen on %s:%d", host, port);
		return NULL;
	}
	hlog("view: listening on %s:%d", host, port);
	for (;;) {
		int c = accept(s, NULL, NULL);
		if (c < 0) continue;
		FILE *in = fdopen(dup(c), "r");
		char line[1024];
		while (in && fgets(line, sizeof line, in)) {
			line[strcspn(line, "\r\n")] = 0;
			if (!line[0]) continue;
			pthread_mutex_lock(&g_mx);
			g_inbox = strdup(line);
			g_outbox = NULL;
			pthread_cond_broadcast(&g_cv);
			while (!g_outbox) pthread_cond_wait(&g_cv, &g_mx);
			struct reply *r = g_outbox;
			g_outbox = NULL;
			pthread_mutex_unlock(&g_mx);
			hlog("%s -> %s", line, r->line);
			char nl = '\n';
			int ok = write(c, r->line, strlen(r->line)) >= 0 && write(c, &nl, 1) == 1;
			if (ok && r->bytes) ok = write(c, r->bytes, r->nbytes) == (ssize_t)r->nbytes;
			int quit = r->quit;
			free(r->bytes);
			free(r);
			if (quit) {
				fflush(NULL);
				_exit(0);
			}
			if (!ok) break;
		}
		if (in) fclose(in);
		close(c);
	}
	return NULL;
}

// --- input: real key presses, pointer moves, buttons and wheel notches, made by the X server's
// XTest devices (libXtst, loaded at run time) as a keyboard and a mouse make them, so the game
// reads them its own way (SDL's X11 events, its CKeyBoard and CMouse). Injected from CheckTick
// (frame f), they reach the game when SDL pumps the events at the start of frame f + 1: the
// camera's update of frame f does not see them, that of f + 1 does. The renderer's controls
// (sim/render/src/controls.rs) model the same latency in lockstep. Key names are the renderer's
// (controls.rs `KEYS`): X keysym names lower-cased, with aliases.

struct keyname {
	const char *name, *keysym;
	int shift; // typed with Shift on a US layout
};
static const struct keyname g_keys[] = {
	{"space", "space", 0},         {"escape", "Escape", 0},     {"return", "Return", 0},
	{"tab", "Tab", 0},             {"backspace", "BackSpace", 0}, {"up", "Up", 0},
	{"down", "Down", 0},           {"left", "Left", 0},         {"right", "Right", 0},
	{"pageup", "Prior", 0},        {"pagedown", "Next", 0},     {"home", "Home", 0},
	{"end", "End", 0},             {"insert", "Insert", 0},     {"delete", "Delete", 0},
	{"kp_plus", "KP_Add", 0},      {"kp_minus", "KP_Subtract", 0}, {"kp_multiply", "KP_Multiply", 0},
	{"kp_divide", "KP_Divide", 0}, {"kp_enter", "KP_Enter", 0}, {"kp_period", "KP_Decimal", 0},
	{"plus", "equal", 1},          {"minus", "minus", 0},       {"equal", "equal", 0},
	{"period", "period", 0},       {"comma", "comma", 0},       {"slash", "slash", 0},
	{"semicolon", "semicolon", 0}, {"apostrophe", "apostrophe", 0}, {"grave", "grave", 0},
	{"bracketleft", "bracketleft", 0}, {"bracketright", "bracketright", 0}, {"backslash", "backslash", 0},
	{"shift", "Shift_L", 0},       {"ctrl", "Control_L", 0},    {"alt", "Alt_L", 0},
	{"pause", "Pause", 0},         {"print", "Print", 0},       {NULL, NULL, 0},
};
static const char *g_key_alias[][2] = {
	{".", "period"},    {"+", "plus"},       {"=", "equal"},       {"-", "minus"},        {",", "comma"},
	{"/", "slash"},     {";", "semicolon"},  {"'", "apostrophe"},  {"`", "grave"},        {"[", "bracketleft"},
	{"]", "bracketright"}, {"\\", "backslash"}, {"esc", "escape"},  {"enter", "return"},   {"pgup", "pageup"},
	{"prior", "pageup"}, {"pgdn", "pagedown"}, {"next", "pagedown"}, {"del", "delete"},    {"kp_add", "kp_plus"},
	{"kp_subtract", "kp_minus"}, {"control", "ctrl"}, {"lshift", "shift"}, {"lctrl", "ctrl"}, {"lalt", "alt"},
	{NULL, NULL},
};

// The input's delivery: the events injected (each key press or release, button press or release,
// pointer move to another pixel, wheel notch makes one SDL event) and those the game's SDL took
// (an event watch: SDL_AddEventWatch). Most reach the frame after the one they were injected in;
// when the X server or the game was slow some reach a frame later still, and such a frame is
// held (view_game: the camera's update not run, the frame not counted) until all have come, so
// that each command sees its frames exactly. HEADLESS_INPUT_TRACE=1 logs each event (SDL2's
// SDL_Event: type +0, timestamp +4; keys: state +12, repeat +13, scancode +16, sym +20, mod +24;
// buttons: button +16, state +17, clicks +18, x +20, y +24; motion: x +20, y +24, rel +28 +32;
// wheel: x +16, y +20).

static int g_frame_no;               // the in-game frames run (CheckTick calls, held ones not) since the load
static int g_injected, g_delivered;  // input events injected, and taken by the game's SDL
static int g_held_frames, g_held_total; // frames held for the input's delivery (now, in all)
static double g_held_since;
static int g_input_trace;

static int input_watch(void *data, void *ev) {
	(void)data;
	uint8_t *e = ev;
	uint32_t type = *(uint32_t *)e, ts = *(uint32_t *)(e + 4);
	if (type == 0x300 || type == 0x301 || (type >= 0x400 && type <= 0x403)) g_delivered++;
	if (!g_input_trace) return 1;
	if (type == 0x300 || type == 0x301)
		hlog("sdl frame %d t %u key %s sym %#x scancode %d mod %#x repeat %d", g_frame_no, ts, type == 0x300 ? "down" : "up",
		     *(int32_t *)(e + 20), *(int32_t *)(e + 16), *(uint16_t *)(e + 24), e[13]);
	else if (type == 0x401 || type == 0x402)
		hlog("sdl frame %d t %u button %d %s clicks %d at %d,%d", g_frame_no, ts, e[16], type == 0x401 ? "down" : "up", e[18],
		     *(int32_t *)(e + 20), *(int32_t *)(e + 24));
	else if (type == 0x400)
		hlog("sdl frame %d t %u motion to %d,%d rel %d,%d", g_frame_no, ts, *(int32_t *)(e + 20), *(int32_t *)(e + 24),
		     *(int32_t *)(e + 28), *(int32_t *)(e + 32));
	else if (type == 0x403)
		hlog("sdl frame %d t %u wheel %d,%d", g_frame_no, ts, *(int32_t *)(e + 16), *(int32_t *)(e + 20));
	return 1;
}

static Window g_win;
static int g_win_x, g_win_y, g_input_ok = -1;
static int g_ptr_x = -1, g_ptr_y = -1, g_buttons; // the pointer as we put it, buttons held (bit per button)
static char g_keys_down[512];                    // the keys we hold, " name name "
static unsigned g_released_code;                 // the last key event, a release: its key

// The XTest extension, the game's window and its place, the keyboard's focus on it (SDL takes
// key events and the window's focus from it), the server's key repeat off (a key held across
// commands would repeat in real time).
static int input_init(void) {
	if (g_input_ok >= 0) return g_input_ok;
	g_input_ok = 0;
	int ev, er, maj, min, w, h;
	Window child;
	if (!X.fake_key || (!g_dpy && !(g_dpy = X.open(NULL))) || !X.xtest_query(g_dpy, &ev, &er, &maj, &min)) {
		hlog("view: no XTest: input commands fail");
		return 0;
	}
	if (!(g_win = game_window(&w, &h))) return 0;
	X.translate(g_dpy, g_win, X.root(g_dpy), 0, 0, &g_win_x, &g_win_y, &child);
	X.set_input_focus(g_dpy, g_win, RevertToPointerRoot, CurrentTime);
	X.autorepeat_off(g_dpy);
	// where the pointer is (a move there makes no event)
	Window rw, cw;
	int rx, ry, wx, wy;
	unsigned int mask;
	if (X.query_pointer && X.query_pointer(g_dpy, g_win, &rw, &cw, &rx, &ry, &wx, &wy, &mask)) g_ptr_x = wx, g_ptr_y = wy;
	X.sync(g_dpy, False);
	hlog("view: input by XTest %d.%d into window %#lx at %d,%d (%dx%d)", maj, min, (unsigned long)g_win, g_win_x, g_win_y, w, h);
	const char *trace = getenv("HEADLESS_INPUT_TRACE");
	g_input_trace = trace && *trace == '1';
	((void (*)(int (*)(void *, void *), void *))a_SDL_AddEventWatch)(input_watch, NULL);
	return g_input_ok = 1;
}

static const char *key_canonical(const char *name) {
	for (int i = 0; g_key_alias[i][0]; i++)
		if (!strcmp(name, g_key_alias[i][0])) return g_key_alias[i][1];
	return name;
}

// The key's X keycode (0 if unknown) and whether Shift types it.
static unsigned key_code(const char *name, int *shift) {
	char sym[32];
	*shift = 0;
	name = key_canonical(name);
	const char *ks = NULL;
	for (int i = 0; g_keys[i].name; i++)
		if (!strcmp(name, g_keys[i].name)) ks = g_keys[i].keysym, *shift = g_keys[i].shift;
	if (!ks) {
		size_t n = strlen(name);
		if (n == 1 && ((name[0] >= 'a' && name[0] <= 'z') || (name[0] >= '0' && name[0] <= '9')))
			ks = name;
		else if (name[0] == 'f' && n <= 3 && atoi(name + 1) >= 1 && atoi(name + 1) <= 24)
			snprintf(sym, sizeof sym, "F%d", atoi(name + 1)), ks = sym;
		else if (!strncmp(name, "kp_", 3) && n == 4 && name[3] >= '0' && name[3] <= '9')
			snprintf(sym, sizeof sym, "KP_%c", name[3]), ks = sym;
		else
			return 0;
	}
	KeySym s = X.string_to_keysym(ks);
	return s == NoSymbol ? 0 : X.keysym_to_keycode(g_dpy, s);
}

static void keys_down_set(const char *name, int down) {
	char pat[72];
	snprintf(pat, sizeof pat, " %s ", name);
	char *at = strstr(g_keys_down, pat);
	if (down && !at && strlen(g_keys_down) + strlen(pat) < sizeof g_keys_down) {
		if (!g_keys_down[0]) strcpy(g_keys_down, " ");
		strcat(g_keys_down, pat + 1);
	} else if (!down && at) {
		memmove(at, at + strlen(pat) - 1, strlen(at + strlen(pat) - 1) + 1);
	}
}

// A key pressed or released. A press right after the same key's release: SDL's X11 takes a release
// followed by a press of the same key less than 2 ms later (server time) for the keyboard's repeat
// and drops the release, so the press comes 5 ms later (XTest's delay).
static void key_event(unsigned code, int down) {
	X.fake_key(g_dpy, code, down ? True : False, down && code == g_released_code ? 5 : CurrentTime);
	g_released_code = down ? 0 : code;
	g_injected++;
}

// A chord ("w", "shift+up", "ctrl+shift+backspace", "+") pressed or released: the modifiers
// first and the key last, released the other way round. 0, or -1 with *err set.
static int chord(const char *spec, int down, const char **err) {
	char mods[3][8];
	int nm = 0;
	const char *k = spec;
	for (;;) {
		const char *names[] = {"shift+", "ctrl+", "control+", "alt+"};
		int found = 0;
		for (int i = 0; i < 4 && !found; i++)
			if (!strncasecmp(k, names[i], strlen(names[i])) && k[strlen(names[i])]) {
				if (nm < 3) snprintf(mods[nm++], sizeof mods[0], "%s", i == 0 ? "shift" : i == 3 ? "alt" : "ctrl");
				k += strlen(names[i]);
				found = 1;
			}
		if (!found) break;
	}
	char key[48];
	snprintf(key, sizeof key, "%s", k);
	for (char *p = key; *p; p++) *p = (char)(*p >= 'A' && *p <= 'Z' ? *p + 32 : *p);
	int shift;
	unsigned code = key_code(key, &shift);
	if (!code) {
		*err = "unknown key";
		return -1;
	}
	if (shift && nm < 3) snprintf(mods[nm++], sizeof mods[0], "shift");
	int s;
	if (down) {
		for (int i = 0; i < nm; i++) {
			key_event(key_code(mods[i], &s), 1);
			keys_down_set(mods[i], 1);
		}
		key_event(code, 1);
		keys_down_set(key_canonical(key), 1);
	} else {
		key_event(code, 0);
		keys_down_set(key_canonical(key), 0);
		for (int i = nm - 1; i >= 0; i--) {
			key_event(key_code(mods[i], &s), 0);
			keys_down_set(mods[i], 0);
		}
	}
	return 0;
}

static int button_num(const char *b) {
	if (!strcmp(b, "left")) return 1;
	if (!strcmp(b, "middle")) return 2;
	if (!strcmp(b, "right")) return 3;
	return 0;
}

static void pointer_to(int x, int y) {
	if (x == g_ptr_x && y == g_ptr_y) return; // the X server sends no motion for no move
	X.fake_motion(g_dpy, -1, g_win_x + x, g_win_y + y, CurrentTime);
	g_ptr_x = x, g_ptr_y = y;
	g_injected++;
}

static void button(int b, int down) {
	X.fake_button(g_dpy, b, down ? True : False, CurrentTime);
	if (b <= 3) g_buttons = down ? g_buttons | 1 << b : g_buttons & ~(1 << b);
	// a wheel button's release makes no SDL event
	if (b <= 3 || down) g_injected++;
}

// Wheel notches: > 0 away from the user (button 4, the game zooms in), < 0 toward (5).
static void wheel(int n) {
	for (int i = 0; i < abs(n); i++) button(n > 0 ? 4 : 5, 1), button(n > 0 ? 4 : 5, 0);
}

// A duration: "N" or "Nf" frames, "Nms" or "Ns" time; *secs < 0 for frames.
static int duration(const char *s, int *frames, double *secs) {
	char *end;
	double v = strtod(s, &end);
	if (end == s || v < 0) return -1;
	*frames = 0, *secs = -1;
	if (!*end || !strcmp(end, "f"))
		*frames = (int)v;
	else if (!strcmp(end, "ms"))
		*secs = v / 1000;
	else if (!strcmp(end, "s"))
		*secs = v;
	else
		return -1;
	// with a timestep a time is that many frames (rounded), as the renderer counts it
	if (*secs >= 0 && g_timestep > 0) *frames = (int)(*secs / g_timestep + 0.5), *secs = -1;
	return 0;
}

// One frame of a command that waits: whether its frames (or its time) are done.
static int waited(void) {
	C.frames++;
	return C.secs >= 0 ? now() - C.t0 >= C.secs : C.frames >= C.n;
}


// The input commands; 1 if the verb is one of them (its reply sent, or C.active kept to go on
// next frame).
static int input_command(const char *verb, const char *arg) {
	static const char *verbs[] = {"key", "hold", "mouse", "move", "button", "click", "wheel", "scroll", "drag", NULL};
	int is = 0;
	for (int i = 0; verbs[i]; i++) is |= !strcmp(verb, verbs[i]);
	if (!is) return 0;
	if (C.stage == 0 && !input_init()) {
		reply_fmt("error %s: no input (XTest or the game's window missing)", verb);
		return 1;
	}
	const char *err = NULL;
	char a[4][64] = {{0}};
	int n = sscanf(arg, "%63s %63s %63s %63s", a[0], a[1], a[2], a[3]);
	if (C.stage == 0) g_cam_set = 0; // input moves the camera from where `camera` left it
	if (!strcmp(verb, "key")) {
		// key CHORD [down|up|tap]: tap (the default) presses and releases in the same frame
		if (n < 1) return reply_fmt("error key CHORD [down|up|tap]"), 1;
		const char *how = n > 1 ? a[1] : "tap";
		int rc = !strcmp(how, "up") ? chord(a[0], 0, &err) : chord(a[0], 1, &err);
		if (rc == 0 && !strcmp(how, "tap")) chord(a[0], 0, &err);
		X.sync(g_dpy, False);
		if (rc) return reply_fmt("error key %s: %s", a[0], err), 1;
		reply_fmt("ok key %s %s frame %d", a[0], how, g_frame_no);
	} else if (!strcmp(verb, "hold")) {
		// hold CHORD DURATION: pressed, DURATION passes (frames, or time), released
		if (C.stage == 0) {
			if (n < 2 || duration(a[1], &C.n, &C.secs)) return reply_fmt("error hold CHORD FRAMES|Nf|Nms|Ns"), 1;
			if (chord(a[0], 1, &err)) return reply_fmt("error hold %s: %s", a[0], err), 1;
			snprintf(C.chord, sizeof C.chord, "%s", a[0]);
			X.sync(g_dpy, False);
			C.stage = 1;
			C.t0 = now();
			if (C.n > 0 || C.secs > 0) return 1;
		} else if (!waited()) {
			return 1;
		}
		chord(C.chord, 0, &err);
		X.sync(g_dpy, False);
		reply_fmt("ok hold %s %d frames frame %d", C.chord, C.frames, g_frame_no);
	} else if (!strcmp(verb, "mouse") || !strcmp(verb, "move")) {
		// mouse X Y [BUTTON [down|up]]: the pointer to the pixel; a button alone clicks
		if (n < 2) return reply_fmt("error %s X Y [left|right|middle [down|up]]", verb), 1;
		pointer_to(atoi(a[0]), atoi(a[1]));
		if (n > 2) {
			int b = button_num(a[2]);
			if (!b) return reply_fmt("error mouse: button %s", a[2]), 1;
			if (n < 4 || !strcmp(a[3], "down")) button(b, 1);
			if (n < 4 || !strcmp(a[3], "up")) button(b, 0);
		}
		X.sync(g_dpy, False);
		reply_fmt("ok %s %d %d frame %d", verb, g_ptr_x, g_ptr_y, g_frame_no);
	} else if (!strcmp(verb, "button")) {
		// button BUTTON down|up [X Y]
		int b = button_num(a[0]);
		if (n < 2 || !b || (strcmp(a[1], "down") && strcmp(a[1], "up"))) return reply_fmt("error button left|right|middle down|up [X Y]"), 1;
		if (n >= 4) pointer_to(atoi(a[2]), atoi(a[3]));
		button(b, !strcmp(a[1], "down"));
		X.sync(g_dpy, False);
		reply_fmt("ok button %s %s at %d %d frame %d", a[0], a[1], g_ptr_x, g_ptr_y, g_frame_no);
	} else if (!strcmp(verb, "click")) {
		// click X Y [BUTTON] [double]: pressed and released there (twice for double), one frame
		if (n < 2) return reply_fmt("error click X Y [left|right|middle] [double]"), 1;
		int b = n > 2 && button_num(a[2]) ? button_num(a[2]) : 1;
		int twice = (n > 2 && !strcmp(a[2], "double")) || (n > 3 && !strcmp(a[3], "double"));
		pointer_to(atoi(a[0]), atoi(a[1]));
		for (int i = 0; i <= twice; i++) button(b, 1), button(b, 0);
		X.sync(g_dpy, False);
		reply_fmt("ok click %d %d%s frame %d", g_ptr_x, g_ptr_y, twice ? " double" : "", g_frame_no);
	} else if (!strcmp(verb, "wheel") || !strcmp(verb, "scroll")) {
		// wheel NOTCHES [X Y]: > 0 away from the user (zoom in); a notch a frame (UpdateZoom
		// takes a frame's last notch only)
		if (C.stage == 0) {
			if (n < 1) return reply_fmt("error %s NOTCHES [X Y]", verb), 1;
			if (n >= 3) pointer_to(atoi(a[1]), atoi(a[2]));
			double nv = atof(a[0]);
			int notches = (int)(nv < 0 ? nv - 0.5 : nv + 0.5);
			C.steps = abs(notches), C.button = notches < 0 ? -1 : 1, C.stage = 1;
		}
		if (C.step < C.steps) {
			wheel(C.button);
			X.sync(g_dpy, False);
			if (++C.step < C.steps) return 1;
		}
		reply_fmt("ok %s %d frame %d", verb, C.steps * C.button, g_frame_no);
	} else if (!strcmp(verb, "drag")) {
		// drag BUTTON X0 Y0 X1 Y1 [STEPS [FRAMES]]: down at the start, FRAMES frames, then STEPS
		// moves along the line each followed by FRAMES frames, released at the end
		if (C.stage == 0) {
			int v[6] = {0, 0, 0, 0, 10, 1};
			int k = sscanf(arg, "%63s %d %d %d %d %d %d", a[0], &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]);
			C.button = button_num(a[0]);
			if (k < 5 || !C.button || v[4] < 1 || v[5] < 1) return reply_fmt("error drag BUTTON X0 Y0 X1 Y1 [STEPS [FRAMES]]"), 1;
			memcpy(C.path, v, sizeof C.path);
			C.steps = v[4], C.n = v[5], C.secs = -1;
			pointer_to(v[0], v[1]);
			button(C.button, 1);
			X.sync(g_dpy, False);
			C.stage = 1;
			return 1;
		}
		if (!waited()) return 1;
		if (C.step < C.steps) {
			C.step++;
			pointer_to(C.path[0] + (C.path[2] - C.path[0]) * C.step / C.steps, C.path[1] + (C.path[3] - C.path[1]) * C.step / C.steps);
			X.sync(g_dpy, False);
			C.frames = 0;
			return 1;
		}
		button(C.button, 0);
		X.sync(g_dpy, False);
		reply_fmt("ok drag to %d %d frame %d", g_ptr_x, g_ptr_y, g_frame_no);
	}
	return 1;
}

// --- the commands themselves (on the main thread, from the main menu or from CheckTick)

static char g_loaded[1024];
static int g_in_game_frames;

static const char *user_dir(char *buf, size_t n) {
	const char *home = getenv("HOME");
	snprintf(buf, n, "%s/.local/share/Paradox Interactive/Stellaris", home ? home : ".");
	return buf;
}

static int copy_file(const char *src, const char *dst) {
	FILE *in = fopen(src, "rb"), *out = in ? fopen(dst, "wb") : NULL;
	if (!in || !out) {
		if (in) fclose(in);
		return -1;
	}
	char buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
	fclose(in);
	fclose(out);
	return 0;
}

static void launch(const char *rel) {
	void *fe = *(void **)a_g_CurrentFrontEndIdler;
	_Alignas(16) uint8_t path[0x30];
	((void (*)(void *, const char *))a_CStringCtor)(path, rel);
	g_launched = 1;
	hlog("LaunchSave(\"%s\")", rel);
	((void (*)(void *, const void *, int, const void *))a_LaunchSave)(fe, path, 0, (char *)fe + 0x250);
}

static void date_str(void *gs, char *buf, size_t n) {
	int d = I32((char *)gs + 0xc4); // days since 0.01.01, 360-day years
	snprintf(buf, n, "%04d.%02d.%02d", d / 360, d % 360 / 30 + 1, d % 30 + 1);
}

static void view_menu(void) {
	if (!*(void **)a_g_CurrentFrontEndIdler || !next_command()) return;
	char verb[64] = "", arg[960] = "";
	sscanf(C.line, "%63s %959[^\n]", verb, arg);
	if (!strcmp(verb, "load")) {
		if (g_launched) return; // the game is loading it: the reply comes from CheckTick
		char ud[1024], dst[2048], rel[1024];
		const char *base = strrchr(arg, '/');
		base = base ? base + 1 : arg;
		snprintf(rel, sizeof rel, "save games/headless/%s", base);
		snprintf(dst, sizeof dst, "%s/%s", user_dir(ud, sizeof ud), rel);
		char dir[2048];
		snprintf(dir, sizeof dir, "%s/save games", ud);
		mkdir(dir, 0755);
		snprintf(dir, sizeof dir, "%s/save games/headless", ud);
		mkdir(dir, 0755);
		if (copy_file(arg, dst) != 0) {
			reply_fmt("error load %s: cannot read it", arg);
			return;
		}
		snprintf(g_loaded, sizeof g_loaded, "%s", arg);
		launch(rel);
		return;
	}
	if (!strcmp(verb, "quit")) {
		struct reply *r = calloc(1, sizeof *r);
		snprintf(r->line, sizeof r->line, "ok quit");
		r->quit = 1;
		reply_done(r);
		return;
	}
	if (!strcmp(verb, "pause") || !strcmp(verb, "resize") || !strcmp(verb, "gui")) {
		reply_fmt("ok %s (main menu)", verb);
		return;
	}
	if (!strcmp(verb, "state")) {
		reply_fmt("ok {\"screen\":\"menu\"}");
		return;
	}
	reply_fmt("error %s: no game loaded (load SAVE first)", verb);
}

static void json_floats(char **p, char *end, const char *name, const float *v, int n, int last) {
	*p += snprintf(*p, end - *p, "\"%s\":[", name);
	for (int i = 0; i < n; i++) *p += snprintf(*p, end - *p, "%s%.6g", i ? "," : "", v[i]);
	*p += snprintf(*p, end - *p, "]%s", last ? "" : ",");
}

static void state_json(void *gs, const char *arg) {
	struct reply *r = calloc(1, sizeof *r);
	char *p = r->line, *end = r->line + sizeof r->line;
	char date[32];
	date_str(gs, date, sizeof date);
	char *cam = camera();
	int sys = camera_system(cam);
	float k = space_scale(cam), rad = 180.0f / 3.14159265f;
	float *cur = (float *)(cam + 0x218), *tgt = (float *)(cam + 0x230);
	int w = 0, h = 0;
	game_window(&w, &h);
	p += snprintf(p, end - p, "ok {\"screen\":\"game\",\"date\":\"%s\",\"days\":%d,\"ticks\":%d,", date,
	              I32((char *)gs + 0xc4), total_ticks(gs));
	// the input as the commands left it: the pointer, the buttons and keys held, the timestep
	char keys[600] = "";
	for (char *k = g_keys_down, *q = keys; *k;) {
		while (*k == ' ') k++;
		if (!*k) break;
		size_t n = strcspn(k, " ");
		q += snprintf(q, keys + sizeof keys - q, "%s\"%.*s\"", q == keys ? "" : ",", (int)n, k);
		k += n;
	}
	// the clock as the keys leave it (the game's own ticks never run here): CInGameIdler +0x594
	// paused (CPauseGame), +0x590 the speed 0..4 (Increase/DecreaseGameSpeedCommand)
	char *idler = *(char **)a_g_CurrentInGameIdler;
	if (idler)
		p += snprintf(p, end - p, "\"clock\":{\"paused\":%s,\"speed\":%d},", U8(idler + 0x594) ? "true" : "false",
		              I32(idler + 0x590) + 1);
	p += snprintf(p, end - p,
	              "\"input\":{\"pointer\":[%d,%d],\"buttons\":[%s%s%s],\"keys\":[%s],\"timestep\":%.3f,\"lockstep\":%s,\"frame\":%d,\"held_frames\":%d},",
	              g_ptr_x, g_ptr_y, g_buttons & 2 ? "\"left\"" : "", g_buttons & 4 ? (g_buttons & 2 ? ",\"middle\"" : "\"middle\"") : "",
	              g_buttons & 8 ? (g_buttons & 6 ? ",\"right\"" : "\"right\"") : "", keys, g_timestep * 1000,
	              g_timestep > 0 ? "true" : "false", g_frame_no, g_held_total);
	if (sys == -1)
		p += snprintf(p, end - p, "\"view\":\"galaxy\",");
	else
		p += snprintf(p, end - p, "\"view\":\"system %d\",", sys);
	p += snprintf(p, end - p, "\"window\":[%d,%d],\"gui\":%s,\"space_scale\":%g,\"camera_set\":%s,", w, h,
	              U8(a_g_bNoGUI) ? "false" : "true", k, g_cam_set ? "true" : "false");
	p += snprintf(p, end - p, "\"camera\":{\"target\":[%.4f,%.4f,%.4f],\"distance\":%.4f,\"pitch\":%.4f,\"yaw\":%.4f,",
	              cur[0], cur[1], cur[2], cur[3], cur[4] * rad, cur[5] * rad);
	p += snprintf(p, end - p, "\"to\":{\"target\":[%.4f,%.4f,%.4f],\"distance\":%.4f,\"pitch\":%.4f,\"yaw\":%.4f},",
	              tgt[0], tgt[1], tgt[2], tgt[3], tgt[4] * rad, tgt[5] * rad);
	json_floats(&p, end, "eye", (float *)(cam + 0x180), 3, 0);
	json_floats(&p, end, "lookat", (float *)(cam + 0x18c), 3, 0);
	json_floats(&p, end, "up", (float *)(cam + 0x198), 3, 0);
	p += snprintf(p, end - p, "\"fov\":%.5f,\"aspect\":%.5f,\"near\":%.5g,\"far\":%.5g,", F32(cam + 0x1a4) * rad,
	              F32(cam + 0x1a8), F32(cam + 0x1ac), F32(cam + 0x1b0));
	json_floats(&p, end, "view", (float *)cam, 16, 0);
	json_floats(&p, end, "proj", (float *)(cam + 0x40), 16, 1);
	p += snprintf(p, end - p, "}");
	// the zoom steps (CGameCamera::GetZoomStepArray: NCamera::ZOOM_STEPS_GALAXY on the galaxy,
	// the system's own at +0x2c8, a CPdxArray<float>: data +8, count +0x14); the zoom is the
	// distance (+0x224, read as CInGameIdler +0x43c by CPlanet::CalcCurrentEntityScale)
	{
		char *arr = sys == -1 ? NULL : cam + 0x2c8;
		if (arr) {
			int n = I32(arr + 0x14);
			if (n > 0 && n < 64) {
				p += snprintf(p, end - p, ",");
				json_floats(&p, end, "zoom_steps", *(float **)(arr + 8), n, 1);
			}
		}
	}
	int pid;
	if (sscanf(arg, "planet %d", &pid) == 1) {
		char *pl = planet(gs, pid);
		if (!pl) {
			p += snprintf(p, end - p, ",\"planet\":null");
		} else {
			void *e = *(void **)(pl + 0xc20);
			float scale = ((float (*)(void *))a_PlanetEntityScale)(pl);
			float size = ((float (*)(void *))a_PlanetDisplaySize)(pl);
			p += snprintf(p, end - p, ",\"planet\":{\"id\":%d,\"size\":%d,\"entity_scale\":%.5f,\"display_size\":%.5f,", pid,
			              I32(pl + 0x150), scale, size);
			if (e) {
				const float *m = ((const float *(*)(void *))a_EntityWorldTransform)(e);
				json_floats(&p, end, "world", m, 16, 1);
			} else {
				p += snprintf(p, end - p, "\"world\":null");
			}
			p += snprintf(p, end - p, "}");
		}
	}
	snprintf(p, end - p, "}");
	reply_done(r);
}

// Runs ticks until the date has moved `days` days: the loop mode's turns (nothing rendered; frame
// smoothing off so that no frame is drawn from inside a tick).
static void step_days(void *gs, int days) {
	uint8_t s_ggs = U8(a_g_AllowGlobalGameStateAccess), s_gp = U8(a_g_AllowGetPlayer),
	        s_pc = U8(a_g_AllowPostCommandToSession), s_fs = U8(a_g_bFrameSmoothing);
	U8(a_g_bFrameSmoothing) = 0;
	int target = I32((char *)gs + 0xc4) + days, stalls = 0;
	while (I32((char *)gs + 0xc4) < target) {
		int before = total_ticks(gs);
		U8(a_g_AllowPostCommandToSession) = 1;
		for (int i = 0, k = per_turn(); i < k; i++) post_tick();
		app_update();
		if (g_autosave) handle_autosave(gs);
		if (total_ticks(gs) == before && ++stalls > 100) break;
	}
	U8(a_g_AllowGlobalGameStateAccess) = s_ggs;
	U8(a_g_AllowGetPlayer) = s_gp;
	U8(a_g_AllowPostCommandToSession) = s_pc;
	U8(a_g_bFrameSmoothing) = s_fs;
}

static int g_frame_min = 10;
static int g_frame_now;
static double g_frame_wait = 2.0, g_frame_timeout = 30.0;

// `frame`: from HEADLESS_FRAME_WAIT seconds (default 2: the GUI's fades, the camera's last
// smoothing) and HEADLESS_FRAME_MIN frames on, a capture a frame; done when two in a row differ by
// less than 0.25/255 on average (sampled), or after HEADLESS_FRAME_TIMEOUT seconds (default 30).
// `frame PATH now`: the camera's update is not run meanwhile (the camera stays as the input left
// it; the game draws fewer frames than it updates, so the last update is drawn some frames
// later): from 0.3 s and 3 frames on, a capture every 0.1 s until two agree, at most 3 s.
static void frame_cmd(const char *arg) {
	C.frames++;
	double t = now() - C.t0;
	if (C.frames < (g_frame_now ? 3 : g_frame_min) || t < (g_frame_now ? 0.3 : g_frame_wait)) return;
	if (g_frame_now && C.prev && t - C.secs < 0.1) return;
	C.secs = t;
	uint8_t *img;
	int w, h;
	if (capture(&img, &w, &h) != 0) {
		reply_fmt("error frame: cannot capture the window");
		return;
	}
	double diff = 1e9;
	if (C.prev && C.pw == w && C.ph == h) {
		uint64_t sum = 0, cnt = 0;
		for (size_t i = 0; i < (size_t)w * h * 3; i += 7, cnt++) sum += abs((int)img[i] - (int)C.prev[i]);
		diff = cnt ? (double)sum / cnt : 0;
	}
	free(C.prev);
	C.prev = img, C.pw = w, C.ph = h;
	if (diff > 0.25 && t < (g_frame_now ? 3.0 : g_frame_timeout)) return;
	size_t len;
	uint8_t *png = png_encode(img, w, h, &len);
	double ms = (now() - C.t0) * 1000;
	if (!strcmp(arg, "-")) {
		struct reply *r = calloc(1, sizeof *r);
		snprintf(r->line, sizeof r->line, "ok frame - %d %d %.0f %zu", w, h, ms, len);
		r->bytes = png, r->nbytes = len;
		reply_done(r);
		return;
	}
	FILE *f = fopen(arg, "wb");
	if (!f) {
		free(png);
		reply_fmt("error frame %s: cannot write it", arg);
		return;
	}
	fwrite(png, 1, len, f);
	fclose(f);
	free(png);
	reply_fmt("ok frame %s %d %d %.0f %d%s", arg, w, h, ms, C.frames, g_frame_now ? " now" : diff > 0.25 ? " unsettled" : "");
}

// ---------------------------------------------------------------- `open`: the fleet windows
// (docs/windows/fleet.md) opened with the game's own calls: `open fleet ID` selects the fleet
// (CInGameIdler::Select of its CSelectable, at CFleet+0x18, as CFleetOrbitalItem::SelectFleet
// does: fleet_view opens for the selection), `open ship ID` (CInGameIdler::ShowShipView: the
// ship_view), `open fleet_manager` (CFleetManagerView::Show, the view at CInGameIdler+0xd78),
// `open none` (CInGameIdler::DeselectAll, CShipView::Close: the view at CInGameIdler+0xb60,
// CFleetManagerView::Hide).

static uintptr_t a_IdlerSelect, a_IdlerDeselectAll, a_IdlerShowShipView, a_FleetManagerShow;
static uintptr_t a_ShipViewClose, a_FleetManagerHide;
static uintptr_t a_FleetDb, a_ShipDb;

static struct symreq g_open_syms[] = {
	{"_ZN12CInGameIdler6SelectEPK11CSelectable", &a_IdlerSelect},
	{"_ZN12CInGameIdler11DeselectAllEv", &a_IdlerDeselectAll},
	{"_ZN12CInGameIdler12ShowShipViewEPK5CShip", &a_IdlerShowShipView},
	{"_ZN17CFleetManagerView4ShowEv", &a_FleetManagerShow},
	{"_ZN9CShipView5CloseEv", &a_ShipViewClose},
	{"_ZN17CFleetManagerView4HideEv", &a_FleetManagerHide},
	{"_ZN7TPdxRefI6CFleetE10_pDatabaseE", &a_FleetDb},
	{"_ZN7TPdxRefI5CShipE10_pDatabaseE", &a_ShipDb},
	{NULL, NULL},
};

// a TPdxRef's object: the database's slots (+0x18, 16 bytes each, the object at +8; count at
// +0x20), the object's id at `id_at` (CFleet +0x30, CShip +0x18)
static void *pdx_ref(uintptr_t db_sym, int id, int id_at) {
	char *db = *(char **)db_sym;
	if (!db || id < 0) return NULL;
	uint32_t i = (uint32_t)id & 0xffffff;
	if (i >= *(uint32_t *)(db + 0x20)) return NULL;
	char *o = *(char **)(*(char **)(db + 0x18) + 16 * (size_t)i + 8);
	return o && I32(o + id_at) == id ? o : NULL;
}

static void open_cmd(const char *arg) {
	static int resolved;
	if (!resolved) {
		if (resolve(g_open_syms) != 0) {
			reply_fmt("error open: symbols missing");
			return;
		}
		resolved = 1;
	}
	void *idler = *(void **)a_g_CurrentInGameIdler;
	if (C.stage == 0) {
		char what[32] = "";
		int id = -1;
		sscanf(arg, "%31s %d", what, &id);
		if (!strcmp(what, "fleet")) {
			char *f = pdx_ref(a_FleetDb, id, 0x30);
			if (!f) {
				reply_fmt("error open: no fleet %d", id);
				return;
			}
			((void (*)(void *, void *))a_IdlerSelect)(idler, f + 0x18);
		} else if (!strcmp(what, "ship")) {
			void *s = pdx_ref(a_ShipDb, id, 0x18);
			if (!s) {
				reply_fmt("error open: no ship %d", id);
				return;
			}
			((void (*)(void *, void *))a_IdlerShowShipView)(idler, s);
		} else if (!strcmp(what, "fleet_manager")) {
			((void (*)(void *))a_FleetManagerShow)(*(void **)((char *)idler + 0xd78));
		} else if (!strcmp(what, "none")) {
			((void (*)(void *))a_IdlerDeselectAll)(idler);
			((void (*)(void *))a_ShipViewClose)(*(void **)((char *)idler + 0xb60));
			((void (*)(void *))a_FleetManagerHide)(*(void **)((char *)idler + 0xd78));
		} else {
			reply_fmt("error open fleet ID, ship ID, fleet_manager or none");
			return;
		}
		C.stage = 1;
		return;
	}
	// a few frames for the window to show (fleet_view slides in: animation_time 200)
	if (++C.frames < 20) return;
	reply_fmt("ok open %s", arg);
}

static void view_game(void *gs) {
	if (g_in_game_frames++ == 0) {
		hlog("view: in game after %.3f s", now() - g_t0);
		if (g_rng_pos_set >= 0) {
			*(volatile uint32_t *)a_Random = (uint32_t)g_rng_pos_set;
			*(volatile uint32_t *)a_nRandomCount = (uint32_t)g_rng_pos_set;
		}
	}
	if (g_in_game_frames < g_wait_frames) return;
	g_in_game = 1;
	// a frame the input has not all reached yet is held (at most 2 s of them, then given up)
	if (g_delivered < g_injected) {
		if (g_held_frames++ == 0) g_held_since = now();
		if (now() - g_held_since < 2.0) {
			g_cam_held = 1;
			g_held_total++;
			return;
		}
		hlog("view: %d input events not taken by the game after %d frames: going on", g_injected - g_delivered, g_held_frames);
		g_delivered = g_injected;
	}
	g_cam_held = 0;
	g_held_frames = 0;
	g_frame_no++;
	// the commands that take no frame run one after another in this frame; one that waits for
	// frames goes on in the next (in lockstep next_command waits for a command: no frame between)
	for (int guard = 0; guard < 10000; guard++) {
		if (!next_command()) return;
		view_command(gs);
		if (C.active) return;
	}
}

static void view_command(void *gs) {
	char verb[64] = "", arg[960] = "";
	sscanf(C.line, "%63s %959[^\n]", verb, arg);
	char *cam = camera();
	char date[32];
	date_str(gs, date, sizeof date);
	if (input_command(verb, arg)) {
		// key, hold, mouse, move, button, click, wheel, scroll, drag
	} else if (!strcmp(verb, "tick") || !strcmp(verb, "frames")) {
		// tick N: N frames run (their camera updates, their renders)
		if (C.stage == 0) {
			C.n = atoi(arg), C.secs = -1, C.stage = 1;
			if (C.n > 0) return;
		} else if (!waited()) {
			return;
		}
		reply_fmt("ok tick %d frame %d", C.n, g_frame_no);
	} else if (!strcmp(verb, "timestep")) {
		// timestep MS: the camera's frame time fixed, and lockstep (no frame between commands);
		// timestep off: the frames' own times, frames run while no command does
		double ms = atof(arg);
		if (!strcmp(arg, "off") || ms <= 0) {
			g_timestep = 0;
			reply_fmt("ok timestep off");
		} else {
			g_timestep = (float)(ms / 1000);
			reply_fmt("ok timestep %.3f", ms);
		}
	} else if (!strcmp(verb, "wait")) {
		// wait SECONDS: frames run that long (with a timestep: SECONDS / timestep frames)
		if (C.stage == 0) {
			char d[64];
			snprintf(d, sizeof d, "%gs", atof(arg));
			duration(d, &C.n, &C.secs);
			C.stage = 1;
			C.t0 = now();
			if (C.n > 0 || C.secs > 0) return;
		} else if (!waited()) {
			return;
		}
		reply_fmt("ok wait %s date %s frame %d", arg, date, g_frame_no);
	} else if (!strcmp(verb, "load")) {
		if (!strcmp(arg, g_loaded) || !g_loaded[0])
			reply_fmt("ok load %s %.1f s", date, now() - g_t0);
		else
			reply_fmt("error load: %s is loaded (one save per game run)", g_loaded);
	} else if (!strcmp(verb, "pause")) {
		reply_fmt("ok pause");
	} else if (!strcmp(verb, "quit")) {
		struct reply *r = calloc(1, sizeof *r);
		snprintf(r->line, sizeof r->line, "ok quit");
		r->quit = 1;
		reply_done(r);
	} else if (!strcmp(verb, "step")) {
		int days = atoi(arg);
		double t = now();
		step_days(gs, days);
		date_str(gs, date, sizeof date);
		reply_fmt("ok step %d days in %.1f s to %s", days, now() - t, date);
	} else if (!strcmp(verb, "gui")) {
		U8(a_g_bNoGUI) = !strcmp(arg, "off");
		reply_fmt("ok gui %s", U8(a_g_bNoGUI) ? "off" : "on");
	} else if (!strcmp(verb, "observe")) {
		// the console command's handler (its arguments unused: an empty CPdxArray, {vtable, data,
		// capacity, size}); its result is { bool ok; a string with CPdxCommonStringAllocator at
		// +0x8 (the allocator +0x8 .. +0x18, data +0x18, size +0x20, inline buffer +0x28) }, made
		// by the handler itself
		void *args[3] = {NULL, NULL, NULL};
		uint8_t res[64];
		memset(res, 0, sizeof res);
		((void (*)(void *, void *))a_ExecuteObserve)(res, args);
		const char *text = *(const char **)(res + 0x18);
		size_t len = *(size_t *)(res + 0x20);
		reply_fmt("%s observe: %.*s", res[0] ? "ok" : "error", (int)(len < 200 ? len : 200), text ? text : "");
	} else if (!strcmp(verb, "resize")) {
		int w = 0, h = 0, ww = 0, wh = 0;
		sscanf(arg, "%d %d", &w, &h);
		uint8_t *img;
		if (capture(&img, &ww, &wh) == 0) free(img);
		if (w == ww && h == wh)
			reply_fmt("ok resize %d %d", w, h);
		else
			reply_fmt("error resize: the window is %d x %d (view.sh --size)", ww, wh);
	} else if (!strcmp(verb, "view")) {
		int id;
		if (C.stage == 0) {
			if (!strcmp(arg, "galaxy")) {
				g_cam_set = 0;
				((void (*)(void *))a_LeaveSystem)(cam);
			} else if (sscanf(arg, "system %d", &id) == 1) {
				void *o = galactic_object(id);
				if (!o) {
					reply_fmt("error view: no system %d", id);
					return;
				}
				g_cam_set = 0;
				((void (*)(void *, void *))a_EnterSystem)(cam, o);
			} else {
				reply_fmt("error view %s: galaxy or system ID", arg);
				return;
			}
			C.stage = 1;
			return;
		}
		// a few frames for the camera to arrive
		if (++C.frames < 4) return;
		int sys = camera_system(cam);
		if (sys == -1)
			reply_fmt("ok view galaxy");
		else
			reply_fmt("ok view system %d", sys);
	} else if (!strcmp(verb, "focus")) {
		int id;
		void *o = sscanf(arg, "system %d", &id) == 1 ? galactic_object(id) : NULL;
		if (!o) {
			reply_fmt("error focus: system ID (in the galaxy)");
			return;
		}
		// CGalacticObject::GetCoordinate: its CCelestialCoordinate at +0x408 (x, y: CFixedPoint
		// int64 x 1e5 at +0x8, +0x10), shown on the galaxy at x GALAXY_SPACE_SCALE_MULT
		// (CCelestialCoordinate::GetDisplayCoordinate): the camera's target goes there
		float *cur = (float *)(cam + 0x218);
		int was_galaxy = camera_system(cam) == -1;
		for (int i = 0; i < 6; i++) g_cam[i] = cur[i];
		// the distance and pitch kept on the galaxy, at most 360 (the renderer's `focus`: 180 map
		// units); from a system, 360 at 57.5 degrees (the galaxy camera's pitch after a load)
		if (!was_galaxy || g_cam[3] > 360) g_cam[3] = 360;
		if (!was_galaxy) g_cam[4] = 57.5f * 3.14159265f / 180.0f, g_cam[5] = 0;
		double x = *(int64_t *)((char *)o + 0x410) * 1e-5, y = *(int64_t *)((char *)o + 0x418) * 1e-5;
		g_cam[0] = (float)(x * F32(a_GalaxyScaleMult));
		g_cam[1] = 0;
		g_cam[2] = (float)(y * F32(a_GalaxyScaleMult));
		if (camera_system(cam) != -1) ((void (*)(void *))a_LeaveSystem)(cam);
		g_cam_set = 1;
		apply_camera(cam);
		reply_fmt("ok focus system %d at %.2f %.2f", id, x, y);
	} else if (!strcmp(verb, "camera")) {
		float v[6];
		if (!strcmp(arg, "off")) {
			g_cam_set = 0;
			reply_fmt("ok camera off");
		} else if (sscanf(arg, "%f %f %f %f %f %f", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) == 6) {
			float k = space_scale(cam), deg = 3.14159265f / 180.0f;
			g_cam[0] = v[0] * k, g_cam[1] = v[1] * k, g_cam[2] = v[2] * k;
			g_cam[3] = v[5] * k, g_cam[4] = v[4] * deg, g_cam[5] = v[3] * deg;
			g_cam_set = 1;
			apply_camera(cam);
			reply_fmt("ok camera");
		} else {
			reply_fmt("error camera X Y Z YAW PITCH DISTANCE, or camera off");
		}
	} else if (!strcmp(verb, "open")) {
		open_cmd(arg);
	} else if (!strcmp(verb, "frame")) {
		// frame PATH now: the frame the game presented last, no frame run (the input's frames
		// exactly); frame PATH: once the picture settles
		size_t al = strlen(arg);
		if (al > 4 && !strcmp(arg + al - 4, " now")) {
			arg[al - 4] = 0;
			g_frame_now = 1;
		}
		frame_cmd(arg[0] ? arg : "frame.png");
		g_cam_freeze = g_frame_now && C.active;
		g_frame_now = 0;
	} else if (!strcmp(verb, "state")) {
		state_json(gs, arg);
	} else {
		reply_fmt("error unknown command %s", verb);
	}
}

static void view_init(void) {
	if (resolve(g_view_syms) != 0) die(2, "view: missing symbols");
	if (view_libs() != 0) die(2, "view: libX11 / libz not found");
	const char *e;
	if ((e = getenv("HEADLESS_FRAME_MIN")) && *e) g_frame_min = atoi(e);
	if ((e = getenv("HEADLESS_FRAME_WAIT")) && *e) g_frame_wait = atof(e);
	if ((e = getenv("HEADLESS_FRAME_TIMEOUT")) && *e) g_frame_timeout = atof(e);
	if ((e = getenv("HEADLESS_REPLIES")) && *e) g_replies = fopen(e, "w");
	if ((e = getenv("HEADLESS_SCRIPT")) && *e && !(g_script = fopen(e, "r"))) die(2, "view: cannot open HEADLESS_SCRIPT");
	g_view_autoload = getenv("HEADLESS_SAVE") && *getenv("HEADLESS_SAVE");
	if (g_view_autoload) {
		g_wait_frames = 3;
	}
	hook_camera_update();
	if ((e = getenv("HEADLESS_LISTEN")) && *e) {
		pthread_t t;
		pthread_create(&t, NULL, listener, (void *)e);
		pthread_detach(t);
	}
	hlog("view mode: %s%s", g_script ? "script, " : "", e && *e ? "listening" : "no listener");
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
	if ((e = getenv("HEADLESS_MODE"))) g_frame_mode = strcmp(e, "frame") == 0, g_viewmode = strcmp(e, "view") == 0;
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
	if (g_viewmode) view_init();
	if ((e = getenv("HEADLESS_PROFILE")) && *e) profile_install(e);
	if ((e = getenv("HEADLESS_AUTOSAVE")) && atoi(e) > 0) {
		g_autosave = 1;
		if ((e = getenv("HEADLESS_AUTOSAVE_DIR")) && *e) g_autosave_dir = e;
		detour(a_DeleteSaveGameFile, (void *)no_delete);
		hlog("autosaves on, none deleted");
	}

	pthread_t t;
	pthread_create(&t, NULL, watchdog, NULL);
	pthread_detach(t);
}
