//============================================================================
//  V60 qword effective-address regression.
//
//  MAME F12DecodeOperands uses dimension 3 for MOVD and for the destination
//  lvalue of MULX/MULUX/DIVX/DIVUX.  The dimension is architecturally visible:
//  qword auto-update steps by eight and indexed modes scale the index by eight.
//  This test also proves that extended multiply still fetches the low dword
//  while using a qword-sized effective address.
//============================================================================
`timescale 1ns/1ps

module tb_v60_qword_ea;

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

    // MOVD [R10+] -> R12:R13.  Source qword autoincrement must add eight.
    movw_imm(5'd10, 32'h0000_a000);
    ab(8'h3f); ab(8'h60 | 5'd12); ab(8'h80 | 5'd10);

    // MOVD [-R14] -> R16:R17.  Source qword autodecrement must subtract eight.
    movw_imm(5'd14, 32'h0000_a010);
    ab(8'h3f); ab(8'h60 | 5'd16); ab(8'ha0 | 5'd14);

    // MOVD [R18 + R19*qword] -> R20:R21.  Group-6 indexed source:
    // first mode low bits select the index, second mode selects the base.
    movw_imm(5'd18, 32'h0000_a000);
    movw_imm(5'd19, 32'h0000_0001);
    ab(8'h3f); ab(8'h60 | 5'd20); ab(8'hc0 | 5'd19); ab(8'h60 | 5'd18);

    // MOVD R4:R5 -> [R22+].  Destination qword autoincrement also adds eight.
    movw_imm(5'd4,  32'haaaa_1111);
    movw_imm(5'd5,  32'hbbbb_2222);
    movw_imm(5'd22, 32'h0000_b100);
    ab(8'h3f); ab(8'he0); ab(8'h60 | 5'd4); ab(8'h80 | 5'd22);

    // MULX.W R0,[R24+] uses a qword destination EA but reads the low dword
    // multiplier.  2*3 -> qword 6 and R24 advances by eight.
    movw_imm(5'd0,  32'h0000_0002);
    movw_imm(5'd24, 32'h0000_b000);
    ab(8'h86); ab(8'h40 | 5'd0); ab(8'h80 | 5'd24);

    ab(8'h00);

    // Source qwords at A000 and A008.
    ram[16'ha000>>1]       = 16'h1111;
    ram[(16'ha000>>1)+1]   = 16'haaaa;
    ram[(16'ha000>>1)+2]   = 16'h2222;
    ram[(16'ha000>>1)+3]   = 16'hbbbb;
    ram[16'ha008>>1]       = 16'h3333;
    ram[(16'ha008>>1)+1]   = 16'hcccc;
    ram[(16'ha008>>1)+2]   = 16'h4444;
    ram[(16'ha008>>1)+3]   = 16'hdddd;

    // MULX memory multiplier at B000 (low dword=3).
    ram[16'hb000>>1]       = 16'h0003;
    ram[(16'hb000>>1)+1]   = 16'h0000;
    ram[(16'hb000>>1)+2]   = 16'hdead;
    ram[(16'hb000>>1)+3]   = 16'hbeef;

    repeat (8) @(posedge clk);
    rst = 0;
    for (i = 0; i < 6000 && !cpu.dbg_halted; i = i + 1) @(posedge clk);

    chk(cpu.dbg_halted, "HALT reached");
    chk(cpu.r[10] == 32'h0000_a008, "MOVD source autoincrement steps by 8");
    chk(cpu.r[12] == 32'haaaa_1111 && cpu.r[13] == 32'hbbbb_2222,
        "MOVD autoincrement reads source qword");
    chk(cpu.r[14] == 32'h0000_a008, "MOVD source autodecrement steps by 8");
    chk(cpu.r[16] == 32'hcccc_3333 && cpu.r[17] == 32'hdddd_4444,
        "MOVD autodecrement reads decremented qword");
    chk(cpu.r[20] == 32'hcccc_3333 && cpu.r[21] == 32'hdddd_4444,
        "MOVD indexed EA scales index by 8");
    chk(cpu.r[22] == 32'h0000_b108, "MOVD destination autoincrement steps by 8");
    chk(ram[16'hb100>>1] == 16'h1111 && ram[(16'hb100>>1)+1] == 16'haaaa &&
        ram[(16'hb100>>1)+2] == 16'h2222 && ram[(16'hb100>>1)+3] == 16'hbbbb,
        "MOVD autoincrement writes destination qword");
    chk(cpu.r[24] == 32'h0000_b008, "MULX destination autoincrement steps by 8");
    chk(ram[16'hb000>>1] == 16'h0006 && ram[(16'hb000>>1)+1] == 16'h0000 &&
        ram[(16'hb000>>1)+2] == 16'h0000 && ram[(16'hb000>>1)+3] == 16'h0000,
        "MULX qword EA preserves low-dword fetch and writes product");

    if (fail == 0) $display("V60 QWORD EA PASS (%0d checks)", pass);
    else           $display("V60 QWORD EA FAIL (%0d/%0d failed)", fail, pass+fail);
    $finish;
end

initial begin #300000; $display("V60 QWORD EA FAIL (timeout)"); $finish; end
endmodule
