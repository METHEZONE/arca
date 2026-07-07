# ARCA Core v0 0.96 OLED Print Kit

Fast overnight print set for a 0.96 inch SSD1306 128x64 I2C OLED.

## Print first

1. `arca-oled-096-test-frame.stl`
   - Fastest part.
   - Use it to verify the OLED visible window and board outline.

2. `arca-core-v0-mini-tray-48x36x16.stl` + `arca-core-v0-mini-faceplate-48x36.stl`
   - For an ESP32-C3 SuperMini / Seeed XIAO-sized board, OLED, mic breakout, and wiring.
   - This is the best "ARCA charm core" direction.

3. `arca-core-v0-mini-monster-faceplate-48x36.stl`
   - Character version for the mini tray.
   - The OLED window stays sized for a 0.96 inch display while the silhouette gets ears, horns, feet, and cheek dots.

4. `arca-core-v0-devkit-tray-70x45x18.stl` + `arca-core-v0-devkit-faceplate-70x45.stl`
   - For a bigger ESP32-S3 DevKit-style board.
   - Print if today's board is a long dev board and you need a roomy prototype shell.

## Suggested slicer settings

- Material: PLA
- Layer height: 0.20 mm
- Walls: 3
- Infill: 12-15%
- Supports: off
- Orientation: flat side on bed
- Tolerance assumption: 0.3-0.5 mm hand-fit clearance

## Hardware assumptions

- Standard 0.96 inch SSD1306 I2C OLED module, usually about 27 x 27 mm.
- Visible OLED area is treated as about 24.5 x 13.5 mm.
- If your OLED board is closer to 28 x 28 mm, sand the frame or scale X/Y by 101-102%.
- The trays intentionally leave a rear center gap for DuPont wires or a USB cable during breadboard tests.

## V1 changes after test fit

- Add real snap tabs after measuring the printed clearance.
- Add USB-C slot on the exact board side.
- Add microphone acoustic port pattern after the INMP441/ICS-43434 location is fixed.
- Add two M2 bosses or heat-set insert pads if the shell needs serviceability.
