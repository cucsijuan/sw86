;#module DOSIO
; dosio.asm - files by handle: open, creat, close, read, write, unlink,
; rename, lseek, isatty. On an error they return -1 and errno is the code
; COS gave.
;#def _open _creat _close _read _write _unlink _rename _lseek _isatty _errno
section .text
_open:                                  ; int open(char *name, int mode)
    push bp
    mov bp, sp
    mov dx, [bp+4]
    mov al, [bp+6]
    mov ah, 3Dh
    int 21h
    jmp __doserr
_creat:                                 ; int creat(char *name, int attrib)
    push bp
    mov bp, sp
    mov dx, [bp+4]
    mov cx, [bp+6]
    mov ah, 3Ch
    int 21h
    jmp __doserr
_close:                                 ; int close(int fd)
    push bp
    mov bp, sp
    mov bx, [bp+4]
    mov ah, 3Eh
    int 21h
    jc __doserr
    xor ax, ax
    jmp __doserr
_read:                                  ; int read(int fd, void *buf, unsigned n)
    mov ah, 3Fh
    jmp short __rw
_write:                                 ; int write(int fd, void *buf, unsigned n)
    mov ah, 40h
__rw:
    push bp
    mov bp, sp
    mov bx, [bp+4]
    mov dx, [bp+6]
    mov cx, [bp+8]
    int 21h
    jmp __doserr
_unlink:                                ; int unlink(char *name)
    push bp
    mov bp, sp
    mov dx, [bp+4]
    mov ah, 41h
    int 21h
    jc __doserr
    xor ax, ax
    jmp __doserr
_rename:                                ; int rename(char *old, char *new)
    push bp
    mov bp, sp
    push di
    mov dx, [bp+4]
    mov di, [bp+6]
    mov ah, 56h
    int 21h
    pop di
    jc __doserr
    xor ax, ax
    jmp __doserr
_lseek:                                 ; unsigned lseek(int fd, unsigned lo, unsigned hi, int whence)
    push bp
    mov bp, sp
    mov bx, [bp+4]
    mov dx, [bp+6]
    mov cx, [bp+8]
    mov al, [bp+10]
    mov ah, 42h
    int 21h
    jmp __doserr
_isatty:                                ; int isatty(int fd)
    push bp
    mov bp, sp
    mov bx, [bp+4]
    mov ax, 4400h
    int 21h
    mov ax, 0
    jc .no
    test dl, 80h
    jz .no
    inc ax
.no:
    pop bp
    ret

; the end of them all: CF set means AX is an error code
__doserr:
    jnc .ok
    mov [_errno-__dbase], ax
    mov ax, -1
.ok:
    pop bp
    ret

section .data
_errno dw 0
