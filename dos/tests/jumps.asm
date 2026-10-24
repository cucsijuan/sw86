; jumps.asm - conditional jumps with NEAR: short when the target is close,
; else the opposite condition over a near JMP. ASM must pick the same form
; as asm86 in every case, also when the distance changes between passes.
org 100h

start:
    cmp ax, bx
    je near start               ; back, close: short
    jl near .far                ; forward, beyond 127 bytes: long
    jg near .close              ; forward, close: short
    times 20 nop
.close:
    jne near .edge              ; just within reach once .grow is short
    times 100 nop
.grow:
    jb near .far
    times 18 nop
.edge:
    jae near start              ; back, beyond -128: long
    times 30 nop
.far:
    ja near .grow
    mov ax, 4C00h
    int 21h
