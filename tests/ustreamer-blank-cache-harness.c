// CAM-05 (2026-10-05): host harness for ustreamer's src/ustreamer/blank.c.
//
// Links the real blank.c against stub frametext/frame/encoder functions that
// count calls, so the test proves how often the software JPEG encoder runs.
// Built twice by tests/ustreamer-cam05-patch-tests.sh: against the patched
// blank.c (EXPECT_CACHED=1) and the pristine one (EXPECT_CACHED=0).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "blank.h"
#include "encoders/cpu/encoder.h"

static unsigned encodes = 0;
static unsigned draws = 0;

us_frame_s *us_frame_init(void) {
	us_frame_s *f = calloc(1, sizeof(*f));
	return f;
}
void us_frame_destroy(us_frame_s *f) {
	free(f->data);
	free(f);
}
us_frametext_s *us_frametext_init(void) {
	us_frametext_s *ft = calloc(1, sizeof(*ft));
	ft->frame = us_frame_init();
	return ft;
}
void us_frametext_destroy(us_frametext_s *ft) {
	free(ft->text);
	us_frame_destroy(ft->frame);
	free(ft);
}
void us_frametext_draw(us_frametext_s *ft, const char *text, uint width, uint height) {
	++draws;
	ft->frame->width = width;
	ft->frame->height = height;
	(void)text;
}
void us_cpu_encoder_compress(const us_frame_s *src, us_frame_s *dest, unsigned quality) {
	++encodes;
	(void)quality;
	dest->width = src->width;
	dest->height = src->height;
	dest->used = 1000;
}

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s (encodes=%u)\n", msg, encodes); ++failures; } else { printf("PASS: %s\n", msg); } } while (0)

int main(void) {
	const int cached = EXPECT_CACHED;
	us_blank_s *b = us_blank_init();
	CHECK(encodes == 1, "init encodes the initial blank once");

	unsigned before = encodes;
	us_blank_draw(b, "< CAMERA PAUSED >", 1920, 1080);
	CHECK(encodes == before + 1, "entering pause encodes the paused blank once");

	before = encodes;
	for (int i = 0; i < 60; ++i) { // one minute of the 1 s offline loop
		us_blank_draw(b, "< CAMERA PAUSED >", 1920, 1080);
	}
	if (cached) {
		CHECK(encodes == before, "60 s paused: no further encodes");
	} else {
		CHECK(encodes == before + 60, "pristine source: one encode per second while paused (the measured 36 % CPU)");
	}

	if (cached) {
		before = encodes;
		us_blank_draw(b, "< NO LIVE VIDEO >", 1920, 1080);
		CHECK(encodes == before + 1, "a different message (fault, unplug) re-encodes");
		before = encodes;
		us_blank_draw(b, "< NO LIVE VIDEO >", 1280, 720);
		CHECK(encodes == before + 1, "a different capture size re-encodes");
		before = encodes;
		us_blank_draw(b, "< CAMERA PAUSED >", 1280, 720);
		CHECK(encodes == before + 1, "back to paused at the new size re-encodes once");
		us_blank_draw(b, "< CAMERA PAUSED >", 1280, 720);
		CHECK(encodes == before + 1, "...and then stays cached");
		CHECK(b->jpeg->width == 1280 && b->jpeg->height == 720, "the cached jpeg matches the requested size");

		b->jpeg->used = 0; // an emptied jpeg is never served from the cache
		before = encodes;
		us_blank_draw(b, "< CAMERA PAUSED >", 1280, 720);
		CHECK(encodes == before + 1, "an empty jpeg is re-encoded");

		char text[32];
		strcpy(text, "< CAMERA PAUSED >");
		before = encodes;
		us_blank_draw(b, text, 1280, 720);
		text[2] = 'X'; // caller's buffer changes after the call: cache must hold its own copy
		us_blank_draw(b, "< CAMERA PAUSED >", 1280, 720);
		CHECK(encodes == before, "the cache keeps its own copy of the text");
	}
	us_blank_destroy(b);
	printf("%s: draws=%u encodes=%u failures=%d\n", cached ? "patched" : "pristine", draws, encodes, failures);
	return failures ? 1 : 0;
}
