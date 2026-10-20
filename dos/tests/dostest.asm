; dostest.asm - checks the COS kernel through INT 21h (DOSTEST.COM)
;
; Each check prints "ok" or "FAIL" and its name; the last line says how
; many failed. Needs CHILD.COM and TESTEXE.EXE on the current drive and a
; diskette in drive B:. Leaves no files behind.
org 100h

    jmp start

failures dw 0
handle   dw 0
handle2  dw 0

; ---------- output ----------

print:                              ; DS:SI, ASCIIZ
    push ax
    push dx
.next:
    lodsb
    test al, al
    jz .done
    mov dl, al
    mov ah, 02h
    int 21h
    jmp .next
.done:
    pop dx
    pop ax
    ret

; CF = 0: "ok   name", CF = 1: "FAIL name". SI = name.
report:
    push si
    jc .fail
    mov si, s_ok
    call print
    jmp .name
.fail:
    inc word [failures]
    mov si, s_fail
    call print
.name:
    pop si
    call print
    mov si, s_crlf
    call print
    ret

; ---------- helpers ----------

; Fills buf with a pattern that depends on the position: buf[i] = i * 7 + seed
fill:
    mov di, buf
    mov cx, BUF_SIZE
    mov al, [seed]
.next:
    stosb
    add al, 7
    loop .next
    ret

; Compares CX bytes of buf2 with the pattern starting at seed. CF if different.
compare:
    mov si, buf2
    mov al, [seed]
.next:
    cmp [si], al
    jne .bad
    inc si
    add al, 7
    loop .next
    clc
    ret
.bad:
    stc
    ret

seed db 0

; ---------- the checks ----------

t_version:
    mov ah, 30h
    int 21h
    cmp ax, 1E03h                   ; 3.30
    je .ok1
    jmp fail
.ok1:
    clc
    ret

t_create_write:
    mov dx, name1
    xor cx, cx
    mov ah, 3Ch
    int 21h
    jnc .ok2
    jmp fail
.ok2:
    mov [handle], ax
    mov byte [seed], 1
    call fill
    mov bx, [handle]
    mov dx, buf
    mov cx, 1000
    mov ah, 40h
    int 21h
    jnc .ok3
    jmp fail
.ok3:
    cmp ax, 1000
    je .ok4
    jmp fail
.ok4:
    mov ah, 3Eh
    int 21h
    jnc .ok5
    jmp fail
.ok5:
    clc
    ret

t_read_back:
    mov dx, name1
    mov ax, 3D00h
    int 21h
    jnc .ok6
    jmp fail
.ok6:
    mov bx, ax
    mov dx, buf2
    mov cx, 2000
    mov ah, 3Fh
    int 21h
    jnc .ok7
    jmp fail
.ok7:
    cmp ax, 1000
    je .ok8
    jmp fail
.ok8:
    mov dx, buf2                    ; at the end: nothing more
    mov cx, 10
    mov ah, 3Fh
    int 21h
    jnc .ok9
    jmp fail
.ok9:
    test ax, ax
    jz .ok10
    jmp fail
.ok10:
    mov ah, 3Eh
    int 21h
    mov byte [seed], 1
    mov cx, 1000
    call compare
    ret

t_seek_append:
    mov dx, name1
    mov ax, 3D02h
    int 21h
    jnc .ok11
    jmp fail
.ok11:
    mov [handle], ax
    mov bx, ax
    mov ax, 4200h                   ; to 500, read 10
    xor cx, cx
    mov dx, 500
    int 21h
    jnc .ok12
    jmp fail
.ok12:
    mov dx, buf2
    mov cx, 10
    mov ah, 3Fh
    int 21h
    cmp ax, 10
    je .ok13
    jmp fail
.ok13:
    mov byte [seed], 1 + 500 * 7 % 256
    mov cx, 10
    call compare
    jnc .ok14
    jmp fail
