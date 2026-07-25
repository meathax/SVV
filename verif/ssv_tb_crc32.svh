// CRC-32/ISO-HDLC (poly 0xEDB88320), matching tools/mame-capture-ssv-frames.lua
function automatic [31:0] ssv_crc32_byte(input [31:0] crc, input [7:0] data);
    integer bit_i;
    logic [31:0] c;
    begin
        c = crc ^ {24'd0, data};
        for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
            if (c[0])
                c = (c >> 1) ^ 32'hEDB88320;
            else
                c = c >> 1;
        end
        ssv_crc32_byte = c;
    end
endfunction
