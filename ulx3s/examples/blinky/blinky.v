// ULX3S Blinky — 8-LED binary counter
//
// Maps the upper 8 bits of a 26-bit free-running counter to the 8 onboard LEDs.
// At 25 MHz:
//   - LED[0] (bit 18) toggles at 25e6 / 2^19 ≈ 47.7 Hz (appears solid)
//   - LED[7] (bit 25) toggles at 25e6 / 2^26 ≈ 0.37 Hz (~2.7 s period)
//
// The visible effect is a binary count rolling across the LEDs, with the
// rightmost LEDs appearing solid and the leftmost blinking slowly.

module top (
    input  wire clk,        // 25 MHz oscillator
    output wire [7:0] led   // 8 onboard LEDs (active high)
);

    reg [29:0] counter = 0;

    always @(posedge clk)
        counter <= counter + 1;

    // Map upper 8 bits to LEDs — gives a visible binary count
    assign led = counter[29:22];

endmodule