.ok14:
    mov bx, [handle]                ; to the end: 1000
    mov ax, 4202h
    xor cx, cx
    xor dx, dx
    int 21h
    cmp ax, 1000
    je .ok15
    jmp fail
.ok15:
    test dx, dx
    jz .ok16
    jmp fail
.ok16:
    mov byte [seed], 50             ; 600 more bytes, into a third cluster
    call fill
    mov bx, [handle]
    mov dx, buf
    mov cx, 600
    mov ah, 40h
    int 21h
    cmp ax, 600
    je .ok17
    jmp fail
.ok17:
    mov ax, 4200h                   ; and read them back
    xor cx, cx
    mov dx, 1000
    int 21h
    mov dx, buf2
    mov cx, 600
    mov ah, 3Fh
    int 21h
    cmp ax, 600
    je .ok18
    jmp fail
.ok18:
    mov ah, 3Eh
    int 21h
    mov byte [seed], 50
    mov cx, 600
    call compare
    ret

t_large:                            ; 40000 bytes: many clusters and tracks
    mov dx, name2
    xor cx, cx
    mov ah, 3Ch
    int 21h
    jnc .ok19
    jmp fail
.ok19:
    mov [handle], ax
    mov byte [seed], 3
    call fill
    mov di, 5
.write:
    mov bx, [handle]
    mov dx, buf
    mov cx, 8000
    mov ah, 40h
    int 21h
    cmp ax, 8000
    je .ok20
    jmp fail
.ok20:
    dec di
    jnz .write
    mov ah, 3Eh
    int 21h
    mov dx, name2
    mov ax, 3D00h
    int 21h
    jnc .ok21
    jmp fail
.ok21:
    mov [handle], ax
    mov di, 5
.read:
    mov bx, [handle]
    mov dx, buf2
    mov cx, 8000
    mov ah, 3Fh
    int 21h
    cmp ax, 8000
    je .ok22
    jmp fail
.ok22:
    mov byte [seed], 3
    mov cx, 8000
    call compare
    jnc .ok23
    jmp fail
.ok23:
    dec di
    jnz .read
    mov bx, [handle]
    mov ah, 3Eh
    int 21h
    clc
    ret

t_truncate:                         ; writing 0 bytes ends the file there
    mov dx, name2
    mov ax, 3D01h
    int 21h
    jnc .ok24
    jmp fail
.ok24:
    mov bx, ax
    mov ax, 4200h
    xor cx, cx
    mov dx, 100
    int 21h
    xor cx, cx
    mov ah, 40h
    int 21h
    jnc .ok25
    jmp fail
.ok25:
    mov ah, 3Eh
    int 21h
    mov dx, name2
    xor cx, cx
    mov ah, 4Eh
    int 21h
    jnc .ok26
    jmp fail
.ok26:
    cmp word [80h+26], 100          ; the size in the DTA
    je .ok27
    jmp fail
.ok27:
    cmp word [80h+28], 0
    je .ok28
    jmp fail
.ok28:
    clc
    ret

t_find:                             ; TEST?.DAT: two files
    mov dx, pattern
    xor cx, cx
    mov ah, 4Eh
    int 21h
    jnc .ok29
    jmp fail
.ok29:
    xor di, di
.count:
    inc di
    mov ah, 4Fh
    int 21h
    jnc .count
    cmp ax, 12h
    je .ok30
    jmp fail
.ok30:
    cmp di, 2
    je .ok31
    jmp fail
.ok31:
    clc
    ret

t_rename:
    mov dx, name1
    mov di, name3
    mov ah, 56h
    int 21h
    jnc .ok32
    jmp fail
.ok32:
    mov dx, name1
    mov ax, 3D00h
    int 21h
    jc .ok33
    jmp fail
.ok33:
    cmp ax, 2
    je .ok34
    jmp fail
.ok34:
    mov dx, name3
    mov ax, 3D00h
    int 21h
    jnc .ok35
    jmp fail
