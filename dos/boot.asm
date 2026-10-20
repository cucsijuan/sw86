; boot.asm - COS boot sector
;
; The BIOS loads this sector at 0000:7C00 and jumps to it with DL = the
; drive. It reads the first FAT, looks for COS.SYS in the root directory
; and loads it at 0070:0000 cluster by cluster, then jumps to it with DL
; still the boot drive. The diskette's own BPB replaces the zeros below
; when the sector is installed (fdimage boot).
;
; Memory while booting: root directory sectors at 0000:0500, the FAT at
; 0000:7E00, the kernel at 0000:0700 (it must stay below 7C00h: 29 KB).
org 7C00h

    jmp short start
    nop
    times 59 db 0                   ; the BPB

SECTORS_PER_CLUSTER equ 7C0Dh       ; BPB fields (word, except the bytes)
RESERVED            equ 7C0Eh
FATS                equ 7C10h       ; byte
ROOT_ENTRIES        equ 7C11h
SECTORS_PER_FAT     equ 7C16h
SECTORS_PER_TRACK   equ 7C18h
HEADS               equ 7C1Ah

DIR_BUFFER  equ 0500h
FAT_BUFFER  equ 7E00h
KERNEL_SEG  equ 0070h

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 7C00h
    sti
    cld
    mov [drive], dl

    ; the root directory follows the FATs; the data area follows it
    mov al, [FATS]
    cbw
    mul word [SECTORS_PER_FAT]
    add ax, [RESERVED]
    mov [root_lba], ax
    mov bx, [ROOT_ENTRIES]
    mov cl, 4
    shr bx, cl                      ; 16 entries per sector
    add bx, ax
    mov [data_lba], bx

    ; the first FAT
    mov ax, [RESERVED]
    mov cx, [SECTORS_PER_FAT]
    mov bx, FAT_BUFFER
read_fat:
    call read_sector
    loop read_fat

    ; look for the kernel in the root directory, a sector at a time
    mov ax, [root_lba]
    mov dx, [ROOT_ENTRIES]
next_dir_sector:
    mov bx, DIR_BUFFER
    call read_sector
    mov di, DIR_BUFFER
next_entry:
    cmp byte [di], 0                ; end of the directory
    je missing
    push di
    mov si, kernel_name
    mov cx, 11
    repe cmpsb
    pop di
    je found
    dec dx
    jz missing
    add di, 32
    cmp di, DIR_BUFFER + 512
    jb next_entry
    jmp next_dir_sector

found:
    mov ax, [di+26]                 ; first cluster
    mov bx, KERNEL_SEG
    mov es, bx
    xor bx, bx
next_cluster:
    push ax
    sub ax, 2
    mov cl, [SECTORS_PER_CLUSTER]
    xor ch, ch
    mul cx
    add ax, [data_lba]
read_cluster:
    call read_sector
    loop read_cluster
    pop ax
    ; FAT12: the entry of cluster n is the 12 bits at n * 1.5
    mov si, ax
    shr si, 1
    add si, ax
    mov dx, [FAT_BUFFER+si]
    test al, 1
    jz even
    mov cl, 4
    shr dx, cl
even:
    and dx, 0FFFh
    mov ax, dx
    cmp ax, 0FF8h
    jb next_cluster

    mov dl, [drive]
    jmp KERNEL_SEG:0000h

missing:
    mov si, msg_missing
    jmp fail

; Reads sector AX (LBA) to ES:BX, then AX + 1 and BX + 512.
; Keeps CX, DX, SI and DI.
read_sector:
    push ax
    push cx
    push dx
    push di
    xor dx, dx
    div word [SECTORS_PER_TRACK]
    mov cl, dl
    inc cl                          ; sector, from 1
    xor dx, dx
    div word [HEADS]
    mov ch, al                      ; cylinder
    mov dh, dl                      ; head
    mov dl, [drive]
    mov di, 4                       ; tries: the first read after a change fails
.try:
    mov ax, 0201h
    int 13h
    jnc .ok
    xor ax, ax                      ; reset the controller and try again
    int 13h
    dec di
    jnz .try
    mov si, msg_error
    jmp fail
.ok:
    pop di
    pop dx
    pop cx
    pop ax
    inc ax
    add bx, 512
    ret

fail:
    call print
    mov si, msg_restart
    call print
    xor ah, ah                      ; a key, then boot again
    int 16h
    int 19h

print:
    lodsb
    test al, al
    jz .done
    mov ah, 0Eh
    mov bx, 0007h
    int 10h
    jmp print
.done:
    ret

kernel_name db 'COS     SYS'
msg_missing db 13, 10, 'COS.SYS is missing', 0
msg_error   db 13, 10, 'Disk error', 0
msg_restart db 13, 10, 'Press any key to restart', 13, 10, 0

drive    db 0
root_lba dw 0
data_lba dw 0

    times 510 - ($ - $$) db 0
