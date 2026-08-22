// SPDX-License-Identifier: GPL-3.0-or-later
//
// Model of the MiSTer 128 MB SDRAM module as it is actually built, as opposed
// to the single monolithic 64Mx16 part that verif/ssv_sdram_chip.sv models and
// that this board does not have.
//
// THE THREE FACTS THIS MODEL ENCODES, all of them load-bearing:
//
//  1. It is TWO 32Mx16 devices, not one. SDRAM_nCS is the DEVICE SELECTOR, not
//     part of the command encoding: device 0 answers when nCS is low, device 1
//     when nCS is high. A controller that folds nCS into a 4-bit command can
//     never address the upper 64 MB at all.
//
//  2. DQML/DQMH are SHORTED to A11/A12 on the module. They are not independent
//     outputs. Whatever the address bus carries during a cycle IS the byte
//     mask. Driving them separately fights the shorted net.
//
//  3. Each device is 4 banks x 8192 rows x 1024 columns. The tenth column bit
//     therefore rides on A9; there is no eleventh column bit and nothing may be
//     placed on A11, because A11 is the DQM short.
//
// Sources: rtl/mem/sdram.sv of the Sega System 32 core (D:\Arcade\AI\S32MULTIONLY),
// which runs on this same board, and which cites Arcade-IremM92_MiSTer
// rtl/sdram.sv:69 and jtframe_sdram_bank_core.v:140 -- "This is a limitation in
// MiSTer's 128MB module".
//
// The model is deliberately LOUD. A controller written for the imaginary part
// does not quietly return wrong data here; it says which rule it broke.

