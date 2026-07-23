# MAME reference notes: Dyna Gear

Reference files:

- `src/mame/seta/ssv.cpp`
- `src/mame/seta/ssv.h`
- `src/mame/seta/ssv_v.cpp`

## Board clocks and raster

- V60 and ES5506: 48 MHz / 3 = 16 MHz.
- Pixel clock: 42.954545 MHz / 6 = 7.1590908 MHz.
- Raster: 454 total pixels, 336 active; 262 total lines, 240 active.
- Dyna Gear visible area is 336 by 240.
- Vblank requests interrupt source 3 at scanline 240.

## Dyna Gear CPU map

| Address | Size | Function |
|---|---:|---|
| `000000-00ffff` | 64 KiB | work RAM |
| `100000-13ffff` | 256 KiB | sprite/list RAM |
| `140000-15ffff` | 128 KiB | palette RAM |
| `160000-17ffff` | 128 KiB | unknown RAM |
| `1c0000-1c007f` | 128 B | scroll/CRT registers |
| `210000-210011` | | watchdog, DIP, player and system I/O |
| `230000-230071` | | interrupt vectors |
| `240000-240071` | | interrupt acknowledge |
| `260000-260001` | | interrupt enable |
| `300000-30007f` | | ES5506 registers on low byte |
| `400000-43ffff` | 256 KiB | Dyna Gear extra RAM |
| `500008-500009` | | extra buttons |
| `f00000-ffffff` | 1 MiB | V60 program ROM |

The V60 reset PC is `fffffff0`; its 24-bit external address reaches the reset
stub at ROM offset `0xffff0`.

## ROM regions

- Program: two 512 KiB byte ROMs interleaved to one 1 MiB little-endian image.
- Sprites: six 2 MiB linear ROMs, 12 MiB total.
- ES5506 region 2: four 1 MiB word-swapped ROMs, 4 MiB total.

## IRQ behavior

`requested & enabled` asserts the V60 IRQ input. During interrupt acknowledge,
the lowest numbered requested source selects its programmed three-bit vector.
Writing the corresponding window at `0x240000 + level*0x10` clears the source.
