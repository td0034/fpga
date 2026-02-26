// ULX3S Buttons — directional LED control
//
// A single lit LED moves across the 8-LED bar using the directional buttons:
//   UP / RIGHT  — shift the lit LED one position toward LED[7]
//   DOWN / LEFT — shift the lit LED one position toward LED[0]
//   FIRE1       — toggle all LEDs on/off
//   FIRE2       — reset to single LED at position 0
//
// Wraps around at both ends. Each button press moves exactly one step
// thanks to rising-edge detection.
//
// Concepts: digital inputs, 2-FF synchronisers (metastability protection),
//           edge detection, registered outputs, one-hot encoding.

module top (
    input  wire clk,          // 25 MHz oscillator
    input  wire btn_up,       // active-high, PULLMODE=DOWN
    input  wire btn_down,
    input  wire btn_left,
    input  wire btn_right,
    input  wire btn_fire1,
    input  wire btn_fire2,
    output reg  [7:0] led     // 8 onboard LEDs (active high)
);

    // ---------------------------------------------------------------
    // 2-FF synchronisers — one per button
    // External signals are asynchronous to clk. Sampling them directly
    // risks metastability. Two flip-flops in series reduce the
    // probability to negligible levels at 25 MHz.
    // ---------------------------------------------------------------
    reg [1:0] sync_up, sync_down, sync_left, sync_right;
    reg [1:0] sync_fire1, sync_fire2;

    always @(posedge clk) begin
        sync_up    <= {sync_up[0],    btn_up};
        sync_down  <= {sync_down[0],  btn_down};
        sync_left  <= {sync_left[0],  btn_left};
        sync_right <= {sync_right[0], btn_right};
        sync_fire1 <= {sync_fire1[0], btn_fire1};
        sync_fire2 <= {sync_fire2[0], btn_fire2};
    end

    // Synchronised (stable) button values — MSB of each shift register
    wire s_up    = sync_up[1];
    wire s_down  = sync_down[1];
    wire s_left  = sync_left[1];
    wire s_right = sync_right[1];
    wire s_fire1 = sync_fire1[1];
    wire s_fire2 = sync_fire2[1];

    // ---------------------------------------------------------------
    // Rising-edge detection
    // Compare the current synchronised value to its state one clock
    // cycle ago. A rising edge is: high now AND low last cycle.
    // This means holding a button produces only one action.
    // ---------------------------------------------------------------
    reg prev_up, prev_down, prev_left, prev_right;
    reg prev_fire1, prev_fire2;

    always @(posedge clk) begin
        prev_up    <= s_up;
        prev_down  <= s_down;
        prev_left  <= s_left;
        prev_right <= s_right;
        prev_fire1 <= s_fire1;
        prev_fire2 <= s_fire2;
    end

    wire rise_up    = s_up    & ~prev_up;
    wire rise_down  = s_down  & ~prev_down;
    wire rise_left  = s_left  & ~prev_left;
    wire rise_right = s_right & ~prev_right;
    wire rise_fire1 = s_fire1 & ~prev_fire1;
    wire rise_fire2 = s_fire2 & ~prev_fire2;

    // ---------------------------------------------------------------
    // Position register and all-on flag
    // pos tracks which single LED is lit (0–7). all_on lights every LED.
    // ---------------------------------------------------------------
    reg [2:0] pos    = 3'd0;
    reg       all_on = 1'b0;

    always @(posedge clk) begin
        // FIRE2 — reset: single LED at position 0, all_on off
        if (rise_fire2) begin
            pos    <= 3'd0;
            all_on <= 1'b0;
        end else begin
            // FIRE1 — toggle all LEDs on/off
            if (rise_fire1)
                all_on <= ~all_on;

            // UP or RIGHT — move toward LED[7] (wraps 7 -> 0)
            if (rise_up | rise_right)
                pos <= (pos == 3'd7) ? 3'd0 : pos + 3'd1;

            // DOWN or LEFT — move toward LED[0] (wraps 0 -> 7)
            if (rise_down | rise_left)
                pos <= (pos == 3'd0) ? 3'd7 : pos - 3'd1;
        end
    end

    // ---------------------------------------------------------------
    // LED output — all on, or single lit LED at pos
    // ---------------------------------------------------------------
    always @(posedge clk)
        led <= all_on ? 8'hFF : (8'd1 << pos);

endmodule
