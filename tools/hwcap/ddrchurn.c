/* ddrchurn (2026-11-22, #27 freeze provocation): memory accesses with very
 * short pauses on both hardware threads, so the DDR controller enters and
 * leaves automatic power-down (after 32 idle clocks) as often as possible.
 * Random 4-byte read-modify-writes over a 32 MB buffer (cache and TLB
 * misses), then a pause that sweeps 0..GMAX loop turns. Prints a line every
 * 10 s so a freeze shows as the lines stopping. No device access.
 * Usage: ddrchurn SECONDS [GMAX] */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BUF_BYTES (32u << 20)
static volatile uint32_t *buf;
static unsigned gmax = 400;
static volatile unsigned long count[2];

static void *run(void *arg)
{
	int cpu = (int)(intptr_t)arg;
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	sched_setaffinity(0, sizeof(set), &set);
	uint32_t x = 0x9e3779b9u * (cpu + 1), n = BUF_BYTES / 4;
	unsigned g = 0;
	unsigned long k = 0;
	for (;;) {
		for (int b = 0; b < 8; b++) {
			x = x * 1103515245u + 12345u;
			buf[(x >> 3) % n] += x;
		}
		g = (g + 7) % gmax;
		for (volatile unsigned i = 0; i < g; i++)
			;
		if ((++k & 0xfff) == 0)
			count[cpu] = k;
	}
	return NULL;
}

int main(int argc, char **argv)
{
	int secs = argc > 1 ? atoi(argv[1]) : 60;
	if (argc > 2)
		gmax = (unsigned)atoi(argv[2]) ? (unsigned)atoi(argv[2]) : 1;
	buf = malloc(BUF_BYTES);
	if (!buf)
		return 2;
	memset((void *)buf, 0x5a, BUF_BYTES);
	pthread_t t[2];
	for (int c = 0; c < 2; c++)
		pthread_create(&t[c], NULL, run, (void *)(intptr_t)c);
	for (int s = 10; s <= secs; s += 10) {
		sleep(10);
		printf("ddrchurn t=%d bursts cpu0=%lu cpu1=%lu\n", s, count[0], count[1]);
		fflush(stdout);
	}
	return 0;
}
