# Pre-RBF optimization notes (26 Jul 2026)

Last full fit before this pass: **99% ALMs**, **100% M10K**, voice setup
**−10.4 ns** on `clk_sys` (MCP-3). No RBF was built in this pass.

## Changes landed (sim-verified)

| Change | Why |
|---|---|
| Voice FSM `S_PROC → S_POLE12 → S_FILT → S_MIX` | Break ~72 ns filter/lerp chain for timing |
| `SSV.sdc` voice MCP scoped to CE regs only | Prior MCP covered SDRAM handshake regs (unsafe) |
| `ce_snd = ce_cpu` | Phase-align OTTO with V60; drop 2nd accumulator |
| Icache + scroll `ramstyle=MLAB` | Pull distributed RAM out of ALMs |
| Sprite `CACHE_ENTRIES` 2048→1536 | Free M10K (attract used ~1277) |
| QSF `BALANCED` + no reg duplication | Recover ALMs vs HIGH PERFORMANCE SPEED |
| `ENABLE_DIAG_VIDEO=0` | Strip diag raster for release candidate |
| ES5506 banks → `ssv_mlab32_sdp` (altsyncram MLAB) | Inference failed on array-in-always_ff; map rose to ~42.4k ALMs |

Gates re-run green: `run_audio_sims.sh` (regs/voice/realrom audio).

## Map-only history

| Build | Est. ALMs | Notes |
|---|---|---|
| Pre-regfile serialize | ~41,115 | Still fat; dual async reads |
| Host-steal single-port arrays | **42,381** | Worse — most banks `can't infer memory` |
| Explicit `ssv_mlab32_sdp` | **33,785** | −8.6k vs failed-infer map; regs ~21.2k |

## Next steps before building an RBF

1. ~~**Map-only after MLAB wrapper**~~ — done: **~33.8k ALMs** (~80% of 41.9k),
   all 20 voice banks via `altsyncram` MLAB. Fit is now worth trying.
2. **Full fit + STA** — voice slack ≥0 with narrowed MCP; re-check sprite
   cache→decode (`DYNAGEAR_FROZEN_VIDEO.md`). Still no RBF until Ready.
3. **`report-quartus.ps1 -RequireReady`** must be true before any deploy.
4. **Optional area:** prove unused V60 FP/bitstring/decimal via MAME opcode
   hit list, then parameter-gate; shrink `LINE_SLOTS` if overflow never trips.
5. **Sim residual (parallel):** attract CRC frame≥1 / IRQ period skew — not an
   RBF blocker for silent attract smoke, but needed for CRC-closed release.
   See `docs/issues/DYNAGEAR_ATTRACT_FRAME_CRC.md`.

## Explicit non-goals until ReadyToDeploy

- Deploying a timing-failing or stale RBF
- Inventing ES5506→`ssv_irq` wiring for Dyna Gear
- Growing BRAM (M10K is exhausted)