.ok35:
    mov bx, ax
    mov ah, 3Eh
    int 21h
    mov dx, name3                   ; onto an existing name: denied
    mov di, name2
    mov ah, 56h
    int 21h
    jc .ok36
    jmp fail
.ok36:
    cmp ax, 5
    je .ok37
    jmp fail
.ok37:
    clc
    ret

t_attributes:
    mov dx, name3
    mov ax, 4301h
    mov cx, 1                       ; read-only
    int 21h
    jnc .ok38
    jmp fail
.ok38:
    mov dx, name3
    mov ax, 4300h
    int 21h
    test cl, 1
    jnz .ok39
    jmp fail
.ok39:
    mov dx, name3
    mov ah, 41h
    int 21h
    jc .ok40
    jmp fail
.ok40:
    cmp ax, 5
    je .ok41
    jmp fail
.ok41:
    mov dx, name3
    mov ax, 3D01h
    int 21h
    jc .ok42
    jmp fail
.ok42:
    mov dx, name3
    mov ax, 4301h
    xor cx, cx
    int 21h
    jnc .ok43
    jmp fail
.ok43:
    clc
    ret

t_dup:
    mov dx, name3
    mov ax, 3D02h
    int 21h
    jnc .ok44
    jmp fail
.ok44:
    mov [handle], ax
    mov bx, ax
    mov ah, 45h
    int 21h
    jnc .ok45
    jmp fail
.ok45:
    mov [handle2], ax
    mov bx, [handle]                ; close one, the other still works
    mov ah, 3Eh
    int 21h
    mov bx, [handle2]
    mov ax, 4200h
    xor cx, cx
    mov dx, 1000
    int 21h
    jnc .ok46
    jmp fail
.ok46:
    mov dx, buf2
    mov cx, 4
    mov ah, 3Fh
    int 21h
    cmp ax, 4
    je .ok47
    jmp fail
.ok47:
    mov ah, 3Eh
    int 21h
    jnc .ok48
    jmp fail
.ok48:
    mov bx, [handle]                ; really closed now
    mov ah, 3Eh
    int 21h
    jc .ok49
    jmp fail
.ok49:
    cmp ax, 6
    je .ok50
    jmp fail
.ok50:
    mov byte [seed], 50
    mov cx, 4
    call compare
    ret

t_delete:
    mov dx, name3
    mov ah, 41h
    int 21h
    jnc .ok51
    jmp fail
.ok51:
    mov dx, name2
    mov ah, 41h
    int 21h
    jnc .ok52
    jmp fail
.ok52:
    mov dx, pattern
    xor cx, cx
    mov ah, 4Eh
    int 21h
    jc .ok53
    jmp fail
.ok53:
    cmp ax, 2
    je .ok54
    jmp fail
.ok54:
    clc
    ret

t_memory:
    mov ah, 48h                     ; too much: error 8, BX = the largest
    mov bx, 0FFFFh
    int 21h
    jc .ok55
    jmp fail
.ok55:
    cmp ax, 8
    je .ok56
    jmp fail
.ok56:
    cmp bx, 1000h
    jae .ok57
    jmp fail
.ok57:
    mov ah, 48h
    mov bx, 100h
    int 21h
    jnc .ok58
    jmp fail
.ok58:
    mov es, ax
    mov byte [es:0FFFh], 5Ah
    mov ah, 4Ah                     ; shrink, then grow back
    mov bx, 10h
    int 21h
    jnc .ok59
    jmp fail
.ok59:
    mov ah, 4Ah
    mov bx, 200h
    int 21h
    jnc .ok60
    jmp fail
.ok60:
    mov ah, 49h
    int 21h
    jnc .ok61
    jmp fail
.ok61:
    mov ax, cs                      ; a segment that is not a block
    inc ax
    mov es, ax
    mov ah, 49h
    int 21h
    jc .ok62
    jmp fail
.ok62:
    cmp ax, 9
    je .ok63
    jmp fail
.ok63:
    push cs
    pop es
    clc
    ret

