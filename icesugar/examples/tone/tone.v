// =============================================================================
// Tone Generator — IceSugar v1.5 + MuseLab PMOD Audio v1.2
// =============================================================================
//
// What this does:
//   Produces a 440 Hz audible tone (the note A4, used for orchestra tuning)
//   on the PMOD Audio v1.2 speaker, and blinks the green LED to show it's
//   running.
//
// How it works:
//   The IceSugar board has a 12 MHz crystal oscillator — the clock ticks
//   12 million times per second. To make a 440 Hz tone we need to toggle
//   the speaker pin high/low at that frequency.
//
//   A complete cycle of a 440 Hz wave takes 1/440 seconds. A square wave
//   toggles once per half-cycle, so we toggle every 1/(440*2) seconds.
//   In clock ticks that's:
//
//       12,000,000 / 440 / 2 = 13,636 ticks per toggle
//
//   We count down from 13,636 to 0, flip the speaker output, and repeat.
//   The PMOD Audio board's onboard amplifier drives the speaker.
//
// Hardware setup:
//   - PMOD Audio v1.2 plugged into PMOD header 3 on the IceSugar board
//   - Speaker output uses FPGA pin 32 (PMOD 3, pin P3_12)
//   - Same pin as the upstream music examples at:
//     https://github.com/wuxx/icesugar/tree/master/src/basic/verilog/music
//
// =============================================================================

module top (
    input  clk,       // 12 MHz clock from onboard oscillator (pin 35)
                      // Pin 35 is a dedicated Global Buffer Input (GBIN0)
                      // — it connects to the iCE40's low-skew clock network,
                      // ensuring all flip-flops see the clock edge at the
                      // same time. Regular GPIO pins would add clock skew.
    output speaker,   // Audio out to PMOD Audio v1.2 (pin 32)
    output led_g      // Green LED — blinks to show design is running (pin 41)
);

    // -------------------------------------------------------------------------
    // Tone generation — clock divider approach
    // -------------------------------------------------------------------------
    //
    // We want 440 Hz. The formula is:
    //
    //   DIVIDER = clock_freq / (tone_freq * 2)
    //           = 12,000,000 / (440 * 2)
    //           = 13,636
    //
    // To change the note, just change DIVIDER. Some examples:
    //   Middle C  (261.63 Hz): 12000000 / 261.63 / 2 ≈ 22934
    //   A4        (440.00 Hz): 12000000 / 440    / 2 = 13636
    //   C5        (523.25 Hz): 12000000 / 523.25 / 2 ≈ 11464
    //
    localparam DIVIDER = 13636;

    // Counter counts down from DIVIDER-1 to 0, then reloads.
    // 17 bits can hold values up to 131,071 — more than enough for 13,636.
    reg [16:0] counter = 0;

    // The speaker output — toggles every time the counter hits zero,
    // producing a square wave at the target frequency.
    reg spk = 0;

    always @(posedge clk) begin
        if (counter == 0) begin
            counter <= DIVIDER - 1;   // Reload the countdown
            spk <= ~spk;             // Flip the speaker output
        end else begin
            counter <= counter - 1;   // Keep counting down
        end
    end

    // Connect the internal register to the output pin
    assign speaker = spk;

    // -------------------------------------------------------------------------
    // LED heartbeat — simple visual indicator
    // -------------------------------------------------------------------------
    //
    // A 24-bit counter driven by the 12 MHz clock. Bit 23 toggles at:
    //   12,000,000 / 2^24 ≈ 0.7 Hz  (roughly once per second)
    //
    // The LED is active low on the IceSugar (0 = on, 1 = off), so we
    // invert with ~ to get: LED on when bit 23 is high.
    //
    reg [23:0] led_cnt = 0;

    always @(posedge clk)
        led_cnt <= led_cnt + 1;

    assign led_g = ~led_cnt[23];

endmodule
