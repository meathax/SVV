# Issue contract: Dyna Gear frozen/corrupt MiSTer video

## Issue

The current Dyna Gear core loads on the physical MiSTer but displays a mostly
black static frame with sparse corrupt grey/coloured graphics near the upper
left. Two framebuffer captures taken seconds apart were byte-identical.

## Deterministic scenario

- Set: `dynagear`
- MRA: `Dyna Gear.mra`
- MRA SHA-256:
  `73958e5a9f6dee5f29f0559d3f05ea71c0fb3cf8ff339daffe0ac05ec3195cf3`
- MiSTer: `192.168.0.69`
- Installed core observed: `SSV_20260724`
- Deployed RBF SHA-256:
  `43595e016efd46968207104ed36368f1f0586f99068356f0bd95ad63a7cf8064`
- MAME reference: 0.288 (`mame0288`)
- Local ROM archive SHA-256:
  `e0088d91679feaff026de267919700c86243c3823f5a1fb55894e1dbc4f7109d`
- Extracted main CPU image SHA-256:
  `c29d3bf37b761aad1f13b01be7da9904c0a975826744b820fdc664c098c66289`
- Extracted sprite image SHA-256:
  `5738ad3ac51f70d20702b564169b5516eb475b55af9a656181770461e86eab4f`
- Inputs: none; cold-load the MRA and observe attract boot.
- Stop: first stable attract frame or ten seconds after load.

## Current evidence

- Verilator PC and full V60 state match MAME through 1,072,678 available RTL
  retirements.
- 549,383 ordered accepted RTL writes match MAME.
- The 60-million-cycle real-ROM video test passes with 707,008 graphics reads
  and 118,457 nonblack pixels.
- The deployed RBF fails timing with worst setup slack of -1.284 ns.
- Its worst path is the sprite descriptor-cache M10K output to coordinate
  logic in `rtl/video/ssv_cached_sprite_renderer.sv`.
- A decode pipeline stage was added and passes the focused sprite test and the
  60-million-cycle real-ROM test.
- A fresh Quartus 17.1 fit then crashed in `quartus_fit.exe` during register
  packing. Timing improvement is therefore not yet measured.

## Last matching event

Not yet established at the frame/scanline level. The architectural trace
matches through the retirement and ordered-write counts above.

## First divergence

Unknown. The timing failure is a proven release blocker but is not yet proven
to cause the frozen image.

## Root-cause hypothesis

Suspect: the deployed timing-failing RBF violates the descriptor-cache to
coordinate path and corrupts or stalls sprite rendering. This predicts that a
timing-qualified pipelined build will change or eliminate the static corrupt
frame without changing architectural traces.

Status: `suspect`; evidence tier: `UNKNOWN`.

## Required next evidence

1. Complete a fresh Quartus fit and pass
   `tools/report-quartus.ps1 -RequireReady`.
2. Deploy the exact hashed candidate and recapture at deterministic landmarks.
3. If the symptom remains, add per-frame and per-layer/scanline hashes to MAME
   and RTL and locate the first differing frame and scanline.
4. Compare sprite descriptors, palette state, graphics fetches, and final
   pixels at that boundary.
5. Generate a narrow GTKWave capture only around the proven RTL divergence.

## Exit gate

Close only after the hardware symptom is reproducible, last-match and
first-divergence points are documented, a focused regression fails before and
passes after the correction, fresh MAME/RTL comparison passes, Quartus timing
is ready, and the hashed RBF reaches correct stable attract video on MiSTer.
