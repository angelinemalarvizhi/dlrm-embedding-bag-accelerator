# cocotb + Icarus flow for the embedding-bag accelerator.
#   make                          all tests (DIM=16, MAX_OUT=4)
#   make DIM=32 MAX_OUT=2         other configurations
#   make NUM_BAGS=500 SEED=3      longer random runs
#   make DEFINES=BUG_MAX_INIT     inject a bug (must FAIL)
SIM          ?= icarus
TOPLEVEL_LANG = verilog
DIM          ?= 16
MAX_OUT      ?= 4
DEFINES      ?=
SEED         ?=
VERILOG_SOURCES = $(PWD)/rtl/sync_fifo.v $(PWD)/rtl/ebag_regs.v $(PWD)/rtl/ebag_engine.v $(PWD)/rtl/ebag_top.v
COCOTB_TOPLEVEL = ebag_top
COCOTB_TEST_MODULES = test_ebag
export PYTHONPATH := $(PWD)/tb:$(PYTHONPATH)
COMPILE_ARGS += -g2005 -Pebag_top.DIM=$(DIM) -Pebag_top.MAX_OUT=$(MAX_OUT) $(addprefix -D,$(DEFINES))
ifneq ($(SEED),)
export COCOTB_RANDOM_SEED = $(SEED)
export RANDOM_SEED = $(SEED)
endif
include $(shell cocotb-config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build* results results.xml __pycache__ tb/__pycache__
