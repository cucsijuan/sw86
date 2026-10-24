;#module CONIO
; conio.asm - the keyboard and the screen, directly
;#def _getch _getche _kbhit _putch _cputs
section .text
_getch:                                 ; int getch(void): a key, not shown
    mov ah, 07h
    int 21h
    xor ah, ah
    ret
_getche:                                ; int getche(void): a key, shown
    mov ah, 01h
    int 21h
    xor ah, ah
    ret
_kbhit:                                 ; int kbhit(void): is a key waiting?
    mov ah, 0Bh
    int 21h
    cbw
    ret
_putch:                                 ; int putch(int c)
    mov bx, sp
    mov dl, [bx+2]
    mov ah, 02h
    int 21h
    mov al, dl
    xor ah, ah
    ret
_cputs:                                 ; int cputs(char *s)
    push bp
    mov bp, sp
    push si
    mov si, [bp+4]
.next:
    lodsb
    or al, al
    jz .end
    mov dl, al
    mov ah, 02h
    int 21h
    jmp .next
.end:
    xor ax, ax
    pop si
    pop bp
    ret
