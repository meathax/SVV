# SSV accuracy reference profile

## Attainable accuracy contract

Physical PCB measurements are unavailable for this project and are not expected
to become available.  The core therefore uses the following evidence order for
all remaining implementation decisions:

1. published NEC, Ensoniq, and other original component documentation;
2. already-recorded legible PCB photographs and manufacturer markings;
3. pinned MAME 0.289 source and deterministic observed behavior;
4. independently verified implementations of the identical device;
5. an explicit deterministic project assumption.

The resulting target is called the **MAME 0.289 behavioral-reference profile**.
Passing this profile means that the universal RTL implements the selected MAME
contract, except where a higher-authority source justifies a recorded exception.
It must not be described as measured PCB-cycle accuracy.

## Higher-authority and deterministic exceptions

- ES5506 interpolation retains the documented nine fractional bits rather than
  copying a conflicting MAME implementation detail.
- V60 `SCLFS` uses deterministic NEC-manual behavior where MAME relies on C++
  undefined behavior.
- ST010 DP behavior remains pinned to the current compatibility policy until a
  primary source proves a correction.

## Permanent evidence limits

Unless new primary documentation is found, the following cannot be proven
against physical hardware:

- exact HSYNC/VSYNC pulse placement and polarity;
- the V60 three-versus-four-clock bus-cycle selection and READY timing;
- ES5506 clock division, voice-slot cadence, and sample-fetch bus timing;
- palette upper-byte storage/readback;
- priority word bit `4.h`;
- the sprite-list latch or buffering epoch;
- Eagle Shot coordinate wiring and display offsets;
- SRMP7 IRQV/level-5 behavior;
- ST0020 status and double-buffer details;
- GDFS ADC clock and Sexy Reaction conversion timing.

For these cases the RTL may implement pinned MAME behavior as a deterministic
compatibility profile, but source comments, tests, and documentation must label
that choice `MAME ASSUMPTION` rather than hardware fact.

## Input-port correction

MAME maps `$500008` to Survival Arts `ADD_BUTTONS`, the extra buttons used by
its six-button control layout.  It is not evidence for a third/fourth-player
port.  Dyna Gear leaves those bits unused/fixed.  The photographed P3/P4
connectors remain physically real but logically unmapped; without new evidence
the core must not assign them to `$500008` or any other CPU address.

## Completion language

Reports must distinguish:

- **source-integrated** — behavior exists in the universal descriptor/RTL path;
- **static-checked** — generators, manifests, syntax, and structural checks pass;
- **behaviorally verified** — an executable focused or full-system test passes;
- **MAME-profile matched** — the pinned normalized comparison passes;
- **timing-clean** — a current Quartus fit passes all timing gates;
- **hardware-tested** — a named RBF was exercised on MiSTer or original PCB.

Under the current no-Verilator, no-Quartus, and no-PCB constraint, work may only
claim the first two levels plus any non-Verilator executable checks that were
actually run.  The unavailable gates remain explicit rather than being waived.
