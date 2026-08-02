//============================================================================
//  V60 ADDC/SUBC carry, borrow, and overflow regression.
//
//  MAME commit f0244b9f63d stopped pre-wrapping (source + carry) before the
//  arithmetic helper.  These vectors distinguish the corrected behaviour from
//  the old implementation at byte, halfword, and word widths.
//============================================================================
`timescale 1ns/1ps

module tb_v60_addc_subc;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;

s32_v60 #(.START_PC(32'h0000_0000)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1),
    .dbg_pc(), .dbg_halted()
);
s32_v60_bus adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:65535];
reg ack_r;
assign m_rdata = ram[m_addr[16:1]];
assign m_ack   = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[16:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[16:1]][15:8] <= m_wdata[15:8];
    end
end

integer pc_a;
task ab(input [7:0] b);
    if (pc_a[0]) ram[pc_a>>1][15:8] = b;
    else         ram[pc_a>>1][7:0]  = b;
    pc_a = pc_a + 1;
endtask
task aw32(input [31:0] w);
    ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]);
endtask
task movw_imm(input [4:0] rn, input [31:0] imm);
    ab(8'h2d); ab(8'h20 | rn); ab(8'hf4); aw32(imm);
endtask
task set_carry(input carry_in);
    // CMP.B source,destination sets CY to unsigned borrow.
    // R28=1, R29=0: 0-1 sets CY; 0-0 clears it.
    ab(8'hb8);
    ab(8'h40 | (carry_in ? 5'd28 : 5'd29));
    ab(8'h60 | 5'd29);
endtask
task carry_op(input [7:0] opcode, input [4:0] dst);
    // F2 D=1: destination is the iflags register, source is an AM register.
    ab(opcode); ab(8'h60 | dst); ab(8'h60 | 5'd0);
endtask
task getpsw(input [4:0] rn);
    ab(8'hf7); ab(8'h60 | rn);
endtask

integer pass = 0, fail = 0;
task chk(input cond, input [319:0] name);
    if (cond) begin pass = pass + 1; $display("  ok   %0s", name); end
    else      begin fail = fail + 1; $display("  FAIL %0s", name); end
endtask

integer i;
initial begin
    for (i = 0; i < 65536; i = i + 1) ram[i] = 16'h0000;
    pc_a = 0;
    movw_imm(5'd31, 32'h0001_0000);
    movw_imm(5'd28, 32'h0000_0001);
    movw_imm(5'd29, 32'h0000_0000);

    // 0 + signed-max + carry -> signed-min: corrected OV=1, CY=0.
    movw_imm(5'd0, 32'h0000_007f); movw_imm(5'd2, 32'h0);
    set_carry(1'b1); carry_op(8'h90, 5'd2); getpsw(5'd3);
    movw_imm(5'd0, 32'h0000_7fff); movw_imm(5'd4, 32'h0);
    set_carry(1'b1); carry_op(8'h92, 5'd4); getpsw(5'd5);
    movw_imm(5'd0, 32'h7fff_ffff); movw_imm(5'd6, 32'h0);
    set_carry(1'b1); carry_op(8'h94, 5'd6); getpsw(5'd7);

    // 0 - signed-max - carry -> signed-min: corrected OV=0, borrow=1.
    movw_imm(5'd0, 32'h0000_007f); movw_imm(5'd8, 32'h0);
    set_carry(1'b1); carry_op(8'h98, 5'd8); getpsw(5'd9);
    movw_imm(5'd0, 32'h0000_7fff); movw_imm(5'd10, 32'h0);
    set_carry(1'b1); carry_op(8'h9a, 5'd10); getpsw(5'd11);
    movw_imm(5'd0, 32'h7fff_ffff); movw_imm(5'd12, 32'h0);
    set_carry(1'b1); carry_op(8'h9c, 5'd12); getpsw(5'd13);

    // Source all-ones plus carry must not wrap before carry/borrow detection.
    movw_imm(5'd0, 32'hffff_ffff); movw_imm(5'd14, 32'h0);
    set_carry(1'b1); carry_op(8'h94, 5'd14); getpsw(5'd15);
    movw_imm(5'd0, 32'hffff_ffff); movw_imm(5'd16, 32'h0);
    set_carry(1'b1); carry_op(8'h9c, 5'd16); getpsw(5'd17);

    ab(8'h00);

    repeat (8) @(posedge clk);
    rst = 0;
    for (i = 0; i < 5000 && !cpu.dbg_halted; i = i + 1) @(posedge clk);

    chk(cpu.dbg_halted, "HALT reached");
    chk(cpu.r[2][7:0]   == 8'h80,       "ADDC.B corrected result");
    chk((cpu.r[3]&4'hf) == 4'h6,        "ADDC.B flags OV=1 S=1 CY=0");
    chk(cpu.r[4][15:0]  == 16'h8000,    "ADDC.H corrected result");
    chk((cpu.r[5]&4'hf) == 4'h6,        "ADDC.H flags OV=1 S=1 CY=0");
    chk(cpu.r[6]        == 32'h8000_0000, "ADDC.W corrected result");
    chk((cpu.r[7]&4'hf) == 4'h6,        "ADDC.W flags OV=1 S=1 CY=0");

    chk(cpu.r[8][7:0]    == 8'h80,      "SUBC.B corrected result");
    chk((cpu.r[9]&4'hf)  == 4'ha,       "SUBC.B flags OV=0 S=1 CY=1");
    chk(cpu.r[10][15:0]  == 16'h8000,   "SUBC.H corrected result");
    chk((cpu.r[11]&4'hf) == 4'ha,       "SUBC.H flags OV=0 S=1 CY=1");
    chk(cpu.r[12]        == 32'h8000_0000, "SUBC.W corrected result");
    chk((cpu.r[13]&4'hf) == 4'ha,       "SUBC.W flags OV=0 S=1 CY=1");

    chk(cpu.r[14] == 32'h0000_0000 && (cpu.r[15]&4'hf) == 4'h9,
        "ADDC.W all-ones source preserves carry and zero");
    chk(cpu.r[16] == 32'h0000_0000 && (cpu.r[17]&4'hf) == 4'h9,
        "SUBC.W all-ones source preserves borrow and zero");

    if (fail == 0) $display("V60 ADDC SUBC PASS (%0d checks)", pass);
    else           $display("V60 ADDC SUBC FAIL (%0d/%0d failed)", fail, pass+fail);
    $finish;
end

initial begin #250000; $display("V60 ADDC SUBC FAIL (timeout)"); $finish; end
endmodule
