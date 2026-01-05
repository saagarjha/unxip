PREFIX ?= /usr/local

.PHONY: all
all: unxip

unxip:
	swift build -c release

.PHONY: clean
clean:
	swift package clean

.PHONY: install
install:
	install -d $(PREFIX)/bin
	install .build/release/unxip $(PREFIX)/bin/

.PHONY: uninstall
uninstall:
	rm -f $(PREFIX)/bin/unxip

.PHONY: format
format:
	swift-format -i *.swift
