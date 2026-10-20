# sw86 - software for the pc86 machine (not tied to any hardware)
# make          assemble every programs/*/*.asm into build/
# make dos      the DOS86 system diskette: build/dos86.img
# make test     DOS86 on the machine (needs python3 and the pc86 tools)
ASM86   ?= ../pc86/vm86/build/asm86
FDIMAGE ?= ../pc86/fdc86/build/fdimage
PCRUN   ?= ../pc86/pc86/build/pcrun
SRCS    := $(wildcard programs/*/*.asm)
BINS    := $(patsubst programs/%.asm,build/%.bin,$(SRCS))
DOS     := build/dos/boot.bin build/dos/DOS86.SYS build/dos/COMMAND.COM

all: $(BINS)

build/%.bin: programs/%.asm
	@mkdir -p $(dir $@)
	$(ASM86) $< -o $@

dos: build/dos86.img

build/dos/boot.bin: dos/boot.asm
	@mkdir -p build/dos
	$(ASM86) $< -o $@

build/dos/DOS86.SYS: dos/dos86.asm
	@mkdir -p build/dos
	$(ASM86) $< -o $@

build/dos/COMMAND.COM: dos/command.asm
	@mkdir -p build/dos
	$(ASM86) $< -o $@

build/dos86.img: $(DOS)
	rm -f $@
	$(FDIMAGE) new $@ --label DOS86
	$(FDIMAGE) add $@ build/dos/DOS86.SYS
	$(FDIMAGE) add $@ build/dos/COMMAND.COM
	$(FDIMAGE) boot $@ build/dos/boot.bin

test:
	python3 tests/dos_test.py --asm $(ASM86) --fdimage $(FDIMAGE) --pcrun $(PCRUN)

clean:
	rm -rf build
.PHONY: all dos test clean
