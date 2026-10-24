;#module C0COM
; c0com.asm - how a .COM program in C starts and ends
;
; The program keeps its 64 KB segment and gives the rest of memory back,
; so it can run other programs. .bss is cleared; the heap goes from its
; end to 2 KB below the stack.
;#def __start _exit __exit __psp __brk __brkend __dbase __image
;#ref _main __setargv __argc __argv
;#weak __flsall
    org 100h
__dbase equ 0
__image equ 0
section .text
__start:
    cld
    mov [__psp], cs
    mov bx, 1000h
    mov ah, 4Ah
    int 21h
    mov di, __dend
    mov cx, __bend
    sub cx, di
    xor al, al
    rep stosb
    mov ax, __bend
    mov [__brk], ax
    mov ax, sp
    sub ax, 2048
    jb .no_memory
    cmp ax, __bend
    jb .no_memory
    mov [__brkend], ax
    call __setargv
    push word [__argv]
    push word [__argc]
    call _main
    push ax
    call _exit
.no_memory:
    mov dx, .message
    mov ah, 09h
    int 21h
    mov ax, 4C01h
    int 21h
section .data
.message db 'Not enough memory', 13, 10, '$'
section .text

; exit(code): the files are written first; _exit(code) ends at once
_exit:
    call __flsall
__exit:
    mov bx, sp
    mov al, [bx+2]
    mov ah, 4Ch
    int 21h

section .data
__psp dw 0
__brk dw 0
__brkend dw 0
