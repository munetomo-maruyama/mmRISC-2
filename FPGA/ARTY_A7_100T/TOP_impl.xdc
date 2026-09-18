#---------------------------------------------------------------------------
# TOP_impl.xdc : implementation-only constraints (read after synth_design)
#
# PMOD JA is not a clock-capable pin pair. TCK/TCKC reaches its BUFG and
# TMSC reaches the escape counter through general routing. The nets are
# referenced by the driver pins of the input buffers (the parent nets), which
# exist only after synthesis.
#---------------------------------------------------------------------------
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins -hierarchical -filter {NAME =~ *JA_TCK_IBUF_inst/O}]]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins -hierarchical -filter {NAME =~ *JA_TMS_IOBUF_inst/O}]]
