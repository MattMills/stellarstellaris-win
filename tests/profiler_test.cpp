// profiler_test.cpp : the profiler's hooks and web server (src/dll/profiler.cpp) in a program of
// their own, on Windows: functions of this program hooked through stellar.profile_hook and called
// with 16 arguments, floating point, a returned struct, recursion, C++ exceptions through the hook
// and threads (one of them calling a function while it is hooked); then the server's routes over
// HTTP. Exits 0 when every check passes.
//
//   cmake --build build --target stellar-profiler-test
//   stellar-profiler-test.exe [port]      (default 18710)

#define _CRT_SECURE_NO_WARNINGS
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include "dll/profiler.h"

#include <lua.hpp>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

HANDLE hProcess;
HMODULE hModule;

namespace {

int failures = 0;

void check(bool ok, const std::string& what) {
	std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
	if (!ok) {
		++failures;
	}
}

volatile int64_t sink = 0;

__declspec(noinline) int64_t sum16(int64_t a1, int64_t a2, int64_t a3, int64_t a4, int64_t a5, int64_t a6,
	int64_t a7, int64_t a8, int64_t a9, int64_t a10, int64_t a11, int64_t a12, int64_t a13, int64_t a14,
	int64_t a15, int64_t a16) {
	volatile int64_t guard = sink;
	return a1 * 1 + a2 * 2 + a3 * 3 + a4 * 4 + a5 * 5 + a6 * 6 + a7 * 7 + a8 * 8 + a9 * 9 + a10 * 10 +
		a11 * 11 + a12 * 12 + a13 * 13 + a14 * 14 + a15 * 15 + a16 * 16 + guard;
}

__declspec(noinline) double mixed(double a, float b, int c, double d, double e, float f) {
	volatile double guard = static_cast<double>(sink);
	return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + guard;
}

struct Big {
	int64_t v[4];
};

__declspec(noinline) Big make_big(int64_t x) {
	volatile int64_t guard = sink;
	Big b;
	for (int i = 0; i < 4; ++i) {
		b.v[i] = x * (i + 1) + guard;
	}
	return b;
}

__declspec(noinline) int fib(int n) {
	volatile int guard = static_cast<int>(sink);
	return n < 2 ? n + guard : fib(n - 1) + fib(n - 2);
}

__declspec(noinline) void thrower(int x) {
	volatile int guard = static_cast<int>(sink);
	if (x + guard > 0) {
		throw std::runtime_error("thrown through the hook");
	}
}

__declspec(noinline) int catcher(int x) {
	volatile int guard = static_cast<int>(sink);
	try {
		thrower(x + guard);
		return 0;
	}
	catch (const std::runtime_error&) {
		return 1;
	}
}

__declspec(noinline) int64_t work(int64_t x) {
	volatile int64_t guard = sink;
	int64_t s = guard;
	for (int i = 0; i < 20; ++i) {
		s += (x ^ i) * 31;
	}
	return s;
}

// work() not hooked: what a call through the hook costs
__declspec(noinline) int64_t work_plain(int64_t x) {
	volatile int64_t guard = sink;
	int64_t s = guard;
	for (int i = 0; i < 20; ++i) {
		s += (x ^ i) * 31;
	}
	return s;
}

int64_t work_expected(int64_t x) {
	int64_t s = 0;
	for (int i = 0; i < 20; ++i) {
		s += (x ^ i) * 31;
	}
	return s;
}

// runs a chunk; false (printed) on an error
bool run(lua_State* L, const char* code) {
	if (luaL_dostring(L, code) != 0) {
		std::printf("lua: %s\n", lua_tostring(L, -1));
		lua_pop(L, 1);
		return false;
	}
	return true;
}

void set_address(lua_State* L, const char* name, const void* address) {
	lua_pushnumber(L, static_cast<lua_Number>(reinterpret_cast<uintptr_t>(address)));
	lua_setglobal(L, name);
}

// one HTTP request, the whole response
std::string http(int port, const std::string& request) {
	SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	sockaddr_in a{};
	a.sin_family = AF_INET;
	a.sin_port = htons(static_cast<u_short>(port));
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (connect(s, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
		closesocket(s);
		return "";
	}
	send(s, request.data(), static_cast<int>(request.size()), 0);
	std::string out;
	char buffer[4096];
	int n;
	while ((n = recv(s, buffer, sizeof(buffer), 0)) > 0) {
		out.append(buffer, static_cast<size_t>(n));
	}
	closesocket(s);
	return out;
}

std::string get(int port, const std::string& path, const std::string& host = "127.0.0.1") {
	return http(port, "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\n\r\n");
}

std::string post(int port, const std::string& path, bool header = true) {
	return http(port, "POST " + path + " HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n" +
		std::string(header ? "X-Stellar: 1\r\n" : "") + "\r\n");
}

bool status(const std::string& response, const char* code) {
	return response.compare(0, 9 + std::strlen(code), std::string("HTTP/1.1 ") + code) == 0;
}

// the calls of a function in /stats (-1 if it is not there)
long long calls_of(const std::string& stats, const char* name) {
	const std::string key = std::string("\"") + name + "\",";
	const size_t at = stats.find(key);
	if (at == std::string::npos) {
		return -1;
	}
	const size_t comma = stats.find(',', at + key.size());
	return std::atoll(stats.c_str() + comma + 1);
}

} // namespace

int main(int argc, char** argv) {
	const int port = argc > 1 ? std::atoi(argv[1]) : 18710;
	hProcess = GetCurrentProcess();
	hModule = GetModuleHandleW(nullptr);

	lua_State* L = luaL_newstate();
	luaL_openlibs(L);
	lua_newtable(L);
	stellar_profiler_open(L);
	lua_setglobal(L, "stellar");

	// a thread that calls work() while it is hooked
	std::atomic<bool> stop{false};
	std::atomic<long long> hot_calls{0}, hot_wrong{0};
	std::thread hot([&] {
		for (int64_t i = 0; !stop.load(); ++i) {
			if (work(i) != work_expected(i)) {
				++hot_wrong;
			}
			++hot_calls;
		}
	});
	Sleep(50);

	set_address(L, "A_sum16", reinterpret_cast<void*>(&sum16));
	set_address(L, "A_mixed", reinterpret_cast<void*>(&mixed));
	set_address(L, "A_make_big", reinterpret_cast<void*>(&make_big));
	set_address(L, "A_fib", reinterpret_cast<void*>(&fib));
	set_address(L, "A_thrower", reinterpret_cast<void*>(&thrower));
	set_address(L, "A_catcher", reinterpret_cast<void*>(&catcher));
	set_address(L, "A_work", reinterpret_cast<void*>(&work));
	const bool hooked = run(L, R"(
		local list = {
			{ address = A_sum16, name = "sum16" }, { address = A_mixed, name = "mixed" },
			{ address = A_make_big, name = "make_big" }, { address = A_fib, name = "fib" },
			{ address = A_thrower, name = "thrower" }, { address = A_catcher, name = "catcher" },
			{ address = A_work, name = "work" },
		}
		local results, n = stellar.profile_hook(list)
		for i, r in ipairs(results) do
			print(string.format("hook %-9s %s", list[i].name, tostring(r)))
		end
		HOOKED = n
	)");
	lua_getglobal(L, "HOOKED");
	check(hooked && lua_tonumber(L, -1) == 7, "all 7 functions hooked");
	lua_pop(L, 1);
	Sleep(50);
	stop.store(true);
	hot.join();
	check(hot_wrong.load() == 0, "work() right while it was hooked under a running thread (" +
		std::to_string(hot_calls.load()) + " calls)");

	// the server
	char page[MAX_PATH];
	GetTempPathA(MAX_PATH, page);
	std::strcat(page, "stellar-profiler-test.html");
	if (FILE* f = std::fopen(page, "wb")) {
		std::fputs("<p>the profiler's page</p>", f);
		std::fclose(f);
	}
	lua_pushstring(L, page);
	lua_setglobal(L, "PAGE");
	lua_pushnumber(L, port);
	lua_setglobal(L, "PORT");
	check(run(L, "assert(stellar.profile_serve(PORT, PAGE))"), "the server listens");
	check(run(L, "assert(not stellar.profile_serve(PORT, PAGE))"), "a second server is refused");
	check(status(post(port, "/reset"), "200"), "POST /reset");

	// calls and results through the thunk
	check(sum16(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16) == 1496, "16 arguments");
	check(mixed(1.5, 2.25f, 3, 4.5, 5.25, 6.5f) == 1.5 + 4.5 + 9 + 18 + 26.25 + 39, "floating point arguments and result");
	const Big b = make_big(7);
	check(b.v[0] == 7 && b.v[1] == 14 && b.v[2] == 21 && b.v[3] == 28, "a struct returned through a hidden pointer");
	check(fib(15) == 610, "recursion");
	int caught = 0;
	for (int i = 0; i < 100; ++i) {
		caught += catcher(1);
	}
	check(caught == 100, "100 exceptions through the hook, caught");
	for (int i = 0; i < 5; ++i) {
		thrower(0);
	}
	check(catcher(0) == 0, "no exception");

	// threads
	std::vector<std::thread> threads;
	std::atomic<long long> wrong{0};
	for (int t = 0; t < 4; ++t) {
		threads.emplace_back([t, &wrong] {
			for (int64_t i = 0; i < 100000; ++i) {
				if (work(i * 4 + t) != work_expected(i * 4 + t)) {
					++wrong;
				}
			}
		});
	}
	for (std::thread& t : threads) {
		t.join();
	}
	check(wrong.load() == 0, "work() right on 4 threads");

	const std::string stats = get(port, "/stats");
	check(status(stats, "200"), "GET /stats");
	check(calls_of(stats, "sum16") == 1, "sum16: 1 call");
	check(calls_of(stats, "fib") == 1973, "fib(15): 1973 calls (" + std::to_string(calls_of(stats, "fib")) + ")");
	check(calls_of(stats, "catcher") == 101, "catcher: 101 calls (" + std::to_string(calls_of(stats, "catcher")) + ")");
	check(calls_of(stats, "thrower") == 6, "thrower: the 6 calls that returned (" + std::to_string(calls_of(stats, "thrower")) + ")");
	check(calls_of(stats, "work") == 400000, "work: 400000 calls on 4 threads (" + std::to_string(calls_of(stats, "work")) + ")");

	// recording paused
	check(status(post(port, "/enable?on=0"), "200"), "POST /enable?on=0");
	sum16(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1);
	check(status(post(port, "/enable?on=1"), "200"), "POST /enable?on=1");
	sum16(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1);
	check(calls_of(get(port, "/stats"), "sum16") == 2, "a call while paused is not counted");

	// the page and the guards
	const std::string index = get(port, "/");
	check(status(index, "200") && index.find("the profiler's page") != std::string::npos, "GET / serves the page");
	check(status(post(port, "/reset", false), "403"), "POST without X-Stellar refused");
	check(status(get(port, "/stats", "evil.example:18710"), "403"), "another Host refused");
	check(status(get(port, "/nothing"), "404"), "unknown path");
	check(status(post(port, "/hook?pattern=CShip%3A%3A*%0A%21*%3A%3A~*"), "200"), "POST /hook");
	check(run(L, R"(
		local r = stellar.profile_requests()
		assert(#r == 1 and r[1] == "CShip::*\n!*::~*", "requests: " .. tostring(r[1]))
		assert(#stellar.profile_requests() == 0)
	)"), "the pattern reaches Lua, once");
	check(run(L, "stellar.profile_note('a note')") && get(port, "/stats").find("\"a note\"") != std::string::npos,
		"notes in /stats");
	check(status(post(port, "/reset"), "200") && calls_of(get(port, "/stats"), "work") == -1,
		"after a reset, uncalled functions are left out");
	check(calls_of(get(port, "/stats?all=1"), "work") == 0, "?all=1 lists them");

	// the cost of a call through the hook, on this thread
	{
		LARGE_INTEGER f, t0, t1, t2;
		QueryPerformanceFrequency(&f);
		const int n = 2000000;
		int64_t a = 0;
		QueryPerformanceCounter(&t0);
		for (int i = 0; i < n; ++i) {
			a += work_plain(i);
		}
		QueryPerformanceCounter(&t1);
		for (int i = 0; i < n; ++i) {
			a += work(i);
		}
		QueryPerformanceCounter(&t2);
		sink = a & 0;
		const double plain = static_cast<double>(t1.QuadPart - t0.QuadPart) * 1e9 / static_cast<double>(f.QuadPart) / n;
		const double hooked = static_cast<double>(t2.QuadPart - t1.QuadPart) * 1e9 / static_cast<double>(f.QuadPart) / n;
		std::printf("cost: %.1f ns a call without the hook, %.1f ns with it: %.1f ns more\n", plain, hooked, hooked - plain);
	}

	std::printf("%s\n", failures == 0 ? "ALL OK" : (std::to_string(failures) + " FAILED").c_str());
	lua_close(L);
	return failures == 0 ? 0 : 1;
}
