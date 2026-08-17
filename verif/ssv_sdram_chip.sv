//============================================================================
//  ssv_sdram_chip.sv  —  behavioural SDR SDRAM device model
//
//  Written to pair with rtl/mem/sdram.sv (SSV / Sega System 32 MiSTer core).
//  This is a FUNCTIONAL + LATENCY model, not a JEDEC compliance checker: it
//  reproduces CAS latency and command decode exactly, but it does NOT enforce
//  refresh intervals, tRAS, tRC or tWR as errors.
//
//  Geometry is parameterised (BANK_BITS/ROW_BITS/COL_BITS), default 32 MB:
//      COL_BITS  9 : 4 banks x 8192 rows x  512 cols x 16 =  32 MB
//      COL_BITS 10 : 4 banks x 8192 rows x 1024 cols x 16 =  64 MB
//      COL_BITS 11 : 4 banks x 8192 rows x 2048 cols x 16 = 128 MB
//      linear word address = { ba, row[ROW_BITS-1:0], col[COL_BITS-1:0] }
//
//  which is exactly the controller's xfer_addr[24:1]:
//      ACT    drives SDRAM_BA <= xfer_addr[24:23]      (bank)
//             drives SDRAM_A  <= xfer_addr[22:10]      (13-bit row)
//      RD/WR  drives SDRAM_A  <= {2'b00, AP, xfer_addr[10:1]}
//               -> A[8:0] = xfer_addr[9:1] = 9-bit column
//                  A[9]   = xfer_addr[10]  = row LSB — a DON'T CARE for a
//                           9-column-bit device; this model ignores it, as
//                           real hardware must.
//                  A[10]  = auto-precharge
//
//----------------------------------------------------------------------------
//  READ -> DATA CYCLE ALIGNMENT   (the one thing that has to be exact)
//----------------------------------------------------------------------------
//  Every signal the controller presents to the chip is a REGISTERED output.
//  A value the controller's always @(posedge clk) block assigns at edge N is
//  therefore on the bus during the interval (N, N+1) and is sampled by this
//  model at edge N+1.  In particular `cmd` is registered (sdram.sv:104-105),
//  so the READ command reaches the device ONE CYCLE AFTER the ST_RD state
//  body executes.
//
//  Controller trace for one word (sdram.sv:272, 336-344, 409-419):
//
//    edge N    state==ST_RD executes:
//                cmd <= CMD_READ, SDRAM_A/BA <= column, cl_pipe[0] <= 1'b1
//              => READ on the command bus during (N, N+1)
//              => cl_pipe[0]==1                during (N, N+1)
//
//    edge N+1  THIS MODEL samples {nCS,nRAS,nCAS,nWE} == CMD_READ.
//              Controller shifts:  cl_pipe[1]==1 during (N+1, N+2)
//
//    edge N+2  cl_pipe[2]==1 during (N+2, N+3)
//
//    edge N+3  cl_pipe[3]==1 during (N+3, N+4).
//              The controller ALSO clocks its input register at this edge:
//                always @(posedge clk) dq_in <= SDRAM_DQ;   (sdram.sv:272)
//              so dq_in takes the value DQ held just before edge N+3.
//
//    edge N+4  the block sees cl_pipe[3]==1 and does
//                cap_buf[rd_captured] <= dq_in;
//              i.e. it commits the word that was on DQ at edge N+3.
//
//  => The read word must be STABLE ON DQ during the interval (N+2, N+3),
//     i.e. it must be REGISTERED ONTO DQ AT EDGE N+2.
//
//  This model decodes the READ at edge K = N+1, so it must drive DQ at
//  edge K+1 == N+2.  That is precisely CAS latency 2 measured the normal
//  way — command registered by the device at edge K, data valid to be
//  latched by the controller at edge K+2 — which confirms the controller's
//  CL2 mode-register programming (13'b000_0_00_010_0_000, sdram.sv:323).
//
//  Generalised for any CL: the data must be registered onto DQ at edge
//  K+CL-1 so it can be sampled at K+CL.  Implemented below as a (CL-1)-deep
//  staging pipeline in front of the DQ output register: stage 0 is loaded at
//  the decode edge K, and the output register takes pipe[CL-2] at K+CL-1.
//  For CL2 that is one staging register.  An off-by-one here would still let
//  the loopback testbench "run", it would just validate the wrong word — so
//  the testbench deliberately uses address-derived, per-word-distinct data.
//
//  WRITE has no such subtlety.  SDR write data is coincident with the WRITE
//  command; the controller drives cmd, dq_out and dqm from the same edge N
//  (sdram.sv:393-402), so this model samples DQ and DQM at the same edge
//  K = N+1 on which it decodes WRITE.
//
//  Reads never mask: the controller forces dqm<=2'b00 for the whole ready
//  branch (sdram.sv:330) and only overrides it in ST_WR, so DQM read
//  masking (a 2-cycle-latency output disable on real parts) is not modelled.
//============================================================================

