// =============================================================================
// I2S Passthrough — PCM1808 ADC → FPGA → PCM5102A DAC
// =============================================================================
//
// What this does:
//   Audio loopback: captures audio from a PCM1808 ADC breakout and plays it
//   back through a PCM5102A DAC breakout in real time. Proves the full
//   audio chain works before adding any DSP.
//
// Architecture:
//   The FPGA is the I2S master for BOTH the ADC and DAC. It generates:
//   - BCLK and LRCK shared by both chips
//   - Reads DATA from the PCM1808 (input)
//   - Writes DATA to the PCM5102A (output)
//
// PCM1808 (ADC) wiring on PMOD 2:
//   BCK  ← FPGA BCLK    (pin 46, P2_1)
//   OUT  → FPGA ADC_DATA (pin 44, P2_2) — serial audio FROM the ADC
//   LRC  ← FPGA LRCK    (pin 42, P2_3)
//   FMT  ← GND (I2S format, directly on breakout)
//   MD0  ← GND \
//   MD1  ← GND / slave mode (256fs or 384fs auto-detect, not relevant
//                             since we're providing BCK/LRC)
//
//   NOTE: PCM1808 in slave mode accepts external BCK and LRC.
//   It needs a system clock (SCKI) of 256×Fs or 384×Fs.
//   Option A: Use a separate oscillator (e.g., 12.288 MHz for 48kHz)
//   Option B: Generate it from the FPGA — we output a ~12 MHz clock
//             (our main clock divided by 1) on a PMOD pin.
//   We use option B: route the 12 MHz clock out to the PCM1808 SCKI pin.
//   12 MHz / 256 = 46,875 Hz — matches our sample rate perfectly.
//
// PCM5102A (DAC) wiring on PMOD 3:
//   BCK  ← FPGA BCLK    (pin 34, P3_1)
//   DIN  ← FPGA DAC_DATA(pin 31, P3_2)
//   LCK  ← FPGA LRCK    (pin 27, P3_3)
//   SCK  ← GND (on breakout — PCM5102A generates internal clock)
//   FMT  ← GND (I2S format)
//   XSMT ← 3.3V (unmute)
//
// =============================================================================

module top (
    input  clk,           // 12 MHz clock (pin 35, GBIN0)
    output i2s_bclk,      // shared I2S bit clock (→ both ADC and DAC)
    output i2s_lrck,      // shared I2S word select
    input  adc_data,      // serial audio from PCM1808
    output dac_data,      // serial audio to PCM5102A
    output adc_scki,      // system clock for PCM1808 (12 MHz passthrough)
    output led_g,         // green LED — heartbeat
    output led_r          // red LED — lights when audio level is high
);

    // =========================================================================
    // PCM1808 system clock — just pass through the 12 MHz clock
    // =========================================================================
    // 12 MHz / 256 = 46,875 Hz sample rate (within PCM1808's 256fs slave mode)
    assign adc_scki = clk;

    // =========================================================================
    // I2S master clock generation — same as 01_i2s_out
    // =========================================================================
    localparam BCLK_DIV = 4;  // 12 MHz / 8 = 1.5 MHz BCLK

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

    reg bclk_prev = 0;
    always @(posedge clk) bclk_prev <= bclk_reg;
    wire bclk_fall = bclk_prev & ~bclk_reg;
    wire bclk_rise = ~bclk_prev & bclk_reg;

    assign i2s_bclk = bclk_reg;

    // =========================================================================
    // Bit counter and LRCK generation
    // =========================================================================
    reg [4:0] bit_cnt = 0;
    reg lrck_reg = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 31)
                bit_cnt <= 0;
            else
                bit_cnt <= bit_cnt + 1;

            if (bit_cnt == 31)
                lrck_reg <= 0;
            else if (bit_cnt == 15)
                lrck_reg <= 1;
        end
    end

    assign i2s_lrck = lrck_reg;

    // =========================================================================
    // ADC input — capture serial data from PCM1808 on BCLK rising edge
    // =========================================================================
    //
    // PCM1808 outputs 24-bit data but we only capture the top 16 bits
    // (the MSBs, which contain most of the signal energy). We ignore the
    // lower 8 bits by only shifting during bit_cnt 1-16 (after the I2S
    // delay bit).
    //
    reg [15:0] adc_shift = 0;
    reg [15:0] adc_left = 0;
    reg [15:0] adc_right = 0;

    always @(posedge clk) begin
        if (bclk_rise) begin
            // Shift in data bits (skip delay bit at positions 0 and 16)
            if ((bit_cnt >= 1 && bit_cnt <= 16) || (bit_cnt >= 17 && bit_cnt <= 31)) begin
                adc_shift <= {adc_shift[14:0], adc_data};
            end

            // Latch completed channels
            if (bit_cnt == 16)  // just finished receiving 16 bits of left
                adc_left <= {adc_shift[14:0], adc_data};
            if (bit_cnt == 0)   // just finished receiving 16 bits of right (wrapped)
                adc_right <= {adc_shift[14:0], adc_data};
        end
    end

    // =========================================================================
    // DAC output — send captured audio to PCM5102A
    // =========================================================================
    reg [15:0] dac_shift = 0;

    always @(posedge clk) begin
        if (bclk_fall) begin
            if (bit_cnt == 0) begin
                // Start of left channel — load left sample
                dac_shift <= adc_left;
            end else if (bit_cnt == 16) begin
                // Start of right channel — load right sample
                dac_shift <= adc_right;
            end else begin
                dac_shift <= {dac_shift[14:0], 1'b0};
            end
        end
    end

    assign dac_data = (bit_cnt == 0 || bit_cnt == 16) ? 1'b0 : dac_shift[15];

    // =========================================================================
    // LED indicators
    // =========================================================================
    // Green LED: heartbeat (~1 Hz)
    reg [23:0] heartbeat = 0;
    always @(posedge clk) heartbeat <= heartbeat + 1;
    assign led_g = ~heartbeat[23];

    // Red LED: lights when audio level exceeds threshold (signal present)
    // Check if the top 4 bits of the absolute value are non-zero
    wire [15:0] abs_left = adc_left[15] ? ~adc_left + 1 : adc_left;
    assign led_r = ~(abs_left[15:12] != 4'b0000);  // active low

endmodule
