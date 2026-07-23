`timescale 1ns/1ps

module tb_ssv_sprite_decode;
logic [15:0] global_mode;
logic [15:0] local_code;
logic [15:0] local_attr;
logic [15:0] local_x;
logic [15:0] local_y;
logic use_local_size;
logic [5:0] local_count;
logic [3:0] scroll_word;
logic is_tilemap;
logic [2:0] tilemap_scroll;
logic [19:0] tile_code;
logic [8:0] color;
logic flip_x, flip_y;
logic [2:0] gfx_mode;
logic shadow;
logic [3:0] x_tiles, y_tiles;
logic signed [10:0] x_pos, y_pos;

ssv_sprite_decode dut (.*);

task automatic check(input logic condition, input string message);
    if (!condition) begin
        $error("FAIL: %s", message);
        $fatal(1);
    end
endtask

initial begin
    global_mode   = 16'hf6a3;
    local_code    = 16'h1234;
    local_attr    = 16'had55;
    local_x       = 16'h480a;
    local_y       = 16'h0ffb;
    use_local_size = 1'b0;
    #1;

    check(local_count == 6'd4, "global count is mode[4:0] plus one");
    check(scroll_word == 4'd10, "global offset selects an even scroll word");
    check(!is_tilemap, "normal sprite classification");
    check(x_tiles == 4'd2 && y_tiles == 4'd4, "global size decode");
    check(gfx_mode == 3'd7 && shadow, "global depth and shadow decode");
    check(tile_code == 20'hd1234, "scrambled high tile-code nibble");
    check(color == 9'h155, "palette color uses nine low attribute bits");
    check(flip_x && !flip_y, "flip bits");
    check(x_pos == 11'sd10 && y_pos == -11'sd5, "signed ten-bit positions");

    global_mode    = 16'h0000;
    local_code     = 16'h0005;
    local_attr     = 16'h0000;
    local_x        = 16'hd000;
    local_y        = 16'h0c00;
    use_local_size = 1'b1;
    #1;

    check(is_tilemap && tilemap_scroll == 3'd5, "tilemap sprite signature");
    check(x_tiles == 4'd1 && y_tiles == 4'd8, "local tilemap size signature");
    check(gfx_mode == 3'd5 && shadow, "local depth and shadow decode");

    local_code = 16'h0008;
    #1;
    check(!is_tilemap, "tilemap scroll index is restricted to zero through seven");

    $display("PASS tb_ssv_sprite_decode");
    $finish;
end
endmodule
