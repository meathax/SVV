# Dyna Gear character-select stall

## Symptom

After COIN1, the game reached `SELECT PLAYER` but never entered the game.

## Deterministic reproduction

- ROM/config: `coin_start_p1` scenario, DSW1 `0xffff`, DSW2 `0xfffd`
- Harness: `verif/tb_ssv_frame_crc.sv`
- Pre-fix evidence: frame 380/765 retained the 836–839-pixel
  `SELECT PLAYER` header silhouette.
- Automated criterion: at frame 440, the header box must contain fewer than
  700 non-black pixels and the complete frame must contain more than 1,000.

## First divergence and root cause

MAME's Dyna Gear `:P1` port reports bits 7:0 as
`UP,DOWN,LEFT,RIGHT,B1,B2,B3,START`. `Arcade-SSV.sv` reversed the direction and
button groups, producing `START,B3,B2,B1,RIGHT,LEFT,DOWN,UP` instead.

Therefore the intended Start/B1 sequence drove Up/Right. Character selection
was never confirmed, even though the CPU, IRQs, and video kept running.

## Fix

`Arcade-SSV.sv` now maps MiSTer joystick bits to the MAME/board port order.
The scenario, full-core harness, and input-matrix expectations use the same
active-low values. `+REQUIRE_PLAY` permanently checks that the game reaches a
populated post-selection story/game frame.

## Verification

- `tb_ssv_input_matrix`: PASS
- 950-frame `coin_start_p1_gameplay`: PASS with `+REQUIRE_GAMEPLAY`
- Frame 850: `green=31553`, `nonblack=74917` (controllable jungle stage)
- Renderer assertions: zero background/object overruns; no cache overflow
- Focused bring-up suite: ALL PASS
- V60 suite: 28 passed, 0 failed (CPU source unchanged by this fix)
- ES5506 register/voice units and natural-IRQ real-ROM audio peak gate: PASS

The formerly separate cached-sprite issue is also closed in simulation. Dyna
Gear needs up to 86 descriptors on one observed scanline; the renderer now has
96 line slots, prefetches the following registered descriptor during the
current descriptor, and bypasses fully transparent rows. The 950-frame run is
assertion-clean through actual play.

Artifacts:

- Pre-fix: `sim_output/live_gameplay/coin_start_10s_f765_4x.png`
- Post-fix: `sim_output/diff/character_select_run2/frame_f440_4x.png`
- Deterministic CRC streams:
  `sim_output/diff/character_select_verify_{1,2,3}.crc`
- Final gameplay CRC stream:
  `sim_output/diff/rtl_final96_gameplay_frames.crc`
- Final gameplay image:
  `sim_output/diff/rtl_final96_gameplay_f0850.png`
