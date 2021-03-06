#pragma once

using namespace std;

#include <string>
#include <iostream>
#include <stdio.h>
#include <fstream>



#ifdef _WIN32
#include "hooking_windows.h"
#endif
#include <include/stellaris-generic.h>

class CLogStream {
	public:
		CLogStream() {}
	protected:
		std::ostringstream _ostringstream;
};

class CLog : public CLogStream {
	
	private:
		ofstream fh;
		const char* log_filename;
		uint char_count = 0;

		// MSVC defines this in winsock2.h!?
		typedef struct local_timeval {
			time_t tv_sec;
			time_t tv_usec;
		} local_timeval;

		
		int gettimeofday(struct local_timeval* tp, struct timezone* tzp);

	public:
		CLog() {};
		CLog(const char* filename);
		void print_timestamp();
		void log(const char* log_statement, bool do_newline, bool do_timestamp);

		void log(const char* log_statement, bool do_newline){ this->log(log_statement, do_newline, true); };
		void log(const char* log_statement){ this->log(log_statement, true, true); };
		void endl(){ this->log("", true, false); };
		void close(){ this->fh.close(); };
		//template <typename T> inline CLog& operator << (T output);
		//inline CLog& operator << (std::ostream& (*p_manip)(std::ostream&));

		template <typename T> inline CLog& operator << (T output) {
			if (char_count == 0) {
				this->print_timestamp();
			}

			this->fh << output;
			char_count += sizeof(output);



			return *this;
		};

		inline CLog& CLog::operator << (std::ostream& (*p_manip)(std::ostream&)) {
			if (p_manip == static_cast<std::ostream & (*)(std::ostream&)> (&std::endl<char, std::char_traits<char> >)) {
				char_count = 0;
			}
			return *this;
		};
		
};