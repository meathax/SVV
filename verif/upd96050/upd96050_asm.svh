// SPDX-License-Identifier: GPL-3.0-or-later
//============================================================================
//  uPD96050 opcode encoders shared by the upd96050 benches, so the three
//  testbenches cannot drift apart on a field position.
//
//  Field layout from MAME src/devices/cpu/upd7725/upd7725.cpp:
//    OP/RT  :350-358  {class, pselect, alu, asl, dpl, dphm, rpdcr, src, dst}
//    JP     :482-484  {class, brch[8:0], na[10:0], bank[1:0]}
//    LD     :543-545  {class, id[15:0], --[1:0], dst[3:0]}   (id = opcode>>6)
//============================================================================

function automatic [23:0] OPW(input [1:0] ps, input [3:0] alu, input asl,
                              input [1:0] dpl, input [3:0] dphm, input rpdcr,
                              input [3:0] src, input [3:0] dst);
    OPW = {2'b00, ps, alu, asl, dpl, dphm, rpdcr, src, dst};
endfunction

function automatic [23:0] RTW(input [1:0] ps, input [3:0] alu, input asl,
                              input [1:0] dpl, input [3:0] dphm, input rpdcr,
                              input [3:0] src, input [3:0] dst);
    RTW = {2'b01, ps, alu, asl, dpl, dphm, rpdcr, src, dst};
endfunction

function automatic [23:0] JPW(input [8:0] brch, input [10:0] na,
                              input [1:0] bank);
    JPW = {2'b10, brch, na, bank};
endfunction

function automatic [23:0] LDW(input [15:0] id, input [3:0] dst);
    LDW = {2'b11, id, 2'b00, dst};
endfunction

// Pure register move: no ALU, no pointer modify.
function automatic [23:0] MOV(input [3:0] src, input [3:0] dst);
    MOV = OPW(2'd0, 4'd0, 1'b0, 2'd0, 4'd0, 1'b0, src, dst);
endfunction

// ALU op with P = IDB sourced from `src`, no destination move.
function automatic [23:0] ALUI(input [3:0] alu, input asl, input [3:0] src);
    ALUI = OPW(2'd1, alu, asl, 2'd0, 4'd0, 1'b0, src, 4'd0);
endfunction
