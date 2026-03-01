// =============================================================================
// I2S Master Output — ULX3S + PCM5102A DAC
// =============================================================================
//
// Generates a 440 Hz sine wave over I2S to a PCM5102A DAC breakout connected
// to the J1 header (GN0–GN7).
//
// Clock derivation from 25 MHz:
//   Toggle BCLK every 8 system clocks → BCLK = 25 MHz / 16 = 1.5625 MHz
//   32 bits per stereo frame → sample rate = 48,828 Hz (~1.7% above 48 kHz)
//
// PCM5102A wiring (active signals accent on GN3–GN5):
//   GN0 (C11) → FLT  = LOW   (normal latency filter)
//   GN1 (A11) → DMP  = LOW   (de-emphasis off)
//   GN2 (B10) → SCL  = LOW   (PCM5102 generates system clock internally)
//   GN3 (C10) → BCK  = BCLK  (I2S bit clock)
//   GN4 (A8)  → DIN  = DATA  (I2S serial data, MSB first)
//   GN5 (B8)  → LCK  = LRCK  (I2S word select: L=low, R=high)
//   GN6 (C7)  → FMT  = LOW   (I2S format)
//   GN7 (B6)  → XMT  = HIGH  (unmute / soft-mute off)
//
// =============================================================================

module top (
    input  clk,          // 25 MHz oscillator (pin G2)

    // PCM5102A control pins (directly from FPGA)
    output pcm_flt,      // GN0 — filter select
    output pcm_dmp,      // GN1 — de-emphasis
    output pcm_scl,      // GN2 — system clock
    output pcm_bck,      // GN3 — I2S bit clock
    output pcm_din,      // GN4 — I2S serial data
    output pcm_lck,      // GN5 — I2S word select (LRCK)
    output pcm_fmt,      // GN6 — format select
    output pcm_xmt,      // GN7 — mute control

    output [7:0] led     // LEDs for heartbeat
);

    // =========================================================================
    // Static control pins
    // =========================================================================
    assign pcm_flt = 1'b0;   // normal latency filter
    assign pcm_dmp = 1'b0;   // de-emphasis off
    assign pcm_scl = 1'b0;   // use internal system clock
    assign pcm_fmt = 1'b0;   // I2S format
    assign pcm_xmt = 1'b1;   // unmute (active high)

    // =========================================================================
    // Clock divider: 25 MHz → 1.5625 MHz BCLK (divide by 16, toggle every 8)
    // =========================================================================
    localparam BCLK_DIV = 8;  // toggle every 8 clocks → 25M / 16 = 1.5625 MHz

    reg [2:0] clk_div = 0;
    reg bclk_reg = 0;

    wire bclk_tick = (clk_div == BCLK_DIV - 1);

    always @(posedge clk) begin
        if (bclk_tick) begin
            clk_div <= 0;
            bclk_reg <= ~bclk_reg;
        end else begin
            clk_div <= clk_div + 1;
        end
    end

    // Detect BCLK falling edge — shift out data here
    reg bclk_prev = 0;
    always @(posedge clk) bclk_prev <= bclk_reg;
    wire bclk_fall = bclk_prev & ~bclk_reg;

    assign pcm_bck = bclk_reg;

    // =========================================================================
    // Bit counter: 0–31 within each stereo frame
    // =========================================================================
    //   Bits  0–15: left channel  (LRCK low)
    //   Bits 16–31: right channel (LRCK high)
    //
    // I2S: data word starts one BCLK after LRCK transition (delay bit).
    //
    reg [4:0] bit_cnt = 0;
    reg lrck_reg = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 31)
                bit_cnt <= 0;
            else
                bit_cnt <= bit_cnt + 1;

            // LRCK: low for left (0–15), high for right (16–31)
            if (bit_cnt == 31)
                lrck_reg <= 0;
            else if (bit_cnt == 15)
                lrck_reg <= 1;
        end
    end

    assign pcm_lck = lrck_reg;

    // =========================================================================
    // Shift register: loads sample at start of each channel, shifts MSB out
    // =========================================================================
    reg [15:0] shift_reg = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 0 || bit_cnt == 16) begin
                // Load sample — this clock is the I2S delay bit (output 0)
                shift_reg <= sample;
            end else begin
                shift_reg <= {shift_reg[14:0], 1'b0};
            end
        end
    end

    // Data: 0 during delay bit, MSB of shift reg otherwise
    assign pcm_din = (bit_cnt == 0 || bit_cnt == 16) ? 1'b0 : shift_reg[15];

    // =========================================================================
    // DDS sine oscillator: 440 Hz
    // =========================================================================
    //
    // Sample rate = 25 MHz / 16 / 32 = 48,828.125 Hz
    // Phase step  = 2^32 × 440 / 48828.125 ≈ 38,698,728
    //
    localparam [31:0] PHASE_STEP = 32'd38698728;

    reg [31:0] phase = 0;

    // Advance phase once per sample (start of left channel)
    always @(posedge clk) begin
        if (bclk_fall && bit_cnt == 0)
            phase <= phase + PHASE_STEP;
    end

    // Sine lookup — 256 entries, unsigned 8-bit
    reg [7:0] sine_val;
    always @(*) begin
        case (phase[31:24])
            8'd0:   sine_val = 128; 8'd1:   sine_val = 131; 8'd2:   sine_val = 134; 8'd3:   sine_val = 137;
            8'd4:   sine_val = 140; 8'd5:   sine_val = 143; 8'd6:   sine_val = 146; 8'd7:   sine_val = 149;
            8'd8:   sine_val = 152; 8'd9:   sine_val = 155; 8'd10:  sine_val = 158; 8'd11:  sine_val = 162;
            8'd12:  sine_val = 165; 8'd13:  sine_val = 167; 8'd14:  sine_val = 170; 8'd15:  sine_val = 173;
            8'd16:  sine_val = 176; 8'd17:  sine_val = 179; 8'd18:  sine_val = 182; 8'd19:  sine_val = 185;
            8'd20:  sine_val = 188; 8'd21:  sine_val = 190; 8'd22:  sine_val = 193; 8'd23:  sine_val = 196;
            8'd24:  sine_val = 198; 8'd25:  sine_val = 201; 8'd26:  sine_val = 203; 8'd27:  sine_val = 206;
            8'd28:  sine_val = 208; 8'd29:  sine_val = 211; 8'd30:  sine_val = 213; 8'd31:  sine_val = 215;
            8'd32:  sine_val = 218; 8'd33:  sine_val = 220; 8'd34:  sine_val = 222; 8'd35:  sine_val = 224;
            8'd36:  sine_val = 226; 8'd37:  sine_val = 228; 8'd38:  sine_val = 230; 8'd39:  sine_val = 232;
            8'd40:  sine_val = 234; 8'd41:  sine_val = 235; 8'd42:  sine_val = 237; 8'd43:  sine_val = 238;
            8'd44:  sine_val = 240; 8'd45:  sine_val = 241; 8'd46:  sine_val = 243; 8'd47:  sine_val = 244;
            8'd48:  sine_val = 245; 8'd49:  sine_val = 246; 8'd50:  sine_val = 248; 8'd51:  sine_val = 249;
            8'd52:  sine_val = 250; 8'd53:  sine_val = 250; 8'd54:  sine_val = 251; 8'd55:  sine_val = 252;
            8'd56:  sine_val = 253; 8'd57:  sine_val = 253; 8'd58:  sine_val = 254; 8'd59:  sine_val = 254;
            8'd60:  sine_val = 254; 8'd61:  sine_val = 255; 8'd62:  sine_val = 255; 8'd63:  sine_val = 255;
            8'd64:  sine_val = 255; 8'd65:  sine_val = 255; 8'd66:  sine_val = 255; 8'd67:  sine_val = 255;
            8'd68:  sine_val = 254; 8'd69:  sine_val = 254; 8'd70:  sine_val = 254; 8'd71:  sine_val = 253;
            8'd72:  sine_val = 253; 8'd73:  sine_val = 252; 8'd74:  sine_val = 251; 8'd75:  sine_val = 250;
            8'd76:  sine_val = 250; 8'd77:  sine_val = 249; 8'd78:  sine_val = 248; 8'd79:  sine_val = 246;
            8'd80:  sine_val = 245; 8'd81:  sine_val = 244; 8'd82:  sine_val = 243; 8'd83:  sine_val = 241;
            8'd84:  sine_val = 240; 8'd85:  sine_val = 238; 8'd86:  sine_val = 237; 8'd87:  sine_val = 235;
            8'd88:  sine_val = 234; 8'd89:  sine_val = 232; 8'd90:  sine_val = 230; 8'd91:  sine_val = 228;
            8'd92:  sine_val = 226; 8'd93:  sine_val = 224; 8'd94:  sine_val = 222; 8'd95:  sine_val = 220;
            8'd96:  sine_val = 218; 8'd97:  sine_val = 215; 8'd98:  sine_val = 213; 8'd99:  sine_val = 211;
            8'd100: sine_val = 208; 8'd101: sine_val = 206; 8'd102: sine_val = 203; 8'd103: sine_val = 201;
            8'd104: sine_val = 198; 8'd105: sine_val = 196; 8'd106: sine_val = 193; 8'd107: sine_val = 190;
            8'd108: sine_val = 188; 8'd109: sine_val = 185; 8'd110: sine_val = 182; 8'd111: sine_val = 179;
            8'd112: sine_val = 176; 8'd113: sine_val = 173; 8'd114: sine_val = 170; 8'd115: sine_val = 167;
            8'd116: sine_val = 165; 8'd117: sine_val = 162; 8'd118: sine_val = 158; 8'd119: sine_val = 155;
            8'd120: sine_val = 152; 8'd121: sine_val = 149; 8'd122: sine_val = 146; 8'd123: sine_val = 143;
            8'd124: sine_val = 140; 8'd125: sine_val = 137; 8'd126: sine_val = 134; 8'd127: sine_val = 131;
            8'd128: sine_val = 128; 8'd129: sine_val = 124; 8'd130: sine_val = 121; 8'd131: sine_val = 118;
            8'd132: sine_val = 115; 8'd133: sine_val = 112; 8'd134: sine_val = 109; 8'd135: sine_val = 106;
            8'd136: sine_val = 103; 8'd137: sine_val = 100; 8'd138: sine_val = 97;  8'd139: sine_val = 93;
            8'd140: sine_val = 90;  8'd141: sine_val = 88;  8'd142: sine_val = 85;  8'd143: sine_val = 82;
            8'd144: sine_val = 79;  8'd145: sine_val = 76;  8'd146: sine_val = 73;  8'd147: sine_val = 70;
            8'd148: sine_val = 67;  8'd149: sine_val = 65;  8'd150: sine_val = 62;  8'd151: sine_val = 59;
            8'd152: sine_val = 57;  8'd153: sine_val = 54;  8'd154: sine_val = 52;  8'd155: sine_val = 49;
            8'd156: sine_val = 47;  8'd157: sine_val = 44;  8'd158: sine_val = 42;  8'd159: sine_val = 40;
            8'd160: sine_val = 37;  8'd161: sine_val = 35;  8'd162: sine_val = 33;  8'd163: sine_val = 31;
            8'd164: sine_val = 29;  8'd165: sine_val = 27;  8'd166: sine_val = 25;  8'd167: sine_val = 23;
            8'd168: sine_val = 21;  8'd169: sine_val = 20;  8'd170: sine_val = 18;  8'd171: sine_val = 17;
            8'd172: sine_val = 15;  8'd173: sine_val = 14;  8'd174: sine_val = 12;  8'd175: sine_val = 11;
            8'd176: sine_val = 10;  8'd177: sine_val = 9;   8'd178: sine_val = 7;   8'd179: sine_val = 6;
            8'd180: sine_val = 5;   8'd181: sine_val = 5;   8'd182: sine_val = 4;   8'd183: sine_val = 3;
            8'd184: sine_val = 2;   8'd185: sine_val = 2;   8'd186: sine_val = 1;   8'd187: sine_val = 1;
            8'd188: sine_val = 1;   8'd189: sine_val = 0;   8'd190: sine_val = 0;   8'd191: sine_val = 0;
            8'd192: sine_val = 0;   8'd193: sine_val = 0;   8'd194: sine_val = 0;   8'd195: sine_val = 0;
            8'd196: sine_val = 1;   8'd197: sine_val = 1;   8'd198: sine_val = 1;   8'd199: sine_val = 2;
            8'd200: sine_val = 2;   8'd201: sine_val = 3;   8'd202: sine_val = 4;   8'd203: sine_val = 5;
            8'd204: sine_val = 5;   8'd205: sine_val = 6;   8'd206: sine_val = 7;   8'd207: sine_val = 9;
            8'd208: sine_val = 10;  8'd209: sine_val = 11;  8'd210: sine_val = 12;  8'd211: sine_val = 14;
            8'd212: sine_val = 15;  8'd213: sine_val = 17;  8'd214: sine_val = 18;  8'd215: sine_val = 20;
            8'd216: sine_val = 21;  8'd217: sine_val = 23;  8'd218: sine_val = 25;  8'd219: sine_val = 27;
            8'd220: sine_val = 29;  8'd221: sine_val = 31;  8'd222: sine_val = 33;  8'd223: sine_val = 35;
            8'd224: sine_val = 37;  8'd225: sine_val = 40;  8'd226: sine_val = 42;  8'd227: sine_val = 44;
            8'd228: sine_val = 47;  8'd229: sine_val = 49;  8'd230: sine_val = 52;  8'd231: sine_val = 54;
            8'd232: sine_val = 57;  8'd233: sine_val = 59;  8'd234: sine_val = 62;  8'd235: sine_val = 65;
            8'd236: sine_val = 67;  8'd237: sine_val = 70;  8'd238: sine_val = 73;  8'd239: sine_val = 76;
            8'd240: sine_val = 79;  8'd241: sine_val = 82;  8'd242: sine_val = 85;  8'd243: sine_val = 88;
            8'd244: sine_val = 90;  8'd245: sine_val = 93;  8'd246: sine_val = 97;  8'd247: sine_val = 100;
            8'd248: sine_val = 103; 8'd249: sine_val = 106; 8'd250: sine_val = 109; 8'd251: sine_val = 112;
            8'd252: sine_val = 115; 8'd253: sine_val = 118; 8'd254: sine_val = 121; 8'd255: sine_val = 124;
        endcase
    end

    // Convert unsigned 8-bit to signed 16-bit at 1/16 amplitude: (sine_val - 128) << 4
    wire signed [15:0] full = {sine_val[7] ^ 1'b1, sine_val[6:0], 8'b0};
    wire signed [15:0] sample = full >>> 4;

    // =========================================================================
    // Heartbeat: LED0 blinks at ~1 Hz
    // =========================================================================
    reg [24:0] heartbeat = 0;
    always @(posedge clk) heartbeat <= heartbeat + 1;
    assign led = {7'b0, heartbeat[24]};  // LED0 blinks ~0.75 Hz

endmodule
