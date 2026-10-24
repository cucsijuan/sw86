;#module MACHINE
; machine.asm - ports, memory anywhere, interrupts on and off
;#def _inp _outp _inpw _outpw _peekb _peek _pokeb _poke _getds _disable _enable
section .text
_inp:                                   ; int inp(int port)
    mov bx, sp
    mov dx, [bx+2]
    in al, dx
    xor ah, ah
    ret
_outp:                                  ; int outp(int port, int value)
    mov bx, sp
    mov dx, [bx+2]
    mov al, [bx+4]
    out dx, al
    xor ah, ah
    ret
_inpw:                                  ; unsigned inpw(int port)
    mov bx, sp
    mov dx, [bx+2]
    in ax, dx
    ret
_outpw:                                 ; unsigned outpw(int port, unsigned value)
    mov bx, sp
    mov dx, [bx+2]
    mov ax, [bx+4]
    out dx, ax
    ret
_peekb:                                 ; int peekb(unsigned seg, unsigned off)
    mov bx, sp
    push es
    mov es, [bx+2]
    mov bx, [bx+4]
    mov al, [es:bx]
    xor ah, ah
    pop es
    ret
_peek:                                  ; unsigned peek(unsigned seg, unsigned off)
    mov bx, sp
    push es
    mov es, [bx+2]
    mov bx, [bx+4]
    mov ax, [es:bx]
    pop es
    ret
_pokeb:                                 ; void pokeb(unsigned seg, unsigned off, int value)
    mov bx, sp
    push es
    mov al, [bx+6]
    mov es, [bx+2]
    mov bx, [bx+4]
    mov [es:bx], al
    pop es
    ret
_poke:                                  ; void poke(unsigned seg, unsigned off, unsigned value)
    mov bx, sp
    push es
    mov ax, [bx+6]
    mov es, [bx+2]
    mov bx, [bx+4]
    mov [es:bx], ax
    pop es
    ret
_getds:                                 ; unsigned getds(void): the data segment
    mov ax, ds
    ret
_disable:
    cli
    ret
_enable:
    sti
    ret
