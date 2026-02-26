// =============================================================================
// Sine Tone + RGB Colour Wheel — IceSugar v1.5
// =============================================================================
//
// What this does:
//   Plays a smooth 440 Hz sine wave on the speaker AND smoothly fades the
//   RGB LED through the full colour wheel — both at the same time.
//
// Why this matters — FPGA parallelism:
//   On a microcontroller (Arduino, STM32, etc.) you'd need to interleave
//   these tasks in a main loop, carefully timing each one so neither starves.
//   On an FPGA, the sine generator and the LED controller are physically
//   separate circuits built from different logic gates. They run truly in
//   parallel — no scheduling, no interrupts, no "loop". Each clock edge
//   advances EVERY register in the design simultaneously.
//
//   This file contains two independent subsystems:
//     1. Audio: phase accumulator → sine LUT → PWM → speaker
//     2. LEDs:  hue counter → RGB calculator → PWM → LED pins
//
//   They share a single PWM counter (saves ~8 LUTs), but otherwise they
//   don't interact at all. The synthesiser places them as separate clusters
//   of logic on the chip. You could delete either section and the other
//   would keep working unchanged.
//
// Hardware:
//   - PMOD Audio v1.2 on PMOD header 3 (speaker on pin 32)
//   - Onboard RGB LED (R=pin 40, G=pin 41, B=pin 39, active low)
//
// =============================================================================

module top (
    input  clk,       // 12 MHz clock (pin 35, GBIN0)
    output speaker,   // PWM audio out (pin 32)
    output led_r,     // Red LED   — active low (pin 40)
    output led_g,     // Green LED — active low (pin 41)
    output led_b      // Blue LED  — active low (pin 39)
);

    // =========================================================================
    // Shared resource: 8-bit PWM counter
    // =========================================================================
    //
    // Both the audio output and the LED brightness control use PWM.
    // They can share the same free-running counter since they all need
    // the same time base. Each output just compares against a different
    // threshold value.
    //
    // PWM frequency = 12 MHz / 256 = 46,875 Hz
    //   - Audio: well above 20 kHz hearing limit, filtered by PMOD RC circuit
    //   - LEDs:  well above ~100 Hz flicker perception, looks smooth
    //
    reg [7:0] pwm_counter = 0;

    always @(posedge clk)
        pwm_counter <= pwm_counter + 1;

    // =========================================================================
    // SUBSYSTEM 1: Sine wave tone generator
    // =========================================================================
    //
    // This is identical to the standalone sine_tone example.
    // It runs completely independently of the LED logic below.
    //
    // Phase accumulator → sine LUT → PWM comparison → speaker pin
    //

    // --- Phase accumulator (sets the tone frequency) ---
    localparam [31:0] PHASE_STEP = 32'd157573;  // 440 Hz

    reg [31:0] phase = 0;

    always @(posedge clk)
        phase <= phase + PHASE_STEP;

    // --- Sine lookup table (256 entries, 8-bit) ---
    // Generated with: round(127.5 + 127.5 * sin(2 * pi * i / 256))
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

    // --- PWM comparison → speaker output ---
    assign speaker = (pwm_counter < sine_val);


    // =========================================================================
    // SUBSYSTEM 2: RGB colour wheel
    // =========================================================================
    //
    // Cycles through the HSV colour wheel at full saturation and brightness.
    // Hue is divided into 6 segments of 256 steps each (1536 steps total):
    //
    //   Segment 0: Red=255,   Green=rises, Blue=0       (red → yellow)
    //   Segment 1: Red=falls, Green=255,   Blue=0       (yellow → green)
    //   Segment 2: Red=0,     Green=255,   Blue=rises   (green → cyan)
    //   Segment 3: Red=0,     Green=falls, Blue=255     (cyan → blue)
    //   Segment 4: Red=rises, Green=0,     Blue=255     (blue → magenta)
    //   Segment 5: Red=255,   Green=0,     Blue=falls   (magenta → red)
    //
    // "rises" means 0→255 over 256 steps; "falls" means 255→0.
    //

    // --- Hue counter ---
    // A slow counter that advances the hue position.
    // We use a prescaler to control the cycle speed.
    //
    // Prescaler ticks:  12,000,000 / 4096 = 2929 hue steps per second
    // Full cycle:       1536 steps / 2929 = ~0.52 seconds per full rotation
    //
    // Increase the prescaler divisor (use more bits) to slow it down:
    //   [11:0] = 4096  → ~0.5 sec/cycle (fast, good for demo)
    //   [13:0] = 16384 → ~2 sec/cycle   (relaxed)
    //   [15:0] = 65536 → ~8 sec/cycle   (very slow fade)
    //
    reg [22:0] hue_prescaler = 0;
    reg [10:0] hue = 0;  // 0–1535 (6 segments × 256 steps)

    always @(posedge clk) begin
        hue_prescaler <= hue_prescaler + 1;
        if (hue_prescaler[13:0] == 0) begin  // ~2 sec per full cycle
            if (hue == 1535)
                hue <= 0;
            else
                hue <= hue + 1;
        end
    end

    // --- Hue → RGB conversion ---
    // Decode the hue counter into 8-bit brightness for each channel.
    //
    wire [2:0]  segment = hue[10:8];   // Which of the 6 segments (0-5)
    wire [7:0]  frac    = hue[7:0];    // Position within segment (0-255)
    wire [7:0]  rising  = frac;        // 0 → 255
    wire [7:0]  falling = 255 - frac;  // 255 → 0

    reg [7:0] r_brightness, g_brightness, b_brightness;

    always @(*) begin
        case (segment)
            //                     Red        Green      Blue
            3'd0: begin r_brightness = 255;     g_brightness = rising;  b_brightness = 0;       end  // red → yellow
            3'd1: begin r_brightness = falling; g_brightness = 255;     b_brightness = 0;       end  // yellow → green
            3'd2: begin r_brightness = 0;       g_brightness = 255;     b_brightness = rising;  end  // green → cyan
            3'd3: begin r_brightness = 0;       g_brightness = falling; b_brightness = 255;     end  // cyan → blue
            3'd4: begin r_brightness = rising;  g_brightness = 0;       b_brightness = 255;     end  // blue → magenta
            3'd5: begin r_brightness = 255;     g_brightness = 0;       b_brightness = falling; end  // magenta → red
            default: begin r_brightness = 0;    g_brightness = 0;       b_brightness = 0;       end
        endcase
    end

    // --- PWM comparison → LED outputs ---
    // Same PWM counter as the audio, but comparing against colour brightness.
    // LEDs are active low: invert so brightness=255 means LED fully on.
    //
    assign led_r = ~(pwm_counter < r_brightness);
    assign led_g = ~(pwm_counter < g_brightness);
    assign led_b = ~(pwm_counter < b_brightness);

endmodule
