`timescale 1ns/1ps
module tb_ssv_family_cfg;
import ssv_pkg::*;
initial begin
    ssv_cfg_t c;
    logic [SDR_AW:1] base;
    c = cfg_dynagear();
    base = sample_word_addr_cfg(c, 2'd2, 32'd0, 1'b0);
    if (base !== SDR_SAMPLES_BASE[SDR_AW:1])
        $fatal(1, "ordinary bank alias changed");
    c.srmp7_sample_half_bank = 1'b1;
    base = sample_word_addr_cfg(c, 2'd2, 32'd0, 1'b0);
    if (sample_word_addr_cfg(c, 2'd2, 32'd0, 1'b1) - base !==
        (26'd1 << 21))
        $fatal(1, "SRMP7 bank entry did not add the MAME 4 MiB stride");
    if (sample_word_addr_cfg(c, 2'd1, 32'd0, 1'b1) !==
        sample_word_addr_cfg(c, 2'd1, 32'd0, 1'b0))
        $fatal(1, "SRMP7 bank write affected region 0/1");
    if (SDR_CPU_RAM_SIZE < 27'h0040fb0)
        $fatal(1, "expanded SRMP7 RAM does not fit backing region");
    if (SDR_EAGL_RAM_BASE < SDR_NVRAM_BASE + SDR_NVRAM_SIZE ||
        SDR_EAGL_RAM_BASE + SDR_EAGL_RAM_SIZE > SDR_GFX_BASE)
        $fatal(1, "Eagle Shot graphics RAM overlaps another SDRAM region");
    $display("PASS tb_ssv_family_cfg");
    $finish;
end
endmodule
