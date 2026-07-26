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
| `ENABLE_DIAG_VIDEO` localparam | Set `0` before release RBF to strip diag raster |

Gates re-run green: `run_audio_sims.sh`, `run_bringup_sims.sh`, Wave C frame 0.

## Next steps before building an RBF

1. **Map-only Quartus** (`tools/build-ssv.ps1 -MapOnly`) — confirm ALM estimate
   drops below ~90% and M10K ≤552. Do not fit/assemble yet if map is still ≥97%.
2. **ES5506 regfile single-port / true MLAB** (`rtl/audio/ssv_es5506_regs.sv`) —
   host+eng dual async reads currently duplicate MLABs as logic (~2–4k ALMs).
   Serialize or register one port.
3. **Full fit + STA** — require voice slack ≥0 with the narrowed MCP; re-check
   sprite cache→decode path (`DYNAGEAR_FROZEN_VIDEO.md`).
4. **Set `ENABLE_DIAG_VIDEO=0`** for the candidate bitstream.
5. **`report-quartus.ps1 -RequireReady`** must be true before any deploy.
6. **Optional area:** prove unused V60 FP/bitstring/decimal via MAME opcode
   hit list, then parameter-gate; shrink `LINE_SLOTS` if overflow never trips.
7. **Sim residual (parallel):** attract CRC frame≥1 / IRQ period skew — not an
   RBF blocker for silent attract smoke, but needed for CRC-closed release.

## Explicit non-goals until ReadyToDeploy

- Deploying a timing-failing or stale RBF
- Inventing ES5506→`ssv_irq` wiring for Dyna Gear
- Growing BRAM (M10K is exhausted)
