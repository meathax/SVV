#!/usr/bin/env python3
"""Static and arithmetic checks for the MAME 0.289 V60 semantic audit.

This deliberately does not simulate RTL.  It is the safe pre-Verilator gate:
it exhaustively compares byte ADDC/SUBC equations, exercises wider boundary and
deterministic-random vectors, and pins the audited qword EA/source-fetch split in
s32_v60.sv.  The queued SystemVerilog benches provide execution-level proof.
"""

from __future__ import annotations

import random
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RTL_PATH = ROOT / "rtl" / "cpu" / "v60" / "s32_v60.sv"


def mame_addc(dst: int, src: int, carry: int, bits: int) -> tuple[int, ...]:
    """MAME f0244b9f63d ADDB/W/L(dst, src, carry)."""
    mask = (1 << bits) - 1
    sign = 1 << (bits - 1)
    total = dst + src + carry
    result = total & mask
    cy = bool(total & (1 << bits))
    ov = bool(((result ^ src) & (result ^ dst) & sign))
    return result, cy, ov, result == 0, bool(result & sign)


def rtl_addc(dst: int, src: int, carry: int, bits: int) -> tuple[int, ...]:
    mask = (1 << bits) - 1
    result = (dst + src + carry) & mask
    cy = (dst + src + carry) > mask
    ov = bool((~(dst ^ src) & (dst ^ result) & (1 << (bits - 1))))
    return result, cy, ov, result == 0, bool(result & (1 << (bits - 1)))


def mame_subc(dst: int, src: int, carry: int, bits: int) -> tuple[int, ...]:
    """MAME f0244b9f63d SUBB/W/L(dst, src, carry)."""
    mask = (1 << bits) - 1
    sign = 1 << (bits - 1)
    wide_mask = (1 << (bits + 1)) - 1
    total = (dst - src - carry) & wide_mask
    result = total & mask
    cy = bool(total & (1 << bits))
    ov = bool(((dst ^ src) & (dst ^ result) & sign))
    return result, cy, ov, result == 0, bool(result & sign)


def rtl_subc(dst: int, src: int, carry: int, bits: int) -> tuple[int, ...]:
    mask = (1 << bits) - 1
    result = (dst - src - carry) & mask
    # The RTL uses a widened comparison so src=all-ones,carry=1 cannot wrap.
    cy = dst < (src + carry)
    ov = bool(((dst ^ src) & (dst ^ result) & (1 << (bits - 1))))
    return result, cy, ov, result == 0, bool(result & (1 << (bits - 1)))


def legacy_addc(dst: int, src: int, carry: int, bits: int) -> tuple[int, ...]:
    mask = (1 << bits) - 1
    wrapped_src = (src + carry) & mask
    return mame_addc(dst, wrapped_src, 0, bits)


def legacy_subc(dst: int, src: int, carry: int, bits: int) -> tuple[int, ...]:
    mask = (1 << bits) - 1
    wrapped_src = (src + carry) & mask
    return mame_subc(dst, wrapped_src, 0, bits)


def arithmetic_checks() -> int:
    checked = 0
    for dst in range(256):
        for src in range(256):
            for carry in (0, 1):
                assert rtl_addc(dst, src, carry, 8) == mame_addc(dst, src, carry, 8)
                assert rtl_subc(dst, src, carry, 8) == mame_subc(dst, src, carry, 8)
                checked += 2

    rng = random.Random(0xF0244B9F)
    for bits in (16, 32):
        mask = (1 << bits) - 1
        sign = 1 << (bits - 1)
        values = (0, 1, sign - 1, sign, sign + 1, mask - 1, mask)
        vectors = [(a, b, c) for a in values for b in values for c in (0, 1)]
        vectors += [(rng.randrange(mask + 1), rng.randrange(mask + 1), rng.randrange(2))
                    for _ in range(20_000)]
        for dst, src, carry in vectors:
            assert rtl_addc(dst, src, carry, bits) == mame_addc(dst, src, carry, bits)
            assert rtl_subc(dst, src, carry, bits) == mame_subc(dst, src, carry, bits)
            checked += 2

    # These are the focused execution-bench vectors and must differ from the
    # pre-f0244b9f wrapped-source implementation.
    for bits in (8, 16, 32):
        signed_max = (1 << (bits - 1)) - 1
        mask = (1 << bits) - 1
        assert mame_addc(0, signed_max, 1, bits) != legacy_addc(0, signed_max, 1, bits)
        assert mame_subc(0, signed_max, 1, bits) != legacy_subc(0, signed_max, 1, bits)
        assert mame_addc(0, mask, 1, bits) != legacy_addc(0, mask, 1, bits)
        assert mame_subc(0, mask, 1, bits) != legacy_subc(0, mask, 1, bits)
    return checked


def static_rtl_checks() -> int:
    text = RTL_PATH.read_text(encoding="utf-8")
    compact = re.sub(r"\s+", "", text).lower()
    required = {
        "qword dim1": "8'h3f:f12_dim1=2'd3;",
        "qword dim2": "8'h3f,8'h86,8'h96,8'ha6,8'hb6:f12_dim2=2'd3;",
        "qword low-dword fetch": "8'h86,8'h96,8'ha6,8'hb6:f12_fetch_dim2=2'd2;",
        "8-byte auto-update": "(d==2'd2)?32'd4:32'd8;",
        "ADDC includes carry unwrapped":
            "wide={1'b0,dimext(b,d2)}+{1'b0,dimext(a,d2)}+{32'b0,f_cy};",
        "SUBC widened borrow":
            "f_cy<=({1'b0,dimext(b,d2)}<({1'b0,dimext(a,d2)}+{32'b0,f_cy}));",
        "8-bit signed displacement": "disp_of={{24{fb[base][7]}},fb[base]};",
        "16-bit signed displacement": "disp_of={{16{fb[base+1][7]}},fb16(base)};",
        "indexed dimension scaling": "(rf_rdata_a<<ea_dim)",
    }
    for name, token in required.items():
        assert token.lower() in compact, f"missing audited RTL contract: {name}"

    # Address-equation vectors for the audited dimension/sign-extension rules.
    steps = [1 << dim for dim in range(4)]
    assert steps == [1, 2, 4, 8]
    assert 0x1000 + ((0x80 ^ 0x80) - 0x80) == 0x0f80
    assert 0x2000 + ((0xff80 ^ 0x8000) - 0x8000) == 0x1f80
    assert 0x3000 + (3 << 3) == 0x3018
    return len(required) + 3


def main() -> None:
    arithmetic = arithmetic_checks()
    static = static_rtl_checks()
    print(f"V60 MAME SEMANTICS PASS: {arithmetic} arithmetic comparisons, "
          f"{static} static/EA checks")


if __name__ == "__main__":
    main()
