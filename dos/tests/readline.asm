; readline.asm - reads a line from standard input (handle 0) and shows it
org 100h

    mov dx, ask
    mov ah, 09h
    int 21h
    xor bx, bx
    mov dx, line
    mov cx, 80
    mov ah, 3Fh
    int 21h
    mov [count], ax
    mov dx, got
    mov ah, 09h
    int 21h
    mov ax, [count]                 ; bytes, with the CR LF
    add al, '0'
    mov dl, al
    mov ah, 02h
    int 21h
    mov dl, ':'
    int 21h
    mov dl, ' '
    int 21h
    mov bx, 1                       ; and the line itself
    mov dx, line
    mov cx, [count]
    mov ah, 40h
    int 21h
    ret

ask   db 'type a line: $'
got   db 'got $'
count dw 0
line  times 80 db 0
