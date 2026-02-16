// =============================================================================
// Blinky — IceSugar v1.5 (iCE40UP5K)
// =============================================================================
//
// What this does:
//   Cycles the onboard RGB LED through colours at roughly 1 Hz.
//   This is the "hello world" of FPGA development — if the LED blinks,
//   your toolchain and board are working.
//
// How it works:
//   A 24-bit counter increments every clock tick (12 MHz). The top three
//   bits (23, 22, 21) change slowly enough to be visible:
//
//     Bit 23 toggles at: 12,000,000 / 2^24 ≈ 0.7 Hz  (~1.4 sec cycle)
//     Bit 22 toggles at: 12,000,000 / 2^23 ≈ 1.4 Hz  (~0.7 sec cycle)
//     Bit 21 toggles at: 12,000,000 / 2^22 ≈ 2.9 Hz  (~0.35 sec cycle)
//
//   Each bit drives one colour of the RGB LED. Because they toggle at
//   different rates, you see the LED cycle through combinations:
//     red, yellow, green, cyan, blue, magenta, white, off, ...
//
// Hardware notes:
//   The IceSugar's RGB LED is active low — driving a pin to 0 turns that
//   colour ON, and 1 turns it OFF. That's why we invert with ~.
//
//   Pin mapping (from https://github.com/wuxx/icesugar):
//     LED_R = pin 40    LED_G = pin 41    LED_B = pin 39
//
// =============================================================================

module top (
    input  clk,       // 12 MHz clock from onboard oscillator (pin 35)
                      // Pin 35 is a dedicated Global Buffer Input (GBIN0)
                      // — it connects to the iCE40's low-skew clock network,
                      // ensuring all flip-flops see the clock edge at the
                      // same time. Regular GPIO pins would add clock skew.
    output led_r,     // Red   LED — active low (pin 40)
    output led_g,     // Green LED — active low (pin 41)
    output led_b      // Blue  LED — active low (pin 39)
);

    // 24-bit free-running counter. At 12 MHz it wraps every ~1.4 seconds.
    // No reset needed — it starts at 0 and just keeps counting.
    reg [23:0] counter = 0;

    always @(posedge clk)
        counter <= counter + 1;

    // Drive each LED colour from a different bit of the counter.
    // The ~ inverts because the LEDs are active low:
    //   counter bit = 1  →  output = 0  →  LED on
    //   counter bit = 0  →  output = 1  →  LED off
    assign led_r = ~counter[23];   // Slowest  — ~0.7 Hz
    assign led_g = ~counter[22];   // Medium   — ~1.4 Hz
    assign led_b = ~counter[21];   // Fastest  — ~2.9 Hz

endmodule
