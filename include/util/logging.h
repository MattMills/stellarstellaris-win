#pragma once

//using namespace std;

#include <string>
#include <iostream>
#include <stdio.h>
#include <string>
#include <fstream>
#include <sstream>

#ifdef _WIN32
#include "hooking/windows_platform.h"
#endif

class CLogStream {
	public:
		CLogStream() {}
	protected:
		std::ostringstream _ostringstream;
};

class CLog : public CLogStream {
	
	private:
		std::ofstream fh;
		const char* log_filename;
		unsigned int char_count = 0;

		// MSVC defines this in winsock2.h!?
		typedef struct local_timeval {
			time_t tv_sec;
			time_t tv_usec;
		} local_timeval;

		
		int gettimeofday(struct local_timeval* tp, struct timezone* tzp);

	public:
		CLog() {}
		CLog(const char* filename);
		void print_timestamp();
		void log(const char* log_statement, bool do_newline, bool do_timestamp);

		void log(const char* log_statement, bool do_newline){ this->log(log_statement, do_newline, true); };
		void log(const char* log_statement){ this->log(log_statement, true, true); };
		void endl(){ this->log("", true, false); };
		void close(){ this->fh.close(); };
		//template <typename T> inline CLog& operator << (T output);
		//inline CLog& operator << (std::ostream& (*p_manip)(std::ostream&));

		uint64_t get_timestamp();
		const uint64_t ONE_SECOND = 10000000;
		const uint64_t ONE_MILLISECOND = 10000;

		template <typename T> inline CLog& operator << (T output) {
			if (char_count == 0) {
				this->print_timestamp();
			}

			this->fh << output;
			char_count += sizeof(output);

			return *this;
		};

		inline CLog& operator << (std::ostream& (*p_manip)(std::ostream&)) {
			if (p_manip == static_cast<std::ostream & (*)(std::ostream&)> (&std::endl<char, std::char_traits<char> >)) {
				char_count = 0;
			}
			return *this;
		};
		
};