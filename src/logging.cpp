
#include "logging.h"



CLog::CLog(const char * filename) {
	this->log_filename = filename;
	this->fh.open(filename); //std::ios_base::app
}

//https://stackoverflow.com/questions/10905892/equivalent-of-gettimeday-for-windows
int CLog::gettimeofday(struct local_timeval* tp, struct timezone* tzp) {
	// Note: some broken versions only have 8 trailing zero's, the correct epoch has 9 trailing zero's
	// This magic number is the number of 100 nanosecond intervals since January 1, 1601 (UTC)
	// until 00:00:00 January 1, 1970 
	static const uint64_t EPOCH = ((uint64_t)116444736000000000ULL);

	SYSTEMTIME  system_time;
	FILETIME    file_time;
	uint64_t    time;

	GetSystemTime(&system_time);
	SystemTimeToFileTime(&system_time, &file_time);
	time = ((uint64_t)file_time.dwLowDateTime);
	time += ((uint64_t)file_time.dwHighDateTime) << 32;

	tp->tv_sec = (time_t)((time - EPOCH) / 10000000L);
	tp->tv_usec = (time_t)(system_time.wMilliseconds * 1000);
	return 0;
}


void CLog::print_timestamp() {
	char time_buffer[26];
	int ms;

	struct local_timeval tv;
	this->gettimeofday(&tv, NULL);

	struct tm* timeinfo = std::localtime(&tv.tv_sec);

	//https://stackoverflow.com/questions/3673226/how-to-print-time-in-format-2009-08-10-181754-811
	ms = lrint(tv.tv_usec / 1000.0); // Round to nearest millisec
	if (ms >= 1000) { // Allow for rounding up to nearest second
		ms -= 1000;
		tv.tv_sec++;
	}

	std::strftime(time_buffer, sizeof(time_buffer), "%Y-%m-%dT%H:%M:%S", timeinfo);
	char time_buffer_with_ms[30];
	std::sprintf(time_buffer_with_ms, "%s.%03d", time_buffer, ms);

	this->fh << "[" << time_buffer_with_ms << "] (" << GetCurrentProcessId() << ") ";
}



void CLog::log(const char* log_statement, bool do_newline, bool do_timestamp) {
	if (do_timestamp)
		this->print_timestamp();

	this->fh << log_statement;

	if (do_newline){
		char_count = 0;
		this->fh << std::endl;
	}
}


inline CLog& CLog::operator << (std::ostream& (*p_manip)(std::ostream&)) {
	if (p_manip == static_cast<std::ostream & (*)(std::ostream&)> (&std::endl<char, std::char_traits<char> >)) {
		char_count = 0;
	}
	return *this;
};