; testexe.asm - a small .EXE written by hand: header, one relocation (the
; segment of its data), its own stack. Prints a message and ends with code 7.
org 0

header:
    db 'MZ'
    dw (file_end - header) % 512        ; bytes in the last page
    dw (file_end - header + 511) / 512  ; pages
    dw 1                                ; relocations
    dw (image - header) / 16            ; header paragraphs
    dw 0                                ; minimum extra paragraphs
    dw 0FFFFh                           ; maximum
    dw (stack_area - image) / 16        ; SS, relative to the image
    dw STACK_SIZE                       ; SP
    dw 0                                ; checksum
    dw start - image                    ; IP
    dw 0                                ; CS, relative to the image
    dw relocations - header
    dw 0                                ; overlay
relocations:
    dw fixup - image, 0
    times 32 - ($ - header) db 0

image:
start:
    db 0B8h                             ; mov ax, segment of the data
fixup:
    dw (data - image) / 16
    mov ds, ax
    mov dx, message - data
    mov ah, 09h
    int 21h
    ; the stack is the one in the header
    mov ax, ss
    sub ax, [cs:fixup - image]
    mov bx, (stack_area - image) / 16 - (data - image) / 16
    cmp ax, bx
    jne .bad
    cmp sp, STACK_SIZE
    jne .bad
    mov ax, 4C07h
    int 21h
.bad:
    mov ax, 4C01h
    int 21h

    times (16 - ($ - image) % 16) % 16 db 0
data:
message db 'Hello from an .EXE', 13, 10, '$'

    times (16 - ($ - image) % 16) % 16 db 0
STACK_SIZE equ 256
stack_area:
    times STACK_SIZE db 0
file_end:
