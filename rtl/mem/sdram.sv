//============================================================================
//  Sega System 32 for MiSTer — SDRAM controller
//  16-bit SDR SDRAM @ clk_ram (96.6 MHz), CL2, strictly serialized single
//  transactions with auto-precharge (no bank interleave).
//  Six request ports with bounded round-robin arbitration (DESIGN.md §4.2):
//    p0: V60 fetch/data (latency critical, 16-bit single)
//    p1: tile fetch      (64-bit burst = 4 words)
//    p2: sprite fetch    (128-bit burst = 8 words)
//    p3: Z80 ROM         (16-bit single, byte laned)
//    p4: MultiPCM        (16-bit single)
//    p5: V25 program ROM  (64-bit burst = 4 words)
//  Write port (ROM download only): highest priority while ioctl_download.
//
//  REQUEST CONTRACT (all ports, including wr): one transaction per req
//  RISING EDGE; the address (and write data/be) is sampled on that edge.
//  A request held high is serviced exactly ONCE — a requester expecting
//  re-service per ack from a held level will hang.  Requesters must be
//  single-outstanding: drop req after (or pulse it before) each ack, and
//  produce a fresh rising edge for the next transaction.  ack is stretched
//  to 2 clk_ram cycles so clk_sys-domain requesters sample it exactly once.
//============================================================================

