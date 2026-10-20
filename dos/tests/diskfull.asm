; diskfull.asm - writes to B:\FULL.DAT until the diskette is full (meant
; for a diskette with little free space): the last write comes up short
; without an error, no space is left, and deleting the file gives it back.
org 100h

    mov ah, 36h
    mov dl, 2
    int 21h
    mov [free_before], bx
    mov dx, name
    xor cx, cx
    mov ah, 3Ch
    int 21h
    jc bad
    mov [handle], ax
.write:
    mov bx, [handle]
    mov dx, chunk
    mov cx, CHUNK
    mov ah, 40h
    int 21h
    jc bad
    cmp ax, CHUNK
    je .write
    mov bx, [handle]
    mov ah, 3Eh
    int 21h
    jc bad
    mov ah, 36h                     ; nothing left
    mov dl, 2
    int 21h
    test bx, bx
    jnz bad
    mov dx, name
    mov ah, 41h
    int 21h
    jc bad
    mov ah, 36h                     ; all of it back
    mov dl, 2
    int 21h
    cmp bx, [free_before]
    jne bad
    mov dx, s_ok
    jmp done
bad:
    mov dx, s_bad
done:
    mov ah, 09h
    int 21h
    ret

CHUNK       equ 4096
free_before dw 0
handle      dw 0
name        db 'B:FULL.DAT', 0
s_ok        db 'disk full: short write, no space left, all back after delete', 13, 10, '$'
s_bad       db 'disk full: FAIL', 13, 10, '$'
chunk:
