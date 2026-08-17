// SPDX-License-Identifier: GPL-3.0-or-later
//
// Run rtl/mem/sdram.sv against a model of the MiSTer 128 MB module as it is
// actually built (verif/ssv_sdram_module.sv), rather than against the single
// monolithic 64Mx16 part verif/ssv_sdram_chip.sv invents.
//
// This is the regression that was missing. Every existing bench instantiates
// ssv_sdram_chip, so every bench has been grading the controller against a part
// this board does not have -- which is why 39/39 attract frames could match
// MAME while hardware showed a black screen, silence, and an SDRAM probe that
// returned byte-identical wrong data no matter what the read path was changed
// to.
//
// Expected result BEFORE the controller is ported to the module contract:
// this bench FAILS, and names which of the three module rules was broken.
// After the port: PASS. Observed-fail-first is the acceptance condition in
// CLAUDE.md, and it is the whole point of writing this before the fix.

`timescale 1ns/1ps

module tb_ssv_sdram_module_contract;

logic clk_ram = 1'b0;
always #2.5 clk_ram = ~clk_ram;

logic rst = 1'b1;
wire  ready;

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH;
wire        SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

localparam int AW = 26;

logic            wr_req = 1'b0;
logic [AW:1]     wr_addr = '0;
logic [15:0]     wr_din  = '0;
logic  [1:0]     wr_be   = 2'b11;
wire             wr_ack;

logic            p0_req = 1'b0;
logic [AW:1]     p0_addr = '0;
wire  [15:0]     p0_dout;
wire             p0_ack;

// The controller exactly as the core instantiates it (Arcade-SSV.sv). It takes
// no geometry parameters: the module's shape is fixed in copper, and making it
// configurable is what allowed a controller for the wrong part to be built.
sdram dut (
    .clk(clk_ram), .init(rst), .ready(ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be),
    .wr_ack(wr_ack),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(1'b0), .p1_addr('0), .p1_dout(), .p1_ack(),
    .p2_req(1'b0), .p2_addr('0), .p2_dout(), .p2_ack(),
    .p3_req(1'b0), .p3_addr('0), .p3_dout(), .p3_ack(),
    .p4_req(1'b0), .p4_addr('0), .p4_dout(), .p4_ack(),
    .p5_req(1'b0), .p5_addr('0), .p5_dout(), .p5_ack()
);

// STRICT=0 so the run reports EVERY rule broken instead of dying on the first.
// A controller written for the wrong part typically breaks more than one, and
// seeing the whole set is what makes the diagnosis actionable.
ssv_sdram_module #(.STRICT(1'b0)) module_model (
    .clk(clk_ram),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
);

task automatic write_word(input [AW:1] a, input [15:0] d);
    begin
        @(posedge clk_ram); #1;
        wr_addr = a; wr_din = d; wr_be = 2'b11; wr_req = 1'b1;
        @(posedge clk_ram); #1;
        wr_req = 1'b0;
        while (!wr_ack) @(posedge clk_ram);
        @(posedge clk_ram); #1;
    end
endtask

task automatic read_word(input [AW:1] a, output [15:0] q);
    begin
        @(posedge clk_ram); #1;
        p0_addr = a; p0_req = 1'b1;
        @(posedge clk_ram); #1;
        p0_req = 1'b0;
        while (!p0_ack) @(posedge clk_ram);
        q = p0_dout;
        @(posedge clk_ram); #1;
    end
endtask

// Addresses chosen to exercise BOTH devices: the region map puts the V60
// program and graphics on the low half and the ST010 / ES5506 samples above
// 64 MB, so a controller that cannot select device 1 loses the samples --
// which is exactly the reported "no sound".
// 27-bit literals: a BYTE address of 0x6000000 needs 27 bits, and writing
// 26'h6000000 truncates to 26 BEFORE the shift, silently collapsing both
// device-1 addresses onto device 0. That would have made this bench report a
// device-1 failure it never actually exercised.
localparam [AW:1] A_DEV0_PROG = 27'h0000000 >> 1;
localparam [AW:1] A_DEV0_GFX  = 27'h2000000 >> 1;
localparam [AW:1] A_DEV1_ST10 = 27'h4000000 >> 1;
localparam [AW:1] A_DEV1_SMPL = 27'h6000000 >> 1;

logic [15:0] got;
integer errors = 0;

task automatic check(input string name, input [AW:1] a, input [15:0] d);
    begin
        write_word(a, d);
        read_word(a, got);
        if (got !== d) begin
            errors++;
            $display("MISMATCH %-10s addr=%07h wrote %04h read %04h",
                     name, {a, 1'b0}, d, got);
        end else
            $display("OK       %-10s addr=%07h = %04h", name, {a, 1'b0}, d);
    end
endtask

initial begin
    repeat (20) @(posedge clk_ram);
    rst = 0;
    while (!ready) @(posedge clk_ram);
    $display("controller reports ready");

    // preload_word() is a SECOND, hand-derived copy of the controller's
    // device/bank/row/column permutation, used by tb_ssv_frame_crc to fill
    // memory without going through the loader. If it disagrees with the
    // controller by even one bit the core fetches garbage and never boots,
    // which is indistinguishable from a controller fault. Check it against a
    // real controller read before trusting any preload-based bench.
    module_model.preload_word(26'h0000010, 16'hFEED);
    read_word(26'h0000010, got);
    if (got !== 16'hFEED) begin
        errors++;
        $display("MISMATCH preload_word @0000010 expected feed read %04h", got);
    end else $display("OK       preload_word = %04h", got);

    module_model.preload_word(26'h1234567, 16'hBA5E);
    read_word(26'h1234567, got);
    if (got !== 16'hBA5E) begin
        errors++;
        $display("MISMATCH preload_word @1234567 expected ba5e read %04h", got);
    end else $display("OK       preload_word hi = %04h", got);

    check("dev0 prog",   A_DEV0_PROG, 16'h207A);
    check("dev0 gfx",    A_DEV0_GFX,  16'h1234);
    check("dev1 st010",  A_DEV1_ST10, 16'hBEEF);
    check("dev1 sample", A_DEV1_SMPL, 16'hC0DE);

    // Byte-enable write: on this module the mask travels on A11/A12, so a
    // controller driving DQM separately corrupts the untouched lane.
    write_word(A_DEV0_PROG, 16'hAAAA);
    @(posedge clk_ram); #1;
    wr_addr = A_DEV0_PROG; wr_din = 16'h55FF; wr_be = 2'b01; wr_req = 1'b1;
    @(posedge clk_ram); #1; wr_req = 1'b0;
    while (!wr_ack) @(posedge clk_ram);
    read_word(A_DEV0_PROG, got);
    if (got !== 16'hAAFF) begin
        errors++;
        $display("MISMATCH byte-enable: wrote 55FF be=01 over AAAA, expected AAFF read %04h", got);
    end else
        $display("OK       byte-enable = %04h", got);

    $display("errors=%0d", errors);
    if (errors)
        $fatal(1, "FAIL tb_ssv_sdram_module_contract (%0d errors)", errors);
    $display("PASS tb_ssv_sdram_module_contract");
    $finish;
end

initial begin
    #50_000_000;
    $fatal(1, "FAIL tb_ssv_sdram_module_contract timeout (controller never completed a transaction)");
end

endmodule
