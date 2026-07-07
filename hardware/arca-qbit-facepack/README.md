# ARCA QBIT Facepack

Original ARCA 0.96 OLED expressions generated for QBIT-compatible `.qgif` playback.

## Target

- Display: SSD1306 128x64 I2C OLED, commonly sold as 0.96 inch.
- Device shell: QBIT or any ESP32-C3 Super Mini OLED desk-pet shell with a 128x64 monochrome OLED.
- Upload path: QBIT local dashboard at `http://qbit.local`, then Files / Library upload.

## Files

- `arca_idle_blink.qgif`
- `arca_listening_waves.qgif`
- `arca_thinking_bubbles.qgif`
- `arca_uploading_cloud.qgif`
- `arca_sleepy_mochi.qgif`
- `arca_excited_monster.qgif`
- `arca_shy_blush.qgif`
- `arca_recording_pulse.qgif`
- `arca-qbit-facepack-preview.svg`
- `manifest.json`

## Print-night workflow

1. Print the QBIT shell at 100% scale.
2. Flash QBIT firmware and connect Wi-Fi.
3. Open `http://qbit.local`.
4. Upload the `.qgif` files from this folder.
5. Set `arca_idle_blink.qgif` as the first idle/default animation if the dashboard allows ordering.

## Product note

These are not copied DASAI/Mochi frames. They are ARCA-owned pixel expressions that use the same general desktop-pet grammar: blink, listening, thinking, shy, sleepy, excited, and recording/uploading states.
