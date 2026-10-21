; hello.asm - the classic: print a string with COS service 09h
org 100h

    mov dx, message     ; DS:DX points to the text
    mov ah, 09h         ; "display a string ending in $"
    int 21h
    ret                 ; a .COM program may end with RET

message db 'Hello from the 8086!', 13, 10, '$'
