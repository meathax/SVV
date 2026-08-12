# Project status

This is a human summary. Machine state lives in `.mister/state.json` and generated reports.

## Current objective

Correct hardware-reported ES5506 static/noise and Dyna Gear busy-scene black
bands, then close the retained HDMI setup miss without modifying MiSTer PLL/IP.

## Current workflow

| Field | Value |
|---|---|
| Action | Shared RTL correction and no-RBF regression |
| Scenario | Dyna Gear attract with real SDRAM controller; ES5506 host/engine collision matrix |
| Stage | Simulation complete; fresh Quartus/RBF and hardware retest pending |
| Last completed run | 120-frame real-controller Dyna Gear PASS: bg/obj overruns 0/0, cache aborts 0 |
| Last matching event/checkpoint | Declared 120-frame stop barrier reached |
| First mismatch/evidence gap | Corrected image has not been synthesized or loaded on MiSTer |
| RTL edits permitted | YES |
| Quartus state | Prior RBF inspected; no new Quartus stage authorized or run |
| Hardware state | Prior RBF reproduced audio/video symptoms; corrected RTL untested |

## Next valid action

Authorize `$mister-rbf-build`, prove the 2.0 Fast-Fit placement search closes
all timing corners, then load the fresh RBF and retest affected games plus
known-good Drift Out.

## Blocking evidence gaps

| ID | Gap | Why blocking | Smallest next experiment |
|---|---|---|---|
| HW-20260812-1 | Corrected RTL has no RBF/hardware result | Simulation cannot prove HDMI timing, physical audio, or busy-game display behavior | Build one fresh universal RBF, retain the prior rollback image, then test Dyna Gear and at least two affected audio titles plus Drift Out |
