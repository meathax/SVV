// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-game configuration and tile-code wrapping.
//
// MAME wraps a sprite tile code with `code % gfxelement->elements()` -- a true
// MODULO, not a mask (src/mame/seta/ssv.cpp, ssv_v.cpp). elements() is the
// declared sprites region divided by 128, and for the nine target titles that
// is 0x18000, 0x20000, 0x30000 or 0x40000. Three of those are 3*2^k, so the
// core's original `wrap_code = code[16:0]` mask is wrong for them in both
// width and wrap rule.
//
// This bench checks ssv_pkg::wrap_code_cfg against a plain reference modulo,
// over a sweep that deliberately includes codes ABOVE elements() -- the only
// region where masking and modulo disagree, and therefore the only region that
// can catch the bug.
//
// Region sizes are quoted from MAME and were verified by reading
// ROM_REGION(..., "sprites") out of ssv.cpp directly.

`timescale 1ns/1ps

module tb_ssv_cfg;

import ssv_pkg::*;

int errors = 0;
int checked = 0;

typedef struct {
    string       name;
    int unsigned region;      // MAME sprites ROM_REGION size, bytes
    int unsigned elements;    // region / 128
    int unsigned k;
    bit          mul3;
} game_t;

// region/128 = tiles; k and mul3 decompose it as (mul3 ? 3<<k : 1<<k).
game_t games [0:8] = '{
    '{"ultrax",   32'h0C00000, 32'h18000, 15, 1'b1},
    '{"dynagear", 32'h1000000, 32'h20000, 17, 1'b0},
    '{"survarts", 32'h1800000, 32'h30000, 16, 1'b1},
    '{"twineag2", 32'h1800000, 32'h30000, 16, 1'b1},
    '{"stmblade", 32'h1800000, 32'h30000, 16, 1'b1},
    '{"cairblad", 32'h2000000, 32'h40000, 18, 1'b0},
    '{"drifto94", 32'h2000000, 32'h40000, 18, 1'b0},
    '{"vasara",   32'h2000000, 32'h40000, 18, 1'b0},
    '{"vasara2",  32'h2000000, 32'h40000, 18, 1'b0}
};

function automatic ssv_cfg_t cfg_for(input int unsigned k, input bit mul3);
    ssv_cfg_t c = cfg_dynagear();
    c.gfx_code_k    = 5'(k);
    c.gfx_code_mul3 = mul3;
    return c;
endfunction

task automatic check_one(input string name, input ssv_cfg_t c,
                         input int unsigned elements, input logic [19:0] code);
    logic [17:0] got;
    int unsigned want;
    begin
        got  = wrap_code_cfg(c, code);
        want = code % elements;
        checked++;
        if (got !== 18'(want)) begin
            errors++;
            if (errors < 12)
                $display("FAIL %-9s code=%05x got=%05x want=%05x (elements=%05x)",
                         name, code, got, want, elements);
        end
    end
endtask

initial begin
    // 1. Decomposition self-check: the table must actually describe the size.
    for (int g = 0; g < 9; g++) begin
        int unsigned m = games[g].mul3 ? (3 << games[g].k) : (1 << games[g].k);
        if (m != games[g].elements) begin
            errors++;
            $display("FAIL %s: (mul3?3:1)<<k = %0x but elements = %0x",
                     games[g].name, m, games[g].elements);
        end
        if (games[g].region / 128 != games[g].elements) begin
            errors++;
            $display("FAIL %s: region/128 = %0x but elements = %0x",
                     games[g].name, games[g].region / 128, games[g].elements);
        end
    end

    // 2. The modulo itself.
    for (int g = 0; g < 9; g++) begin
        ssv_cfg_t c = cfg_for(games[g].k, games[g].mul3);
        int unsigned e = games[g].elements;

        // Boundaries: last in range, first out of range, and the 2x/3x wraps.
        check_one(games[g].name, c, e, 20'd0);
        check_one(games[g].name, c, e, 20'(e - 1));
        check_one(games[g].name, c, e, 20'(e));
        check_one(games[g].name, c, e, 20'(e + 1));
        if (2*e < 32'h100000) check_one(games[g].name, c, e, 20'(2*e));
        if (2*e + 5 < 32'h100000) check_one(games[g].name, c, e, 20'(2*e + 5));

        // Sweep the whole 20-bit code space at a stride that is coprime with
        // the moduli, so it does not sit on a single residue class.
        for (int unsigned code = 0; code < 32'h100000; code += 1021)
            check_one(games[g].name, c, e, 20'(code));
    end

    // 3. Dyna Gear must be untouched: its modulus is 2^17, so the wrap is
    //    exactly the old mask and the generalisation cannot have moved it.
    begin
        ssv_cfg_t c = cfg_dynagear();
        for (int unsigned code = 0; code < 32'h100000; code += 337) begin
            if (wrap_code_cfg(c, 20'(code)) !== 18'(code[16:0])) begin
                errors++;
                if (errors < 12)
                    $display("FAIL dynagear regression code=%05x", code);
            end
            checked++;
        end
    end

    // 4. Prove this bench DISCRIMINATES. A test that passes against both the
    //    old behaviour and the new one is worthless, and CLAUDE.md requires a
    //    regression test to have been observed failing without the fix. Rather
    //    than rely on having run it at the right commit, show here that the
    //    superseded `code[16:0]` mask disagrees with the modulo on every
    //    non-power-of-two title -- so had the mask still been in place,
    //    section 2 above would have failed.
    for (int g = 0; g < 9; g++) begin
        int unsigned e = games[g].elements;
        int unsigned disagreements = 0;
        for (int unsigned code = 0; code < 32'h100000; code += 1021) begin
            logic [17:0] old_mask = 18'(code[16:0]);
            if (old_mask !== 18'(code % e)) disagreements++;
        end
        if (games[g].mul3 && disagreements == 0) begin
            errors++;
            $display("FAIL %s: old mask agrees with modulo everywhere -- this bench cannot detect the bug it exists for",
                     games[g].name);
        end
        if (!games[g].mul3 && games[g].k == 17 && disagreements != 0) begin
            errors++;
            $display("FAIL dynagear: old mask should be exactly equivalent");
        end
        $display("  %-9s elements=%05x old-mask disagreements=%0d",
                 games[g].name, e, disagreements);
    end

    $display("tb_ssv_cfg: %0d checks, %0d errors", checked, errors);
    if (errors != 0) $fatal(1, "FAIL tb_ssv_cfg");
    $display("PASS tb_ssv_cfg");
    $finish;
end

endmodule