`timescale 1ns/1ps

module ssv_sdram_chip #(
    // Optional sequencing assertions.  Default OFF, as required: this is a
    // functional model, not a compliance checker.  Enable with the parameter
    // or with the +sdram_strict plusarg.
    parameter bit CHECK_OPEN_ROW = 1'b0,
    // Minimum ACT->READ/WRITE gap in clocks that CHECK_OPEN_ROW also polices.
    // tRCD >= 21 ns; at 96.6 MHz (10.352 ns) that is 3 clocks, which is what
    // the controller inserts (ST_ACT -> ST_RCD1 -> ST_RCD2 -> ST_RD).
    parameter int TRCD_CYCLES   = 3,
    parameter bit VERBOSE       = 1'b0,
    // Device geometry. Parameterised so a bench can build a 32/64/128 MB part
    // AND so the controller can be checked against a MISMATCHED one -- see the
    // note at the localparams below.
    parameter int BANK_BITS     = 2,
    parameter int ROW_BITS      = 13,
    parameter int COL_BITS      = 9
) (
    // Pin names mirror the controller's (rtl/mem/sdram.sv) so the model drops
    // straight onto it, here or in verif/ssv_sdram_harness.sv.
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

// short internal aliases
wire        cke  = SDRAM_CKE;
wire [12:0] addr = SDRAM_A;
wire  [1:0] ba   = SDRAM_BA;
wire        dqml = SDRAM_DQML;
wire        dqmh = SDRAM_DQMH;

// ---------------------------------------------------------------------------
// geometry
// ---------------------------------------------------------------------------
// Geometry now arrives as parameters (see the port list). Building the model
// with a DIFFERENT geometry from the controller is a deliberate test: a
// controller configured for 2048 columns talking to a 512-column part drives
// real column bits onto pins that part treats as don't-cares, so addresses
// alias 4:1 with no error raised anywhere. If this model cannot reproduce
// that, the 128 MB verification story is vacuous.
//
// mem[] is 2**ADDR_BITS words, so ADDR_BITS 26 costs 128 MB of HOST memory per
// instance. Keep full-core benches at the smallest geometry their layout needs.
localparam int ADDR_BITS = BANK_BITS + ROW_BITS + COL_BITS;

// ---------------------------------------------------------------------------
// commands {nCS,nRAS,nCAS,nWE}
// ---------------------------------------------------------------------------
localparam [3:0] C_MRS   = 4'b0000;
localparam [3:0] C_REF   = 4'b0001;
localparam [3:0] C_PRE   = 4'b0010;
localparam [3:0] C_ACT   = 4'b0011;
localparam [3:0] C_WRITE = 4'b0100;
localparam [3:0] C_READ  = 4'b0101;
localparam [3:0] C_BST   = 4'b0110;
localparam [3:0] C_NOP   = 4'b0111;

wire [3:0] cmd = {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
wire       selected = (SDRAM_nCS == 1'b0);

// ---------------------------------------------------------------------------
// backing store — plain unpacked array so a testbench can preload it by
// hierarchical reference:   tb.u_chip.mem[24'h001234] = 16'hbeef;
// (preload()/preload_range() below do the same thing as XMR task calls)
// ---------------------------------------------------------------------------
reg [15:0] mem [0:(1<<ADDR_BITS)-1];

task automatic preload(input [ADDR_BITS-1:0] a, input [15:0] d);
    mem[a] = d;
endtask

task automatic preload_range(input [ADDR_BITS-1:0] a0,
                             input [ADDR_BITS-1:0] a1,
                             input [15:0] d);
    for (int unsigned i = a0; i <= a1; i++) mem[i] = d;
endtask

function automatic [15:0] peek(input [ADDR_BITS-1:0] a);
    peek = mem[a];
endfunction

// ---------------------------------------------------------------------------
// bank state
// ---------------------------------------------------------------------------
reg                bank_active [0:3];
reg [ROW_BITS-1:0] bank_row    [0:3];
// act_age[b] is incremented once per clock while bank b is active and is
// cleared on its ACT.  Sampled PRE-edge inside the command decode below it
// therefore reads (edges since the ACT decode edge) - 1, so the actual
// ACT->RD/WR command gap in device clocks is  act_age[b] + 1.
int                act_age     [0:3];

// mode register (loaded by MRS)
int  cas_lat  = 2;
int  burst_len = 1;
bit  mrs_seen  = 1'b0;

// runtime option flags
bit strict  = CHECK_OPEN_ROW;
bit verbose = VERBOSE;

// FAULT INJECTION, default 0 (correct CL2 alignment).  +sdram_read_skew=N
// shifts read data N clocks later on DQ (N<0 = one clock earlier).  It exists
// for exactly one purpose: to let tb_ssv_sdram_loopback demonstrate that it
// FAILS when the read alignment is wrong, so a pass means something.  Never
// use it in a functional run — a non-zero value prints a banner every time.
int read_skew = 0;

initial begin
    if ($test$plusargs("sdram_strict"))  strict  = 1'b1;
    if ($test$plusargs("sdram_verbose")) verbose = 1'b1;
    void'($value$plusargs("sdram_read_skew=%d", read_skew));
    if (read_skew < -1) read_skew = -1;
    if (read_skew >  2) read_skew =  2;
    if (read_skew != 0)
        $display("*** ssv_sdram_chip: READ DATA SKEWED BY %0d CLK - FAULT INJECTION ACTIVE ***",
                 read_skew);
    for (int i = 0; i < 4; i++) begin
        bank_active[i] = 1'b0;
        bank_row[i]    = '0;
        act_age[i]     = 0;
    end
end

// (pipe_v/pipe_d are initialised in an initial block after their declaration)

// ---------------------------------------------------------------------------
// read data path.  See the alignment derivation at the top of the file.
//   stage 0 is loaded on the edge that decodes READ (edge K)
//   the DQ output register takes stage (CL-2) at edge K+CL-1
//   -> for CL2 that is stage 0 taken at edge K+1
// ---------------------------------------------------------------------------
localparam int MAXCL = 4;
reg [15:0] pipe_d [0:MAXCL-1];
reg        pipe_v [0:MAXCL-1];

reg [15:0] dq_reg = 16'h0000;
reg        dq_drv = 1'b0;

initial begin
    for (int i = 0; i < MAXCL; i++) begin
        pipe_v[i] = 1'b0;
        pipe_d[i] = 16'h0000;
    end
end

assign SDRAM_DQ = dq_drv ? dq_reg : 16'hzzzz;

// Column decode.
//
// The controller drives A[9:0] from word-address bits [10:1], A[10] with
// auto-precharge, and -- only on a 2048-column part -- A[11] with the 11th
// column bit. So a <=10-column part takes the low COL_BITS of A directly,
// while an 11-column part splices A[11] on ABOVE A[9], skipping the AP pin.
wire [COL_BITS-1:0] col_in   = (COL_BITS == 11)
                             ? {addr[11], addr[9:0]}
                             : addr[COL_BITS-1:0];
wire                auto_pre = addr[10];

// Linear word address of the cell this cycle's RD/WR command selects:
//     { bank, open row of that bank, column }
// Kept as a wire rather than a function call so it can index mem[] on the
// left-hand side of a non-blocking assignment.
wire [ADDR_BITS-1:0] cur_addr = {ba, bank_row[ba], col_in};

integer si;
always @(posedge clk) begin
    if (cke) begin
        // ---- shift the read staging pipeline ----------------------------
        for (si = MAXCL-1; si > 0; si = si - 1) begin
            pipe_v[si] <= pipe_v[si-1];
            pipe_d[si] <= pipe_d[si-1];
        end
        pipe_v[0] <= 1'b0;

        // ---- DQ output register (reads the PRE-edge pipeline values) -----
        // At edge K+CL-1 this samples the stage loaded at edge K, so DQ is
        // valid throughout (K+CL-1, K+CL) and the controller latches it at
        // edge K+CL.  CL2 -> index 0.
        dq_drv <= (read_skew >= 0) ? pipe_v[cas_lat-2+read_skew] : 1'b0;
        dq_reg <= (read_skew >= 0) ? pipe_d[cas_lat-2+read_skew] : 16'h0000;

        for (si = 0; si < 4; si = si + 1)
            if (bank_active[si] && act_age[si] < 1000) act_age[si] <= act_age[si] + 1;

        // ---- command decode ---------------------------------------------
        if (selected) begin
            case (cmd)

            C_MRS: begin
                mrs_seen  <= 1'b1;
                cas_lat   <= int'(addr[6:4]);
                burst_len <= 1 << int'(addr[2:0]);
                if (verbose)
                    $display("[%0t] SDRAM MRS: A=%b CL=%0d BL=%0d %s",
                             $time, addr, addr[6:4], 1 << addr[2:0],
                             addr[3] ? "interleaved" : "sequential");
                if (int'(addr[6:4]) < 2 || int'(addr[6:4]) > MAXCL)
                    $fatal(1, "ssv_sdram_chip: unsupported CAS latency %0d in MRS",
                           addr[6:4]);
            end

            C_ACT: begin
                bank_active[ba] <= 1'b1;
                bank_row[ba]    <= addr[ROW_BITS-1:0];
                act_age[ba]     <= 0;
                if (verbose) $display("[%0t] SDRAM ACT  b%0d row %0d", $time, ba, addr);
            end

            C_READ: begin
                if (strict && !bank_active[ba])
                    $fatal(1, "ssv_sdram_chip: READ to bank %0d with no open row (col %0d)",
                           ba, col_in);
                if (strict && bank_active[ba] && (act_age[ba] + 1) < TRCD_CYCLES)
                    $fatal(1, "ssv_sdram_chip: tRCD violation, READ %0d clk after ACT (need %0d)",
                           act_age[ba] + 1, TRCD_CYCLES);
                if (read_skew >= 0) begin
                    pipe_v[0] <= 1'b1;
                    pipe_d[0] <= mem[cur_addr];
                end
                else begin
                    // fault injection: bypass the staging register entirely so
                    // DQ is valid one clock too early (effective CL1).  These
                    // assignments come after the default ones above, so they win.
                    dq_drv <= 1'b1;
                    dq_reg <= mem[cur_addr];
                end
                if (verbose)
                    $display("[%0t] SDRAM READ b%0d row %0d col %0d -> %04x%s",
                             $time, ba, bank_row[ba], col_in, mem[cur_addr],
                             auto_pre ? " (AP)" : "");
                if (auto_pre) begin
                    bank_active[ba] <= 1'b0;
                    act_age[ba]     <= 0;
                end
            end

            C_WRITE: begin
                if (strict && !bank_active[ba])
                    $fatal(1, "ssv_sdram_chip: WRITE to bank %0d with no open row (col %0d)",
                           ba, col_in);
                if (strict && bank_active[ba] && (act_age[ba] + 1) < TRCD_CYCLES)
                    $fatal(1, "ssv_sdram_chip: tRCD violation, WRITE %0d clk after ACT (need %0d)",
                           act_age[ba] + 1, TRCD_CYCLES);
                // SDR: write data and byte masks are coincident with the
                // WRITE command, so sample DQ/DQM on this very edge.
                mem[cur_addr] <= {
                    dqmh ? mem[cur_addr][15:8] : SDRAM_DQ[15:8],
                    dqml ? mem[cur_addr][ 7:0] : SDRAM_DQ[ 7:0]
                };
                if (verbose)
                    $display("[%0t] SDRAM WR   b%0d row %0d col %0d <- %04x dqm=%b%b%s",
                             $time, ba, bank_row[ba], col_in, SDRAM_DQ, dqmh, dqml,
                             auto_pre ? " (AP)" : "");
                if (auto_pre) begin
                    bank_active[ba] <= 1'b0;
                    act_age[ba]     <= 0;
                end
            end

            C_PRE: begin
                if (addr[10]) begin
                    for (si = 0; si < 4; si = si + 1) bank_active[si] <= 1'b0;
                    if (verbose) $display("[%0t] SDRAM PRE-ALL", $time);
                end
                else begin
                    bank_active[ba] <= 1'b0;
                    if (verbose) $display("[%0t] SDRAM PRE  b%0d", $time, ba);
                end
            end

            C_REF: begin
                // auto-refresh: functionally a no-op for a model that never
                // loses data.  Refresh interval is deliberately NOT policed.
                if (verbose) $display("[%0t] SDRAM REF", $time);
            end

            C_BST: /* burst terminate: BL1, nothing in flight to stop */ ;
            C_NOP: ;
            default: ;
            endcase
        end
    end
end

endmodule
