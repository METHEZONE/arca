// AXP2101 battery readout.
//
// The PMU has its own fuel gauge, so battery percent is a single register read
// (0xA4) rather than an ADC + curve fit. Charging state comes from 0x01.
//
// This talks to the AXP2101 on the shared I2C bus that the BSP already brought
// up (SDA=15 SCL=14). If the BSP in your component version exposes the bus with
// a different accessor than bsp_i2c_get_handle(), this is the only place to fix.
#pragma once

#include <stdbool.h>

void  arca_power_start(void);
float arca_power_battery(void);   // 0.0 - 1.0, or -1 when unknown
bool  arca_power_charging(void);
