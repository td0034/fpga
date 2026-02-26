// =============================================================================
// DDS Synth — SPI-controlled oscillator → I2S DAC output
// =============================================================================
//
// What this does:
//   Combines modules 01 and 03: the ESP32-S3 sends a frequency value over SPI,
//   and the FPGA generates a sine wave at that frequency, output via I2S to
//   the PCM5102A DAC. This is the first "real" synth: MIDI note on the ESP32
//   → SPI register write → FPGA plays the tone.
//
// SPI register map:
//   0x00: Phase step byte 3 (MSB)  — phase_step[31:24]
//   0x01: Phase step byte 2        — phase_step[23:16]
//   0x02: Phase step byte 1        — phase_step[15:8]
//   0x03: Phase step byte 0 (LSB)  — phase_step[7:0]
//   0x04: Gate (0=off, nonzero=on) — enables/disables the oscillator
//   0x05: Waveform select          — 0=sine, 1=saw, 2=square, 3=triangle
//   0x10: Status (read-only)       — returns 0x42
//
// Phase step calculation (for ESP32 firmware):
//   step = (uint32_t)(freq_hz * 4294967296.0 / 46875.0)
//
//   Common values:
//     A3  (220.00 Hz): 20,145,111
//     A4  (440.00 Hz): 40,290,222
//     A5  (880.00 Hz): 80,580,444
//     C4  (261.63 Hz): 23,938,780
//
// Wiring:
//   SPI on PMOD 2 (ESP32-S3), I2S on PMOD 3 (PCM5102A DAC)
//   Same pin assignments as modules 01 and 03.
//
// =============================================================================

