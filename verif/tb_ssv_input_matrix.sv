`timescale 1ns/1ps
// Lock Arcade-SSV.sv player/system/DSW1/DSW2 bit mapping vs MAME dynagear ports.

module tb_ssv_input_matrix;

// Mirror of Arcade-SSV.sv mapping (keep in sync).
function automatic [15:0] player_port(input [31:0] joy);
    // MAME bits 7:0 = UP,DOWN,LEFT,RIGHT,B1,B2,B3,START
    player_port = {8'hff, ~{joy[3], joy[2], joy[1], joy[0],
                              joy[4], joy[5], joy[6], joy[7]}};
endfunction

function automatic [15:0] system_port(
    input coin1, input coin2, input service, input test_btn
);
    system_port = {8'hff, ~{3'b000, test_btn, 1'b0, service, coin2, coin1}};
endfunction

function automatic [3:0] coinage_nibble(input [3:0] osd);
    case (osd)
        4'd0:  coinage_nibble = 4'hF;
        4'd1:  coinage_nibble = 4'h7;
        4'd2:  coinage_nibble = 4'h8;
        4'd3:  coinage_nibble = 4'h9;
        4'd4:  coinage_nibble = 4'h6;
        4'd5:  coinage_nibble = 4'hE;
        4'd6:  coinage_nibble = 4'hD;
        4'd7:  coinage_nibble = 4'hC;
        4'd8:  coinage_nibble = 4'hB;
        4'd9:  coinage_nibble = 4'hA;
        4'd10: coinage_nibble = 4'h5;
        4'd11: coinage_nibble = 4'h4;
        4'd12: coinage_nibble = 4'h3;
        4'd13: coinage_nibble = 4'h2;
        4'd14: coinage_nibble = 4'h1;
        default: coinage_nibble = 4'hF;
    endcase
endfunction

function automatic [15:0] dsw1_port(input [3:0] coin_a_osd, input [3:0] coin_b_osd);
    dsw1_port = {8'hff, coinage_nibble(coin_b_osd), coinage_nibble(coin_a_osd)};
endfunction

function automatic [15:0] dsw2_port(
    input flip_osd, input demo_off_osd,
    input [1:0] diff_osd, input [1:0] lives_osd,
    input free_osd, input health_osd
);
    logic [1:0] dip_difficulty;
    logic [1:0] dip_lives;
    logic [7:0] dsw2_lo;
    begin
        dip_difficulty =
            (diff_osd == 2'd0) ? 2'b11 :
            (diff_osd == 2'd1) ? 2'b10 :
            (diff_osd == 2'd2) ? 2'b01 : 2'b00;
        dip_lives =
            (lives_osd == 2'd0) ? 2'b11 :
            (lives_osd == 2'd1) ? 2'b01 :
            (lives_osd == 2'd2) ? 2'b10 : 2'b00;
        dsw2_lo = {
            ~health_osd,
            ~free_osd,
            dip_lives,
            dip_difficulty,
            demo_off_osd,
            ~flip_osd
        };
        dsw2_port = {8'hff, dsw2_lo};
    end
endfunction

integer fails;

task automatic expect16(input string name, input [15:0] got, input [15:0] exp);
    if (got !== exp) begin
        $display("FAIL %s got=%04x exp=%04x", name, got, exp);
        fails = fails + 1;
    end
endtask

initial begin
    fails = 0;

    // Idle joysticks → all ones (active-low released).
    expect16("P1 idle", player_port(32'd0), 16'hFFFF);
    expect16("P2 idle", player_port(32'd0), 16'hFFFF);

    // MAME P1 low byte: UP,DOWN,LEFT,RIGHT,B1,B2,B3,START
    // joy bits: 0=R 1=L 2=D 3=U 4=B1 5=B2 6=B3 7=Start
    expect16("P1 UP", player_port(32'h8), 16'hFF7F);
    expect16("P1 DOWN", player_port(32'h4), 16'hFFBF);
    expect16("P1 LEFT", player_port(32'h2), 16'hFFDF);
    expect16("P1 RIGHT", player_port(32'h1), 16'hFFEF);
    expect16("P1 B1", player_port(32'h10), 16'hFFF7);
    expect16("P1 B2", player_port(32'h20), 16'hFFFB);
    expect16("P1 B3", player_port(32'h40), 16'hFFFD);
    expect16("P1 START", player_port(32'h80), 16'hFFFE);

    // SYSTEM: COIN1,COIN2,SERVICE1,TILT=0,TEST
    expect16("SYS idle", system_port(0, 0, 0, 0), 16'hFFFF);
    expect16("SYS COIN1", system_port(1, 0, 0, 0), 16'hFFFE);
    expect16("SYS COIN2", system_port(0, 1, 0, 0), 16'hFFFD);
    expect16("SYS SERVICE", system_port(0, 0, 1, 0), 16'hFFFB);
    expect16("SYS TEST", system_port(0, 0, 0, 1), 16'hFFEF);

    // DSW1 defaults (status coin OSD=0): Coin A/B 1C/1C → 0xFF
    expect16("DSW1 default", dsw1_port(4'd0, 4'd0), 16'hFFFF);
    expect16("DSW1 4C/1C A", dsw1_port(4'd1, 4'd0), 16'hFFF7);
    expect16("DSW1 Multi E B", dsw1_port(4'd0, 4'd14), 16'hFF1F);

    // DSW2 defaults (status=0): Demo Sounds ON, Flip Off, Normal, 2 lives,
    // Free Play Off, 4 Hearts → low byte 0xFD
    expect16("DSW2 default", dsw2_port(0, 0, 2'd0, 2'd0, 0, 0), 16'hFFFD);

    if (fails != 0)
        $fatal(1, "input matrix failures=%0d", fails);
    $display("PASS tb_ssv_input_matrix");
    $finish;
end
endmodule
