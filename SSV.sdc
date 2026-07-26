# SSV MiSTer core timing constraints.
# Board clocks (FPGA_CLK*_50, HPS user clocks) are created in sys/sys_top.sdc.
# Do not invent a CLK_50M / RESET / HPS_BUS top-level here — the compiled
# entity is sys_top, and those emu-wrapper names do not exist as ports.

derive_pll_clocks
derive_clock_uncertainty

# The V60 is clock-enabled at approximately 16.1 MHz from clk_sys.  The
# accumulator ratio guarantees at least three clk_sys periods between enable
# pulses, and every V60 state register is updated by the same `ce` branch.
# Constrain only register-to-register paths wholly inside that instance.
set v60_registers [get_registers {*|s32_v60:cpu|*}]
set v60_registers [add_to_collection $v60_registers \
    [get_registers {*|s32_v60_bus:bus_adapter|*}]]
set_multicycle_path -setup 3 \
    -from $v60_registers -to $v60_registers
set_multicycle_path -hold 2 \
    -from $v60_registers -to $v60_registers

# ES5506 voice CE domain (~16 MHz, same ratio as V60). Only CE-updated
# registers get the multicycle; SDRAM handshake regs (sdr_*, got_ack,
# wait_cnt, s1/s2) stay single-cycle on clk_sys.
set voice_ce_registers [get_registers {*|ssv_es5506_voice:sound_voices|state*}]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|voice_i*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|proc_*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|mix_*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|audio_*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|cr*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|fc*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|lvol*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|rvol*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|accum*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|o*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|eng_*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|filtcount*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|vstart*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|vend*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|k1*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|k2*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|ecount*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|sample_tick*}]]
set_multicycle_path -setup 3 \
    -from $voice_ce_registers -to $voice_ce_registers
set_multicycle_path -hold 2 \
    -from $voice_ce_registers -to $voice_ce_registers
