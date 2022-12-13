PREFIX		?= /usr/local

.PHONY: all
all: unxip

unxip: unxip.swift
	swiftc -parse-as-library -O $<

.PHONY: clean
clean:
	rm unxip
	
.PHONY: install
install:
	install unxip $(PREFIX)/bin/

.PHONY: uninstall
uninstall:
	rm $(PREFIX)/bin/unxip
