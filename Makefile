all: build

build: *.m
	clang -Wall -o test test.m `pkg-config --libs --cflags mpv` -framework Cocoa -framework OpenGL -framework QuartzCore

fmt:
	clang-format -i test.m

clean:
	rm test
