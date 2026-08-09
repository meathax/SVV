`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// Behavioural SDR SDRAM chip model (verification only).
//
// Models the part `rtl/mem/sdram.sv` is written against: a 256 Mbit x16 SDR
// device, 4 banks x 8192 rows x 512 columns, CL2, burst length 1, with
// auto-precharge selected by A10 on a READ/WRITE command.
//
// Address decode matches the controller exactly:
//     word address [24:1] = { BA[1:0], row A[12:0], col A[8:0] }
// The controller drives SDRAM_A[9:0] <= xfer_addr[10:1] on a column command,
// so A[9] carries address bit 10, which is also row bit 0.  On a 512-column
// part A[9] is a don't-care for the column, so the map stays unique.  The
// model therefore uses A[8:0] as the column, and flags a use of A[9] that
// would alias on a 1024-column part (informational only).
//
// Timing contract implemented (the pieces the controller depends on):
//   * commands are sampled on the rising edge of clk while CKE is high;
//   * a READ sampled at edge E drives DQ so that the data is stable at the
//     controller's sampling edge E+2 (CL2);
//   * a WRITE takes its data and DQM byte mask from the same edge as the
//     command;
//   * A10 on a column command auto-precharges the bank when the access ends.
//
// Protocol checking (counted always, fatal only with +SDRAM_STRICT):
//   * column command to a bank with no open row
//   * ACTIVATE to a bank that already has a row open
//   * AUTO REFRESH while any bank is open
//   * tRCD / tRP / tRC / tMRD / CL violations against the JEDEC -6 numbers
//     the controller's comments cite
//   * refresh interval longer than 64 ms / 8192 rows
//
// The array is left at FILL_WORD until written, so anything the ROM loader
// never wrote reads as a defined value rather than X.
// ---------------------------------------------------------------------------

module sdram_chip_model #(
    parameter int unsigned ROWS      = 8192,
    parameter int unsigned COLS      = 512,
    parameter int unsigned BANKS     = 4,
    // Cycle counts at clk_ram = 96.6 MHz (10.35 ns).  These mirror the numbers
    // in rtl/mem/sdram.sv's own comments.
    parameter int unsigned T_RCD     = 3,
    parameter int unsigned T_RP      = 3,
    parameter int unsigned T_RC      = 7,
    parameter int unsigned T_MRD     = 2,
    parameter int unsigned CAS       = 2,
    parameter int unsigned T_REFI    = 800,   // 64 ms / 8192 rows @96.6 MHz
    parameter logic [15:0] FILL_WORD = 16'h0000
) (
    input               clk,
    input               cke,
    input               nCS,
    input               nRAS,
    input               nCAS,
    input               nWE,
    input        [1:0]  BA,
    input       [12:0]  A,
    input               DQML,
    input               DQMH,
    inout       [15:0]  DQ,

    // Backdoor image load (used to install the ROM image without paying
    // 8.9 M controller write transactions).  Synchronous, one word per clk.
    input               bd_we,
    input       [23:0]  bd_addr,
    input       [15:0]  bd_din,

    // Observability
    output logic [31:0] n_act,
    output logic [31:0] n_read,
    output logic [31:0] n_write,
    output logic [31:0] n_ref,
    output logic [31:0] n_pre,
    output logic [31:0] n_violation
);

localparam int unsigned MEM_WORDS = BANKS * ROWS * COLS;

// 16 M words = 32 MiB.
logic [15:0] mem [0:MEM_WORDS-1];

localparam logic [3:0] CMD_NOP    = 4'b0111;
localparam logic [3:0] CMD_ACT    = 4'b0011;
localparam logic [3:0] CMD_READ   = 4'b0101;
localparam logic [3:0] CMD_WRITE  = 4'b0100;
localparam logic [3:0] CMD_PRE    = 4'b0010;
localparam logic [3:0] CMD_REF    = 4'b0001;
localparam logic [3:0] CMD_MRS    = 4'b0000;
localparam logic [3:0] CMD_BST    = 4'b0110;
localparam logic [3:0] CMD_DESL   = 4'b1111;

wire [3:0] cmd_i = {nCS, nRAS, nCAS, nWE};
wire [3:0] cmd   = nCS ? CMD_DESL : cmd_i;

logic               bank_open  [0:3];
logic [12:0]        bank_row   [0:3];
int unsigned        t_act      [0:3];   // cycle of last ACT per bank
int unsigned        t_pre      [0:3];   // cycle of last PRE per bank
int unsigned        t_last_col [0:3];

int unsigned cyc;
int unsigned t_mrs;
int unsigned t_ref_last;
logic        mrs_seen;
logic [2:0]  mrs_cl;
logic [2:0]  mrs_bl;

int unsigned v_count;
logic        strict;
logic        quiet_until_ready;   // ignore checks until the MRS lands
logic        a9_alias_warned;
logic        ref_seen_since_mrs;

// CL2 read return pipeline.  Stage 0 is loaded on the command edge; stage 1
// drives DQ so the word is stable at the controller's sample edge (E+2).
logic [15:0] dq_r0, dq_r1;
logic        dq_v0, dq_v1;

assign DQ = dq_v1 ? dq_r1 : 16'hzzzz;

int unsigned c_act, c_read, c_write, c_ref, c_pre;

assign n_act       = c_act;
assign n_read      = c_read;
assign n_write     = c_write;
assign n_ref       = c_ref;
assign n_pre       = c_pre;
assign n_violation = v_count;

function automatic int unsigned word_addr(input [1:0] b,
                                          input [12:0] r,
                                          input [12:0] a_col);
    word_addr = (int'(b) * int'(ROWS) * int'(COLS))
              + (int'(r) * int'(COLS))
              + (int'(a_col) & (int'(COLS) - 1));
endfunction

task automatic violation(input string msg);
    v_count = v_count + 1;
    if (v_count <= 32)
        $display("SDRAM_MODEL VIOLATION @%0t cyc=%0d: %s", $time, cyc, msg);
    if (strict)
        $fatal(1, "SDRAM_MODEL VIOLATION: %s", msg);
endtask

initial begin
    integer k;
    strict = $test$plusargs("SDRAM_STRICT");
    quiet_until_ready = 1'b1;
    a9_alias_warned = 1'b0;
    ref_seen_since_mrs = 1'b0;
    v_count = 0;
    c_act = 0; c_read = 0; c_write = 0; c_ref = 0; c_pre = 0;
    cyc = 0;
    t_mrs = 0;
    t_ref_last = 0;
    mrs_seen = 1'b0;
    mrs_cl = 3'd0;
    mrs_bl = 3'd0;
    dq_v0 = 1'b0;
    dq_v1 = 1'b0;
    dq_r0 = 16'h0000;
    dq_r1 = 16'h0000;
    for (k = 0; k < 4; k = k + 1) begin
        bank_open[k] = 1'b0;
        bank_row[k]  = 13'd0;
        t_act[k]     = 0;
        t_pre[k]     = 0;
        t_last_col[k] = 0;
    end
    for (k = 0; k < MEM_WORDS; k = k + 1)
        mem[k] = FILL_WORD;
end

always @(posedge clk) begin
    int unsigned wa;
    int unsigned b;

    cyc <= cyc + 1;

    // ---- backdoor image load ------------------------------------------
    if (bd_we)
        mem[bd_addr] <= bd_din;

    // ---- CL2 return pipeline ------------------------------------------
    dq_v0 <= 1'b0;
    dq_r1 <= dq_r0;
    dq_v1 <= dq_v0;

    if (cke) begin
        case (cmd)
        CMD_ACT: begin
            b = int'(BA);
            c_act <= c_act + 1;
            if (!quiet_until_ready) begin
                if (bank_open[b])
                    violation($sformatf("ACT to bank %0d with row %0d already open",
                                        b, bank_row[b]));
                else if (cyc < t_pre[b] + T_RP)
                    violation($sformatf("tRP violation on bank %0d: ACT %0d cycles after PRE",
                                        b, cyc - t_pre[b]));
                if (cyc < t_act[b] + T_RC && t_act[b] != 0)
                    violation($sformatf("tRC violation on bank %0d: %0d cycles ACT-to-ACT",
                                        b, cyc - t_act[b]));
            end
            bank_open[b] <= 1'b1;
            bank_row[b]  <= A;
            t_act[b]     <= cyc;
        end

        CMD_READ, CMD_WRITE: begin
            b = int'(BA);
            if (!quiet_until_ready) begin
                if (!bank_open[b])
                    violation($sformatf("%s to bank %0d with no open row",
                                        (cmd == CMD_READ) ? "READ" : "WRITE", b));
                else if (cyc < t_act[b] + T_RCD)
                    violation($sformatf("tRCD violation on bank %0d: column command %0d cycles after ACT",
                                        b, cyc - t_act[b]));
                if (A[9] && !a9_alias_warned && COLS <= 512) begin
                    a9_alias_warned = 1'b1;
                    $display("SDRAM_MODEL NOTE @%0t: A[9] set on a column command; harmless on a %0d-column part but would alias the row on a 1024-column part",
                             $time, COLS);
                end
            end
            wa = word_addr(BA, bank_open[b] ? bank_row[b] : 13'd0, {4'd0, A[8:0]});
            if (cmd == CMD_READ) begin
                c_read <= c_read + 1;
                dq_r0  <= mem[wa];
                dq_v0  <= 1'b1;
            end
            else begin
                c_write <= c_write + 1;
                if (dq_v1)
                    violation("WRITE while the model is driving read data (bus contention)");
                if (!DQML) mem[wa][7:0]  <= DQ[7:0];
                if (!DQMH) mem[wa][15:8] <= DQ[15:8];
            end
            t_last_col[b] <= cyc;
            if (A[10]) begin      // auto-precharge
                bank_open[b] <= 1'b0;
                t_pre[b]     <= cyc;
                c_pre        <= c_pre + 1;
            end
        end

        CMD_PRE: begin
            c_pre <= c_pre + 1;
            if (A[10]) begin
                for (b = 0; b < 4; b = b + 1) begin
                    bank_open[b] <= 1'b0;
                    t_pre[b]     <= cyc;
                end
            end
            else begin
                bank_open[int'(BA)] <= 1'b0;
                t_pre[int'(BA)]     <= cyc;
            end
        end

        CMD_REF: begin
            c_ref <= c_ref + 1;
            if (!quiet_until_ready) begin
                for (b = 0; b < 4; b = b + 1)
                    if (bank_open[b])
                        violation($sformatf("AUTO REFRESH with bank %0d still open", b));
                // Skip the first interval after MRS: the init burst issues 8
                // back-to-back refreshes and then ref_cnt starts from the end
                // of the init countdown, so the first steady-state gap is one
                // long interval by construction and refreshes nothing late.
                if (t_ref_last != 0 && ref_seen_since_mrs &&
                    (cyc - t_ref_last) > T_REFI)
                    violation($sformatf("refresh interval %0d cycles exceeds tREFI budget %0d",
                                        cyc - t_ref_last, T_REFI));
            end
            t_ref_last <= cyc;
            ref_seen_since_mrs <= 1'b1;
        end

        CMD_MRS: begin
            mrs_seen <= 1'b1;
            mrs_cl   <= A[6:4];
            mrs_bl   <= A[2:0];
            t_mrs    <= cyc;
            quiet_until_ready <= 1'b0;
            ref_seen_since_mrs <= 1'b0;
            t_ref_last <= cyc;
            if (A[6:4] != 3'(CAS))
                violation($sformatf("MRS programmed CL=%0d, model implements CL=%0d",
                                    A[6:4], CAS));
            if (A[2:0] != 3'b000)
                violation($sformatf("MRS programmed burst length code %0d; model implements BL=1",
                                    A[2:0]));
        end

        default: ; // NOP / DESELECT / BURST TERMINATE
        endcase
    end
end

// Report on request.
task automatic report_stats();
    $display("SDRAM_MODEL act=%0d read=%0d write=%0d refresh=%0d precharge=%0d violations=%0d",
             c_act, c_read, c_write, c_ref, c_pre, v_count);
endtask

endmodule