`timescale 1ns/1ps

module sdram #(
    // SDRAM geometry. The DE10-Nano exposes SDRAM_A[12:0] and SDRAM_BA[1:0],
    // so the row address caps at 13 bits and capacity is set by the column
    // count:
    //   2 + 13 +  9 = 24 bit word address ->  32 MB (4 x 8192 x  512)
    //   2 + 13 + 10 = 25                  ->  64 MB (4 x 8192 x 1024)
    //   2 + 13 + 11 = 26                  -> 128 MB (4 x 8192 x 2048)
    // 128 MB is the only decomposition reachable for a 64M x 16 part: 8 banks
    // would need BA[2] and 16384 rows would need A[13], neither of which is
    // routed. The 11th column bit therefore rides on A11, since A10 is
    // auto-precharge (JEDEC).
    parameter int BANK_BITS = 2,
    parameter int ROW_BITS  = 13,
    parameter int COL_BITS  = 9,
    // tRFC in clk_ram cycles, minus one (loaded into refw_cnt; the machine
    // waits TRFC_CYC+1). The previous hardcoded 3'd6 gave 7 cycles = 72 ns,
    // fine for a 256 Mbit part and NOT fine for a 1 Gbit one, and refw_cnt was
    // 3 bits so it could not even express the larger value.
    //
    // TRFC_CYC = 11 -> 12 cycles = 124.2 ns at 96.648 MHz, which covers the
    // 110 ns typical of 1 Gbit SDR SDRAM and the 120 ns some parts specify.
    // Chosen to be safe for any plausible part rather than tuned to one, since
    // over-waiting costs a fraction of a percent of the bus and under-waiting
    // is silent bit rot.
    parameter int TRFC_CYC  = 6,
    // Refresh interval, in clk_ram cycles.
    //
    // THE ROW COUNT IS NOT A FREE VARIABLE, which is what makes this provably
    // safe without a datasheet. Only SDRAM_A[12:0] and SDRAM_BA[1:0] are
    // routed on the DE10-Nano, so a 128 MB part is reachable ONLY as
    // 4 banks x 8192 rows x 2048 columns:
    //   8 banks x 8192 x 1024 would need BA[2] -- not routed
    //   4 banks x 16384 x 1024 would need A[13] -- not routed
    // So the part has 8192 rows and must be fully refreshed every 64 ms, i.e.
    // one REF command every 7.8125 us.
    //
    // REF_CYC = 700 -> 7.2428 us, a 7.3% margin. Refresh then costs about 2%
    // of the bus (12 tRFC cycles plus ~2 for the PRE-all, per 700).
    parameter int REF_CYC   = 700
) (
    input             clk,          // clk_ram
    input             init,         // reset/init request
    output reg        ready,

    // SDRAM chip interface
    inout      [15:0] SDRAM_DQ,
    output reg [12:0] SDRAM_A,
    output reg  [1:0] SDRAM_BA,
    output            SDRAM_DQML,
    output            SDRAM_DQMH,
    output reg        SDRAM_nCS,
    output reg        SDRAM_nCAS,
    output reg        SDRAM_nRAS,
    output reg        SDRAM_nWE,
    output            SDRAM_CKE,

    // download/write port (word writes, ROM load)
    input             wr_req,
    input      [AW:1] wr_addr,
    input      [15:0] wr_din,
    input       [1:0] wr_be,
    output reg        wr_ack,

    // p0: V60
    input             p0_req,
    input      [AW:1] p0_addr,
    output reg [15:0] p0_dout,
    output reg        p0_ack,

    // p1: tiles — 4-word burst, aligned to 8 bytes
    input             p1_req,
    input      [AW:3] p1_addr,
    output reg [63:0] p1_dout,
    output reg        p1_ack,

    // p2: sprites — 8-word burst, aligned to 16 bytes
    input             p2_req,
    input      [AW:4] p2_addr,
    output reg [127:0] p2_dout,
    output reg        p2_ack,

    // p3: Z80
    input             p3_req,
    input      [AW:1] p3_addr,
    output reg [15:0] p3_dout,
    output reg        p3_ack,

    // p4: MultiPCM
    input             p4_req,
    input      [AW:1] p4_addr,
    output reg [15:0] p4_dout,
    output reg        p4_ack,

    // p5: V25 program ROM - 4-word burst, aligned to 8 bytes
    input             p5_req,
    input      [AW:3] p5_addr,
    output reg [63:0] p5_dout,
    output reg        p5_ack
);

// Derived address field positions. Everything below slices with these rather
// than with literal bit numbers, so a geometry change cannot leave one stale
// slice behind -- which is exactly how a silent address aliasing bug gets in.
localparam int AW      = BANK_BITS + ROW_BITS + COL_BITS;
localparam int COL_HI  = COL_BITS;
localparam int ROW_LO  = COL_BITS + 1;
localparam int ROW_HI  = COL_BITS + ROW_BITS;
localparam int BANK_LO = ROW_HI + 1;
localparam int BANK_HI = AW;

reg [15:0] dq_out;
reg        dq_oe;
reg  [1:0] dqm;

assign SDRAM_CKE  = 1'b1;
assign SDRAM_DQML = dqm[0];
assign SDRAM_DQMH = dqm[1];

localparam BURST_1   = 3'b000;
localparam CL        = 3'd2;

// commands {nCS,nRAS,nCAS,nWE}
localparam CMD_NOP   = 4'b0111;
localparam CMD_ACT   = 4'b0011;
localparam CMD_READ  = 4'b0101;
localparam CMD_WRITE = 4'b0100;
localparam CMD_PRE   = 4'b0010;
localparam CMD_REF   = 4'b0001;
localparam CMD_MRS   = 4'b0000;

reg  [3:0] cmd = CMD_NOP;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

assign SDRAM_DQ = dq_oe ? dq_out : 16'hZZZZ;

// init sequencer
reg [15:0] init_cnt = 16'hffff;
wire       init_done = (init_cnt == 0);

// refresh: 8192 rows / 64 ms @96.6MHz -> every ~755 cycles
reg [9:0]  ref_cnt;
reg        ref_pend;

typedef enum logic [3:0] {
    ST_IDLE, ST_ACT, ST_RCD1, ST_RCD2, ST_RD, ST_RDW, ST_WR, ST_WRRC,
    ST_PRE_REF, ST_REF, ST_REFW,
    ST_PRE_BANK, ST_PRE_WAIT
} state_t;
state_t state = ST_IDLE;

// Open-row tracking.
//
// Previously every transaction was ACT -> tRCD -> READ -> auto-precharge, so a
// 4-word graphics fetch cost 12 clocks to move 4 words. Measured against the
// scanline budget that was 63% of memory bandwidth for graphics alone, and the
// renderer missed thousands of line deadlines per second on hardware: drifting
// horizontal corruption bands, and starved ES5506 sample fetches heard as
// pitch-dropped audio.
//
// Reads now leave their row open and a later read into the same row skips
// ACT + tRCD. A row holds 512 words while consecutive graphics fetches along a
// scanline are 32 words apart, so the common case is a hit.
//
// Writes are excluded on purpose and keep auto-precharging: write recovery is
// where a mistake corrupts memory instead of merely costing time, and writes
// are rare outside ROM download.
reg  [3:0] row_open;            // per bank: a row is open
reg [ROW_BITS-1:0] open_row [0:3];      // and which one
reg  [1:0] prew_cnt;

reg [2:0]  grant;
reg [2:0]  rr_next;
reg [3:0]  rd_total;        // words to read (1/4/8)
reg [3:0]  rd_issued;
reg [3:0]  rd_captured;
reg [AW:1] xfer_addr;
reg        is_write;
reg [15:0] din_r;
reg [1:0]  be_r;
reg [2:0]  wrrc_cnt;
reg [3:0]  refw_cnt;
reg [1:0]  ack_stretch;     // acks held 2 clk_ram cycles (clk_sys is /2 sync)

reg [15:0] din_pipe_d1, din_pipe_d2;   // unused placeholder (kept for clarity)

// Request mailboxes.  Capture every transaction's metadata with its request;
// arbitration may delay a lower-priority port long after the producer pulses
// req or moves on to its next address.  This mirrors the latched per-slot
// request interfaces used by mature MiSTer SDRAM frameworks.
reg p0_pend, p1_pend, p2_pend, p3_pend, p4_pend, p5_pend, wr_pend;
reg [AW:1] p0_addr_p, p3_addr_p, p4_addr_p, wr_addr_p;
reg [AW:3] p1_addr_p;
reg [AW:3] p5_addr_p;
reg [AW:4] p2_addr_p;
reg [15:0] wr_din_p;
reg  [1:0] wr_be_p;

// Reads rotate after every grant.  This prevents continuous V60 cache misses
// from starving sprite/audio traffic while retaining the download write port
// as the sole highest-priority client (game logic is held reset during it).
reg       read_valid;
reg [2:0] read_grant;
always @* begin
    read_valid = 1'b1;
    read_grant = rr_next;
    // Round-robin is kept deliberately. Giving the graphics fetch strict
    // priority was measured and removed: it cut gameplay line-deadline misses
    // by only 10% (22847 -> 20437), because the renderer is not waiting on
    // arbitration. Per-line budget on a missed line is ~2490 cycles of which
    // plotting is ~1720 and waiting for SDRAM only ~127, so queueing delay is
    // not the constraint and a priority scheme only starves the CPU for nothing.
    case (rr_next)
        3'd0: if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else read_valid=0;
        3'd1: if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else read_valid=0;
        3'd2: if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else read_valid=0;
        3'd3: if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else read_valid=0;
        3'd4: if (p4_pend) read_grant=4; else if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else read_valid=0;
        default: if (p5_pend) read_grant=5; else if (p0_pend) read_grant=0; else if (p1_pend) read_grant=1; else if (p2_pend) read_grant=2; else if (p3_pend) read_grant=3; else if (p4_pend) read_grant=4; else read_valid=0;
    endcase
end

// Row-hit is evaluated per port, in parallel with arbitration, and only the
// single-bit result is muxed by the grant. Doing it the other way round --
// mux the address first, then index open_row and compare 13 bits -- put a
// lookup and a wide comparator downstream of the priority mux and cost 137 ps,
// which this design does not have (it closes at well under 0.5 ns). Comparing
// first and selecting after keeps the grant path a 6:1 mux of one bit.
//
// Placed after the request mailboxes and read_grant rather than before them,
// which is where it used to sit: it reads both, and a use-before-declaration
// is only legal by the implicit-net rule. Pure reordering of declarations --
// grant_row_hit has exactly one consumer, far below, and no logic changed.
function automatic logic row_hit(input logic [1:0] bank,
                                input logic [ROW_BITS-1:0] row);
    row_hit = row_open[bank] && (open_row[bank] == row);
endfunction

// p1/p2/p5 are declared narrower than [AW:1] (their bursts are 8- and 16-byte
// aligned), so slicing them with [BANK_HI:BANK_LO] / [ROW_HI:ROW_LO] directly
// would be reading bit numbers that mean something different in a narrower
// vector. Build the full-width view first -- the same expression ST_IDLE
// already forms when it loads xfer_addr -- and slice only that.
wire [AW:1] p1_view = {p1_addr_p, 2'b00};
wire [AW:1] p2_view = {p2_addr_p, 3'b000};
wire [AW:1] p5_view = {p5_addr_p, 2'b00};

wire hit_p0 = row_hit(p0_addr_p[BANK_HI:BANK_LO], p0_addr_p[ROW_HI:ROW_LO]);
wire hit_p1 = row_hit(p1_view[BANK_HI:BANK_LO],   p1_view[ROW_HI:ROW_LO]);
wire hit_p2 = row_hit(p2_view[BANK_HI:BANK_LO],   p2_view[ROW_HI:ROW_LO]);
wire hit_p3 = row_hit(p3_addr_p[BANK_HI:BANK_LO], p3_addr_p[ROW_HI:ROW_LO]);
wire hit_p4 = row_hit(p4_addr_p[BANK_HI:BANK_LO], p4_addr_p[ROW_HI:ROW_LO]);
wire hit_p5 = row_hit(p5_view[BANK_HI:BANK_LO],   p5_view[ROW_HI:ROW_LO]);

logic grant_row_hit;
always @* begin
    case (read_grant)
        3'd0:    grant_row_hit = hit_p0;
        3'd1:    grant_row_hit = hit_p1;
        3'd2:    grant_row_hit = hit_p2;
        3'd3:    grant_row_hit = hit_p3;
        3'd4:    grant_row_hit = hit_p4;
        default: grant_row_hit = hit_p5;
    endcase
end

// Latch each port on the RISING EDGE of its request.  The previous
// level-sampled guard (req && !pend && !ack) had a one-clk_ram drop window: a
// requester that pulses its next request in direct response to an ack (the V60
// icache fill chain does) can present a 2-cycle pulse whose first cycle is
// blocked by the still-clearing pend and whose second is blocked by the
// stretched ack — the transaction vanished and the port hung forever.  Which
// transactions hit the window depended on each ack's clk_ram parity, i.e. on
// arbitration history — so adding V25 p5 traffic could sink the V60 while
// lighter boards never faulted.  Edge-detection latches exactly once per
// request pulse (or per level-request start: the loader holds wr_req until
// wr_ack) regardless of ack overlap.
reg p0_req_d, p1_req_d, p2_req_d, p3_req_d, p4_req_d, p5_req_d, wr_req_d;
reg p0_ack_d2, p1_ack_d2, p2_ack_d2, p3_ack_d2, p4_ack_d2, p5_ack_d2, wr_ack_d2;
always @(posedge clk) begin
    // Completion clears pend on the ack RISING EDGE only, and FIRST, so a
    // same-edge new request edge below overrides it (the later nonblocking
    // assignment wins).  Two hazards are closed together: (1) a chained
    // request whose rising edge lands on the very edge the previous ack
    // clears pend — the V60 icache fill pattern — latches instead of
    // vanishing; (2) the 2-cycle ack stretch must not wipe a request that
    // latched during the stretch window on the stretch's second cycle.
    p0_ack_d2 <= p0_ack; p1_ack_d2 <= p1_ack; p2_ack_d2 <= p2_ack;
    p3_ack_d2 <= p3_ack; p4_ack_d2 <= p4_ack; p5_ack_d2 <= p5_ack;
    wr_ack_d2 <= wr_ack;
    if (p0_ack && !p0_ack_d2) p0_pend <= 1'b0;
    if (p1_ack && !p1_ack_d2) p1_pend <= 1'b0;
    if (p2_ack && !p2_ack_d2) p2_pend <= 1'b0;
    if (p3_ack && !p3_ack_d2) p3_pend <= 1'b0;
    if (p4_ack && !p4_ack_d2) p4_pend <= 1'b0;
    if (p5_ack && !p5_ack_d2) p5_pend <= 1'b0;
    if (wr_ack && !wr_ack_d2) wr_pend <= 1'b0;
    p0_req_d <= p0_req; p1_req_d <= p1_req; p2_req_d <= p2_req;
    p3_req_d <= p3_req; p4_req_d <= p4_req; p5_req_d <= p5_req;
    wr_req_d <= wr_req;
    // Every s32 requester keeps at most one transaction outstanding (pulse, or
    // level held until ack), so an unqualified rising-edge latch is exact.
    if (p0_req && !p0_req_d) begin
        p0_pend <= 1'b1; p0_addr_p <= p0_addr;
    end
    if (p1_req && !p1_req_d) begin
        p1_pend <= 1'b1; p1_addr_p <= p1_addr;
    end
    if (p2_req && !p2_req_d) begin
        p2_pend <= 1'b1; p2_addr_p <= p2_addr;
    end
    if (p3_req && !p3_req_d) begin
        p3_pend <= 1'b1; p3_addr_p <= p3_addr;
    end
    if (p4_req && !p4_req_d) begin
        p4_pend <= 1'b1; p4_addr_p <= p4_addr;
    end
    if (p5_req && !p5_req_d) begin
        p5_pend <= 1'b1; p5_addr_p <= p5_addr;
    end
    if (wr_req && !wr_req_d) begin
        wr_pend <= 1'b1; wr_addr_p <= wr_addr;
        wr_din_p <= wr_din; wr_be_p <= wr_be;
    end
    if (init) begin
        {p0_pend,p1_pend,p2_pend,p3_pend,p4_pend,p5_pend,wr_pend} <= '0;
        {p0_req_d,p1_req_d,p2_req_d,p3_req_d,p4_req_d,p5_req_d,wr_req_d} <= '0;
        {p0_ack_d2,p1_ack_d2,p2_ack_d2,p3_ack_d2,p4_ack_d2,p5_ack_d2,wr_ack_d2} <= '0;
        p0_addr_p <= '0; p1_addr_p <= '0; p2_addr_p <= '0;
        p3_addr_p <= '0; p4_addr_p <= '0; p5_addr_p <= '0; wr_addr_p <= '0;
        wr_din_p <= '0; wr_be_p <= '0;
    end
end

`ifdef SIMULATION
// Contract watchdog (sim only): a request held high long after its pend
// cleared means the requester expects per-ack re-service from a level — the
// pre-edge-latch semantics.  It would receive exactly one transaction and
// hang silently in hardware; make that loud here.  Legitimate level holds
// drop within a few clk_ram of the stretched ack (clk_sys requesters take 2).
generate
    genvar gi;
    for (gi = 0; gi < 7; gi = gi + 1) begin : g_reqwatch
        reg [7:0] held;
        wire req_i  = gi==0 ? p0_req  : gi==1 ? p1_req  : gi==2 ? p2_req  :
                      gi==3 ? p3_req  : gi==4 ? p4_req  : gi==5 ? p5_req  : wr_req;
        wire pend_i = gi==0 ? p0_pend : gi==1 ? p1_pend : gi==2 ? p2_pend :
                      gi==3 ? p3_pend : gi==4 ? p4_pend : gi==5 ? p5_pend : wr_pend;
        always @(posedge clk) begin
            if (init || !req_i || pend_i) held <= 8'd0;
            else if (held != 8'hff) begin
                held <= held + 8'd1;
                if (held == 8'd200)
                    $display("SDRAM CONTRACT WARNING: port %0d req held %0d cycles after service — held levels are serviced once, not per ack", gi, held);
            end
        end
    end
endgenerate

// ---------------------------------------------------------------------------
// Phase 0 instrumentation (C1 row conflicts, C2 service latency).
//
// Simulation only, so there is no synthesis impact and no `.qsf`/timing risk.
//
// Everything is sampled off the controller's OWN state transitions rather than
// re-derived from the port addresses, because a re-derivation can disagree with
// the machine it is supposed to be measuring and then the measurement is worse
// than none.  The three exits from ST_IDLE are exhaustive and mutually
// exclusive (sdram.sv ST_IDLE row-hit path):
//
//   ST_IDLE -> ST_RD        the row was already open        -> row HIT
//   ST_IDLE -> ST_ACT       the bank was closed             -> cold MISS
//   ST_IDLE -> ST_PRE_BANK  the WRONG row was open          -> CONFLICT
//
// Only the third costs the extra PRE + tRP + ACT + tRCD, and only the third
// is attributable to another port -- so conflicts are recorded as
// [evictor][victim], where the evictor is whichever port last ACTivated that
// bank.  That attribution is the number Phase 2 is gated on: if
// (p0 -> p2) and (p4 -> p2) are small, region-to-bank isolation is not worth
// doing and the plan says to drop it.
//
// Port indices are 0..5 = p0..p5 and 6 = the write port (grant 3'd7 remaps to
// 6; grant is never 6, so there is no collision).
// ---------------------------------------------------------------------------
localparam int SDR_NPORT = 7;
localparam int SDR_WRI   = 6;   // write-port stats index
localparam int SDR_UNK   = 7;   // "no recorded evictor" row in the matrix

integer   sdr_row_hit   [0:SDR_NPORT-1];
integer   sdr_row_miss  [0:SDR_NPORT-1];
integer   sdr_conflict  [0:SDR_NPORT][0:SDR_NPORT-1];  // [evictor][victim]
integer   sdr_conflict_total;
integer   sdr_refresh_count;

reg [2:0] sdr_row_owner       [0:3];
reg       sdr_row_owner_valid [0:3];

longint   sdr_now;
longint   sdr_lat_sum  [0:SDR_NPORT-1];
integer   sdr_lat_max  [0:SDR_NPORT-1];
integer   sdr_lat_cnt  [0:SDR_NPORT-1];
integer   sdr_lat_hist [0:SDR_NPORT-1][0:15];
longint   sdr_req_t    [0:SDR_NPORT-1];
reg       sdr_lat_busy [0:SDR_NPORT-1];

// grant carries 3'd7 for the write port; fold it into index 6.
wire [2:0] sdr_gi = (grant == 3'd7) ? 3'd6 : grant;
state_t    sdr_state_d;

integer sdr_i, sdr_j;
initial begin
    sdr_now            = 0;
    sdr_conflict_total = 0;
    sdr_refresh_count  = 0;
    for (sdr_i = 0; sdr_i < SDR_NPORT; sdr_i = sdr_i + 1) begin
        sdr_row_hit[sdr_i]  = 0;
        sdr_row_miss[sdr_i] = 0;
        sdr_lat_sum[sdr_i]  = 0;
        sdr_lat_max[sdr_i]  = 0;
        sdr_lat_cnt[sdr_i]  = 0;
        sdr_req_t[sdr_i]    = 0;
        sdr_lat_busy[sdr_i] = 1'b0;
        for (sdr_j = 0; sdr_j < 16; sdr_j = sdr_j + 1)
            sdr_lat_hist[sdr_i][sdr_j] = 0;
    end
    for (sdr_i = 0; sdr_i <= SDR_NPORT; sdr_i = sdr_i + 1)
        for (sdr_j = 0; sdr_j < SDR_NPORT; sdr_j = sdr_j + 1)
            sdr_conflict[sdr_i][sdr_j] = 0;
    for (sdr_i = 0; sdr_i < 4; sdr_i = sdr_i + 1) begin
        sdr_row_owner[sdr_i]       = 3'd0;
        sdr_row_owner_valid[sdr_i] = 1'b0;
    end
end

always @(posedge clk) begin
    sdr_now     <= sdr_now + 1;
    sdr_state_d <= state;

    if (init) begin
        // init's PRE-all closes every bank, exactly as row_open does above.
        for (sdr_i = 0; sdr_i < 4; sdr_i = sdr_i + 1)
            sdr_row_owner_valid[sdr_i] <= 1'b0;
    end else if (init_done) begin
        // --- C1: classify each transaction by how it left ST_IDLE ---
        if (sdr_state_d == ST_IDLE) begin
            case (state)
            ST_RD: sdr_row_hit[sdr_gi] <= sdr_row_hit[sdr_gi] + 1;
            ST_ACT: sdr_row_miss[sdr_gi] <= sdr_row_miss[sdr_gi] + 1;
            ST_PRE_BANK: begin
                // A wrong-row eviction. Attribute it to whoever opened it.
                sdr_row_miss[sdr_gi] <= sdr_row_miss[sdr_gi] + 1;
                sdr_conflict_total   <= sdr_conflict_total + 1;
                if (sdr_row_owner_valid[xfer_addr[BANK_HI:BANK_LO]])
                    sdr_conflict[sdr_row_owner[xfer_addr[BANK_HI:BANK_LO]]][sdr_gi] <=
                        sdr_conflict[sdr_row_owner[xfer_addr[BANK_HI:BANK_LO]]][sdr_gi] + 1;
                else
                    sdr_conflict[SDR_UNK][sdr_gi] <=
                        sdr_conflict[SDR_UNK][sdr_gi] + 1;
            end
            default: ;
            endcase
        end

        // Record the owner as the row is actually activated. A write clears
        // row_open again in ST_WR (auto-precharge), so drop ownership there
        // or the next conflict is blamed on a row that is no longer open.
        if (state == ST_ACT) begin
            sdr_row_owner[xfer_addr[BANK_HI:BANK_LO]]       <= sdr_gi;
            sdr_row_owner_valid[xfer_addr[BANK_HI:BANK_LO]] <= 1'b1;
        end
        if (state == ST_WR)
            sdr_row_owner_valid[xfer_addr[BANK_HI:BANK_LO]] <= 1'b0;

        // Refresh PRE-alls close every bank (see ST_IDLE refresh path).
        if (state == ST_PRE_REF && sdr_state_d != ST_PRE_REF) begin
            sdr_refresh_count <= sdr_refresh_count + 1;
            for (sdr_i = 0; sdr_i < 4; sdr_i = sdr_i + 1)
                sdr_row_owner_valid[sdr_i] <= 1'b0;
        end
    end
end

// --- C2: per-port req-rise -> ack-rise service latency, in clk_ram ---
//
// This is the number that matters to the renderer: it includes arbitration
// queueing and the ack stretch, not just the chip transaction. The histogram
// is 16 buckets of 4 cycles, saturating, so a long tail is visible as a
// non-zero top bucket rather than being averaged away.
generate
    genvar gl;
    for (gl = 0; gl < SDR_NPORT; gl = gl + 1) begin : g_latwatch
        wire lreq = gl==0 ? p0_req : gl==1 ? p1_req : gl==2 ? p2_req :
                    gl==3 ? p3_req : gl==4 ? p4_req : gl==5 ? p5_req : wr_req;
        wire lreq_d = gl==0 ? p0_req_d : gl==1 ? p1_req_d : gl==2 ? p2_req_d :
                      gl==3 ? p3_req_d : gl==4 ? p4_req_d : gl==5 ? p5_req_d :
                      wr_req_d;
        wire lack = gl==0 ? p0_ack : gl==1 ? p1_ack : gl==2 ? p2_ack :
                    gl==3 ? p3_ack : gl==4 ? p4_ack : gl==5 ? p5_ack : wr_ack;
        wire lack_d = gl==0 ? p0_ack_d2 : gl==1 ? p1_ack_d2 : gl==2 ? p2_ack_d2 :
                      gl==3 ? p3_ack_d2 : gl==4 ? p4_ack_d2 : gl==5 ? p5_ack_d2 :
                      wr_ack_d2;
        always @(posedge clk) begin
            automatic int ldelta;
            automatic int lbucket;
            if (init) begin
                sdr_lat_busy[gl] <= 1'b0;
            end else begin
                // Latch the request edge. Ports are single-outstanding by
                // contract (see REQUEST CONTRACT above), so one timestamp is
                // exact; the watchdog above is what catches a violator.
                if (lreq && !lreq_d) begin
                    sdr_req_t[gl]    <= sdr_now;
                    sdr_lat_busy[gl] <= 1'b1;
                end
                if (lack && !lack_d && sdr_lat_busy[gl]) begin
                    sdr_lat_busy[gl] <= 1'b0;
                    ldelta  = int'(sdr_now - sdr_req_t[gl]);
                    lbucket = ldelta >> 2;
                    if (lbucket > 15) lbucket = 15;
                    sdr_lat_hist[gl][lbucket] <= sdr_lat_hist[gl][lbucket] + 1;
                    sdr_lat_sum[gl] <= sdr_lat_sum[gl] + longint'(ldelta);
                    sdr_lat_cnt[gl] <= sdr_lat_cnt[gl] + 1;
                    if (ldelta > sdr_lat_max[gl]) sdr_lat_max[gl] <= ldelta;
                end
            end
        end
    end
endgenerate

// Called by the testbench at end of run. Nothing is printed unless asked for,
// so existing gates keep their exact output.
task automatic sdram_dump_stats(input string tag);
    integer i, j, tot;
    begin
        $display("=== SDRAM STATS %s ===", tag);
        $display("SDRAM_REFRESH count=%0d", sdr_refresh_count);
        $display("SDRAM_ROWS port     hits     misses   hit%%");
        for (i = 0; i < SDR_NPORT; i = i + 1) begin
            tot = sdr_row_hit[i] + sdr_row_miss[i];
            if (tot != 0)
                $display("SDRAM_ROWS %-4s %8d %8d %6.2f",
                         (i == SDR_WRI) ? "wr" : $sformatf("p%0d", i),
                         sdr_row_hit[i], sdr_row_miss[i],
                         100.0 * real'(sdr_row_hit[i]) / real'(tot));
        end
        $display("SDRAM_CONFLICT total=%0d  (rows=evictor, cols=victim)",
                 sdr_conflict_total);
        for (i = 0; i <= SDR_NPORT; i = i + 1) begin
            tot = 0;
            for (j = 0; j < SDR_NPORT; j = j + 1) tot = tot + sdr_conflict[i][j];
            if (tot != 0)
                $display("SDRAM_CONFLICT %-4s -> p0=%0d p1=%0d p2=%0d p3=%0d p4=%0d p5=%0d wr=%0d",
                         (i == SDR_UNK) ? "none" :
                         (i == SDR_WRI) ? "wr" : $sformatf("p%0d", i),
                         sdr_conflict[i][0], sdr_conflict[i][1],
                         sdr_conflict[i][2], sdr_conflict[i][3],
                         sdr_conflict[i][4], sdr_conflict[i][5],
                         sdr_conflict[i][6]);
        end
        $display("SDRAM_LAT port     count      avg    max  (clk_ram, req->ack)");
        for (i = 0; i < SDR_NPORT; i = i + 1)
            if (sdr_lat_cnt[i] != 0)
                $display("SDRAM_LAT %-4s %9d %8.2f %6d",
                         (i == SDR_WRI) ? "wr" : $sformatf("p%0d", i),
                         sdr_lat_cnt[i],
                         real'(sdr_lat_sum[i]) / real'(sdr_lat_cnt[i]),
                         sdr_lat_max[i]);
        for (i = 0; i < SDR_NPORT; i = i + 1) begin
            if (sdr_lat_cnt[i] == 0) continue;
            $write("SDRAM_LAT_HIST %-4s",
                   (i == SDR_WRI) ? "wr" : $sformatf("p%0d", i));
            for (j = 0; j < 16; j = j + 1) $write(" %0d", sdr_lat_hist[i][j]);
            $write("\n");
        end
    end
endtask
`endif

// Centre the SDRAM board interface with SDRAM_CLK forwarded at 180 degrees.
// Commands and write data launched here have half a cycle of setup at the
// chip. CL2 read data returns to this direct pin-to-register sample under the
// SDC input-delay and multicycle constraints, so Quartus can place dq_in in
// the input IOE. The fourth pipe tap transfers the already-registered word
// into the response buffer one cycle later without a pin-to-core critical path.
// CAS address field. A[9:0] carry column bits 0..9 (the upper ones are
// don't-cares on a part with fewer than 10 column bits, which is why the 32 MB
// build could drive them freely), A[10] is auto-precharge, and A[11] carries
// the 11th column bit on a 2048-column (128 MB) part. A[12] is unused during
// CAS on every geometry here.
function automatic logic [12:0] cas_addr(input logic [AW:1] a, input logic ap);
    cas_addr = {1'b0, (COL_BITS >= 11) ? a[11] : 1'b0, ap, a[10:1]};
endfunction

reg [15:0] dq_in;
reg [3:0]  cl_pipe;
reg [15:0] cap_buf [0:7];

always @(posedge clk) dq_in <= SDRAM_DQ;

task automatic deliver(input [15:0] final_word);
    case (grant)
        // The final buffer write and delivery share an edge.  Use the staged
        // word directly for the last lane instead of returning stale cap_buf.
        3'd0: begin p0_dout <= final_word; p0_ack <= 1'b1; end
        3'd1: begin p1_dout <= {final_word, cap_buf[2], cap_buf[1], cap_buf[0]}; p1_ack <= 1'b1; end
        3'd2: begin p2_dout <= {final_word, cap_buf[6], cap_buf[5], cap_buf[4],
                                cap_buf[3], cap_buf[2], cap_buf[1], cap_buf[0]}; p2_ack <= 1'b1; end
        3'd3: begin p3_dout <= final_word; p3_ack <= 1'b1; end
        3'd4: begin p4_dout <= final_word; p4_ack <= 1'b1; end
        3'd5: begin p5_dout <= {final_word, cap_buf[2], cap_buf[1], cap_buf[0]}; p5_ack <= 1'b1; end
        default: ;
    endcase
endtask

always @(posedge clk) begin
    cmd    <= CMD_NOP;
    dq_oe  <= 1'b0;

    // acks: assert for 2 cycles so clk_sys (=clk/2, synchronous) always
    // samples exactly one rising edge with ack high
    if (ack_stretch != 0) ack_stretch <= ack_stretch - 1'd1;
    else begin
        p0_ack <= 1'b0; p1_ack <= 1'b0; p2_ack <= 1'b0;
        p3_ack <= 1'b0; p4_ack <= 1'b0; p5_ack <= 1'b0; wr_ack <= 1'b0;
    end

    if (init) begin
        init_cnt <= 16'hffff;
        ready    <= 1'b0;
        state    <= ST_IDLE;
        ref_pend <= 1'b0;
        ref_cnt  <= 10'd0;
        dqm      <= 2'b11;
        row_open <= 4'd0;   // init's PRE-all leaves every bank closed
        cl_pipe  <= 4'b0000;
        ack_stretch <= 0;
        rr_next <= 3'd0;
    end
    else if (!init_done) begin
        init_cnt <= init_cnt - 1'd1;
        dqm      <= 2'b11;
        // init: wait >100us, PRE-all, 8x REF, MRS (JEDEC)
        case (init_cnt)
            16'h0400: begin cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1; end
            16'h03c0, 16'h0380, 16'h0340, 16'h0300,
            16'h02c0, 16'h0280, 16'h0240, 16'h0200: cmd <= CMD_REF;
            16'h00a0: begin
                cmd      <= CMD_MRS;
                SDRAM_BA <= 2'b00;
                SDRAM_A  <= 13'b000_0_00_010_0_000; // CL2, sequential, burst 1
            end
            16'h0001: ready <= 1'b1;
            default: ;
        endcase
    end
    else begin
        dqm <= 2'b00;
        // refresh scheduling: 8192 rows / 64ms @ 96.65MHz -> every 755 cyc
        ref_cnt <= ref_cnt + 1'd1;
        if (ref_cnt == REF_CYC[9:0]) begin ref_cnt <= 0; ref_pend <= 1'b1; end

        // Read capture after CL2 and the centred IOE register above.
        cl_pipe <= {cl_pipe[2:0], 1'b0};
        if (cl_pipe[3]) begin
            cap_buf[rd_captured[2:0]] <= dq_in;
            rd_captured <= rd_captured + 1'd1;
            if (rd_captured + 1'd1 == rd_total) begin
                deliver(dq_in);
                ack_stretch <= 2'd1;   // hold ack this cycle + next
            end
        end

        case (state)
        ST_IDLE: begin
            if (ref_pend && cl_pipe == 0) begin
                cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1;
                refw_cnt <= 4'd1;             // tRP >= 2 cycles before REF
                row_open <= 4'd0;             // PRE-all closes every bank
                state <= ST_PRE_REF;
            end
            else if (wr_pend | read_valid) begin
                logic [AW:1] a;
                logic        is_write_next;
                is_write_next = wr_pend;
                if      (wr_pend) begin grant <= 3'd7; a = wr_addr_p;           rd_total <= 4'd1; is_write <= 1'b1; end
                else begin
                    grant <= read_grant;
                    is_write <= 1'b0;
                    rr_next <= (read_grant == 3'd5) ? 3'd0 : read_grant + 1'd1;
                    case (read_grant)
                        3'd0: begin a = p0_addr_p;           rd_total <= 4'd1; end
                        3'd1: begin a = {p1_addr_p, 2'b00};  rd_total <= 4'd4; end
                        3'd2: begin a = {p2_addr_p, 3'b000}; rd_total <= 4'd8; end
                        3'd3: begin a = p3_addr_p;           rd_total <= 4'd1; end
                        3'd4: begin a = p4_addr_p;           rd_total <= 4'd1; end
                        default: begin a = {p5_addr_p, 2'b00}; rd_total <= 4'd4; end
                    endcase
                end
                xfer_addr <= a;
                din_r     <= wr_din_p;
                be_r      <= wr_be_p;
                rd_issued   <= 0;
                rd_captured <= 0;
                // Row-hit path. Reads leave their row open (see ST_RD), so a
                // transaction landing in an already-open row can skip
                // ACT + tRCD entirely -- 3 of the 8 overhead cycles. A row is
                // 512 words and consecutive graphics fetches along a scanline
                // are 32 words apart, so this hits almost every time.
                //
                // Writes are deliberately excluded: they still auto-precharge,
                // because write recovery (tDAL) is where getting this wrong
                // would corrupt memory rather than merely cost cycles, and
                // writes are rare outside ROM download.
                // Register the arbitration result before it drives the SDRAM
                // row-address pins.  Besides making the request mailbox a
                // clean transaction boundary, this removes the long
                // pending-request -> priority mux -> output-DDR path.
                if (!is_write_next && grant_row_hit)
                    state <= ST_RD;            // row already open: straight to CAS
                else if (row_open[a[BANK_HI:BANK_LO]])
                    state <= ST_PRE_BANK;      // wrong row open: close it first
                else
                    state <= ST_ACT;
            end
        end

        // Close a bank whose open row is not the one we need. Reachable only
        // after that bank's previous transaction has fully drained, which is
        // more than tRAS after its ACT, so no extra guard is needed here.
        ST_PRE_BANK: begin
            cmd      <= CMD_PRE;
            SDRAM_BA <= xfer_addr[BANK_HI:BANK_LO];
            SDRAM_A[10] <= 1'b0;               // single bank, not all
            row_open[xfer_addr[BANK_HI:BANK_LO]] <= 1'b0;
            prew_cnt <= 2'd1;                  // tRP >= 2 cycles before ACT
            state    <= ST_PRE_WAIT;
        end
        ST_PRE_WAIT: begin
            if (prew_cnt == 0) state <= ST_ACT;
            else prew_cnt <= prew_cnt - 1'd1;
        end

        ST_ACT: begin
            cmd      <= CMD_ACT;
            SDRAM_BA <= xfer_addr[BANK_HI:BANK_LO];
            SDRAM_A  <= 13'(xfer_addr[ROW_HI:ROW_LO]);
            // Remember what is open. A write clears this again in ST_WR,
            // because writes still auto-precharge.
            row_open[xfer_addr[BANK_HI:BANK_LO]] <= 1'b1;
            open_row[xfer_addr[BANK_HI:BANK_LO]] <= xfer_addr[ROW_HI:ROW_LO];
            state    <= ST_RCD1;
        end

        // tRCD >= 21ns = 3 cycles ACT->READ/WRITE
        ST_RCD1: state <= ST_RCD2;
        ST_RCD2: state <= is_write ? ST_WR : ST_RD;

        ST_WR: begin
            cmd      <= CMD_WRITE;
            SDRAM_BA <= xfer_addr[BANK_HI:BANK_LO];
            SDRAM_A  <= cas_addr(xfer_addr, 1'b1);       // A10 = auto-precharge
            // The write auto-precharges, so whatever ST_ACT just recorded for
            // this bank is no longer open.
            row_open[xfer_addr[BANK_HI:BANK_LO]] <= 1'b0;
            dq_out   <= din_r;
            dq_oe    <= 1'b1;
            dqm      <= ~be_r;
            wrrc_cnt <= 3'd4;   // tDAL ~= 42ns = 5 cycles before next ACT
            state    <= ST_WRRC;
        end
        ST_WRRC: begin
            if (wrrc_cnt == 3'd4) begin wr_ack <= 1'b1; ack_stretch <= 2'd1; end
            if (wrrc_cnt == 0) state <= ST_IDLE;
            else wrrc_cnt <= wrrc_cnt - 1'd1;
        end

        ST_RD: begin
            // issue one READ per cycle until rd_total issued.
            // A10 stays low: the row is left open so the next transaction into
            // it can skip ACT + tRCD. ST_PRE_BANK closes it on a row conflict
            // and the refresh path closes all four.
            cmd      <= CMD_READ;
            SDRAM_BA <= xfer_addr[BANK_HI:BANK_LO];
            SDRAM_A  <= cas_addr(xfer_addr, 1'b0);
            cl_pipe[0] <= 1'b1;
            xfer_addr[COL_HI:1] <= xfer_addr[COL_HI:1] + 1'd1;
            rd_issued <= rd_issued + 1'd1;
            if (rd_issued + 1'd1 == rd_total) state <= ST_RDW;
        end
        ST_RDW: begin
            // wait for capture pipeline to finish (delivery in capture logic);
            // also cover tRC for the single-read case with the drain cycles
            if (cl_pipe == 0) state <= ST_IDLE;
        end

        ST_PRE_REF: begin
            if (refw_cnt == 0) begin
                cmd      <= CMD_REF;
                ref_pend <= 1'b0;
                refw_cnt <= TRFC_CYC[3:0];
                state    <= ST_REFW;
            end
            else refw_cnt <= refw_cnt - 1'd1;
        end
        ST_REF: state <= ST_REFW;   // (unused; kept for enum stability)
        ST_REFW: begin
            if (refw_cnt == 0) state <= ST_IDLE;
            else refw_cnt <= refw_cnt - 1'd1;
        end
        default: state <= ST_IDLE;
        endcase
    end
end

endmodule
