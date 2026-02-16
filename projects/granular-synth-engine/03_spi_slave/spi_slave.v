// =============================================================================
// SPI Slave — ESP32-S3 → FPGA register interface
// =============================================================================
//
// What this does:
//   Implements a SPI slave that lets the ESP32-S3 write to FPGA registers
//   over a 4-wire SPI bus. First test: control the RGB LED color.
//   Later: control oscillator frequency, grain parameters, etc.
//
// SPI protocol:
//   Mode 0 (CPOL=0, CPHA=0): clock idle low, data sampled on rising edge
//   8-bit address + 8-bit data per transaction (16 clocks total)
//   MSB first
//   CS active low — one transaction per CS assertion
//
//   Write: ESP32 sends [ADDR][DATA], FPGA latches DATA into register[ADDR]
//   Read:  ESP32 sends [ADDR | 0x80][0x00], FPGA returns register[ADDR] on MISO
//          (bit 7 of address = read flag)
//
// Register map:
//   0x00: LED red   brightness (0-255, 0=off, 255=max)
//   0x01: LED green brightness
//   0x02: LED blue  brightness
//   0x03: Status register (read-only) — returns 0xA5 (magic byte, proves comms work)
//
// Wiring (PMOD 2 — directly to ESP32-S3 GPIOs):
//   SCK  ← ESP32 SPI clock    (pin 46, P2_1)
//   MOSI ← ESP32 SPI MOSI     (pin 44, P2_2)
//   MISO → ESP32 SPI MISO     (pin 42, P2_3)
//   CS   ← ESP32 SPI CS       (pin 37, P2_4)
//
// ESP32-S3 SPI setup (Arduino/ESP-IDF):
//   SPI.begin(SCK_PIN, MISO_PIN, MOSI_PIN, CS_PIN);
//   SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
//   digitalWrite(CS_PIN, LOW);
//   SPI.transfer(addr);
//   SPI.transfer(data);
//   digitalWrite(CS_PIN, HIGH);
//
// =============================================================================

module top (
    input  clk,        // 12 MHz clock
    input  spi_sck,    // SPI clock from ESP32
    input  spi_mosi,   // SPI data from ESP32
    output spi_miso,   // SPI data to ESP32
    input  spi_cs_n,   // SPI chip select (active low)
    output led_r,      // Red LED (active low, PWM)
    output led_g,      // Green LED (active low, PWM)
    output led_b       // Blue LED (active low, PWM)
);

    // =========================================================================
    // SPI input synchronization
    // =========================================================================
    //
    // The SPI signals come from the ESP32 (a different clock domain).
    // We synchronize them through 2-stage flip-flops to prevent metastability.
    //
    reg [1:0] sck_sync = 0;
    reg [1:0] mosi_sync = 0;
    reg [1:0] cs_sync = 2'b11;  // CS idle high

    always @(posedge clk) begin
        sck_sync  <= {sck_sync[0],  spi_sck};
        mosi_sync <= {mosi_sync[0], spi_mosi};
        cs_sync   <= {cs_sync[0],   spi_cs_n};
    end

    wire sck_synced  = sck_sync[1];
    wire mosi_synced = mosi_sync[1];
    wire cs_synced   = cs_sync[1];

    // Edge detection on SCK
    reg sck_prev = 0;
    always @(posedge clk) sck_prev <= sck_synced;
    wire sck_rise = ~sck_prev & sck_synced;
    wire sck_fall = sck_prev & ~sck_synced;

    // CS edge detection
    reg cs_prev = 1;
    always @(posedge clk) cs_prev <= cs_synced;
    wire cs_fall = cs_prev & ~cs_synced;   // start of transaction

    // =========================================================================
    // SPI shift register — receives 16 bits (8 addr + 8 data)
    // =========================================================================
    reg [3:0] bit_count = 0;
    reg [7:0] rx_addr = 0;
    reg [7:0] rx_data = 0;
    reg [7:0] tx_data = 0;
    reg addr_done = 0;
    reg data_done = 0;

    always @(posedge clk) begin
        data_done <= 0;

        if (cs_synced) begin
            // CS high — reset state
            bit_count <= 0;
            addr_done <= 0;
        end else begin
            if (sck_rise) begin
                if (!addr_done) begin
                    // Receiving address byte
                    rx_addr <= {rx_addr[6:0], mosi_synced};
                    if (bit_count == 7) begin
                        addr_done <= 1;
                        bit_count <= 0;
                    end else begin
                        bit_count <= bit_count + 1;
                    end
                end else begin
                    // Receiving data byte
                    rx_data <= {rx_data[6:0], mosi_synced};
                    if (bit_count == 7) begin
                        data_done <= 1;
                        bit_count <= 0;
                    end else begin
                        bit_count <= bit_count + 1;
                    end
                end
            end
        end
    end

    // =========================================================================
    // MISO output — send read data on falling edge of SCK
    // =========================================================================
    //
    // When address byte is complete and read bit (bit 7) is set,
    // load the register value and shift it out MSB first.
    //
    reg [7:0] miso_shift = 0;
    reg miso_bit = 0;

    always @(posedge clk) begin
        if (cs_synced) begin
            miso_bit <= 0;
        end else if (addr_done && bit_count == 0 && sck_fall) begin
            // First falling edge after address — load read data
            // Look up register based on address (without read bit)
            case (rx_addr[6:0])
                7'h00: miso_shift <= regs[0];
                7'h01: miso_shift <= regs[1];
                7'h02: miso_shift <= regs[2];
                7'h03: miso_shift <= 8'hA5;   // status magic byte
                default: miso_shift <= 8'h00;
            endcase
            miso_bit <= 1;
        end else if (sck_fall && addr_done) begin
            miso_shift <= {miso_shift[6:0], 1'b0};
        end
    end

    assign spi_miso = cs_synced ? 1'bz : miso_shift[7];

    // =========================================================================
    // Register file — writable by SPI
    // =========================================================================
    reg [7:0] regs [0:2];  // reg[0]=R, reg[1]=G, reg[2]=B

    initial begin
        regs[0] = 8'd0;
        regs[1] = 8'd0;
        regs[2] = 8'd0;
    end

    always @(posedge clk) begin
        if (data_done && !rx_addr[7]) begin
            // Write: addr bit 7 = 0
            case (rx_addr[6:0])
                7'h00: regs[0] <= rx_data;
                7'h01: regs[1] <= rx_data;
                7'h02: regs[2] <= rx_data;
            endcase
        end
    end

    // =========================================================================
    // PWM LED drivers — 8-bit PWM for each LED
    // =========================================================================
    reg [7:0] pwm_cnt = 0;
    always @(posedge clk) pwm_cnt <= pwm_cnt + 1;

    // Active low: LED on when pwm_cnt < brightness value
    assign led_r = ~(pwm_cnt < regs[0]);
    assign led_g = ~(pwm_cnt < regs[1]);
    assign led_b = ~(pwm_cnt < regs[2]);

endmodule
