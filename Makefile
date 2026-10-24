# sw86 - software for the pc86 machine (not tied to any hardware)
# make          assemble every programs/*/*.asm into build/
# make dos      the COS system diskette: build/cos.img
# make smallc   the C compiler: build/smallc (for this computer), build/dos/SMALLC.EXE and CLIB.LIB
# make test     COS, ASM, EDIT, CBasic and Small-C on the machine (needs python3 and the pc86 tools)
ASM86   ?= ../pc86/vm86/build/asm86
FDIMAGE ?= ../pc86/fdc86/build/fdimage
PCRUN   ?= ../pc86/pc86/build/pcrun
SRCS    := $(wildcard programs/*/*.asm)
BINS    := $(patsubst programs/%.asm,build/%.bin,$(SRCS))
HOSTCC  ?= cc
DOS     := build/dos/boot.bin build/dos/COS.SYS build/dos/COMMAND.COM build/dos/ASM.COM build/dos/EDIT.COM \
           build/dos/BASIC.COM build/dos/SMALLC.EXE build/dos/CLIB.LIB
SC_SRCS := smallc/main.c smallc/lex.c smallc/decl.c smallc/expr.c smallc/gen.c smallc/stmt.c smallc/link.c
SC_HDRS := $(wildcard smallc/include/*.h)
LIB_SRCS := $(wildcard smallc/lib/*.asm) $(wildcard smallc/lib/*.c)

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

build/dos/BASIC.COM: dos/basic.asm
	@mkdir -p build/dos
	$(ASM86) $< -o $@

smallc: build/dos/SMALLC.EXE build/dos/CLIB.LIB

build/smallc: $(SC_SRCS) smallc/smallc.h
	@mkdir -p build
	$(HOSTCC) -std=c99 -O1 -o $@ $(SC_SRCS)

build/dos/CLIB.LIB: build/smallc $(LIB_SRCS) $(SC_HDRS)
	@mkdir -p build/dos
	build/smallc -Ismallc/include/ -c -o $@ $(LIB_SRCS)

build/dos/SMALLC.EXE: build/smallc build/dos/CLIB.LIB $(SC_SRCS) smallc/smallc.h $(SC_HDRS)
	build/smallc -n -Lbuild/dos/CLIB.LIB -Ismallc/include/ -e -S -o $@ $(SC_SRCS)
	$(ASM86) build/dos/SMALLC.ASM -o $@

build/cos.img: $(DOS) $(SC_HDRS) programs/hello/hello.asm programs/hello/hello.c dos/apes.bas
	rm -f $@
	$(FDIMAGE) new $@ --label COS
	$(FDIMAGE) add $@ build/dos/COS.SYS
	$(FDIMAGE) add $@ build/dos/COMMAND.COM
	$(FDIMAGE) add $@ build/dos/ASM.COM
	$(FDIMAGE) add $@ build/dos/EDIT.COM
	$(FDIMAGE) add $@ build/dos/BASIC.COM
	$(FDIMAGE) add $@ build/dos/SMALLC.EXE
	$(FDIMAGE) add $@ build/dos/CLIB.LIB
	for h in $(SC_HDRS); do $(FDIMAGE) add $@ $$h $$(basename $$h | tr a-z A-Z); done
	$(FDIMAGE) add $@ programs/hello/hello.asm HELLO.ASM
	$(FDIMAGE) add $@ programs/hello/hello.c HELLO.C
	$(FDIMAGE) add $@ dos/apes.bas APES.BAS
	$(FDIMAGE) boot $@ build/dos/boot.bin

test:
	python3 tests/dos_test.py --asm $(ASM86) --fdimage $(FDIMAGE) --pcrun $(PCRUN)
	python3 tests/tools_test.py --asm $(ASM86) --fdimage $(FDIMAGE) --pcrun $(PCRUN)
	python3 tests/basic_test.py --asm $(ASM86) --fdimage $(FDIMAGE) --pcrun $(PCRUN)
	python3 tests/smallc_test.py --asm $(ASM86) --fdimage $(FDIMAGE) --pcrun $(PCRUN) --hostcc $(HOSTCC)

clean:
	rm -rf build
.PHONY: all dos smallc test clean