t_exec_com:
    mov word [exec_block+2], tail
    mov [exec_block+4], cs
    mov word [exec_block+6], 5Ch
    mov [exec_block+8], cs
    mov word [exec_block+10], 6Ch
    mov [exec_block+12], cs
    mov dx, child
    mov bx, exec_block
    mov ax, 4B00h
    int 21h
    push cs
    pop ds
    push cs
    pop es
    jnc .ok64
    jmp fail
.ok64:
    mov ah, 4Dh
    int 21h
    cmp ax, 002Ah
    je .ok65
    jmp fail
.ok65:
    clc
    ret

t_exec_exe:
    mov dx, exe
    mov bx, exec_block
    mov ax, 4B00h
    int 21h
    push cs
    pop ds
    push cs
    pop es
    jnc .ok66
    jmp fail
.ok66:
    mov ah, 4Dh
    int 21h
    cmp ax, 0007h
    je .ok67
    jmp fail
.ok67:
    clc
    ret

t_exec_missing:
    mov dx, missing
    mov bx, exec_block
    mov ax, 4B00h
    int 21h
    push cs
    pop ds
    push cs
    pop es
    jc .ok68
    jmp fail
.ok68:
    cmp ax, 2
    je .ok69
    jmp fail
.ok69:
    clc
    ret

t_ioctl:
    mov ax, 4400h                   ; standard output: the console
    mov bx, 1
    int 21h
    jnc .ok70
    jmp fail
.ok70:
    test dl, 80h
    jnz .ok71
    jmp fail
.ok71:
    test dl, 02h
    jnz .ok72
    jmp fail
.ok72:
    clc
    ret

t_parse:                            ; B:FOO*.T?T into an FCB
    mov si, parse_text
    mov di, fcb
    mov ax, 2900h
    int 21h
    cmp al, 1                       ; wildcards
    je .ok73
    jmp fail
.ok73:
    cmp byte [fcb], 2
    je .ok74
    jmp fail
.ok74:
    mov si, fcb+1
    mov di, parse_want
    mov cx, 11
    repe cmpsb
    je .ok75
    jmp fail
.ok75:
    clc
    ret

t_cwd:
    mov si, buf2
    mov byte [si], 'x'
    xor dl, dl
    mov ah, 47h
    int 21h
    jnc .ok76
    jmp fail
.ok76:
    cmp byte [buf2], 0
    je .ok77
    jmp fail
.ok77:
    clc
    ret

t_drive_b:                          ; a file on B:, then gone
    mov dx, name_b
    xor cx, cx
    mov ah, 3Ch
    int 21h
    jnc .ok78
    jmp fail
.ok78:
    mov bx, ax
    mov dx, s_ok
    mov cx, 5
    mov ah, 40h
    int 21h
    mov ah, 3Eh
    int 21h
    mov dx, name_b
    mov ax, 3D00h
    int 21h
    jnc .ok79
    jmp fail
.ok79:
    mov bx, ax
    mov dx, buf2
    mov cx, 100
    mov ah, 3Fh
    int 21h
    push ax
    mov ah, 3Eh
    int 21h
    pop ax
    cmp ax, 5
    jne fail
    mov dx, name_b
    mov ah, 41h
    int 21h
    jc fail
    clc
    ret

t_free_space:                       ; deleting gives the clusters back
    mov ah, 36h
    mov dl, 2
    int 21h
    cmp ax, 0FFFFh
    je fail
    mov [free_before], bx
    mul cx                          ; bytes per cluster
    mov cx, ax
    mov ax, 2000 - 1                ; clusters for 2000 bytes
    add ax, cx
    xor dx, dx
    div cx
    mov [clusters], ax
    mov dx, name_b
    xor cx, cx
    mov ah, 3Ch
    int 21h
    jc fail
    mov bx, ax
    mov dx, buf
    mov cx, 2000
    mov ah, 40h
    int 21h
    mov ah, 3Eh
    int 21h
    mov ah, 36h
    mov dl, 2
    int 21h
    mov ax, [free_before]
    sub ax, bx
    cmp ax, [clusters]
    jne fail
    mov dx, name_b
    mov ah, 41h
    int 21h
    mov ah, 36h
    mov dl, 2
    int 21h
    cmp bx, [free_before]
    jne fail
    clc
    ret

