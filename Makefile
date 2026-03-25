PG_CONFIG    ?= pg_config

PG_VER       := $(shell $(PG_CONFIG) --version | grep -oE '[0-9]+' | head -1)
PG_PKGLIBDIR := $(shell $(PG_CONFIG) --pkglibdir)
PG_SHAREDIR  := $(shell $(PG_CONFIG) --sharedir)
PG_BINDIR    := $(shell $(PG_CONFIG) --bindir)

EXTENSION    = block_copy_command
PACKAGE_DIR  = target/release/$(EXTENSION)-pg$(PG_VER)

# .so on Linux, .dylib on macOS
UNAME_S      := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    LIB_EXT = dylib
else
    LIB_EXT = so
endif

REGRESS      = setup copy_blocked
REGRESS_OPTS = --inputdir=tests/pg_regress

.PHONY: all package install installcheck clean

all: package

package:
	cargo pgrx package --pg-config $(PG_CONFIG)

install: package
	install -m 755 \
		"$(PACKAGE_DIR)$(PG_PKGLIBDIR)/$(EXTENSION).$(LIB_EXT)" \
		"$(PG_PKGLIBDIR)/"
	install -m 644 \
		"$(PACKAGE_DIR)$(PG_SHAREDIR)/extension/$(EXTENSION).control" \
		"$(PG_SHAREDIR)/extension/"
	install -m 644 \
		"$(PACKAGE_DIR)$(PG_SHAREDIR)/extension/$(EXTENSION)"--*.sql \
		"$(PG_SHAREDIR)/extension/"

installcheck:
	"$(PG_BINDIR)/pg_regress" \
		$(REGRESS_OPTS) \
		--bindir="$(PG_BINDIR)" \
		$(REGRESS)

clean:
	cargo clean
