// Wall-clock time for recording filenames and the recordedAt field.
//
// The board has a PCF85063 RTC kept alive by the battery through the AXP2101,
// so timestamps survive a power cycle without any network. The BSP brings the
// RTC up and the IDF newlib time functions read from it, so we mostly just need
// formatting plus an SNTP top-up whenever Wi-Fi happens to be available.
#pragma once

#include <stdbool.h>
#include <stddef.h>

void arca_clock_init(void);

// True once the clock looks like a real date rather than 1970.
bool arca_clock_is_set(void);

// "20260804T193210" - safe for FAT filenames.
void arca_clock_stamp_compact(char *out, size_t len);

// "2026-08-04T19:32:10Z" - what /api/hardware ingest wants for recordedAt.
void arca_clock_stamp_iso(char *out, size_t len);

// Call once Wi-Fi is up. Non-blocking; corrects drift in the background.
void arca_clock_sntp_start(void);
