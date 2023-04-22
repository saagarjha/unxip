PREFIX ?= /usr/local

.PHONY: all
all: unxip

unxip: unxip.swift
	swiftc -O -whole-module-optimization -parse-as-library $<

.PHONY: clean
clean:
	rm unxip

.PHONY: install
install:
	install unxip $(PREFIX)/bin/

.PHONY: uninstall
uninstall:
	rm $(PREFIX)/bin/unxip

.PHONY: format
format:
	swift-format -i *.swift
