;#module MEMORY
; memory.asm - memcpy, memmove and memset, with the string instructions
;#def _memcpy _memmove _memset
section .text
_memcpy:                                ; void *memcpy(void *d, void *s, int n)
_memmove:                               ; void *memmove(void *d, void *s, int n)
    push bp
    mov bp, sp
    push si
    push di
    mov di, [bp+4]
    mov si, [bp+6]
    mov cx, [bp+8]
    cmp si, di
    jae .up
    add si, cx                          ; overlapping, d above s: from the end
    dec si
    add di, cx
    dec di
    std
    rep movsb
    cld
    jmp short .end
.up:
    rep movsb
.end:
    mov ax, [bp+4]
    pop di
    pop si
    pop bp
    ret
_memset:                                ; void *memset(void *d, int c, int n)
    push bp
    mov bp, sp
    push di
    mov di, [bp+4]
    mov al, [bp+6]
    mov cx, [bp+8]
    rep stosb
    mov ax, [bp+4]
    pop di
    pop bp
    ret
