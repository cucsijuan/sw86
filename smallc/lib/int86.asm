;#module INT86
; int86.asm - calling an interrupt with the registers in a struct REGS
;
; The interrupt number is written into the INT instruction itself.
;#def _int86 _intdos
section .text
_intdos:                                ; int intdos(struct REGS *in, struct REGS *out)
    mov bx, sp
    push word [bx+4]
    push word [bx+2]
    mov ax, 21h
    push ax
    call _int86
    add sp, 6
    ret
_int86:                                 ; int int86(int n, struct REGS *in, struct REGS *out)
    push bp
    mov bp, sp
    push si
    push di
    mov al, [bp+4]
    mov [cs:__int86n - __image + 1], al
    mov bx, [bp+6]
    mov ax, [bx]
    mov cx, [bx+4]
    mov dx, [bx+6]
    mov si, [bx+8]
    mov di, [bx+10]
    mov bx, [bx+2]
__int86n:
    int 21h
    pushf
    push bx
    mov bx, [bp+8]
    mov [bx], ax
    pop ax
    mov [bx+2], ax
    mov [bx+4], cx
    mov [bx+6], dx
    mov [bx+8], si
    mov [bx+10], di
    pop ax
    and ax, 1
    mov [bx+12], ax
    mov ax, [bx]
    pop di
    pop si
    pop bp
    ret
