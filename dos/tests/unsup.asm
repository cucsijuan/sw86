; unsup.asm - calls a function COS does not have (0Fh, open an FCB): the
; kernel says so and ends the program; the line after it never prints.
org 100h

    mov dx, 5Ch
    mov ah, 0Fh
    int 21h
    mov dx, after
    mov ah, 09h
    int 21h
    ret

after db 'still running', 13, 10, '$'
