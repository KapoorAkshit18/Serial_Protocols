# ============================================================
# Shrike Lite FPGA - Timing Constraints
# Go Configure
# ============================================================

# ------------------------------------------------------------
# System Clock
# ------------------------------------------------------------
# Input clock = 50 MHz
#
# Period:
#   T = 1 / 50 MHz
#     = 20 ns
#
# Therefore the system clock period is 20 ns.
# ------------------------------------------------------------

create_clock -name clk -period 20.000 [get_ports {clk}]


# ------------------------------------------------------------
# Clock uncertainty
# ------------------------------------------------------------
# Optional margin for clock jitter/skew.
# Keep conservative if your Go Configure flow supports it.
# ------------------------------------------------------------

# set_clock_uncertainty 0.5 [get_clocks clk]