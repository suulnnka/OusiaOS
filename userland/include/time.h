/* OusiaOS libc —— <time.h> */
#ifndef _OusiaOS_TIME_H
#define _OusiaOS_TIME_H

typedef long time_t;
typedef long clock_t;
#define CLOCKS_PER_SEC 1000000

time_t time(time_t *t);
clock_t clock(void);

#endif
