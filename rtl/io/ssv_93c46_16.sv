// SPDX-License-Identifier: GPL-3.0-or-later
// 93C46/S2914-compatible 64x16 serial EEPROM command/data path.  Organization
// is fixed to the 16-bit mode selected by EEPROM_93C46_16BIT in MAME.
`timescale 1ns/1ps
module ssv_93c46_16 (
    input logic clk, input logic rst,
    input logic cs, input logic sk, input logic di,
    output logic dout
);
logic cs_d, sk_d, write_enable;
logic [5:0] address;
logic [8:0] command;
logic [4:0] bit_count;
logic [15:0] shift;
logic [15:0] mem [0:63];
integer i;
always_ff @(posedge clk) begin
    if (rst) begin
        cs_d<=0; sk_d<=0; dout<=1; write_enable<=0; address<=0;
        command<=0; bit_count<=0; shift<=0;
        for (i=0;i<64;i=i+1) mem[i] <= 16'hffff;
    end else begin
        cs_d <= cs; sk_d <= sk;
        if (!cs) begin bit_count<=0; command<=0; dout<=1; end
        else if (sk && !sk_d) begin
            if (bit_count < 9) begin
                command <= {command[7:0],di};
                bit_count <= bit_count + 1'd1;
                if (bit_count == 8) begin
                    address <= {command[4:0],di};
                    case (command[6:5])
                        2'b10: begin // READ: start bit + opcode 10 + A5:A0
                            shift <= mem[{command[4:0],di}];
                            dout <= mem[{command[4:0],di}][15];
                        end
                        2'b00: begin // EWEN/EWDS: top two address bits
                            write_enable <= command[4] && command[3];
                        end
                        default: ;
                    endcase
                end
            end else if (command[6:5] == 2'b10) begin
                shift <= {shift[14:0],1'b1};
                dout <= shift[14];
            end else if (command[6:5] == 2'b01) begin
                shift <= {shift[14:0],di};
                bit_count <= bit_count + 1'd1;
                if (bit_count == 24 && write_enable)
                    mem[address] <= {shift[14:0],di};
            end else if (command[6:5] == 2'b11 && write_enable) begin
                mem[address] <= 16'hffff;
            end
        end
    end
end
endmodule
