;#module STDIOA
; stdioa.asm - getc and putc for a character in the buffer; the rest (the
; end of the buffer, CR and Ctrl-Z in text, '\n', a character given back)
; goes to _getc and _putc in stdio.c. A FILE is fd, flags, ptr, cnt, ...
;#def _getc _fgetc _putc _fputc
;#ref __getc __putc
section .text
_getc:                                  ; int getc(FILE *f)
_fgetc:
    mov bx, sp
    mov bx, [bx+2]
    cmp word [bx+12], -1
    jne .slow
    cmp word [bx+6], 0
    jle .slow
    push si
    mov si, [bx+4]
    mov al, [si]
    pop si
    xor ah, ah
    test byte [bx+2], 4
    jz .take
    cmp al, 13
    je .slow
    cmp al, 26
    je .slow
.take:
    inc word [bx+4]
    dec word [bx+6]
    ret
.slow:
    jmp __getc

_putc:                                  ; int putc(int c, FILE *f)
_fputc:
    mov bx, sp
    mov al, [bx+2]
    mov bx, [bx+4]
    cmp al, 10
    je .slow
    test byte [bx+2], 2
    jz .slow
    cmp word [bx+6], 0
    jle .slow
    push si
    mov si, [bx+4]
    mov [si], al
    pop si
    inc word [bx+4]
    dec word [bx+6]
    xor ah, ah
    ret
.slow:
    jmp __putc
