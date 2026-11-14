/* Test-only realtime jump: age ctime/btime too without setting the host clock. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <time.h>

int clock_gettime(clockid_t clock, struct timespec *ts) {
    static int (*real_clock_gettime)(clockid_t, struct timespec *);
    if (!real_clock_gettime)
        real_clock_gettime = dlsym(RTLD_NEXT, "clock_gettime");
    int result = real_clock_gettime(clock, ts);
    if (result == 0 && clock == CLOCK_REALTIME)
        ts->tv_sec += (time_t)366 * 24 * 60 * 60;
    return result;
}
