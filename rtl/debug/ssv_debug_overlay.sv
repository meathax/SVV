// ssv_debug_overlay.sv
//
// Temporary on-screen debug overlay for chasing the ES5506 sound issue.
// Draws a column of small squares over the right edge of the active
// picture. Each of the first NUM_TOGGLES squares is a toggle flip-flop
// that flips every time its monitored sound-path pulse fires; a screenshot
// taken during the bad behaviour freezes the toggle parity of every event
// right up to that instant, so a square that has stopped flipping across
// consecutive screenshots marks the point activity stalled. The last row
// shows the 5-bit last-serviced voice index directly (bit i -> column i).
//
// Green = bit/toggle 1, red = bit/toggle 0. Not meant to ship: gate with
// the instantiating module's ENABLE parameter/localparam and remove this
// file (and its files.qip line) once the ES5506 issue is closed.
//
// hpos/scanline are expected to be ssv_core's debug_hpos/debug_scanline
// (i.e. hcnt/vcnt) in the same clk_sys domain as rgb_in -- no CDC needed.
// The renderer's internal pixel pipeline may delay rgb_in by a few cycles
// relative to hcnt/vcnt, so square placement can be off by a handful of
// pixels; that's cosmetic only and doesn't affect which square is which.
module ssv_debug_overlay #(
    parameter SQ_W = 16,   // square width, pixels
    parameter SQ_H = 10,   // square height, pixels
    parameter GAP  = 3,    // gap between squares, pixels
    parameter X0   = 300,  // left edge of the square column
    parameter Y0   = 8     // top edge of the first square
) (
    input  logic        clk_sys,
    input  logic        rst,

    input  logic [23:0] rgb_in,
    input  logic  [8:0] hpos,       // debug_hpos (core hcnt)
    input  logic  [8:0] scanline,   // debug_scanline (core vcnt)

    // sound-path pulses, one toggle square each
    input  logic         sound_commit,
    input  logic         irq_promote,
    input  logic         voice_writeback,
    input  logic         sample_req,
    input  logic         sample_done,
    input  logic         sample_tick,
    input  logic         sample_underrun,
    input  logic         frame_boundary,
    input  logic  [4:0]  voice_index,   // last-serviced voice, shown as 5 bits

    output logic [23:0] rgb_out
);

localparam int NUM_TOGGLES = 8;
localparam [23:0] GREEN = 24'h00FF00;
localparam [23:0] RED   = 24'hFF0000;

logic [NUM_TOGGLES-1:0] pulse_in, pulse_d, toggle_bits;

// Row order top-to-bottom: sound_commit, irq_promote, voice_writeback,
// sample_req, sample_done, sample_tick, sample_underrun, frame_boundary.
assign pulse_in = {frame_boundary, sample_underrun, sample_tick, sample_done,
                    sample_req, voice_writeback, irq_promote, sound_commit};

always_ff @(posedge clk_sys) begin
    if (rst) begin
        toggle_bits <= '0;
        pulse_d     <= '0;
    end
    else begin
        pulse_d     <= pulse_in;
        toggle_bits <= toggle_bits ^ (pulse_in & ~pulse_d);
    end
end

function automatic logic square_hit(input int row, input int col);
    logic [8:0] sx0, sy0;
    sx0 = 9'(X0 + col * (SQ_W + GAP));
    sy0 = 9'(Y0 + row * (SQ_H + GAP));
    square_hit = (hpos >= sx0) && (hpos < sx0 + SQ_W) &&
                 (scanline >= sy0) && (scanline < sy0 + SQ_H);
endfunction

logic        overlay_hit;
logic [23:0] overlay_rgb;
integer row;
always_comb begin
    overlay_hit = 1'b0;
    overlay_rgb = 24'h000000;
    // toggle rows, bit i shown from row 0 (LSB, sound_commit) down
    for (row = 0; row < NUM_TOGGLES; row = row + 1) begin
        if (square_hit(row, 0)) begin
            overlay_hit = 1'b1;
            overlay_rgb = toggle_bits[row] ? GREEN : RED;
        end
    end
    // one extra row: 5 squares, voice_index bit 0..4 left to right
    for (row = 0; row < 5; row = row + 1) begin
        if (square_hit(NUM_TOGGLES, row)) begin
            overlay_hit = 1'b1;
            overlay_rgb = voice_index[row] ? GREEN : RED;
        end
    end
end

assign rgb_out = overlay_hit ? overlay_rgb : rgb_in;

endmodule
