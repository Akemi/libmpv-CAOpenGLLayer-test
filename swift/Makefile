all: build

build: *.swift
	swiftc -o test test.swift -import-objc-header bridging-header.h `pkg-config --libs --cflags mpv`

clean:
	rm test
