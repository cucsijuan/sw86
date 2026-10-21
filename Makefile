# sw86 - software for the pc86 machine (not tied to any hardware)
# make          assemble every programs/*/*.asm into build/
# make dos      the COS system diskette: build/cos.img
# make test     COS, ASM and EDIT on the machine (needs python3 and the pc86 tools)
ASM86   ?= ../pc86/vm86/build/asm86
FDIMAGE ?= ../pc86/fdc86/build/fdimage
PCRUN   ?= ../pc86/pc86/build/pcrun
SRCS    := $(wildcard programs/*/*.asm)
BINS    := $(patsubst programs/%.asm,build/%.bin,$(SRCS))
DOS     := build/dos/boot.bin build/dos/COS.SYS build/dos/COMMAND.COM build/dos/ASM.COM build/dos/EDIT.COM

all: $(BINS)

build/%.bin: programs/%.asm
	@mkdir -p $(dir $@)
	$(ASM86) $< -o $@

dos: build/cos.img

build/dos/boot.bin: dos/boot.asm
	@mkdir -p build/dos
	$(ASM86) $< -o $@

build/dos/COS.SYS: dos/cos.asm
	@mkdir -p build/dos
	$(ASM86) $< -o $@

build/dos/COMMAND.COM: dos/command.asm
	@mkdir -p build/dos
	$(ASM86) $< -o $@

build/dos/ASM.COM: dos/asm.asm
	@mkdir -p build/dos
	$(ASM86) $< -o $@

build/dos/EDIT.COM: dos/edit.asm
	@mkdir -p build/dos
	$(ASM86) $< -o $@

build/cos.img: $(DOS) programs/hello/hello.asm
	rm -f $@
	$(FDIMAGE) new $@ --label COS
	$(FDIMAGE) add $@ build/dos/COS.SYS
	$(FDIMAGE) add $@ build/dos/COMMAND.COM
	$(FDIMAGE) add $@ build/dos/ASM.COM
	$(FDIMAGE) add $@ build/dos/EDIT.COM
	$(FDIMAGE) add $@ programs/hello/hello.asm HELLO.ASM
	$(FDIMAGE) boot $@ build/dos/boot.bin

test:
	python3 tests/dos_test.py --asm $(ASM86) --fdimage $(FDIMAGE) --pcrun $(PCRUN)
	python3 tests/tools_test.py --asm $(ASM86) --fdimage $(FDIMAGE) --pcrun $(PCRUN)

clean:
	rm -rf build
.PHONY: all dos test clean
