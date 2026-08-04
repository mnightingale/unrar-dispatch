#
# Microbenchmark for the CRC32 thread pool in hash.cpp.
#
#   make -f crcmt/makefile run
#   UNRAR_CRC_FOLD=0 make -f crcmt/makefile run    # x86: same table, table CRC
#
# Unlike crcbench, this one is not standalone: it drives the real
# DataHash::Update, so it links unrar's own objects. The top-level makefile has
# no objects-only target, so unrar is built and the .o files it leaves behind
# are reused, minus rar.o which carries main().
#
# If the tree was last built with different CPPFLAGS (crcbench/build-ab.sh
# leaves it clean, but a hand-run `make CPPFLAGS=-DNO_CRC_FOLD` would not),
# run `make -C . clean` first or the benchmark measures that build instead.
#

CXX=c++
# No -Wno-* flags: those exist in the top-level makefile for upstream code
# patterns, they are clang spellings, and GCC reports them as unrecognized.
# mtbench.cpp is local code and should compile clean without them.
CXXFLAGS=-O2 -std=c++11
DEFINES=-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -DRAR_SMP -DUNRAR
DIR=$(dir $(lastword $(MAKEFILE_LIST)))
ROOT=$(DIR)..
BUILD=$(DIR)build

.PHONY: all run clean

all: $(BUILD)/mtbench

$(BUILD)/mtbench: $(DIR)mtbench.cpp $(ROOT)/hash.cpp $(ROOT)/crc.cpp $(ROOT)/threadpool.cpp
	@mkdir -p $(BUILD)
	$(MAKE) -C $(ROOT)
	$(CXX) $(CXXFLAGS) $(DEFINES) -I$(ROOT) -o $@ $(DIR)mtbench.cpp \
		`ls $(ROOT)/*.o | grep -v '/rar\.o$$'` -pthread
	@# Cheap insurance, as in crcbench/build-ab.sh: say which CRC32 the linked
	@# binary can actually reach, so a stale build cannot be mistaken for a result.
	@n=`{ objdump -d $@ 2>/dev/null || otool -tv $@ 2>/dev/null; } | grep -ci pclmul || true`; \
	 echo "==> $@ links $$n pclmulqdq instructions (0 on non-x86, or a -DNO_CRC_FOLD tree)"

run: $(BUILD)/mtbench
	@$(BUILD)/mtbench

clean:
	rm -rf $(BUILD)
