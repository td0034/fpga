// =============================================================================
// UART Hello World — IceSugar v1.5
// =============================================================================
//
// What this does:
//   Sends "Hello from iCE40!\r\n" over the USB serial port once per second.
//   Open a serial terminal (PuTTY, minicom, etc.) at 115200 baud 8N1 to see it.
//   The green LED toggles each time a message is sent.
//
// How UART works:
//   UART (Universal Asynchronous Receiver/Transmitter) is the simplest serial
//   protocol. The line idles HIGH. To send a byte:
//
//     1. Pull the line LOW for one bit period        (start bit)
//     2. Send 8 data bits, least significant first   (data bits)
//     3. Return the line HIGH for one bit period      (stop bit)
//
//   Both sides agree on a baud rate (bits per second). At 115200 baud,
//   each bit lasts 1/115200 ≈ 8.68 µs.
//
//   In clock ticks: 12,000,000 / 115200 ≈ 104 ticks per bit.
//
// Hardware:
//   The IceSugar's iCELink debugger bridges FPGA UART to a USB CDC serial
//   port. On the host it appears as a COM port (Windows) or /dev/ttyACMx
//   (Linux). TX = pin 6 (FPGA → PC), RX = pin 4 (PC → FPGA).
//
// =============================================================================

module top (
    input  clk,       // 12 MHz clock (pin 35, GBIN0)
    output uart_tx,   // UART transmit to PC (pin 6)
    output led_g      // Green LED — toggles per message (pin 41)
);

    // =========================================================================
    // UART transmitter
    // =========================================================================
    //
    // Baud rate calculation:
    //   CLKS_PER_BIT = 12,000,000 / 115,200 = 104.17 → 104
    //   This gives an actual baud rate of 12,000,000 / 104 = 115,385
    //   That's 0.16% off — well within UART's ±2% tolerance.
    //
    localparam CLKS_PER_BIT = 104;

    // Bit counter: each UART frame is 10 bits (1 start + 8 data + 1 stop).
    // We use a shift register to serialize the bits.
    reg [3:0]  bit_idx = 0;      // Which bit we're sending (0-9)
    reg [6:0]  baud_cnt = 0;     // Counts clock ticks per bit period
    reg [9:0]  shift_reg = 10'h3FF; // Shift register — idles all 1s (line HIGH)
    reg        tx_busy = 0;      // High while a byte is being sent

    // The actual TX output comes from the bottom bit of the shift register.
    // When idle, shift_reg is all 1s, so the line stays HIGH.
    assign uart_tx = shift_reg[0];

    // tx_start and tx_data are driven by the message sequencer below.
    reg       tx_start = 0;
    reg [7:0] tx_data = 0;

    always @(posedge clk) begin
        if (tx_busy) begin
            // Currently sending a byte — count ticks per bit
            if (baud_cnt == CLKS_PER_BIT - 1) begin
                baud_cnt <= 0;
                // Shift right: the next bit moves into position [0]
                shift_reg <= {1'b1, shift_reg[9:1]};
                if (bit_idx == 9) begin
                    // All 10 bits sent (start + 8 data + stop)
                    tx_busy <= 0;
                end else begin
                    bit_idx <= bit_idx + 1;
                end
            end else begin
                baud_cnt <= baud_cnt + 1;
            end
        end else if (tx_start) begin
            // Load a new byte into the shift register:
            //   bit[0]   = 0         (start bit — pulls line LOW)
            //   bit[8:1] = data      (8 data bits, LSB first)
            //   bit[9]   = 1         (stop bit — returns line HIGH)
            shift_reg <= {1'b1, tx_data, 1'b0};
            bit_idx <= 0;
            baud_cnt <= 0;
            tx_busy <= 1;
        end
    end

    // =========================================================================
    // Message ROM — the string to send
    // =========================================================================
    //
    // Stores "Hello from iCE40!\r\n" as a sequence of ASCII bytes.
    // A case statement acts as a small ROM — the synthesiser turns this into
    // lookup logic (LUTs), not block RAM, since it's so small.
    //
    localparam MSG_LEN = 20;

    reg [7:0] msg_char;
    reg [4:0] msg_idx = 0;

    always @(*) begin
        case (msg_idx)
            0:  msg_char = "H";
            1:  msg_char = "e";
            2:  msg_char = "l";
            3:  msg_char = "l";
            4:  msg_char = "o";
            5:  msg_char = " ";
            6:  msg_char = "f";
            7:  msg_char = "r";
            8:  msg_char = "o";
            9:  msg_char = "m";
            10: msg_char = " ";
            11: msg_char = "i";
            12: msg_char = "C";
            13: msg_char = "E";
            14: msg_char = "4";
            15: msg_char = "0";
            16: msg_char = "!";
            17: msg_char = " ";
            18: msg_char = 8'h0D;  // \r (carriage return)
            19: msg_char = 8'h0A;  // \n (line feed)
            default: msg_char = 0;
        endcase
    end

    // =========================================================================
    // Message sequencer — sends the string once per second
    // =========================================================================
    //
    // State machine with three states:
    //   IDLE    — wait for the delay timer, then start sending
    //   SEND    — load the next character into the UART TX
    //   WAIT_TX — wait for the UART TX to finish before sending the next char
    //
    localparam IDLE    = 2'd0;
    localparam SEND    = 2'd1;
    localparam WAIT_TX = 2'd2;

    reg [1:0]  state = IDLE;

    // Delay counter: 12,000,000 ticks = 1 second between messages.
    reg [23:0] delay_cnt = 0;

    // LED toggles each time we send a message
    reg led = 1;
    assign led_g = led;

    always @(posedge clk) begin
        tx_start <= 0;  // Default: don't start a new byte

        case (state)
            IDLE: begin
                if (delay_cnt == 12_000_000 - 1) begin
                    delay_cnt <= 0;
                    msg_idx <= 0;
                    state <= SEND;
                    led <= ~led;   // Toggle LED
                end else begin
                    delay_cnt <= delay_cnt + 1;
                end
            end

            SEND: begin
                // Load the current character and trigger the UART
                tx_data <= msg_char;
                tx_start <= 1;
                state <= WAIT_TX;
            end

            WAIT_TX: begin
                // Wait for UART to finish sending this byte
                if (!tx_busy && !tx_start) begin
                    if (msg_idx == MSG_LEN - 1) begin
                        // Whole message sent — go back to idle
                        state <= IDLE;
                    end else begin
                        // Advance to next character
                        msg_idx <= msg_idx + 1;
                        state <= SEND;
                    end
                end
            end

            default: state <= IDLE;
        endcase
    end

endmodule
