# buttons — directional LED control

A single LED moves across the 8-LED bar when you press the directional buttons.
Holding a button moves exactly one step; you have to release and press again to move again.

## Button mapping

| Button      | Action                                   |
|-------------|------------------------------------------|
| UP / RIGHT  | Shift lit LED one position toward LED[7] |
| DOWN / LEFT | Shift lit LED one position toward LED[0] |
| FIRE1       | Toggle all LEDs on/off                   |
| FIRE2       | Reset — single LED back at LED[0]        |

Movement wraps around at both ends (LED[7] -> LED[0] and vice versa).

## Key concepts

- **2-FF synchronisers** — each button passes through two flip-flops in series before use,
  reducing the probability of metastability to negligible levels at 25 MHz.
- **Rising-edge detection** — comparing the synchronised signal to its value one clock cycle
  ago gives a single-cycle pulse on press, so holding a button does not repeat.
- **One-hot encoding** — the active LED is represented as `1 << pos` (a single bit set),
  decoded directly from a 3-bit position register.
- **Registered outputs** — `led` is driven from a flip-flop, eliminating glitches.

## Build and flash

```bash
cd ulx3s
make -C examples/buttons
./flash.sh build/buttons/top.bit
```

Build output: `ulx3s/build/buttons/top.bit`
