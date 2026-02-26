// =============================================================================
// Sine Wave Tone — IceSugar v1.5 + MuseLab PMOD Audio v1.2
// =============================================================================
//
// What this does:
//   Plays a smooth 440 Hz sine wave on the speaker, instead of the harsh
//   square wave from the basic tone example. The red LED brightness tracks
//   the sine wave as a visual indicator.
//
// How it works — three stages:
//
//   1. PHASE ACCUMULATOR — determines the frequency
//      A 32-bit counter incremented by a fixed step every clock tick.
//      It wraps around naturally (like an odometer rolling over).
//      The top 8 bits index into the sine table — as the accumulator
//      wraps, it sweeps through one full cycle of the sine wave.
//
//      Frequency formula:
//        step = 2^32 × tone_freq / clock_freq
//             = 4,294,967,296 × 440 / 12,000,000
//             ≈ 157,573
//
//      To change pitch, just change PHASE_STEP. Examples:
//        Middle C  (261.63 Hz): step = 93,663
//        A4        (440.00 Hz): step = 157,573
//        C5        (523.25 Hz): step = 187,388
//
//   2. SINE LOOKUP TABLE — converts phase to amplitude
//      A 256-entry ROM storing one full cycle of a sine wave, scaled to
//      unsigned 8-bit values (0–255). Value 128 = zero crossing,
//      255 = positive peak, 0 = negative peak.
//
//      The table is generated from: round(127.5 + 127.5 × sin(2π × i/256))
//
//   3. PWM OUTPUT — converts amplitude to analog via duty cycle
//      An 8-bit counter free-runs at 12 MHz / 256 = 46,875 Hz.
//      The output pin is HIGH when the counter is less than the sine value.
//      Higher sine value → longer HIGH time → higher average voltage.
//      The PMOD Audio's onboard RC filter smooths the PWM into an analog
//      signal that the amplifier drives to the speaker.
//
//      46.875 kHz PWM is well above the ~20 kHz human hearing limit,
//      so you hear the 440 Hz sine wave, not the PWM switching.
//
// Hardware:
//   PMOD Audio v1.2 plugged into PMOD header 3.
//   Speaker output on FPGA pin 32 (PMOD 3, P3_12).
//
// =============================================================================

module top (
    input  clk,       // 12 MHz clock (pin 35, GBIN0)
    output speaker,   // PWM audio out to PMOD Audio v1.2 (pin 32)
    output led_r      // Red LED — brightness tracks sine wave (pin 40)
);

    // =========================================================================
    // Stage 1: Phase accumulator
    // =========================================================================
    //
    // Think of this as a very precise "position" in the sine wave cycle.
    // The top 8 bits (phase[31:24]) select which of the 256 sine table
    // entries we read. The lower 24 bits provide fractional precision,
    // allowing fine frequency control.
    //
    // With a 32-bit accumulator and 12 MHz clock, the frequency resolution
    // is: 12,000,000 / 2^32 ≈ 0.0028 Hz — extremely fine.
    //
    localparam [31:0] PHASE_STEP = 32'd157573;  // 440 Hz

    reg [31:0] phase = 0;

    always @(posedge clk)
        phase <= phase + PHASE_STEP;

    // =========================================================================
    // Stage 2: Sine lookup table (256 entries × 8 bits)
    // =========================================================================
    //
    // One full cycle of sin(), scaled to unsigned 8-bit:
    //   - 128 = zero crossing (mid-point)
    //   - 255 = positive peak
    //   -   0 = negative peak
    //
    // The synthesiser implements this as combinational logic (LUTs).
    // On the iCE40UP5K this uses about 60 LUTs out of 5280 available.
    //
    // Generated with: round(127.5 + 127.5 * sin(2 * pi * i / 256))
    //
    reg [7:0] sine_val;

    always @(*) begin
        case (phase[31:24])
            //       index 0 = 0°          index 64 = 90° (peak)
            //       index 128 = 180°      index 192 = 270° (trough)
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

    // =========================================================================
    // Stage 3: PWM output
    // =========================================================================
    //
    // An 8-bit counter free-runs from 0 to 255, wrapping every 256 clocks.
    // PWM frequency = 12,000,000 / 256 = 46,875 Hz (inaudible).
    //
    // The output is HIGH when pwm_counter < sine_val.
    // So sine_val = 200 means the output is HIGH for 200/256 = 78% of the time.
    //
    // The PMOD Audio's RC low-pass filter averages this into a proportional
    // analogue voltage. As sine_val smoothly rises and falls through the
    // sine table, the speaker traces out a smooth sine wave.
    //
    reg [7:0] pwm_counter = 0;

    always @(posedge clk)
        pwm_counter <= pwm_counter + 1;

    assign speaker = (pwm_counter < sine_val);

    // =========================================================================
    // LED — brightness follows the sine wave
    // =========================================================================
    //
    // Reuse the same PWM technique to dim the red LED in sync with the audio.
    // When the sine is at its peak (255), the LED is brightest.
    // When the sine crosses zero (128), the LED is at half brightness.
    // At the trough (0), the LED is off.
    //
    // At 440 Hz this is too fast to see individual cycles — you'll see a
    // steady glow at roughly half brightness, proving the PWM is working.
    //
    // The LED is active low, so we invert: LED on when pwm_counter >= sine_val.
    //
    assign led_r = (pwm_counter >= sine_val);

endmodule
