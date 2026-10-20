; child.asm - run by DOSTEST: prints its command tail, ends with code 42
org 100h

    mov dx, said
    mov ah, 09h
    int 21h
    mov cl, [80h]
    xor ch, ch
    mov si, 81h
.char:
    jcxz .done
    lodsb
    mov dl, al
    mov ah, 02h
    int 21h
    dec cx
    jmp .char
.done:
    mov dx, crlf
    mov ah, 09h
    int 21h
    mov ax, 4C2Ah
    int 21h

said db 'child got:$'
crlf db 13, 10, '$'
