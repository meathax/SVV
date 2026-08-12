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
logic [1:0] opcode;
logic [4:0] bit_count;
logic [15:0] shift;
logic [15:0] mem [0:63];
logic [5:0] init_addr;
logic init_busy;
always_ff @(posedge clk) begin
    if (rst) begin
        cs_d<=0; sk_d<=0; dout<=1; write_enable<=0; address<=0;
        command<=0; opcode<=0; bit_count<=0; shift<=0;
        init_addr<=0; init_busy<=1;
    end else if (init_busy) begin
        // One write per cycle preserves an inferrable single-port RAM.  Hold
        // the serial interface idle until reset has restored the erased image.
        mem[init_addr] <= 16'hffff;
        cs_d<=0; sk_d<=0; dout<=1; write_enable<=0;
        address<=0; command<=0; opcode<=0; bit_count<=0; shift<=0;
        if (init_addr == 6'd63)
            init_busy <= 1'b0;
        else
            init_addr <= init_addr + 1'd1;
    end else begin
        cs_d <= cs; sk_d <= sk;
        if (!cs) begin bit_count<=0; command<=0; dout<=1; end
        else if (sk && !sk_d) begin
            if (bit_count < 9) begin
                command <= {command[7:0],di};
                bit_count <= bit_count + 1'd1;
                if (bit_count == 8) begin
                    address <= {command[4:0],di};
                    opcode <= command[6:5];
                    case (command[6:5])
                        2'b10: begin // READ: start bit + opcode 10 + A5:A0
                            shift <= mem[{command[4:0],di}];
                            dout <= mem[{command[4:0],di}][15];
                        end
                        2'b00: begin // EWEN/EWDS: top two address bits
                            write_enable <= command[4] && command[3];
                        end
                        2'b11: begin // ERASE completes with the command
                            if (write_enable)
                                mem[{command[4:0],di}] <= 16'hffff;
                        end
                        default: ;
                    endcase
                end
            end else if (opcode == 2'b10) begin
                shift <= {shift[14:0],1'b1};
                dout <= shift[14];
            end else if (opcode == 2'b01) begin
                shift <= {shift[14:0],di};
                bit_count <= bit_count + 1'd1;
                if (bit_count == 24 && write_enable)
                    mem[address] <= {shift[14:0],di};
            end
        end
    end
end
endmodule
