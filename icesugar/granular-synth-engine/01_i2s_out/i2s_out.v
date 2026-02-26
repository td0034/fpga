// =============================================================================
// I2S Master Output — IceSugar v1.5 + PCM5102A DAC
// =============================================================================
//
// What this does:
//   Generates proper I2S signals (BCLK, LRCK, DATA) to drive a PCM5102A DAC
//   breakout board. Outputs a 440 Hz sine wave as 16-bit signed audio at
//   48 kHz sample rate. Green LED blinks at ~1 Hz as a heartbeat.
//
// I2S format (Philips standard):
//   - BCLK: bit clock, 48 kHz × 32 bits = 1.536 MHz
//   - LRCK: left/right word select, toggles every 16 BCLK cycles (= 48 kHz)
//            LOW = left channel, HIGH = right channel
//   - DATA: MSB-first, 16-bit signed samples, transitions on BCLK falling edge,
//            sampled by DAC on BCLK rising edge
//   - Data is one BCLK late relative to LRCK transition (I2S standard)
//
// Clock derivation from 12 MHz:
//   12 MHz / 1.536 MHz = 7.8125 — not an integer!
//   We use divide-by-8 (BCLK = 1.5 MHz), giving 46,875 Hz sample rate.
//   That's < 2% off from 48 kHz — inaudible difference.
//
// PCM5102A wiring (directly to PMOD header):
//   BCK  ← FPGA BCLK    (pin 34, PMOD3 P3_1)
//   DIN  ← FPGA DATA    (pin 31, PMOD3 P3_2)
//   LCK  ← FPGA LRCK    (pin 27, PMOD3 P3_3)
//   SCK  ← tie to GND on the breakout (or leave floating — PCM5102A
//           auto-generates its system clock when SCK is grounded)
//   FMT  ← GND (I2S format)
//   XSMT ← 3.3V (unmute / soft-mute off)
//
// =============================================================================

module top (
    input  clk,        // 12 MHz clock (pin 35, GBIN0)
    output i2s_bclk,   // I2S bit clock → PCM5102A BCK
    output i2s_data,   // I2S serial data → PCM5102A DIN
    output i2s_lrck,   // I2S word select → PCM5102A LCK
    output led_g       // Green LED heartbeat
);

    // =========================================================================
    // Clock divider: 12 MHz → 1.5 MHz BCLK (divide by 8)
    // =========================================================================
    //
    // We need to toggle the BCLK output, so we count to 3 (half of 8 = 4,
    // but counting from 0 means we toggle at count 3).
    //
    // Actually: divide-by-8 means we toggle every 4 clocks.
    //   12 MHz / 8 = 1.5 MHz BCLK
    //   1.5 MHz / 32 bits = 46,875 Hz sample rate
    //
    localparam BCLK_DIV = 4;  // toggle every 4 clocks (12M / 8 = 1.5M)

    reg [1:0] clk_div = 0;
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

    // Detect falling edge of BCLK — this is when we shift out the next bit
    reg bclk_prev = 0;
    always @(posedge clk) bclk_prev <= bclk_reg;
    wire bclk_fall = bclk_prev & ~bclk_reg;

    assign i2s_bclk = bclk_reg;

    // =========================================================================
    // Bit counter: counts 0-31 within each stereo frame
    // =========================================================================
    //
    // Bits 0-15:  left channel (LRCK low)
    // Bits 16-31: right channel (LRCK high)
    //
    // In I2S, the data word starts one BCLK after the LRCK transition.
    // Bit 0 and bit 16 are the "delay" bits (we send 0), then MSB first.
    //
    reg [4:0] bit_cnt = 0;
    reg lrck_reg = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 31) begin
                bit_cnt <= 0;
            end else begin
                bit_cnt <= bit_cnt + 1;
            end

            // LRCK transitions: low for left (bits 0-15), high for right (bits 16-31)
            if (bit_cnt == 31)
                lrck_reg <= 0;  // about to start left channel
            else if (bit_cnt == 15)
                lrck_reg <= 1;  // about to start right channel
        end
    end

    assign i2s_lrck = lrck_reg;

    // =========================================================================
    // Sample generation: load a new sample at the start of each channel
    // =========================================================================
    //
    // We latch the current sine value into a shift register when bit_cnt == 0
    // (start of left) and bit_cnt == 16 (start of right). Both channels get
    // the same sample (mono output on both L and R).
    //
    reg [15:0] shift_reg = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 0 || bit_cnt == 16) begin
                // Load new sample — bit_cnt 0 and 16 are the I2S delay bit
                // (we output 0 for this bit, then MSB first starting next cycle)
                shift_reg <= sample;
            end else begin
                // Shift out MSB first
                shift_reg <= {shift_reg[14:0], 1'b0};
            end
        end
    end

    // Data output: MSB of shift register during data bits, 0 during delay bit
    assign i2s_data = (bit_cnt == 0 || bit_cnt == 16) ? 1'b0 : shift_reg[15];

    // =========================================================================
    // DDS sine oscillator: 440 Hz
    // =========================================================================
    //
    // Phase accumulator + sine lookup, same concept as the sine_tone example
    // but now outputting 16-bit signed samples for I2S instead of 8-bit PWM.
    //
    // Frequency formula (sample rate = 46,875 Hz, 32-bit accumulator):
    //   step = 2^32 × 440 / 46875 = 40,290,222
    //
    // The sine table outputs unsigned 8-bit (0-255), which we convert to
    // 16-bit signed by: (value - 128) << 8
    // This gives a range of -32768 to +32512.
    //
    localparam [31:0] PHASE_STEP = 32'd40290222;  // 440 Hz at 46875 Hz SR

    reg [31:0] phase = 0;

    // Advance phase once per sample (at the start of left channel)
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

    // Convert unsigned 8-bit (0-255) to signed 16-bit (-32768 to +32512)
    wire signed [15:0] sample = {sine_val[7] ^ 1'b1, sine_val[6:0], 8'b0};
    // Explanation: sine_val 128 → 0x0000, sine_val 255 → 0x7F00, sine_val 0 → 0x8000
    // This is equivalent to: (sine_val - 128) << 8, done with bit manipulation

    // =========================================================================
    // Heartbeat LED — blinks at ~1 Hz
    // =========================================================================
    reg [23:0] heartbeat = 0;
    always @(posedge clk) heartbeat <= heartbeat + 1;
    assign led_g = ~heartbeat[23];  // active low, ~0.7 Hz

endmodule
