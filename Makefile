# sw86 - software for the pc86 machine (not tied to any hardware)
# make ASM86=/path/to/asm86   assemble every programs/*/*.asm into build/
ASM86 ?= ../pc86/vm86/build/asm86
SRCS  := $(wildcard programs/*/*.asm)
BINS  := $(patsubst programs/%.asm,build/%.bin,$(SRCS))

all: $(BINS)

build/%.bin: programs/%.asm
	@mkdir -p $(dir $@)
	$(ASM86) $< -o $@

clean:
	rm -rf build
.PHONY: all clean
