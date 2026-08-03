#
# Standalone CRC32 benchmark: unrar's slicing-by-16 vs PCLMULQDQ folding.
#
#   make -f crcbench/makefile run
#
# No -march is passed. Each folding implementation carries its own
# __attribute__((target(...))), matching how unrar already handles SIMD
# (blake2s_sse.cpp, rijndael.hpp, rs16.hpp), so one binary runs everywhere
# and picks a path at runtime.
#

CXX=c++
CXXFLAGS=-O2 -std=c++11 -Wall -Wextra
DIR=$(dir $(lastword $(MAKEFILE_LIST)))
BUILD=$(DIR)build

.PHONY: all run clean

all: $(BUILD)/crcbench

# crcfold.cpp is #included by crcbench.cpp (as crc.cpp does), not compiled
# separately - so the benchmark measures the shipping implementation.
$(BUILD)/crcbench: $(DIR)crcbench.cpp $(DIR)../crcfold.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ $(DIR)crcbench.cpp

run: $(BUILD)/crcbench
	@$(BUILD)/crcbench

clean:
	rm -rf $(BUILD)
