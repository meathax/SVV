# Eight-set differential-readiness baseline — 2026-08-14

These SHA-256 values were captured before the readiness edits. The worktree was
already dirty; the hashes identify the exact user-owned RTL/optimization state
that this infrastructure change was layered onto.

| Input | Pre-readiness SHA-256 |
|---|---|
| `rtl/ssv_core.sv` | `376D41354C54CBFA781C35D4C1650702FCFD0036F77B4822C5EB6C5B336D56C9` |
| `rtl/cpu/v60/s32_v60.sv` | `5621804ACFEAE2831C6BFB2CB8AD327CF9E138F450ADEC344DA42254C6B362AC` |
| `verif/tb_ssv_frame_crc.sv` | `7740F3DBDC34166F2BA0ADA1737247AB94D7BAD7AFA664F39C2C0CF4128B0A44` |
| `verif/ssv_visual_sdl.cpp` | `F426DDC00E1A01E584F05875ADD524CC1E6615D00FC1A5E6944B37CF49908300` |
| `tools/build_ssv_visual.ps1` | `892A62A30FA5BC8045493064D6602B23145F3CA17E4A3E9E5196326D36086439` |
| `tools/run_ssv_lockstep.ps1` | `2FEFA1BFC03EED52E581B4382E248C71980E76EA0811EA61575E5BDC31B1F603` |
| `tools/mame-ssv-lockstep.lua` | `5DC9F52000D934317411927A6BC21101DECEC7BFF14417610F7265227AF1939E` |
| `tools/ssv_lockstep_preflight.py` | `4B632B7B7E481F31D1467BB7058E4DA124475773D4CBA16F14F16AEFB60C892` |
| `.mister/project.json` | `4AD515200EDADA81D89F067A7E6DA9CCE4FA8F84F2FECF7032ADD3BB4F251A98` |
| `core-debug.toml` | `28A4833113020D3E92853F35D96A6A7438FA499C7E06A21DA665B3B95D7BD4B5` |
| `docs/OBSERVABILITY.json` | `584FDB9CF511341007BD4A77F96304D6CCF941F10DBBC2F1A728A6C9870528D4` |

The existing V60 multiplier, EEPROM memory, address-width and renderer-mux
changes remain separate optimization work. This readiness implementation does
not claim their focused regressions, Quartus fit, timing closure or hardware
validation.