module top (
    input  clk,           // 12 MHz
    // SPI (PMOD 2)
    input  spi_sck,
    input  spi_mosi,
    output spi_miso,
    input  spi_cs_n,
    // I2S (PMOD 3)
    output i2s_bclk,
    output i2s_data,
    output i2s_lrck,
    // LEDs
    output led_g,
    output led_r
);

    // =========================================================================
    // SPI slave — synchronized, edge-detected, register-writing
    // =========================================================================
    reg [1:0] sck_sync = 0, mosi_sync = 0, cs_sync = 2'b11;
    always @(posedge clk) begin
        sck_sync  <= {sck_sync[0],  spi_sck};
        mosi_sync <= {mosi_sync[0], spi_mosi};
        cs_sync   <= {cs_sync[0],   spi_cs_n};
    end

    wire sck_s  = sck_sync[1];
    wire mosi_s = mosi_sync[1];
    wire cs_s   = cs_sync[1];

    reg sck_prev = 0;
    always @(posedge clk) sck_prev <= sck_s;
    wire sck_rise = ~sck_prev & sck_s;
    wire sck_fall = sck_prev & ~sck_s;

    reg [3:0] spi_bit_cnt = 0;
    reg [7:0] spi_rx_addr = 0;
    reg [7:0] spi_rx_data = 0;
    reg spi_addr_done = 0;
    reg spi_data_done = 0;

    always @(posedge clk) begin
        spi_data_done <= 0;
        if (cs_s) begin
            spi_bit_cnt <= 0;
            spi_addr_done <= 0;
        end else if (sck_rise) begin
            if (!spi_addr_done) begin
                spi_rx_addr <= {spi_rx_addr[6:0], mosi_s};
                if (spi_bit_cnt == 7) begin
                    spi_addr_done <= 1;
                    spi_bit_cnt <= 0;
                end else
                    spi_bit_cnt <= spi_bit_cnt + 1;
            end else begin
                spi_rx_data <= {spi_rx_data[6:0], mosi_s};
                if (spi_bit_cnt == 7) begin
                    spi_data_done <= 1;
                    spi_bit_cnt <= 0;
                end else
                    spi_bit_cnt <= spi_bit_cnt + 1;
            end
        end
    end

    // MISO — read back registers
    reg [7:0] miso_shift = 0;
    always @(posedge clk) begin
        if (cs_s)
            miso_shift <= 0;
        else if (spi_addr_done && spi_bit_cnt == 0 && sck_fall) begin
            case (spi_rx_addr[6:0])
                7'h00: miso_shift <= phase_step_reg[31:24];
                7'h01: miso_shift <= phase_step_reg[23:16];
                7'h02: miso_shift <= phase_step_reg[15:8];
                7'h03: miso_shift <= phase_step_reg[7:0];
                7'h04: miso_shift <= {7'd0, gate};
                7'h05: miso_shift <= {6'd0, waveform};
                7'h10: miso_shift <= 8'h42;
                default: miso_shift <= 8'h00;
            endcase
        end else if (sck_fall && spi_addr_done)
            miso_shift <= {miso_shift[6:0], 1'b0};
    end
    assign spi_miso = cs_s ? 1'bz : miso_shift[7];

    // =========================================================================
    // Parameter registers
    // =========================================================================
    reg [31:0] phase_step_reg = 32'd40290222;  // default 440 Hz
    reg gate = 1;                               // default on
    reg [1:0] waveform = 0;                     // default sine

    always @(posedge clk) begin
        if (spi_data_done && !spi_rx_addr[7]) begin
            case (spi_rx_addr[6:0])
                7'h00: phase_step_reg[31:24] <= spi_rx_data;
                7'h01: phase_step_reg[23:16] <= spi_rx_data;
                7'h02: phase_step_reg[15:8]  <= spi_rx_data;
                7'h03: phase_step_reg[7:0]   <= spi_rx_data;
                7'h04: gate <= spi_rx_data[0];
                7'h05: waveform <= spi_rx_data[1:0];
            endcase
        end
    end

    // =========================================================================
    // I2S master — BCLK, LRCK generation (same as module 01)
    // =========================================================================
    localparam BCLK_DIV = 4;
    reg [1:0] bclk_div = 0;
    reg bclk_reg = 0;

    wire bclk_tick = (bclk_div == BCLK_DIV - 1);
    always @(posedge clk) begin
        if (bclk_tick) begin
            bclk_div <= 0;
            bclk_reg <= ~bclk_reg;
        end else
            bclk_div <= bclk_div + 1;
    end

    reg bclk_p = 0;
    always @(posedge clk) bclk_p <= bclk_reg;
    wire bclk_fall = bclk_p & ~bclk_reg;

    assign i2s_bclk = bclk_reg;

    reg [4:0] bit_cnt = 0;
    reg lrck_reg = 0;
    always @(posedge clk) begin
        if (bclk_fall) begin
            bit_cnt <= (bit_cnt == 31) ? 0 : bit_cnt + 1;
            if (bit_cnt == 31) lrck_reg <= 0;
            else if (bit_cnt == 15) lrck_reg <= 1;
        end
    end
    assign i2s_lrck = lrck_reg;

    // =========================================================================
    // DDS oscillator — multi-waveform
    // =========================================================================
    reg [31:0] phase = 0;

    always @(posedge clk) begin
        if (bclk_fall && bit_cnt == 0)
            phase <= phase + phase_step_reg;
    end

    // Sine lookup (unsigned 8-bit, same table as before)
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

    // Multi-waveform selection
    reg signed [15:0] wave_out;
    always @(*) begin
        case (waveform)
            2'd0: // Sine — unsigned 8-bit to signed 16-bit
                wave_out = {sine_val[7] ^ 1'b1, sine_val[6:0], 8'b0};
            2'd1: // Sawtooth — phase top bits directly
                wave_out = {phase[31] ^ 1'b1, phase[30:16]};
            2'd2: // Square — full amplitude based on phase MSB
                wave_out = phase[31] ? 16'sh7F00 : 16'sh8100;
            2'd3: // Triangle — fold the sawtooth
                wave_out = phase[31] ?
                    {1'b0, ~phase[30:16]} :  // descending half
                    {1'b0, phase[30:16]};     // ascending half
            default:
                wave_out = 0;
        endcase
    end

    // Gate control — mute when gate is off
    wire signed [15:0] sample = gate ? wave_out : 16'sd0;

    // =========================================================================
    // I2S data output — shift out sample MSB first
    // =========================================================================
    reg [15:0] shift_reg = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 0 || bit_cnt == 16)
                shift_reg <= sample;
            else
                shift_reg <= {shift_reg[14:0], 1'b0};
        end
    end

    assign i2s_data = (bit_cnt == 0 || bit_cnt == 16) ? 1'b0 : shift_reg[15];

    // =========================================================================
    // LEDs
    // =========================================================================
    reg [23:0] hb = 0;
    always @(posedge clk) hb <= hb + 1;
    assign led_g = ~hb[23];              // heartbeat
    assign led_r = ~gate;                // red when gate is on (active low)

endmodule
