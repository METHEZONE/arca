// ARCA Core v1 - the face.
//
// Landscape 284 x 240, USB-C + buttons along the TOP edge:
//
//        [BOOT]        [USB-C]        [PWR]
//     ┌──────────────────────────────────────┐
//     │  REC ◂        84%  ⇡2        ▸ SYNC  │  <- button hints sit directly
//     │                                      │     under their own button
//     │            ●          ●              │
//     │                 ‿                    │
//     │                                      │
//     │           ▁▃▅▇▅▃▁   00:42            │
//     └──────────────────────────────────────┘
//
// Drawn procedurally with LVGL rather than blitting the v0 face pack. The
// hardware/arca-qbit-facepack assets are 1-bit 128x64 built for the old SSD1306
// OLED; upscaling them 2.2x to a 65K colour IPS looks like a mistake. Same eight
// expressions, redrawn as vectors, so they stay sharp and can animate smoothly.
//
// Touch can only WAKE or cycle the view. It can never start or stop a recording,
// because a capacitive panel in a pocket triggers constantly.
#pragma once

void arca_face_start(void);

// Called by the event loop so the panel dims/sleeps on its own schedule.
void arca_face_note_activity(void);
