// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-game configuration and tile-code wrapping.
//
// MAME wraps a sprite tile code with `code % gfxelement->elements()` -- a true
// MODULO, not a mask (src/mame/seta/ssv.cpp, ssv_v.cpp). elements() is the
// declared sprites region divided by 128, and for the ten manifest entries that
// is 0x18000, 0x20000, 0x30000 or 0x40000. Two of those are 3*2^k, so the
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
    int unsigned factor;
    bit          mul3;
} game_t;

// Every graphics size in the authoritative supported-set manifest. Unqualified
// MAME geometries are intentionally not accepted by this release-profile test.
// region/128 = odd_factor << k.
game_t games [0:3] = '{
    '{"12 MiB", 32'h0C00000, 32'h18000, 15, 3, 1'b1},
    '{"16 MiB", 32'h1000000, 32'h20000, 17, 1, 1'b0},
    '{"24 MiB", 32'h1800000, 32'h30000, 16, 3, 1'b1},
    '{"32 MiB", 32'h2000000, 32'h40000, 18, 1, 1'b0}
};

function automatic ssv_cfg_t cfg_for(input int unsigned k, input bit mul3);
    ssv_cfg_t c = cfg_dynagear();
    c.gfx_code_k    = 5'(k);
    c.gfx_code_mul3 = mul3;
    // gfx_code_mask is DERIVED from k and must move with it. Leaving it at
    // cfg_dynagear()'s k=17 value while sweeping k made 3615 of these checks
    // fail -- which is the bench doing its job, since a real cfg block that
    // disagreed with its own k would corrupt every tile address.
    c.gfx_code_mask = (20'd1 << k) - 20'd1;
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
    for (int g = 0; g < 4; g++) begin
        int unsigned m;
        m = games[g].factor << games[g].k;
        if (m != games[g].elements) begin
            errors++;
            $display("FAIL %s: factor<<k = %0x but elements = %0x",
                     games[g].name, m, games[g].elements);
        end
        if (games[g].region / 128 != games[g].elements) begin
            errors++;
            $display("FAIL %s: region/128 = %0x but elements = %0x",
                     games[g].name, games[g].region / 128, games[g].elements);
        end
    end

    // 2. The modulo itself.
    for (int g = 0; g < 4; g++) begin
        ssv_cfg_t c;
        int unsigned e;
        c = cfg_for(games[g].k, games[g].mul3);
        e = games[g].elements;

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
        ssv_cfg_t c;
        c = cfg_dynagear();
        for (int unsigned code = 0; code < 32'h100000; code += 337) begin
            if (wrap_code_cfg(c, 20'(code)) !== 18'(code[16:0])) begin
                errors++;
                if (errors < 12)
                    $display("FAIL dynagear regression code=%05x", code);
            end
            checked++;
        end
    end

    // 4. The raster-status read is a MAME-visible part of the shared map.
    // Cairblad polls this register during boot; its exact bit positions are
    // not the same as the compact internal timing signals.
    if (ssv_video_status(1'b0, 1'b0) !== 16'h0000 ||
        ssv_video_status(1'b0, 1'b1) !== 16'h0800 ||
        ssv_video_status(1'b1, 1'b0) !== 16'h3000 ||
        ssv_video_status(1'b1, 1'b1) !== 16'h3800) begin
        errors++;
        $display("FAIL raster status encoding");
    end
    checked += 4;

    // 5. The optional extra-button window remains descriptor-selected rather
    // than being a global address alias. Supported profiles expose either the
    // Dyna decoded-idle port or no window at all.
    begin
        if (extra_input_window_cfg(cfg_dynagear(), 24'h500008) !== 1'b1 ||
            cfg_dynagear().extra_input_mode !== 2'd1 ||
            extra_input_window_cfg(cfg_dynagear(), 24'h50000a) !== 1'b0 ||
            extra_input_window_cfg(cfg_cairblad(), 24'h500008) !== 1'b0 ||
            extra_input_window_cfg(cfg_vasara(), 24'h500009) !== 1'b0) begin
            errors++;
            $display("FAIL descriptor-gated extra-input window");
        end
        checked += 5;
    end

    // 6. The MAME map-specific extra CPU RAM windows are descriptor data:
    // Dyna uses $400000, Twin Eagle/Ultra X use $010000, and the remaining
    // supported maps do not expose backing RAM in either location.
    begin
        if (cfg_dynagear().extra_ram_mode !== 2'd1 ||
            cfg_cairblad().extra_ram_mode !== 2'd0 ||
            cfg_vasara().extra_ram_mode !== 2'd0 ||
            cfg_drifto94().extra_ram_mode !== 2'd0 ||
            cfg_stmblade().extra_ram_mode !== 2'd0 ||
            cfg_twineag2().extra_ram_mode !== 2'd2 ||
            cfg_ultrax().extra_ram_mode !== 2'd2) begin
            errors++;
            $display("FAIL descriptor extra CPU RAM mode");
        end
        checked += 7;
    end

    // 7. Drift Out/Storm Blade expose MAME's random-read test windows at
    // $510000/$520000; the other universal descriptors must not alias them.
    begin
        if (cfg_dynagear().has_drifto_unknown !== 1'b0 ||
            cfg_cairblad().has_drifto_unknown !== 1'b0 ||
            cfg_drifto94().has_drifto_unknown !== 1'b1 ||
            cfg_stmblade().has_drifto_unknown !== 1'b1 ||
            cfg_twineag2().has_drifto_unknown !== 1'b0 ||
            cfg_ultrax().has_drifto_unknown !== 1'b0) begin
            errors++;
            $display("FAIL descriptor Drift Out random-read windows");
        end
        checked += 6;
    end

    // 8. NVRAM window size is also descriptor-selected: Cairblad has 64 KiB,
    // Drift Out/STM Blade have 2 KiB, and the other qualified sets have none.
    begin
        if (cfg_dynagear().nvram_mode !== 2'd0 ||
            cfg_cairblad().nvram_mode !== 2'd2 ||
            cfg_drifto94().nvram_mode !== 2'd1 ||
            cfg_stmblade().nvram_mode !== 2'd1 ||
            cfg_twineag2().nvram_mode !== 2'd0 ||
            cfg_ultrax().nvram_mode !== 2'd0) begin
            errors++;
            $display("FAIL descriptor NVRAM window size");
        end
        checked += 6;
    end


    // 9. Descriptor-visible geometry and Vasara's fixed-high system-input
    // wiring are source-derived and must not leak into other profiles.
    begin
        if (active_width_cfg(cfg_dynagear()) !== 9'd336 ||
            active_height_cfg(cfg_dynagear()) !== 9'd240 ||
            active_width_cfg(cfg_cairblad()) !== 9'd338 ||
            active_width_cfg(cfg_stmblade()) !== 9'd352 ||
            active_width_cfg(cfg_twineag2()) !== 9'd336 ||
            active_width_cfg(cfg_ultrax()) !== 9'd336 ||
            // cfg_for_game() is the universal frame/visual bench path. Keep
            // its IDs in parity with the direct descriptor constructors.
            active_width_cfg(cfg_for_game(4'd6)) !== 9'd336 ||
            active_width_cfg(cfg_for_game(4'd7)) !== 9'd336 ||
            active_height_cfg(cfg_drifto94()) !== 9'd238 ||
            cfg_vasara().system_input_mode !== 1'b1 ||
            cfg_vasara2().system_input_mode !== 1'b1 ||
            !cfg_vasara().rapid_fire_b3_to_b1 ||
            !cfg_vasara2().rapid_fire_b3_to_b1 ||
            !cfg_twineag2().rapid_fire_b1 || !cfg_twineag2().rapid_fire_b2 ||
            cfg_drifto94().system_input_mode !== 1'b0 ||
            cfg_dynagear().system_input_mode !== 1'b0 ||
            cfg_dynagear().rapid_fire_b3_to_b1 || cfg_dynagear().rapid_fire_b1 ||
            cfg_dynagear().rapid_fire_b2) begin
            errors++;
            $display("FAIL descriptor geometry/system-input mode");
        end
        checked += 13;
    end

    // 10. Prove this bench DISCRIMINATES. A test that passes against both the
    //    old behaviour and the new one is worthless, and CLAUDE.md requires a
    //    regression test to have been observed failing without the fix. Rather
    //    than rely on having run it at the right commit, show here that the
    //    superseded `code[16:0]` mask disagrees with the modulo on every
    //    non-power-of-two title -- so had the mask still been in place,
    //    section 2 above would have failed.
    for (int g = 0; g < 4; g++) begin
        int unsigned e;
        int unsigned disagreements;
        e = games[g].elements;
        disagreements = 0;
        for (int unsigned code = 0; code < 32'h100000; code += 1021) begin
            logic [17:0] old_mask;
            old_mask = 18'(code[16:0]);
            if (old_mask !== 18'(code % e)) disagreements++;
        end
        if (games[g].factor != 1 && disagreements == 0) begin
            errors++;
            $display("FAIL %s: old mask agrees with modulo everywhere -- this bench cannot detect the bug it exists for",
                     games[g].name);
        end
        if (games[g].factor == 1 && games[g].k == 17 && disagreements != 0) begin
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
