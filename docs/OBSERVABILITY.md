# MAME ↔ RTL observability contract

The authoritative machine contract is `OBSERVABILITY.json`. This document explains and justifies it.

A domain is not strict merely because both sides emit similarly named fields.

## Anchors

| Anchor | MAME definition | RTL definition | Equivalence evidence | Status |
|---|---|---|---|---|
| reset_assert |  |  |  | UNPROVEN |
| reset_release |  |  |  | UNPROVEN |
| first_fetch |  |  |  | UNPROVEN |
| frame_boundary |  |  |  | UNPROVEN |

## Domain map

| Domain | Purpose | MAME capture point | RTL capture point | Phase | Ordering | Strict? |
|---|---|---|---|---|---|---|
| mainbus | CPU-visible transactions |  |  | completed | domain seq | NO |

## Per-domain proof checklist

For every strict domain document:

- source and canonical address units;
- native width on each side;
- endian interpretation;
- lane zero meaning and lane-to-canonical mapping;
- byte-enable/mask polarity;
- behavior when no mask is exposed;
- request/accepted/completed/sampled/retired phase;
- waits/retries/deduplication policy;
- domain-local sequence origin;
- cross-domain relation, if any;
- unknown/open-bus representation;
- side effects of observation;
- trace loss/truncation checks.

## Event-field mapping

| Canonical field | MAME source/expression | RTL signal/expression | Transform | Evidence |
|---|---|---|---|---|
| address |  |  |  |  |
| data |  |  |  |  |
| byte_enable |  |  |  |  |
| rw |  |  |  |  |
| phase |  |  |  |  |

Optional fields such as PC, IRQ, scanline, hpos, wait, ack, bank or chip-select are compared only when their sampling boundary is equivalent.

## Input timebase

| Scenario | Timebase | MAME mapping | RTL mapping | Proven? |
|---|---|---|---|---|
| boot | canonical event |  |  | NO |

Do not use native MAME cycles and RTL cycles as though they were the same unit.

## Discovery versus golden capture

Discovery tools may omit lanes, deduplicate events or expose only a low byte. Mark such traces `diagnostic`. Golden captures must be lossless for all strict fields and detect dropped/duplicate records.

## Current gaps

| Gap | Consequence | Next experiment |
|---|---|---|
|  |  |  |
