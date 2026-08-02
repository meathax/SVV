//============================================================================
// Twin Eagle II V60 compiler-frame regression.
//
// Replays the real common memset routine at ROM $e02524, including the exact
// PREPARE #0 / PUSHM #$106 / POPM #$106 / DISPOSE / RSR sequence that first
// failed during the bounded real-ROM boot.  The caller uses a smaller buffer
// so this remains media-independent and fast.
//============================================================================
`timescale 1ns/1ps

module tb_v60_frame_stack;

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

reg [15:0] ram [0:131071]; // 256 KiB
reg ack_r;
assign m_rdata = ram[m_addr[17:1]];
assign m_ack   = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[17:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[17:1]][15:8] <= m_wdata[15:8];
    end
end

integer pa;
task ab(input [7:0] b);
    if (pa[0]) ram[pa>>1][15:8] = b;
    else       ram[pa>>1][7:0]  = b;
    pa = pa + 1;
endtask
task aw32(input [31:0] w);
    ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]);
endtask
task mov_imm(input [4:0] rn, input [31:0] value);
    ab(8'h2d); ab(8'h20 | rn); ab(8'hf4); aw32(value);
endtask
task push_reg(input [4:0] rn);
    ab(8'hef); ab(8'h60 | rn);
endtask

integer i, cycles, bad;
localparam [31:0] INITIAL_SP = 32'h0003_0000;
localparam [31:0] BUFFER     = 32'h0001_0000;
localparam [31:0] LENGTH     = 32'h0000_01d3;

initial begin
    for (i = 0; i < 131072; i = i + 1) ram[i] = 16'ha55a;

    // Caller: push length, push destination, call the real routine.  Arguments
    // therefore appear at 12[FP] and 8[FP], respectively, after PREPARE.
    pa = 0;
    mov_imm(5'd31, INITIAL_SP);
    mov_imm(5'd30, 32'h1122_3344);
    mov_imm(5'd1,  32'h1111_1111);
    mov_imm(5'd2,  32'h2222_2222);
    mov_imm(5'd8,  32'h8888_8888);
    mov_imm(5'd0, LENGTH);
    push_reg(5'd0);
    mov_imm(5'd0, BUFFER);
    push_reg(5'd0);
    ab(8'he8); ab(8'hf3); aw32(32'h0000_0100); // JSR direct $100
    mov_imm(5'd10, 32'hc001_c0de);             // reached only after valid RSR
    ab(8'h00);                                 // HALT

    // Byte-for-byte copy of Twin Eagle II $e02524..$e02570, relocated to $100.
    // All internal branches are PC-relative, so relocation is safe.
    pa = 32'h100;
    ab(8'hde); ab(8'hf4); aw32(32'h0000_0000); // PREPARE #0
    ab(8'hec); ab(8'hf4); aw32(32'h0000_0106); // PUSHM #$106 (R8,R2,R1)
    ab(8'h2d); ab(8'h28); ab(8'h1e); ab(8'h08);
    ab(8'h2d); ab(8'h20); ab(8'he0);
    ab(8'h2d); ab(8'h21); ab(8'hf4); aw32(32'h0000_0010);
    ab(8'h2d); ab(8'h22); ab(8'h1e); ab(8'h0c);
    ab(8'hac); ab(8'h41); ab(8'h62); ab(8'h7e); ab(8'h14); ab(8'h00);
    ab(8'h2d); ab(8'h40); ab(8'h88); ab(8'h2d); ab(8'h40); ab(8'h88);
    ab(8'h2d); ab(8'h40); ab(8'h88); ab(8'h2d); ab(8'h40); ab(8'h88);
    ab(8'hac); ab(8'h41); ab(8'h62); ab(8'h63); ab(8'hf1); ab(8'h84);
    ab(8'h41); ab(8'h62); ab(8'hba); ab(8'h22); ab(8'he0); ab(8'h74);
    ab(8'h0a); ab(8'h00); ab(8'h09); ab(8'h40); ab(8'h88); ab(8'hd3);
    ab(8'h62); ab(8'h65); ab(8'hfb);
    ab(8'he4); ab(8'hf4); aw32(32'h0000_0106); // POPM #$106
    ab(8'hcc);                                 // DISPOSE
    ab(8'hca);                                 // RSR

    // Preserve one word on either side to detect an overrun.
    ram[(BUFFER-2)>>1] = 16'hbeef;
    ram[(BUFFER+LENGTH+1)>>1] = 16'hface;

    repeat (8) @(posedge clk);
    rst = 0;
    cycles = 0;
    while (!cpu.dbg_halted && cycles < 500000) begin
        @(posedge clk);
        cycles = cycles + 1;
    end

    bad = 0;
    for (i = 0; i < LENGTH; i = i + 1)
        if ((i[0] ? ram[(BUFFER+i)>>1][15:8] : ram[(BUFFER+i)>>1][7:0]) !== 8'h00)
            bad = bad + 1;

    if (cpu.dbg_halted &&
        cpu.r[10] == 32'hc001_c0de &&
        cpu.r[31] == INITIAL_SP - 8 &&
        cpu.r[30] == 32'h1122_3344 &&
        cpu.r[1]  == 32'h1111_1111 &&
        cpu.r[2]  == 32'h2222_2222 &&
        cpu.r[8]  == 32'h8888_8888 &&
        bad == 0 &&
        ram[(BUFFER-2)>>1] == 16'hbeef &&
        ram[(BUFFER+LENGTH+1)>>1] == 16'hface) begin
        $display("V60 FRAME STACK PASS cycles=%0d", cycles);
    end else begin
        $display("V60 FRAME STACK FAIL cycles=%0d pc=%08x sp=%08x fp=%08x r1=%08x r2=%08x r8=%08x r10=%08x bad=%0d before=%04x after=%04x",
            cycles, cpu.dbg_pc, cpu.r[31], cpu.r[30], cpu.r[1], cpu.r[2],
            cpu.r[8], cpu.r[10], bad, ram[(BUFFER-2)>>1], ram[(BUFFER+LENGTH+1)>>1]);
    end
    $finish;
end

endmodule
