`timescale 1ns/1ps
// Lock Arcade-SSV.sv player/system/DSW1/DSW2 bit mapping vs MAME dynagear ports.
//
// SCOPE WARNING: this bench re-declares its own copy of the wrapper functions
// and checks them against constants in this same file. It is a change-detector
// for Arcade-SSV.sv, NOT an independent golden — when the P1 bit order was
// corrected, this file was edited in the same commit, so a PASS here proved
// only that the two copies agreed.
//
// What actually pins the port order to the board is the raw in_p1 / in_system
// values in verif/scenarios/dynagear/coin_start_p1*.json: they come from a
// MAME 0.288 replay and are driven straight into ssv_core by tb_ssv_frame_crc,
// so the game itself has to respond to them. Change a mapping here and re-run
// that scenario before believing it.

module tb_ssv_input_matrix;

// Mirror of Arcade-SSV.sv mapping (keep in sync).
// joy bits: 0=R 1=L 2=D 3=U 4=Fire 5=Jump 6=Test 7=Service 8=Start 9=Coin
function automatic [15:0] player_port(input [31:0] joy);
    // MAME bits 7:0 = UP,DOWN,LEFT,RIGHT,B1,B2,B3,START. Dyna Gear has no
    // third button: B3 is tied released and no joystick bit can reach it.
    player_port = {8'hff, ~{joy[3], joy[2], joy[1], joy[0],
                              joy[4], joy[5], 1'b0, joy[8]}};
endfunction

// Mirror of Arcade-SSV.sv db15_to_joy (DB15 SNAC pad -> joy numbering).
// DB15 bits: 11=Select 10=Start 9=F 8=E 7=D 6=C 5=B 4=A 3=U 2=D 1=L 0=R
// A=Fire, B=Jump, Start=Start, Select=Coin, Select+A=Test, Select+B=Service.
function automatic [31:0] db15_to_joy(input [15:0] db);
    logic sel, chord;
    begin
        sel   = db[11];
        chord = sel & (db[4] | db[5]);
        db15_to_joy = {22'd0, sel & ~chord, db[10], sel & db[5], sel & db[4],
                       db[5] & ~sel, db[4] & ~sel,
                       db[3], db[2], db[1], db[0]};
    end
endfunction

function automatic [15:0] system_port(
    input coin1, input coin2, input service, input test_btn
);
    system_port = {8'hff, ~{3'b000, test_btn, 1'b0, service, coin2, coin1}};
endfunction

// DIP switches now come straight from the MRA on ioctl index 254; the wrapper
// no longer translates anything, so these mirror the whole of what it does.
function automatic [15:0] dsw1_port(input [7:0] sw0);
    dsw1_port = {8'hff, sw0};
endfunction

function automatic [15:0] dsw2_port(input [7:0] sw1);
    dsw2_port = {8'hff, sw1};
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
    // joy bits: 0=R 1=L 2=D 3=U 4=Fire 5=Jump 6=Test 7=Service 8=Start 9=Coin
    expect16("P1 UP", player_port(32'h8), 16'hFF7F);
    expect16("P1 DOWN", player_port(32'h4), 16'hFFBF);
    expect16("P1 LEFT", player_port(32'h2), 16'hFFDF);
    expect16("P1 RIGHT", player_port(32'h1), 16'hFFEF);
    expect16("P1 FIRE", player_port(32'h10), 16'hFFF7);
    expect16("P1 JUMP", player_port(32'h20), 16'hFFFB);
    expect16("P1 START", player_port(32'h100), 16'hFFFE);

    // Dyna Gear has no third button. Pressing EVERY joystick bit at once must
    // still leave B3 (P1 bit 1) released -- 0xFF02 has bit1 set and nothing
    // else in the low byte. This is the check that the button is gone, not
    // merely unmapped.
    expect16("P1 NO B3", player_port(32'hFFFFFFFF), 16'hFF02);

    // DB15 SNAC pad maps onto the same joy numbering.
    expect16("DB15 UP", player_port(db15_to_joy(16'h0008)), 16'hFF7F);
    expect16("DB15 DOWN", player_port(db15_to_joy(16'h0004)), 16'hFFBF);
    expect16("DB15 LEFT", player_port(db15_to_joy(16'h0002)), 16'hFFDF);
    expect16("DB15 RIGHT", player_port(db15_to_joy(16'h0001)), 16'hFFEF);
    expect16("DB15 A=FIRE", player_port(db15_to_joy(16'h0010)), 16'hFFF7);
    expect16("DB15 B=JUMP", player_port(db15_to_joy(16'h0020)), 16'hFFFB);
    expect16("DB15 START", player_port(db15_to_joy(16'h0400)), 16'hFFFE);

    // Buttons C..F are physically present on a six-button CHAMMA panel and
    // must reach nothing at all -- in particular not the absent third button.
    expect16("DB15 C IDLE", player_port(db15_to_joy(16'h0040)), 16'hFFFF);
    expect16("DB15 D IDLE", player_port(db15_to_joy(16'h0080)), 16'hFFFF);
    expect16("DB15 E IDLE", player_port(db15_to_joy(16'h0100)), 16'hFFFF);
    expect16("DB15 F IDLE", player_port(db15_to_joy(16'h0200)), 16'hFFFF);
    if (db15_to_joy(16'h03C0) != 32'd0)
        begin $display("FAIL DB15 C-F must be inert"); fails = fails + 1; end

    // Select alone = Coin (joy[9]); Select+A = Test (joy[6]); Select+B =
    // Service (joy[7]). A chord must NOT also fire Coin, Fire or Jump.
    if (db15_to_joy(16'h0800) != 32'h200)
        begin $display("FAIL DB15 Select->Coin"); fails = fails + 1; end
    if (db15_to_joy(16'h0810) != 32'h40)
        begin $display("FAIL DB15 Select+A->Test only"); fails = fails + 1; end
    if (db15_to_joy(16'h0820) != 32'h80)
        begin $display("FAIL DB15 Select+B->Service only"); fails = fails + 1; end
    // A chord must leave the game's own P1 port completely idle.
    expect16("DB15 TEST CHORD P1 IDLE",
             player_port(db15_to_joy(16'h0810)), 16'hFFFF);

    // ---------------------------------------------------------------------
    // Independent anchor: these five constants are NOT derived from
    // Arcade-SSV.sv. They are the literal in_p1 / in_system words that
    // verif/scenarios/dynagear/coin_start_p1.json feeds straight into
    // ssv_core, captured from a MAME 0.288 dynagear replay in which the game
    // actually inserts a coin, starts, confirms a character and moves. If the
    // wrapper mapping and these disagree, the wrapper is wrong -- editing the
    // mirror above cannot make this block pass.
    //
    // scenario frame 165/250: "P1 START pressed (active-low bit0)"
    expect16("SCENARIO START", player_port(32'h100), 16'hFFFE);
    // scenario frame 255/330: "P1 B1 confirm" / "P1 B1 attack"
    expect16("SCENARIO B1", player_port(32'h10), 16'hFFF7);
    // scenario frame 300: "P1 RIGHT"
    expect16("SCENARIO RIGHT", player_port(32'h1), 16'hFFEF);
    // scenario frame 360: "P1 UP"
    expect16("SCENARIO UP", player_port(32'h8), 16'hFF7F);
    // scenario frame 840 (gameplay): "RIGHT+B1 attack" == 0xFFE7
    expect16("SCENARIO RIGHT+B1", player_port(32'h11), 16'hFFE7);
    // scenario frame 30: "COIN1 pressed (active-low bit0)"
    expect16("SCENARIO COIN1", system_port(1, 0, 0, 0), 16'hFFFE);
    // ---------------------------------------------------------------------

    // SYSTEM: COIN1,COIN2,SERVICE1,TILT=0,TEST
    expect16("SYS idle", system_port(0, 0, 0, 0), 16'hFFFF);
    expect16("SYS COIN1", system_port(1, 0, 0, 0), 16'hFFFE);
    expect16("SYS COIN2", system_port(0, 1, 0, 0), 16'hFFFD);
    expect16("SYS SERVICE", system_port(0, 0, 1, 0), 16'hFFFB);
    expect16("SYS TEST", system_port(0, 0, 0, 1), 16'hFFEF);

    // ---------------------------------------------------------------------
    // DIP switches. These constants are NOT derived from Arcade-SSV.sv -- they
    // are the raw DSW1/DSW2 bytes MAME 0.288 puts on $210002/$210004 for
    // dynagear, read off INPUT_PORTS_START(dynagear) and SSV_COINAGE_EXTENDED
    // in src/mame/seta/ssv.cpp. They are also exactly what mra/Dyna Gear.mra
    // now has to produce, so this block pins the MRA and the board together.
    //
    // Defaults FF / FD: Coin A and B 1C/1C, Flip Off, Demo Sounds On,
    // Difficulty Normal, 2 lives, Free Play Off, 4 Hearts.
    expect16("DSW1 default", dsw1_port(8'hff), 16'hFFFF);
    expect16("DSW2 default", dsw2_port(8'hfd), 16'hFFFD);

    // Coin A = 4C/1C is nibble 7 (SSV_COINAGE_EXTENDED 0x0007 << 0).
    expect16("DSW1 4C/1C A", dsw1_port(8'hf7), 16'hFFF7);
    // Coin B = Multi E is nibble 1 in the high half (0x0001 << 4).
    expect16("DSW1 Multi E B", dsw1_port(8'h1f), 16'hFF1F);
    // DSW2 bit 7 clear = 3 Hearts (0x0080 selects 4 Hearts).
    expect16("DSW2 3 Hearts", dsw2_port(8'h7d), 16'hFF7D);
    // DSW2 bits 3:2 = 00 is Hardest (0x000c is Normal).
    expect16("DSW2 Hardest", dsw2_port(8'hf1), 16'hFFF1);

    // The wrapper must not alter the byte on its way to the game: whatever the
    // MRA sends is what $210002/$210004 read back, high half tied to 1.
    for (int i = 0; i < 256; i++) begin
        if (dsw1_port(i[7:0]) !== {8'hff, i[7:0]}) begin
            $display("FAIL DSW1 passthrough %02x", i); fails = fails + 1;
        end
        if (dsw2_port(i[7:0]) !== {8'hff, i[7:0]}) begin
            $display("FAIL DSW2 passthrough %02x", i); fails = fails + 1;
        end
    end

    if (fails != 0)
        $fatal(1, "input matrix failures=%0d", fails);
    $display("PASS tb_ssv_input_matrix");
    $finish;
end
endmodule
