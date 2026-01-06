.PHONY: all clean test

NIMFLAGS = -d:release --opt:size

all: bin/ocdev

bin/ocdev: cmd/ocdev/src/ocdev.nim cmd/ocdev/src/*.nim
	cd cmd/ocdev && nim c $(NIMFLAGS) -o:../../bin/ocdev src/ocdev.nim

bin/ocdev-debug: cmd/ocdev/src/ocdev.nim cmd/ocdev/src/*.nim
	cd cmd/ocdev && nim c -o:../../bin/ocdev-debug src/ocdev.nim

test: bin/ocdev
	nim c -r cmd/ocdev/tests/test_all.nim
	./cmd/ocdev/tests/integration.sh

clean:
	rm -f bin/ocdev bin/ocdev-debug
	rm -rf cmd/ocdev/deps/pkgs
	find cmd/ocdev -name "*.o" -delete

# Development helpers
dev-setup:
	cd cmd/ocdev && atlas init && atlas use cligen

size-check: bin/ocdev
	@echo "Binary size: $$(du -h bin/ocdev | cut -f1)"
	@size=$$(stat -c%s bin/ocdev 2>/dev/null || stat -f%z bin/ocdev); \
	if [ $$size -gt 512000 ]; then \
		echo "WARNING: Binary exceeds 500KB target"; \
	fi
