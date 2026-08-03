#
# Multi-ISA unrar build. Standalone: the vendored ../makefile is never edited.
#
#   make -f dispatch/makefile all       build variants + dispatcher
#   make -f dispatch/makefile bench     benchmark the built variants
#   make -f dispatch/makefile audit     ISA-containment disassembly audit
#   make -f dispatch/makefile install   install to $(DESTDIR)
#
# On aarch64 the recommended output is a single binary with no dispatcher:
# the unrar source already runtime-gates its NEON paths (crc.cpp:44 CRC_Neon,
# rijndael.cpp:125 AES_Neon), and the audit target verifies the compiler kept
# those instructions inside the guarded functions.
#

CC=cc
CFLAGS=-O2 -Wall -Wextra -std=c99
DESTDIR=/usr
BINDIR=$(DESTDIR)/bin
LIBEXECDIR=$(DESTDIR)/libexec/unrar

# abspath, not a relative path: scripts that cd (make-corpus.sh) would
# otherwise resolve these against the wrong directory. It also keeps build
# output readable rather than "dispatch/../dispatch/...".
ROOT=$(abspath $(dir $(lastword $(MAKEFILE_LIST)))..)
BUILD=$(ROOT)/dispatch/build
CORPUS=$(ROOT)/dispatch/corpus

ARCH := $(shell uname -m)

# The dispatcher is only meaningful where there is an ISA ladder to choose
# between. aarch64 ships one binary.
ifneq (,$(filter x86_64 amd64,$(ARCH)))
  NEED_DISPATCH=1
else
  NEED_DISPATCH=0
endif

.PHONY: all variants dispatcher bench audit corpus install uninstall clean help

ifeq ($(NEED_DISPATCH),1)
all: variants dispatcher
else
all: variants
	@echo
	@echo "$(ARCH): single binary, no dispatcher needed."
	@echo "Run 'make -f dispatch/makefile audit' to confirm ISA containment."
endif

variants:
	$(ROOT)/dispatch/build-variants.sh -o $(BUILD)

dispatcher: $(BUILD)/unrar
$(BUILD)/unrar: $(ROOT)/dispatch/unrar-dispatch.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -DUNRAR_VARIANT_DIR='"$(LIBEXECDIR)"' \
	      -o $@ $(ROOT)/dispatch/unrar-dispatch.c

corpus:
	$(ROOT)/dispatch/make-corpus.sh -o $(CORPUS)

bench:
	$(ROOT)/dispatch/bench.sh -b $(BUILD) -c $(CORPUS)

# Needs unstripped binaries to attribute instructions to symbols.
audit:
	$(ROOT)/dispatch/build-variants.sh -u -o $(BUILD)-sym
	@for b in $(BUILD)-sym/unrar.*; do \
	  case "$$b" in *.buildlog) continue;; esac; \
	  $(ROOT)/dispatch/audit-isa.sh "$$b"; \
	done

ifeq ($(NEED_DISPATCH),1)
install: all
	install -d $(BINDIR) $(LIBEXECDIR)
	install -m 755 $(BUILD)/unrar $(BINDIR)/unrar
	@for v in $(BUILD)/unrar.*; do \
	  case "$$v" in *.buildlog) continue;; esac; \
	  echo "install -m 755 $$v $(LIBEXECDIR)/"; \
	  install -m 755 "$$v" $(LIBEXECDIR)/; \
	done
else
install: all
	install -d $(BINDIR)
	@v=$$(ls $(BUILD)/unrar.* 2>/dev/null | grep -v buildlog | head -1); \
	 echo "install -m 755 $$v $(BINDIR)/unrar"; \
	 install -m 755 "$$v" $(BINDIR)/unrar
endif

uninstall:
	rm -f $(BINDIR)/unrar
	rm -rf $(LIBEXECDIR)

clean:
	rm -rf $(BUILD) $(BUILD)-sym
	$(MAKE) -C $(ROOT) clean

help:
	@sed -n '2,15p' $(lastword $(MAKEFILE_LIST))
