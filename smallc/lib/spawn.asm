;#module SPAWN
; spawn.asm - running another program
;
; int spawn(char *path, char *args): runs the program (with its extension,
; .COM or .EXE) with that command tail and gives its return code, or -1
; if it could not be run.
;#def _spawn
section .text
_spawn:
    push bp
    mov bp, sp
    push si
    push di
    mov si, [bp+6]                      ; the tail: a count, " args", CR
    mov di, .tail + 1 - __dbase
    mov al, ' '
    stosb
    xor cx, cx
    inc cx
.copy:
    lodsb
    or al, al
    jz .copied
    cmp cx, 126
    jae .copy
    stosb
    inc cx
    jmp .copy
.copied:
    mov al, 13
    stosb
    mov [.tail - __dbase], cl
    mov [.block + 4 - __dbase], ds
    mov [.block + 8 - __dbase], ds
    mov [.block + 12 - __dbase], ds
    mov dx, [bp+4]
    mov bx, .block - __dbase
    mov ax, 4B00h
    int 21h
    jc .error
    mov ah, 4Dh
    int 21h
    xor ah, ah
    jmp short .end
.error:
    mov ax, -1
.end:
    pop di
    pop si
    pop bp
    ret

section .data
.block  dw 0, .tail - __dbase, 0, .fcb - __dbase, 0, .fcb - __dbase, 0
.fcb    db 0, '           ', 0, 0, 0, 0
.tail   times 128 db 0
