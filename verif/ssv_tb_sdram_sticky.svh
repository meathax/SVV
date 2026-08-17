// Sticky / CE-safe behavioral SDRAM helpers for SSV realrom TBs.
// Hold ack until the request drops so fractional ce_cpu cannot miss it.
// Include inside a module that declares the sdr_* and memory arrays.

task automatic ssv_tb_sdram_reset_sticky;
    sdr_p0_ack = 1'b0;
    sdr_p1_ack = 1'b0;
    sdr_wr_ack = 1'b0;
    sdr_p4_ack = 1'b0;
endtask
