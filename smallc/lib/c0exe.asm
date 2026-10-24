;#module C0EXE
; c0exe.asm - how an .EXE program in C starts and ends
;
; The header comes first: the code is one segment, the data another (its
; .data, .bss, heap and stack, up to 64 KB). The only relocation is the
; segment of the data, in the first instruction.
;#def __start _exit __exit __psp __brk __brkend __dbase __image
;#ref _main __setargv __argc __argv
;#weak __flsall
section .text
__header:
    db 'MZ'
    dw (__dend - __header) % 512        ; bytes in the last page
    dw (__dend - __header + 511) / 512  ; pages
    dw 1                                ; relocations
    dw 2                                ; header paragraphs
    dw (__bend - __dend + 15) / 16 + 257 ; minimum: .bss and 4 KB of stack
    dw 0FFFFh                           ; maximum: all there is
    dw (__bend - __image + 15) / 16     ; SS: the stack after .bss, at first
    dw 4096                             ; SP
    dw 0                                ; checksum
    dw __start - __image                ; IP
    dw 0                                ; CS
    dw 28                               ; where the relocations are
    dw 0                                ; overlay
    dw __fixup - __image, 0
__image:
__start:
    db 0B8h                             ; mov ax, the segment of the data
__fixup:
    dw (__dbase - __image) / 16
    mov ds, ax
    mov [__psp - __dbase], es
    mov bx, [es:2]                      ; up to 64 KB of data, if there is
    sub bx, ax
    cmp bx, 1000h
    jbe .size
    mov bx, 1000h
.size:
    mov dx, bx
    mov cl, 4
    shl dx, cl                          ; 1000h paragraphs: SP = 0, the top
    cli
    mov ss, ax
    mov sp, dx
    sti
    add bx, ax                          ; keep that, give the rest back
    mov ax, es
    sub bx, ax
    mov ah, 4Ah
    int 21h
    push ds
    pop es
    cld
    mov di, __dend - __dbase
    mov cx, __bend - __dend
    xor al, al
    rep stosb
    mov ax, __bend - __dbase
    mov [__brk - __dbase], ax
    mov ax, sp
    or ax, ax
    jnz .below
    mov ax, 0F800h
    jmp short .heap
.below:
    sub ax, 2048
    jb .no_memory
.heap:
    cmp ax, __bend - __dbase
    jb .no_memory
    mov [__brkend - __dbase], ax
    call __setargv
    push word [__argv - __dbase]
    push word [__argc - __dbase]
    call _main
    push ax
    call _exit
.no_memory:
    mov dx, __nomem - __dbase
    mov ah, 09h
    int 21h
    mov ax, 4C01h
    int 21h

; exit(code): the files are written first; _exit(code) ends at once
_exit:
    call __flsall
__exit:
    mov bx, sp
    mov al, [bx+2]
    mov ah, 4Ch
    int 21h

section .data
__dbase:
__psp dw 0
__brk dw 0
__brkend dw 0
__nomem db 'Not enough memory', 13, 10, '$'