`timescale 1ns/1ps

module ssv_sdram_module #(
    // Per device. Two devices gives a 26-bit word address = 128 MB.
    parameter int BANK_BITS   = 2,
    parameter int ROW_BITS    = 13,
    parameter int COL_BITS    = 10,
    parameter bit STRICT      = 1'b1,
    parameter bit VERBOSE     = 1'b0
) (
    input  wire        clk,
    inout  wire [15:0] SDRAM_DQ,
    input  wire [12:0] SDRAM_A,
    input  wire  [1:0] SDRAM_BA,
    input  wire        SDRAM_DQML,
    input  wire        SDRAM_DQMH,
    input  wire        SDRAM_nCS,
    input  wire        SDRAM_nCAS,
    input  wire        SDRAM_nRAS,
    input  wire        SDRAM_nWE,
    input  wire        SDRAM_CKE
);

localparam int ADDR_BITS = BANK_BITS + ROW_BITS + COL_BITS;   // 25 per device

// Commands are {nRAS,nCAS,nWE} ONLY. nCS is the device select.
localparam [2:0] C_MRS   = 3'b000;
localparam [2:0] C_REF   = 3'b001;
localparam [2:0] C_PRE   = 3'b010;
localparam [2:0] C_ACT   = 3'b011;
localparam [2:0] C_WRITE = 3'b100;
localparam [2:0] C_READ  = 3'b101;
localparam [2:0] C_BST   = 3'b110;
localparam [2:0] C_NOP   = 3'b111;

wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
wire       dev = SDRAM_nCS;          // 0 = device 0, 1 = device 1

// ---------------------------------------------------------------------------
// RULE 2 as an assertion. DQML/DQMH are the A11/A12 net. If the controller
// drives them to anything else it is fighting a short that exists in copper,
// and on hardware the mask is undefined. Catch it the first time.
// ---------------------------------------------------------------------------
integer dqm_fights = 0;
always @(posedge clk) begin
    if (SDRAM_CKE &&
        ({SDRAM_DQMH, SDRAM_DQML} !== {SDRAM_A[12], SDRAM_A[11]})) begin
        if (dqm_fights == 0) begin
            $display("[%0t] SDRAM_MODULE_VIOLATION: DQM driven independently of A[12:11].",
                     $time);
            $display("            DQMH/DQML = %b%b but A[12:11] = %b%b",
                     SDRAM_DQMH, SDRAM_DQML, SDRAM_A[12], SDRAM_A[11]);
            $display("            On the MiSTer 128 MB module these pins are the SAME NET.");
            if (STRICT)
                $fatal(1, "controller drives DQM against the module's A11/A12 short");
        end
        dqm_fights = dqm_fights + 1;
    end
end

// Effective mask always comes from the address bus, never from the DQM pins.
wire dqmh_eff = SDRAM_A[12];
wire dqml_eff = SDRAM_A[11];

// ---------------------------------------------------------------------------
// Two devices.
// ---------------------------------------------------------------------------
reg [15:0] mem0 [0:(1<<ADDR_BITS)-1];
reg [15:0] mem1 [0:(1<<ADDR_BITS)-1];

reg [ROW_BITS-1:0] row0 [0:(1<<BANK_BITS)-1];
reg [ROW_BITS-1:0] row1 [0:(1<<BANK_BITS)-1];
reg [(1<<BANK_BITS)-1:0] act0, act1;

// RULE 1/3: a device that never saw MRS returns garbage on hardware. Track it
// so "the controller only ever initialised one device" is reported as itself
// rather than as mysterious data corruption 200 ms later.
reg mrs0 = 1'b0, mrs1 = 1'b0;
integer unmrs_access = 0;

// Column is 10 bits: A9 is the top one. A10 is auto-precharge, A11/A12 are the
// DQM short -- nothing addressable may live there.
wire [COL_BITS-1:0] col_in   = {SDRAM_A[9], SDRAM_A[8:0]};
wire                auto_pre = SDRAM_A[10];

// CL2 read pipeline. Structure copied from verif/ssv_sdram_chip.sv, whose
// alignment is already proven against this controller family: stage 0 is loaded
// on the edge that decodes READ (edge K), and the DQ output register takes
// stage CL-2 -- index 0 for CL2 -- reading the PRE-edge value, so DQ is valid
// across (K+1, K+2) and the controller latches it at K+2. Getting this wrong
// makes every read return zero, which looks exactly like a controller fault.
localparam int MAXCL = 4;
reg [15:0] pipe_d [0:MAXCL-1];
reg        pipe_v [0:MAXCL-1];
reg [15:0] dq_reg;
reg        dq_drv;
integer    si;

assign SDRAM_DQ = dq_drv ? dq_reg : 16'hzzzz;

integer i;
// mem0/mem1 are DELIBERATELY not initialised here. Benches preload them by
// hierarchical task call from their own initial blocks, and initial-block
// ordering across modules is indeterminate: an explicit zero-fill here ran
// AFTER tb_ssv_frame_crc's preload and silently erased the entire ROM image,
// which presented as "V60 fetches the right addresses, every word reads 0000,
// video_enable never rises" -- indistinguishable from a controller fault until
// the per-transaction log showed correct addresses with zero data. Verilator's
// two-state semantics zero uninitialised arrays anyway; the old
// ssv_sdram_chip.sv left its array alone for the same reason.
initial begin
    for (i = 0; i < MAXCL; i = i + 1) begin
        pipe_v[i] = 1'b0;
        pipe_d[i] = 16'h0000;
    end
    act0 = '0; act1 = '0; dq_drv = 1'b0;
end

task automatic preload(input integer device, input [ADDR_BITS-1:0] a,
                       input [15:0] d);
    if (device == 0) mem0[a] = d; else mem1[a] = d;
endtask

// Preload by flat 26-bit WORD address, so a bench can keep using plain linear
// addresses as it did with the single-chip model. Applies exactly the
// device/bank/row/column permutation the controller drives, which for word
// index w is:
//     device = w[25]                (SDRAM_nCS)
//     bank   = w[23:22]             (SDRAM_BA)
//     row    = w[21:9]              (13 bits)
//     column = {w[24], w[8:0]}      (10 bits; the top one rides A9)
// Note the column MSB is w[24], NOT w[9] -- the map is interleaved, and
// hand-deriving it instead of taking it from the controller is how a preload
// silently lands somewhere the core never reads.
task automatic preload_word(input [25:0] w, input [15:0] d);
    logic                 dev_i;
    logic [ADDR_BITS-1:0] lin;
    begin
        dev_i = w[25];
        lin   = {w[23:22], w[21:9], w[24], w[8:0]};
        if (dev_i) mem1[lin] = d; else mem0[lin] = d;
    end
endtask

wire [ADDR_BITS-1:0] cur0 = {SDRAM_BA, row0[SDRAM_BA], col_in};
wire [ADDR_BITS-1:0] cur1 = {SDRAM_BA, row1[SDRAM_BA], col_in};

always @(posedge clk) begin
    if (SDRAM_CKE) begin
        // Shift the staging pipeline, then take stage CL-2 = 0 from its
        // PRE-edge value for the DQ output register. The case below reloads
        // stage 0 on a READ, after this shift, which is what makes the
        // pre-edge read correct.
        for (si = MAXCL-1; si > 0; si = si - 1) begin
            pipe_v[si] <= pipe_v[si-1];
            pipe_d[si] <= pipe_d[si-1];
        end
        pipe_v[0] <= 1'b0;
        dq_drv <= pipe_v[0];
        dq_reg <= pipe_d[0];

        case (cmd)
        C_MRS: begin
            if (dev == 1'b0) mrs0 <= 1'b1; else mrs1 <= 1'b1;
            if (VERBOSE) $display("[%0t] MODULE dev%0d MRS A=%013b", $time, dev, SDRAM_A);
        end
        C_ACT: begin
            if (dev == 1'b0) begin row0[SDRAM_BA] <= SDRAM_A; act0[SDRAM_BA] <= 1'b1; end
            else              begin row1[SDRAM_BA] <= SDRAM_A; act1[SDRAM_BA] <= 1'b1; end
        end
        C_PRE: begin
            if (SDRAM_A[10]) begin
                if (dev == 1'b0) act0 <= '0; else act1 <= '0;
            end else begin
                if (dev == 1'b0) act0[SDRAM_BA] <= 1'b0; else act1[SDRAM_BA] <= 1'b0;
            end
        end
        C_READ: begin
            if ((dev == 1'b0 && !mrs0) || (dev == 1'b1 && !mrs1)) begin
                if (unmrs_access == 0)
                    $display("[%0t] SDRAM_MODULE_VIOLATION: READ to device %0d which never received MRS. Real silicon returns garbage.",
                             $time, dev);
                unmrs_access = unmrs_access + 1;
                if (STRICT) $fatal(1, "read from un-initialised SDRAM device %0d", dev);
            end
            pipe_v[0]  <= 1'b1;
            pipe_d[0]  <= (dev == 1'b0) ? mem0[cur0] : mem1[cur1];
            if (auto_pre) begin
                if (dev == 1'b0) act0[SDRAM_BA] <= 1'b0; else act1[SDRAM_BA] <= 1'b0;
            end
        end
        C_WRITE: begin
            if ((dev == 1'b0 && !mrs0) || (dev == 1'b1 && !mrs1)) begin
                if (unmrs_access == 0)
                    $display("[%0t] SDRAM_MODULE_VIOLATION: WRITE to device %0d which never received MRS.",
                             $time, dev);
                unmrs_access = unmrs_access + 1;
                if (STRICT) $fatal(1, "write to un-initialised SDRAM device %0d", dev);
            end
            // Mask comes from the shorted A11/A12 net, not the DQM pins.
            if (dev == 1'b0)
                mem0[cur0] <= {dqmh_eff ? mem0[cur0][15:8] : SDRAM_DQ[15:8],
                               dqml_eff ? mem0[cur0][7:0]  : SDRAM_DQ[7:0]};
            else
                mem1[cur1] <= {dqmh_eff ? mem1[cur1][15:8] : SDRAM_DQ[15:8],
                               dqml_eff ? mem1[cur1][7:0]  : SDRAM_DQ[7:0]};
            if (auto_pre) begin
                if (dev == 1'b0) act0[SDRAM_BA] <= 1'b0; else act1[SDRAM_BA] <= 1'b0;
            end
        end
        default: ;
        endcase
    end
end

final begin
    $display("SDRAM_MODULE dqm_fights=%0d unmrs_access=%0d mrs0=%0b mrs1=%0b",
             dqm_fights, unmrs_access, mrs0, mrs1);
end

endmodule
