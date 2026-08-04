// ARCA Core v1 - two-button input.
//
// Landscape, USB-C edge up:
//
//        [ BOOT ]   [ USB-C ]   [ PWR ]
//     ┌───────────────────────────────────┐
//     │                                   │
//     │            ( ARCA face )          │
//     │                                   │
//     └───────────────────────────────────┘
//
//   LEFT  = BOOT (GPIO0)   -> RECORD
//     hold                : push-to-talk. Records while held, stops on release.
//     click               : starts a long session. Next click stops it.
//     hold during session : drops a highlight marker.
//
//   RIGHT = PWR (GPIO41)   -> SCREEN / MARK / SYNC
//     click               : wake screen, then cycle face -> stats -> last upload
//     double click        : drop a highlight marker
//     hold ~1.2 s         : sync to cloud now
//     hold ~6 s           : AXP2101 kills power in hardware. Avoid.
//
// Why record is on the LEFT and not the RIGHT: push-to-talk means holding the
// button for as long as you are talking, and a long hold on PWR reaches the
// PMU's hardware power-off. Firmware cannot override that, so push-to-talk
// physically cannot live on PWR.
//
// Recording does not begin on the raw press edge - it begins 45 ms later, once
// the press is confirmed. That costs nothing, because the recorder always keeps
// ARCA_PREROLL_SECONDS of audio in PSRAM and prepends it. You get the sentence
// you already said before you decided it mattered.

#pragma once

void arca_buttons_start(void);