free_before dw 0
clusters    dw 0

fail:
    stc
    ret

; ---------- main ----------

tests:
    dw t_version, n_version
    dw t_create_write, n_create_write
    dw t_read_back, n_read_back
    dw t_seek_append, n_seek_append
    dw t_large, n_large
    dw t_truncate, n_truncate
    dw t_find, n_find
    dw t_rename, n_rename
    dw t_attributes, n_attributes
    dw t_dup, n_dup
    dw t_delete, n_delete
    dw t_memory, n_memory
    dw t_exec_com, n_exec_com
    dw t_exec_exe, n_exec_exe
    dw t_exec_missing, n_exec_missing
    dw t_ioctl, n_ioctl
    dw t_parse, n_parse
    dw t_cwd, n_cwd
    dw t_drive_b, n_drive_b
    dw t_free_space, n_free_space
    dw 0

start:
    mov sp, stack_top
    mov bx, (program_end - $$ + 100h + 15) / 16
    mov ah, 4Ah                     ; leave memory for the children
    int 21h
    mov si, tests
.next:
    lodsw
    test ax, ax
    jz .done
    mov bx, ax
    lodsw
    push si
    push ax
    call bx
    pop si
    call report
    pop si
    jmp .next
.done:
    mov si, s_done
    call print
    mov ax, [failures]
    add al, '0'
    mov dl, al
    mov ah, 02h
    int 21h
    mov si, s_failures
    call print
    mov ax, 4C00h
    int 21h

n_version      db 'version 3.30', 0
n_create_write db 'create and write', 0
n_read_back    db 'read back, end of file', 0
n_seek_append  db 'seek, append past a cluster', 0
n_large        db '40000 bytes across tracks', 0
n_truncate     db 'truncate with a 0-byte write', 0
n_find         db 'find first and next with wildcards', 0
n_rename       db 'rename', 0
n_attributes   db 'read-only attribute', 0
n_dup          db 'duplicate handle', 0
n_delete       db 'delete', 0
n_memory       db 'allocate, resize, free', 0
n_exec_com     db 'EXEC a .COM with a tail, return code', 0
n_exec_exe     db 'EXEC an .EXE with a relocation', 0
n_exec_missing db 'EXEC a missing program', 0
n_ioctl        db 'IOCTL: standard output is the console', 0
n_parse        db 'parse a name into an FCB', 0
n_cwd          db 'current directory: the root', 0
n_drive_b      db 'a file on drive B:', 0
n_free_space   db 'free space on B:', 0

s_ok       db 'ok   ', 0
s_fail     db 'FAIL ', 0
s_crlf     db 13, 10, 0
s_done     db 'DOSTEST: ', 0
s_failures db ' failure(s)', 13, 10, 0

name1      db 'TEST1.DAT', 0
name2      db 'TEST2.DAT', 0
name3      db 'TEST3.DAT', 0
pattern    db 'TEST?.DAT', 0
name_b     db 'B:\FILE.B', 0
child      db 'CHILD.COM', 0
exe        db 'TESTEXE.EXE', 0
missing    db 'NOWHERE.COM', 0
tail       db 7, ' hello!', 13
parse_text db 'B:FOO*.T?T', 0
parse_want db 'FOO?????T?T'
fcb        times 37 db 0
exec_block dw 0, tail, 0, 5Ch, 0, 6Ch, 0

program_image_end:

BUF_SIZE    equ 8000
buf         equ program_image_end
buf2        equ buf + BUF_SIZE
stack_top   equ buf2 + BUF_SIZE + 512
program_end equ stack_top
