; dos86.asm - DOS86 kernel (DOS86.SYS)
;
; A subset of MS-DOS 3.30 for the pc86 machine: INT 21h with the real
; function numbers, .COM and .EXE programs with a PSP and an environment,
; memory control blocks, file handles on FAT12 diskettes in drives A: and B:
; (root directory only), the console through the BIOS, Ctrl-C (INT 23h) and
; critical errors (INT 24h). A function it does not implement stops the
; program with a message instead of doing something different.
;
; The boot sector loads this file at 0070:0000 and jumps to it with DL =
; the boot drive. Code and data use one segment; buffers and stacks follow
; the image (see "Memory past the image" at the end); the free memory
; starts after them.
;
; Inside INT 21h: DS = ES = SS = the kernel segment, the caller's registers
; are in r_ax..r_fl (copied back to the caller's stack frame on return).
; File system routines get the drive table entry in BP.
org 0

KSEG            equ 0070h

; drive table entry
D_NUM           equ 0           ; BIOS drive number
D_VALID         equ 1           ; BPB and FAT loaded
D_SPC           equ 2           ; sectors per cluster
D_FATS          equ 3
D_RES           equ 4           ; reserved sectors
D_ROOTENT       equ 6
D_TOTAL         equ 8
D_SPF           equ 10
D_SPT           equ 12
D_HEADS         equ 14
D_ROOTLBA       equ 16
D_DATALBA       equ 18
D_MAXCL         equ 20          ; highest cluster number
D_CLBYTES       equ 22
D_FATBUF        equ 24
D_FATDIRTY      equ 26
D_HINT          equ 28          ; where to look for a free cluster
D_SIZE          equ 32
MAX_DRIVES      equ 2

; system file table entry
SF_REF          equ 0           ; handles pointing at it, 0 = free
SF_MODE         equ 1           ; 0 read, 1 write, 2 read/write
SF_FLAGS        equ 2
SF_DEV          equ 3           ; device type, or the drive of a file
SF_ATTR         equ 4
SF_FIRST        equ 6
SF_SIZE         equ 8           ; dword
SF_POS          equ 12          ; dword
SF_DIRIX        equ 16
SF_CURCL        equ 18          ; cluster number SF_CURCI of the chain
SF_CURCI        equ 20          ; FFFFh: unknown
SF_TIME         equ 22
SF_DATE         equ 24
SF_NAME         equ 26          ; 11 bytes
SFT_SIZE        equ 40
SFT_COUNT       equ 20

F_DEVICE        equ 80h
F_CLEAN         equ 40h         ; not written since it was opened
F_RAW           equ 20h         ; device in raw (binary) mode
F_STAMP         equ 02h         ; date and time set with 5701h
F_DIRTY         equ 01h         ; the directory entry needs updating

DEV_CON         equ 1
DEV_NUL         equ 2

ERR_FULL        equ 0FFFFh      ; internal: no free cluster

    jmp init

; ======================================================================
; INT 21h
; ======================================================================

; The caller's registers, in the order of the stack frame built on entry
r_ax    dw 0
r_bx    dw 0
r_cx    dw 0
r_dx    dw 0
r_si    dw 0
r_di    dw 0
r_bp    dw 0
r_ds    dw 0
r_es    dw 0
r_ip    dw 0
r_cs    dw 0
r_fl    dw 0

u_ss    dw 0                    ; the caller's stack (points at the frame)
u_sp    dw 0
indos   db 0

int21:
    push es
    push ds
    push bp
    push di
    push si
    push dx
    push cx
    push bx
    push ax
    mov ax, cs
    mov es, ax
    mov ax, ss
    mov ds, ax
    mov si, sp
    mov di, r_ax
    mov cx, 12
    cld
    rep movsw
    mov ax, cs
    mov ds, ax
    mov [u_ss], ss
    mov [u_sp], sp
    cli
    mov ss, ax
    mov sp, kstack_top
    sti
    inc byte [indos]
    and word [r_fl], 0FFFEh         ; CF clear unless the function fails
    mov bl, [r_ax+1]
    cmp bl, 68h
    ja .unsupported
    xor bh, bh
    shl bx, 1
    call [fn_table+bx]
    jmp dos_exit
.unsupported:
    jmp fn_unsupported

; Copies r_ax..r_fl back into the frame and returns to the caller.
dos_exit:
    cli
    mov ss, [u_ss]
    mov sp, [u_sp]
    sti
    dec byte [indos]
    mov es, [u_ss]
    mov di, sp
    mov si, r_ax
    mov cx, 12
    cld
    rep movsw
    pop ax
    pop bx
    pop cx
    pop dx
    pop si
    pop di
    pop bp
    pop ds
    pop es
    iret

; AX = error code: the caller gets CF set and AX = the code.
set_error:
    mov [r_ax], ax
    mov [last_error], ax
    or word [r_fl], 1
    ret

fn_table:
    dw fn_00, fn_01, fn_02, fn_unsupported, fn_unsupported, fn_unsupported, fn_06, fn_07     ; 00
    dw fn_08, fn_09, fn_0A, fn_0B, fn_0C, fn_0D, fn_0E, fn_unsupported                      ; 08
    dw fn_unsupported, fn_unsupported, fn_unsupported, fn_unsupported                       ; 10
    dw fn_unsupported, fn_unsupported, fn_unsupported, fn_unsupported
    dw fn_unsupported, fn_19, fn_1A, fn_unsupported, fn_unsupported, fn_unsupported         ; 18
    dw fn_unsupported, fn_unsupported
    dw fn_unsupported, fn_unsupported, fn_unsupported, fn_unsupported, fn_unsupported       ; 20
    dw fn_25, fn_unsupported, fn_unsupported
    dw fn_unsupported, fn_29, fn_2A, fn_2B, fn_2C, fn_2D, fn_2E, fn_2F                      ; 28
    dw fn_30, fn_31, fn_unsupported, fn_33, fn_34, fn_35, fn_36, fn_37                      ; 30
    dw fn_38, fn_unsupported, fn_unsupported, fn_3B, fn_3C, fn_3D, fn_3E, fn_3F             ; 38
    dw fn_40, fn_41, fn_42, fn_43, fn_44, fn_45, fn_46, fn_47                               ; 40
    dw fn_48, fn_49, fn_4A, fn_4B, fn_4C, fn_4D, fn_4E, fn_4F                               ; 48
    dw fn_50, fn_62, fn_unsupported, fn_unsupported, fn_54, fn_unsupported, fn_56, fn_57    ; 50
    dw fn_58, fn_59, fn_unsupported, fn_5B, fn_unsupported, fn_unsupported                  ; 58
    dw fn_unsupported, fn_unsupported
    dw fn_unsupported, fn_unsupported, fn_62, fn_unsupported, fn_unsupported                ; 60
    dw fn_unsupported, fn_unsupported, fn_unsupported
    dw fn_68                                                                                ; 68

; A function this DOS does not have: say so and end the program.
fn_unsupported:
    mov si, msg_unsup_fn
    call print_str
    mov al, [r_ax+1]
    call print_hex8
    mov si, msg_unsup_end
    call print_str
    mov ax, 00FFh
    jmp terminate

; ======================================================================
; Console
; ======================================================================

pending_scan db 0               ; scan code still to return after a 0

; AL to the screen through the BIOS; a tab moves to the next multiple of 8.
con_out:
    push ax
    push bx
    push cx
    push dx
    cmp al, 9
    jne .plain
    mov ah, 03h
    xor bh, bh
    int 10h
    mov cl, dl
    and cl, 7
    mov ch, 8
    sub ch, cl
.space:
    mov al, ' '
    call tty
    dec ch
    jnz .space
    jmp .done
.plain:
    call tty
.done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

tty:
    mov ah, 0Eh
    mov bx, 0007h
    int 10h
    ret

; Waits for a key: AL = its character, or 0 and the scan code on the next call.
con_read:
    mov al, [pending_scan]
    test al, al
    jz .wait
    mov byte [pending_scan], 0
    ret
.wait:
    xor ah, ah
    int 16h
    test al, al
    jnz .done
    mov [pending_scan], ah
.done:
    ret

; ZF = 1 if no key is waiting.
con_check:
    cmp byte [pending_scan], 0
    jne .done
    mov ah, 01h
    int 16h
.done:
    ret

; Like con_read, but Ctrl-C runs the Ctrl-C handler.
con_read_brk:
    call con_read
    cmp al, 3
    je ctrl_c
    ret

; Ctrl-C inside a function: back to the caller's context with its own
; registers, INT 23h, and the function again if the handler returns.
ctrl_c:
    mov si, msg_ctrl_c
    call print_str
    cli
    mov ss, [u_ss]
    mov sp, [u_sp]
    sti
    dec byte [indos]
    pop ax
    pop bx
    pop cx
    pop dx
    pop si
    pop di
    pop bp
    pop ds
    pop es
    int 23h
    jmp int21

print_str:                      ; DS:SI, ASCIIZ
    push ax
    push si
.next:
    lodsb
    test al, al
    jz .done
    call con_out
    jmp .next
.done:
    pop si
    pop ax
    ret

print_hex8:                     ; AL in two hex digits
    push ax
    push cx
    mov ah, al
    mov cl, 4
    shr al, cl
    call .digit
    mov al, ah
    and al, 0Fh
    call .digit
    pop cx
    pop ax
    ret
.digit:
    add al, '0'
    cmp al, '9'
    jbe .out
    add al, 7
.out:
    call con_out
    ret

; Echoes a typed character: control characters as ^X.
echo_char:
    cmp al, ' '
    jae .plain
    cmp al, 9
    je .plain
    push ax
    mov al, '^'
    call con_out
    pop ax
    push ax
    add al, '@'
    call con_out
    pop ax
    ret
.plain:
    call con_out
    ret

; Erases the character AL from the screen (two columns for ^X).
erase_char:
    cmp al, ' '
    jae .one
    cmp al, 9
    je .one
    call .one
.one:
    push ax
    mov al, 8
    call con_out
    mov al, ' '
    call con_out
    mov al, 8
    call con_out
    pop ax
    ret

; Line input into ES:DI: [max] [count] [characters... CR], as function 0Ah.
line_input:
    mov cl, [es:di]
    test cl, cl
    jz .ret
    xor ch, ch
.key:
    call con_read
    test al, al
    jz .extended
    cmp al, 3
    jne .ok1
    jmp ctrl_c
.ok1:
    cmp al, 13
    je .enter
    cmp al, 8
    je .backspace
    cmp al, 27
    je .escape
    mov ah, ch
    inc ah
    cmp ah, cl
    jae .full
    mov bl, ch
    xor bh, bh
    mov [es:di+bx+2], al
    inc ch
    call echo_char
    jmp .key
.full:
    mov al, 7
    call con_out
    jmp .key
.extended:
    call con_read                   ; editing keys are not supported: drop them
    jmp .key
.backspace:
    test ch, ch
    jz .key
    dec ch
    mov bl, ch
    xor bh, bh
    mov al, [es:di+bx+2]
    call erase_char
    jmp .key
.escape:                            ; cancel the line, as DOS: "\" and a new line
    mov al, '\'
    call con_out
    mov al, 13
    call con_out
    mov al, 10
    call con_out
    xor ch, ch
    jmp .key
.enter:
    mov bl, ch
    xor bh, bh
    mov byte [es:di+bx+2], 13
    mov [es:di+1], ch
    mov al, 13
    call con_out
.ret:
    ret

fn_01:                              ; read a key with echo
    call con_read_brk
    mov [r_ax], al
    test al, al
    jz .ret
    call echo_char
.ret:
    ret

fn_02:                              ; write DL
    mov al, [r_dx]
    mov [r_ax], al
    call con_out
    ret

fn_06:                              ; direct console I/O
    mov al, [r_dx]
    cmp al, 0FFh
    je .input
    mov [r_ax], al
    call con_out
    ret
.input:
    call con_check
    jz .none
    call con_read
    mov [r_ax], al
    and word [r_fl], 0FFBFh         ; ZF = 0: a character
    ret
.none:
    mov byte [r_ax], 0
    or word [r_fl], 0040h
    ret

fn_07:                              ; read a key, no echo, no Ctrl-C check
    call con_read
    mov [r_ax], al
    ret

fn_08:                              ; read a key, no echo
    call con_read_brk
    mov [r_ax], al
    ret

fn_09:                              ; write the string at DS:DX up to '$'
    push ds
    mov si, [r_dx]
    mov ds, [r_ds]
.next:
    lodsb
    cmp al, '$'
    je .done
    call con_out
    jmp .next
.done:
    pop ds
    mov [r_ax], al
    ret

fn_0A:                              ; buffered input at DS:DX
    mov es, [r_ds]
    mov di, [r_dx]
    call line_input
    push cs
    pop es
    ret

fn_0B:                              ; is a key waiting? (Ctrl-C is handled)
    call con_check
    jz .none
    cmp byte [pending_scan], 0
    jne .some
    cmp al, 3
    jne .some
    call con_read
    jmp ctrl_c
.some:
    mov byte [r_ax], 0FFh
    ret
.none:
    mov byte [r_ax], 0
    ret

fn_0C:                              ; flush the keyboard, then function AL
    call con_check
    jz .flushed
    call con_read
    jmp fn_0C
.flushed:
    mov al, [r_ax]
    mov [r_ax+1], al
    cmp al, 01h
    jne .ok2
    jmp fn_01
.ok2:
    cmp al, 06h
    jne .ok3
    jmp fn_06
.ok3:
    cmp al, 07h
    je fn_07
    cmp al, 08h
    je fn_08
    cmp al, 0Ah
    je fn_0A
    mov byte [r_ax], 0
    ret

; ======================================================================
; Simple functions
; ======================================================================

fn_19:                              ; current drive
    mov al, [cur_drive]
    mov [r_ax], al
    ret

fn_0E:                              ; select drive DL
    mov al, [r_dx]
    cmp al, [num_drives]
    jae .ret
    mov [cur_drive], al
.ret:
    mov al, [num_drives]
    mov [r_ax], al
    ret

fn_0D:                              ; disk reset: write everything pending
    call flush_all
    ret

fn_1A:                              ; set the DTA to DS:DX
    mov ax, [r_dx]
    mov [dta_off], ax
    mov ax, [r_ds]
    mov [dta_seg], ax
    ret

fn_2F:                              ; get the DTA
    mov ax, [dta_off]
    mov [r_bx], ax
    mov ax, [dta_seg]
    mov [r_es], ax
    ret

fn_25:                              ; set interrupt vector AL to DS:DX
    xor ax, ax
    mov es, ax
    mov bl, [r_ax]
    xor bh, bh
    shl bx, 1
    shl bx, 1
    mov ax, [r_dx]
    cli
    mov [es:bx], ax
    mov ax, [r_ds]
    mov [es:bx+2], ax
    sti
    push cs
    pop es
    ret

fn_35:                              ; get interrupt vector AL
    xor ax, ax
    mov es, ax
    mov bl, [r_ax]
    xor bh, bh
    shl bx, 1
    shl bx, 1
    mov ax, [es:bx]
    mov [r_bx], ax
    mov ax, [es:bx+2]
    mov [r_es], ax
    push cs
    pop es
    ret

fn_2E:                              ; set the verify flag
    mov al, [r_ax]
    and al, 1
    mov [verify], al
    ret

fn_54:                              ; get the verify flag
    mov al, [verify]
    mov [r_ax], al
    ret

fn_30:                              ; version 3.30
    mov word [r_ax], 1E03h
    mov word [r_bx], 0FF00h
    mov word [r_cx], 0
    ret

fn_33:                              ; Ctrl-Break flag, boot drive
    mov al, [r_ax]
    cmp al, 0
    je .get
    cmp al, 1
    je .set
    cmp al, 5
    je .boot
    jmp fn_unsupported
.get:
    mov al, [break_flag]
    mov [r_dx], al
    ret
.set:
    mov al, [r_dx]
    and al, 1
    mov [break_flag], al
    ret
.boot:
    mov al, [boot_drive]
    inc al
    mov [r_dx], al
    ret

fn_34:                              ; address of the InDOS flag
    mov word [r_bx], indos
    mov [r_es], cs
    ret

fn_37:                              ; switch character
    cmp byte [r_ax], 0
    je .get
    jmp fn_unsupported
.get:
    mov byte [r_dx], '/'
    mov byte [r_ax], 0
    ret

fn_38:                              ; country information (United States)
    cmp byte [r_ax], 0
    je .get
    jmp fn_unsupported
.get:
    mov es, [r_ds]
    mov di, [r_dx]
    mov si, country_info
    mov cx, 34
    rep movsb
    push cs
    pop es
    mov word [r_bx], 1
    ret

fn_50:                              ; set the current PSP
    mov ax, [r_bx]
    mov [cur_psp], ax
    ret

fn_62:                              ; get the current PSP
    mov ax, [cur_psp]
    mov [r_bx], ax
    ret

fn_58:                              ; allocation strategy: first fit only
    mov al, [r_ax]
    cmp al, 0
    je .get
    cmp al, 1
    jne .unsupported
    cmp word [r_bx], 0
    jne .unsupported
    ret
.get:
    mov word [r_ax], 0
    ret
.unsupported:
    jmp fn_unsupported

fn_59:                              ; extended error
    mov ax, [last_error]
    mov [r_ax], ax
    mov word [r_bx], 0104h          ; class: out of resource, action: abort
    mov byte [r_cx+1], 1            ; locus: unknown
    ret

; ======================================================================
; Date and time
; ======================================================================

; Reads the BIOS tick count, advances the date at midnight: CX:DX ticks.
update_date:
    xor ah, ah
    int 1Ah
    test al, al
    jz .ret
    push cx
    push dx
    call next_day
    pop dx
    pop cx
.ret:
    ret

next_day:
    mov al, [cur_month]
    call month_days
    inc byte [cur_day]
    cmp [cur_day], al
    jbe .ret
    mov byte [cur_day], 1
    inc byte [cur_month]
    cmp byte [cur_month], 12
    jbe .ret
    mov byte [cur_month], 1
    inc word [cur_year]
.ret:
    ret

; AL = month of [cur_year] -> AL = its days. Keeps the other registers.
month_days:
    push bx
    push ax
    mov bx, [cur_year]
    call days_in
    pop bx
    pop bx
    ret
; AL = month, BX = year -> AL = days
days_in:
    cmp al, 2
    jne .table
    mov al, 28
    test bl, 3
    jnz .ret
    inc al
.ret:
    ret
.table:
    push bx
    mov bl, al
    xor bh, bh
    mov al, [month_len+bx-1]
    pop bx
    ret

month_len db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

fn_2A:                              ; get date
    call update_date
    mov ax, [cur_year]
    mov [r_cx], ax
    mov al, [cur_month]
    mov [r_dx+1], al
    mov al, [cur_day]
    mov [r_dx], al
    ; day of the week: 1 January 1980 was a Tuesday
    mov dx, 2
    mov bx, 1980
.year:
    cmp bx, [cur_year]
    jae .months
    add dx, 365
    test bl, 3
    jnz .ny
    inc dx
.ny:
    inc bx
    jmp .year
.months:
    mov al, 1
.month:
    cmp al, [cur_month]
    jae .days
    push ax
    call days_in
    xor ah, ah
    add dx, ax
    pop ax
    inc al
    jmp .month
.days:
    mov al, [cur_day]
    dec al
    xor ah, ah
    add ax, dx
    xor dx, dx
    mov bx, 7
    div bx
    mov [r_ax], dl
    ret

fn_2B:                              ; set date CX-DH-DL
    mov bx, [r_cx]
    cmp bx, 1980
    jb .bad
    cmp bx, 2099
    ja .bad
    mov al, [r_dx+1]
    cmp al, 1
    jb .bad
    cmp al, 12
    ja .bad
    push ax
    call days_in
    mov ah, al
    pop cx
    mov al, [r_dx]
    cmp al, 1
    jb .bad
    cmp al, ah
    ja .bad
    mov [cur_year], bx
    mov [cur_month], cl
    mov [cur_day], al
    mov byte [r_ax], 0
    ret
.bad:
    mov byte [r_ax], 0FFh
    ret

; The tick counter runs at 1193180 / 65536 = 18.2065 Hz = 19663 / 1080.
; CX:DX ticks -> AX seconds since midnight (DX:AX), CX hundredths.
ticks_to_time:
    mov ax, dx
    mov dx, cx
    mov bx, 1080
    call mul32
    mov bx, 19663
    call div32                      ; DX:AX seconds, CX remainder
    push dx
    push ax
    mov ax, cx
    mov bx, 100
    mul bx
    mov bx, 19663
    div bx
    mov cx, ax                      ; hundredths
    pop ax
    pop dx
    ret

fn_2C:                              ; get time
    call update_date
    call ticks_to_time
    mov [r_dx], cl
    mov bx, 3600
    div bx                          ; AX hours, DX seconds of the hour
    mov [r_cx+1], al
    mov ax, dx
    mov bl, 60
    div bl
    mov [r_cx], al
    mov [r_dx+1], ah
    ret

fn_2D:                              ; set time CH:CL:DH.DL
    mov al, [r_cx+1]
    cmp al, 23
    ja .bad
    cmp byte [r_cx], 59
    ja .bad
    cmp byte [r_dx+1], 59
    ja .bad
    cmp byte [r_dx], 99
    ja .bad
    ; seconds since midnight
    xor ah, ah
    mov bx, 3600
    mul bx
    push dx
    push ax
    mov al, [r_cx]
    mov bl, 60
    mul bl
    mov bl, [r_dx+1]
    xor bh, bh
    add ax, bx
    pop bx
    pop dx
    add ax, bx
    adc dx, 0
    ; ticks = (seconds * 19663 + hundredths * 19663 / 100) / 1080
    mov bx, 19663
    call mul32
    push dx
    push ax
    mov al, [r_dx]
    xor ah, ah
    mul bx
    mov bx, 100
    div bx
    pop bx
    pop dx
    add ax, bx
    adc dx, 0
    mov bx, 1080
    call div32
    mov cx, dx
    mov dx, ax
    mov ah, 01h
    int 1Ah
    mov byte [r_ax], 0
    ret
.bad:
    mov byte [r_ax], 0FFh
    ret

; Date and time for a directory entry: AX = time, DX = date
file_stamp:
    call update_date
    call ticks_to_time
    mov bx, 3600
    div bx                          ; AX hours, DX seconds
    push ax
    mov ax, dx
    mov bl, 60
    div bl                          ; AL minutes, AH seconds
    mov bl, ah
    shr bl, 1
    xor bh, bh                      ; seconds / 2
    mov cl, 5
    xor ah, ah
    shl ax, cl
    or bx, ax                       ; minutes << 5
    pop ax
    mov cl, 11
    shl ax, cl
    or ax, bx                       ; hours << 11
    push ax
    mov ax, [cur_year]
    sub ax, 1980
    mov cl, 9
    shl ax, cl
    mov dx, ax
    mov al, [cur_month]
    xor ah, ah
    mov cl, 5
    shl ax, cl
    or dx, ax
    mov al, [cur_day]
    xor ah, ah
    or dx, ax
    pop ax
    ret

; DX:AX * BX -> DX:AX (the low 32 bits). Keeps BX and CX.
mul32:
    push cx
    mov cx, ax
    mov ax, dx
    mul bx
    xchg ax, cx
    mul bx
    add dx, cx
    pop cx
    ret

; DX:AX / BX -> DX:AX quotient, CX remainder. Keeps BX.
div32:
    push ax
    mov ax, dx
    xor dx, dx
    div bx
    mov cx, ax
    pop ax
    div bx
    xchg cx, dx
    ret

; ======================================================================
; Memory
; ======================================================================

; MCB: type 'M' or 'Z' (last), owner (0 = free), size in paragraphs.

; BX = paragraphs -> AX = segment, owned by the current PSP.
; CF: AX = 8 and BX = the largest free block, or AX = 7 (chain broken).
mem_alloc:
    push es
    push cx
    push dx
    push si
    mov si, bx
    xor dx, dx
    mov ax, [first_mcb]
.next:
    mov es, ax
    mov cl, [es:0]
    cmp cl, 'M'
    je .valid
    cmp cl, 'Z'
    jne .broken
.valid:
    cmp word [es:1], 0
    jne .skip
    call mcb_merge
    mov cx, [es:3]
    cmp cx, dx
    jbe .not_larger
    mov dx, cx
.not_larger:
    cmp cx, si
    jb .skip
    mov bx, si
    call mcb_split
    mov ax, [cur_psp]
    mov [es:1], ax
    mov ax, es
    inc ax
    clc
    jmp .ret
.skip:
    cmp byte [es:0], 'Z'
    je .none
    mov ax, es
    add ax, [es:3]
    inc ax
    jmp .next
.none:
    mov bx, dx
    mov ax, 8
    stc
    jmp .ret
.broken:
    mov ax, 7
    stc
.ret:
    pop si
    pop dx
    pop cx
    pop es
    ret

; ES = an MCB: absorbs the free blocks right after it.
mcb_merge:
    push ax
    push ds
.again:
    cmp byte [es:0], 'Z'
    je .done
    mov ax, es
    add ax, [es:3]
    inc ax
    mov ds, ax
    mov al, [0]
    cmp al, 'M'
    je .check
    cmp al, 'Z'
    jne .done
.check:
    cmp word [1], 0
    jne .done
    mov [es:0], al
    mov ax, [3]
    inc ax
    add [es:3], ax
    jmp .again
.done:
    pop ds
    pop ax
    ret

; ES = an MCB, BX = new size (not larger): the rest becomes a free block.
mcb_split:
    push ax
    push cx
    push ds
    mov cx, [es:3]
    sub cx, bx
    jz .done
    mov ax, es
    add ax, bx
    inc ax
    mov ds, ax
    mov al, [es:0]
    mov [0], al
    mov word [1], 0
    dec cx
    mov [3], cx
    mov byte [es:0], 'M'
    mov [es:3], bx
.done:
    pop ds
    pop cx
    pop ax
    ret

; AX = segment of a block -> ES = its MCB, or CF and AX = 9.
mcb_of:
    dec ax
    mov es, ax
    cmp byte [es:0], 'M'
    je .ok
    cmp byte [es:0], 'Z'
    je .ok
    push cs
    pop es
    mov ax, 9
    stc
    ret
.ok:
    clc
    ret

; AX = segment of a block to free. CF, AX = 9 if it is not a block.
mem_free:
    push es
    call mcb_of
    jc .ret
    mov word [es:1], 0
.ret:
    pop es
    ret

; AX = segment of a block, BX = new size. CF: AX = 8, BX = the largest
; possible size; or AX = 9.
mem_resize:
    push es
    push cx
    call mcb_of
    jc .ret
    mov cx, [es:3]                  ; current size
    call mcb_merge
    cmp bx, [es:3]
    jbe .fits
    push word [es:3]
    mov bx, cx                      ; give back what was merged
    call mcb_split
    pop bx
    mov ax, 8
    stc
    jmp .ret
.fits:
    call mcb_split
    clc
.ret:
    push cs
    pop es
    pop cx
    pop es
    ret

; AX = PSP: frees every block it owns.
mem_free_owner:
    push es
    push bx
    mov bx, [first_mcb]
.next:
    mov es, bx
    cmp [es:1], ax
    jne .keep
    mov word [es:1], 0
.keep:
    cmp byte [es:0], 'M'
    jne .done
    add bx, [es:3]
    inc bx
    jmp .next
.done:
    pop bx
    pop es
    ret

fn_48:                              ; allocate BX paragraphs
    mov bx, [r_bx]
    call mem_alloc
    jc .error
    mov [r_ax], ax
    ret
.error:
    mov [r_bx], bx
    jmp set_error

fn_49:                              ; free the block at ES
    mov ax, [r_es]
    call mem_free
    jc .error
    ret
.error:
    jmp set_error

fn_4A:                              ; resize the block at ES to BX
    mov ax, [r_es]
    mov bx, [r_bx]
    call mem_resize
    jc .error
    ret
.error:
    mov [r_bx], bx
    jmp set_error

; ======================================================================
; Diskettes: BIOS access, track cache, FAT
; ======================================================================

; DL = drive (0 = A:) -> BP = its table entry, BPB and FAT loaded.
; CF: AX = error.
drive_ready:
    cmp dl, [num_drives]
    jb .exists
    mov ax, 0Fh
    stc
    ret
.exists:
    mov al, D_SIZE
    mul dl
    add ax, drives
    mov bp, ax
    mov ah, 16h                     ; has the diskette been changed?
    mov dl, [bp+D_NUM]
    int 13h
    cmp ah, 06h
    jne .check
    call drive_invalidate
.check:
    cmp byte [bp+D_VALID], 0
    je .load
    clc
    ret
.load:
    ; the boot sector, into the track buffer
    call track_flush
    mov byte [tc_valid], 0
    mov byte [dk_tries_changed], 2
.read_boot:
    mov byte [dk_cmd], 2
    mov byte [dk_count], 1
    mov byte [dk_cyl], 0
    mov byte [dk_head], 0
    mov byte [dk_sec], 1
    mov word [dk_buf], track_buf
    call bios_disk
    jnc .parse
    cmp ax, 0FFFEh                  ; changed: read it again
    jne .error
    dec byte [dk_tries_changed]
    jnz .read_boot
    mov ax, 15h
.error:
    stc
    ret
.parse:
    mov si, track_buf
    cmp word [si+0Bh], 512
    je .ok4
    jmp .unknown
.ok4:
    mov al, [si+0Dh]
    test al, al
    jnz .ok5
    jmp .unknown
.ok5:
    mov [bp+D_SPC], al
    mov ah, 2                       ; bytes per cluster = 512 * spc
    xor al, al
    mov cl, [bp+D_SPC]
    xor ch, ch
    mul cx
    mov [bp+D_CLBYTES], ax
    mov ax, [si+0Eh]
    mov [bp+D_RES], ax
    mov al, [si+10h]
    cmp al, 1
    jae .ok6
    jmp .unknown
.ok6:
    cmp al, 2
    jbe .ok7
    jmp .unknown
.ok7:
    mov [bp+D_FATS], al
    mov ax, [si+11h]
    mov [bp+D_ROOTENT], ax
    mov ax, [si+13h]
    mov [bp+D_TOTAL], ax
    mov ax, [si+16h]
    test ax, ax
    jnz .ok8
    jmp .unknown
.ok8:
    cmp ax, 9
    jbe .ok9
    jmp .unknown
.ok9:
    mov [bp+D_SPF], ax
    mov ax, [si+18h]
    test ax, ax
    jz .unknown
    cmp ax, 18
    ja .unknown
    mov [bp+D_SPT], ax
    mov ax, [si+1Ah]
    cmp ax, 1
    jb .unknown
    cmp ax, 2
    ja .unknown
    mov [bp+D_HEADS], ax
    ; root directory and data area
    mov al, [bp+D_FATS]
    xor ah, ah
    mul word [bp+D_SPF]
    add ax, [bp+D_RES]
    mov [bp+D_ROOTLBA], ax
    mov bx, [bp+D_ROOTENT]
    add bx, 15
    mov cl, 4
    shr bx, cl
    add ax, bx
    mov [bp+D_DATALBA], ax
    mov bx, ax
    mov ax, [bp+D_TOTAL]
    sub ax, bx
    jbe .unknown
    xor dx, dx
    mov cl, [bp+D_SPC]
    xor ch, ch
    div cx
    inc ax
    cmp ax, 0FF6h
    ja .unknown
    mov [bp+D_MAXCL], ax
    ; the first FAT into memory
    mov cx, [bp+D_SPF]
    mov ax, [bp+D_RES]
    mov di, [bp+D_FATBUF]
.fat:
    push ax
    push cx
    call sec_get
    jc .fat_error
    mov cx, 256
    rep movsw
    pop cx
    pop ax
    inc ax
    loop .fat
    mov byte [bp+D_FATDIRTY], 0
    mov word [bp+D_HINT], 2
    mov byte [bp+D_VALID], 1
    clc
    ret
.fat_error:
    pop cx
    pop cx
    stc
    ret
.unknown:                           ; not a FAT12 diskette this DOS knows
    mov byte [dk_cmd], 2
    mov byte [dk_status], 0FFh
    call crit_error
    cmp al, 1
    jne .ok10
    jmp .load
.ok10:
    mov ax, 83
    stc
    ret

; Forgets what is known about the diskette in drive BP (it was changed).
drive_invalidate:
    mov byte [bp+D_VALID], 0
    mov byte [bp+D_FATDIRTY], 0
    mov al, [bp+D_NUM]
    cmp al, [tc_drive]
    jne .ret
    mov byte [tc_valid], 0
    mov word [tc_dirty], 0
    mov word [tc_dirty+2], 0
.ret:
    ret

dk_cmd           db 0           ; 2 read, 3 write
dk_count         db 0
dk_cyl           db 0
dk_head          db 0
dk_sec           db 0
dk_buf           dw 0
dk_status        db 0
dk_tries         db 0
dk_tries_changed db 0

; INT 13h with the parameters above for drive BP, with retries and the
; critical error handler. CF: AX = 83 (failed) or 0FFFEh (diskette changed).
bios_disk:
    mov byte [dk_tries], 3
.try:
    mov ah, [dk_cmd]
    mov al, [dk_count]
    mov ch, [dk_cyl]
    mov cl, [dk_sec]
    mov dh, [dk_head]
    mov dl, [bp+D_NUM]
    mov bx, [dk_buf]
    int 13h
    jnc .ok
    cmp ah, 06h
    je .changed
    mov [dk_status], ah
    xor ax, ax
    mov dl, [bp+D_NUM]
    int 13h
    dec byte [dk_tries]
    jnz .try
    call crit_error
    cmp al, 1
    je bios_disk
    mov ax, 83
    stc
    ret
.changed:
    call drive_invalidate
    mov ax, 0FFFEh
    stc
    ret
.ok:
    clc
    ret

; Calls INT 24h for the error in [dk_status] on drive BP.
; AL = 1 retry, 3 fail. Abort ends the program and does not return.
crit_error:
    push bx
    push cx
    push dx
    push si
    push di
    mov al, [dk_status]
    mov di, 0Ch                     ; general failure
    cmp al, 03h
    jne .not_wp
    mov di, 0                       ; write protect
.not_wp:
    cmp al, 80h
    jne .not_nr
    mov di, 2                       ; not ready
.not_nr:
    cmp al, 04h
    jne .not_snf
    mov di, 8                       ; sector not found
.not_snf:
    cmp al, 10h
    jne .not_crc
    mov di, 4                       ; data error
.not_crc:
    cmp al, 0FFh
    jne .not_media
    mov di, 7                       ; unknown media
.not_media:
    mov ah, 1Eh                     ; retry and fail allowed, data area
    cmp byte [dk_cmd], 3
    jne .read
    or ah, 1
.read:
    mov al, [bp+D_NUM]
    push bp
    xor bp, bp
    xor si, si
    int 24h
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    cmp al, 2
    je .abort
    cmp al, 1
    je .ret
    mov al, 3
.ret:
    ret
.abort:
    call drive_invalidate
    mov ax, [cur_psp]
    cmp ax, [kpsp_seg]
    jne .terminate
    mov al, 3                       ; the kernel itself cannot be aborted
    ret
.terminate:
    cli
    mov ax, cs
    mov ss, ax
    mov sp, kstack_top
    sti
    mov byte [term_type], 2
    xor ax, ax
    jmp terminate

; ---------- track cache ----------
;
; One whole track of one drive, read with a single INT 13h. Changed sectors
; are marked and written back (one INT 13h) before another track is read,
; on close and at disk reset.

tc_valid  db 0
tc_drive  db 0FFh
tc_track  dw 0                  ; cylinder * heads + head
tc_spt    dw 0
tc_dirty  dw 0, 0               ; a bit per sector
tc_last   dw 0                  ; sector returned last by sec_get
want_idx  dw 0

; BP = drive, AX = LBA -> SI = the sector in the track buffer. CF: AX = error.
; Keeps BX, CX, DX, DI.
sec_get:
    push bx
    push cx
    push dx
    xor dx, dx
    div word [bp+D_SPT]             ; AX = track, DX = sector in the track
    mov [want_idx], dx
    mov bl, [bp+D_NUM]
    cmp byte [tc_valid], 0
    je .load
    cmp bl, [tc_drive]
    jne .load
    cmp ax, [tc_track]
    je .hit
.load:
    push ax
    call track_flush                ; a failure has been reported (INT 24h)
    pop ax
    mov [tc_track], ax
    mov [tc_drive], bl
    mov byte [tc_valid], 0
    mov cx, [bp+D_SPT]
    mov [tc_spt], cx
    mov [dk_count], cl
    xor dx, dx
    div word [bp+D_HEADS]
    mov [dk_cyl], al
    mov [dk_head], dl
    mov byte [dk_sec], 1
    mov byte [dk_cmd], 2
    mov word [dk_buf], track_buf
    call bios_disk
    jc .ret
    mov byte [tc_valid], 1
.hit:
    mov si, [want_idx]
    mov [tc_last], si
    mov cl, 9
    shl si, cl
    add si, track_buf
    clc
.ret:
    pop dx
    pop cx
    pop bx
    ret

; Marks the sector returned last by sec_get as changed.
sec_mark:
    push ax
    push cx
    mov cx, [tc_last]
    mov ax, 1
    cmp cx, 16
    jae .high
    shl ax, cl
    or [tc_dirty], ax
    jmp .done
.high:
    sub cx, 16
    shl ax, cl
    or [tc_dirty+2], ax
.done:
    pop cx
    pop ax
    ret

; Writes the changed sectors of the track back. CF: AX = error.
track_flush:
    cmp byte [tc_valid], 0
    je .clean
    mov ax, [tc_dirty]
    or ax, [tc_dirty+2]
    jz .clean
    push bx
    push cx
    push dx
    push bp
    ; the drive of the cached track
    mov al, D_SIZE
    mul byte [tc_drive]
    add ax, drives
    mov bp, ax
    ; first and last changed sector
    xor bx, bx
.first:
    call .is_dirty
    jnz .found_first
    inc bx
    jmp .first
.found_first:
    mov dx, bx
    mov bx, [tc_spt]
.last:
    dec bx
    call .is_dirty
    jz .last
    ; write sectors DX..BX
    sub bx, dx
    inc bx
    mov [dk_count], bl
    mov ax, dx
    inc al
    mov [dk_sec], al
    mov cl, 9
    shl dx, cl
    add dx, track_buf
    mov [dk_buf], dx
    mov ax, [tc_track]
    xor dx, dx
    div word [bp+D_HEADS]
    mov [dk_cyl], al
    mov [dk_head], dl
    mov byte [dk_cmd], 3
    call bios_disk
    mov word [tc_dirty], 0          ; written, or given up
    mov word [tc_dirty+2], 0
    jnc .written
    push ax                         ; what is in memory no longer matches
    call drive_invalidate           ; the diskette: read it again
    pop ax
    stc
.written:
    pop bp
    pop dx
    pop cx
    pop bx
    ret
.clean:
    clc
    ret
; ZF = 0 if sector BX of the track is marked
.is_dirty:
    push cx
    push ax
    mov cx, bx
    mov ax, [tc_dirty]
    cmp cx, 16
    jb .bit
    mov ax, [tc_dirty+2]
    sub cx, 16
.bit:
    shr ax, cl
    test al, 1
    pop ax
    pop cx
    ret

; ---------- FAT ----------

; BP = drive, AX = cluster -> AX = its FAT entry. Keeps the rest.
fat_get:
    push si
    mov si, ax
    shr si, 1
    add si, ax
    add si, [bp+D_FATBUF]
    test al, 1
    mov ax, [si]
    jz .even
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
.even:
    and ax, 0FFFh
    pop si
    ret

; BP = drive, AX = cluster, DX = value. Keeps everything.
fat_set:
    push ax
    push bx
    push dx
    push si
    mov si, ax
    shr si, 1
    add si, ax
    add si, [bp+D_FATBUF]
    and dx, 0FFFh
    test al, 1
    mov bx, [si]
    jz .even
    shl dx, 1
    shl dx, 1
    shl dx, 1
    shl dx, 1
    and bx, 000Fh
    jmp .store
.even:
    and bx, 0F000h
.store:
    or bx, dx
    mov [si], bx
    mov byte [bp+D_FATDIRTY], 1
    pop si
    pop dx
    pop bx
    pop ax
    ret

; BP = drive -> AX = a free cluster, now marked as the end of a chain.
; CF: AX = ERR_FULL.
cluster_alloc:
    push cx
    push dx
    ; from the one after the last cluster given out, once round the FAT
    mov ax, [bp+D_HINT]
    cmp ax, 2
    jb .first
    cmp ax, [bp+D_MAXCL]
    jbe .search
.first:
    mov ax, 2
.search:
    mov cx, [bp+D_MAXCL]
    dec cx
.next:
    push ax
    call fat_get
    test ax, ax
    pop ax
    jz .found
    inc ax
    cmp ax, [bp+D_MAXCL]
    jbe .counted
    mov ax, 2
.counted:
    loop .next
    mov ax, ERR_FULL
    stc
    jmp .ret
.found:
    mov dx, 0FFFh
    call fat_set
    mov dx, ax
    inc dx
    mov [bp+D_HINT], dx
    clc
.ret:
    pop dx
    pop cx
    ret

; BP = drive, AX = first cluster of a chain to free.
free_chain:
    push dx
    xor dx, dx
.next:
    cmp ax, 2
    jb .done
    cmp ax, 0FF8h
    jae .done
    push ax
    call fat_get
    mov dx, ax
    pop ax
    push dx
    xor dx, dx
    call fat_set
    pop ax
    jmp .next
.done:
    pop dx
    ret

; BP = drive -> AX = free clusters
count_free:
    push bx
    push cx
    xor cx, cx
    mov bx, 2
.next:
    cmp bx, [bp+D_MAXCL]
    ja .done
    mov ax, bx
    call fat_get
    test ax, ax
    jnz .used
    inc cx
.used:
    inc bx
    jmp .next
.done:
    mov ax, cx
    pop cx
    pop bx
    ret

; Writes drive BP's FAT (every copy) into the track cache.
fat_flush:
    cmp byte [bp+D_VALID], 0
    je .clean
    cmp byte [bp+D_FATDIRTY], 0
    je .clean
    push bx
    push cx
    push si
    push di
    mov ax, [bp+D_RES]
    mov bl, [bp+D_FATS]
.copy:
    mov si, [bp+D_FATBUF]
    mov cx, [bp+D_SPF]
.sector:
    push ax
    push si
    call sec_get
    mov di, si
    pop si
    jc .error
    push cx
    mov cx, 256
    rep movsw
    pop cx
    call sec_mark
    pop ax
    inc ax
    loop .sector
    dec bl
    jnz .copy
    mov byte [bp+D_FATDIRTY], 0
    pop di
    pop si
    pop cx
    pop bx
.clean:
    clc
    ret
.error:
    pop ax
    pop di
    pop si
    pop cx
    pop bx
    stc
    ret

; Everything pending to the diskettes.
; CF: AX = the error of the first write that failed.
flush_all:
    push bp
    push bx
    xor bx, bx
    mov bp, drives
    call .fat
    mov bp, drives + D_SIZE
    call .fat
    call track_flush
    jc .error
    mov ax, bx
    cmp bx, 1                       ; CF if an earlier one failed
    cmc
.error:
    pop bx
    pop bp
    ret
.fat:
    call fat_flush
    jnc .ret
    test bx, bx
    jnz .ret
    mov bx, ax
.ret:
    ret

; ======================================================================
; Names and the root directory
; ======================================================================

pathbuf  times 128 db 0
fname    times 11 db 0          ; the name being looked for, 8 + 3
p_drive  db 0
p_wild   db 0
p_dev    db 0                   ; 0 file, DEV_CON, DEV_NUL, 3 another device
f_index  dw 0                   ; directory entry
f_attr   db 0                   ; attributes searched for

; Copies the ASCIIZ at r_ds:r_dx into pathbuf, in capitals.
path_from_dsdx:
    mov ax, [r_ds]
    mov si, [r_dx]
; AX:SI -> pathbuf
path_copy:
    push ds
    mov di, pathbuf
    mov cx, 127
    mov ds, ax
.next:
    lodsb
    cmp al, 'a'
    jb .store
    cmp al, 'z'
    ja .store
    sub al, 20h
.store:
    stosb
    test al, al
    jz .done
    loop .next
    mov byte [es:di], 0
.done:
    pop ds
    ret

; pathbuf -> p_drive, fname, p_wild, p_dev. CF: AX = error (3 bad path,
; 2 bad name).
parse_path:
    mov si, pathbuf
    mov al, [cur_drive]
    mov [p_drive], al
    mov byte [p_wild], 0
    mov byte [p_dev], 0
    cmp byte [si+1], ':'
    jne .no_drive
    mov al, [si]
    sub al, 'A'
    cmp al, 26
    jae .bad_name
    mov [p_drive], al
    add si, 2
.no_drive:
    cmp byte [si], '\'
    je .root
    cmp byte [si], '/'
    jne .name
.root:
    inc si
.name:
    mov di, fname
    mov cx, 11
    mov al, ' '
    rep stosb
    mov di, fname
    mov cx, 8
    call name_part
    jc .bad_name
    cmp byte [si], '.'
    jne .no_ext
    inc si
    mov di, fname + 8
    mov cx, 3
    call name_part
    jc .bad_name
.no_ext:
    cmp byte [si], 0
    jne .bad_path                   ; a directory in the path
    cmp byte [fname], ' '
    je .bad_path
    call check_device
    clc
    ret
.bad_path:
    mov ax, 3
    stc
    ret
.bad_name:
    mov ax, 2
    stc
    ret

; Up to CX characters of a name from SI to DI (more are dropped).
name_part:
.next:
    mov al, [si]
    test al, al
    jz .end
    cmp al, '.'
    je .end
    cmp al, '\'
    je .end
    cmp al, '/'
    je .end
    cmp al, '*'
    je .star
    cmp al, '?'
    jne .check
    mov byte [p_wild], 1
    jmp .store
.check:
    call bad_char
    jc .ret
.store:
    jcxz .skip
    mov [di], al
    inc di
    dec cx
.skip:
    inc si
    jmp .next
.star:
    mov byte [p_wild], 1
    mov al, '?'
    rep stosb
.rest:
    inc si
    mov al, [si]
    test al, al
    jz .end
    cmp al, '.'
    je .end
    cmp al, '\'
    je .end
    jmp .rest
.end:
    clc
.ret:
    ret

; CF if AL cannot be part of a file name.
bad_char:
    cmp al, ' '
    jbe .bad
    push di
    push cx
    mov di, bad_chars
    mov cx, bad_chars_end - bad_chars
    repne scasb
    pop cx
    pop di
    je .bad
    clc
    ret
.bad:
    stc
    ret

bad_chars db '"+,:;<=>[]|'
bad_chars_end:

check_device:
    mov si, dev_names
    mov bl, 1
.next:
    cmp byte [si], 0
    je .none
    push si
    mov di, fname
    mov cx, 8
    repe cmpsb
    pop si
    je .found
    add si, 9
    jmp .next
.found:
    mov al, [si+8]
    mov [p_dev], al
.none:
    ret

dev_names:
    db 'CON     ', DEV_CON
    db 'NUL     ', DEV_NUL
    db 'AUX     ', 3
    db 'PRN     ', 3
    db 'COM1    ', 3
    db 'COM2    ', 3
    db 'LPT1    ', 3
    db 'LPT2    ', 3
    db 'CLOCK$  ', 3
    db 0

; BP = drive, AX = entry number -> SI = the entry. CF: AX = error.
dir_entry:
    push cx
    push dx
    mov dx, ax
    and dx, 15
    mov cl, 5
    shl dx, cl
    mov cl, 4
    shr ax, cl
    add ax, [bp+D_ROOTLBA]
    call sec_get
    jc .ret
    add si, dx
.ret:
    pop dx
    pop cx
    ret

; Looks for fname (with ? wildcards) from entry f_index on, with the
; attributes allowed by f_attr. SI = the entry, f_index its number.
; CF: AX = 12h (no more), or a disk error.
dir_search:
.next:
    mov ax, [f_index]
    cmp ax, [bp+D_ROOTENT]
    jae .none
    call dir_entry
    jc .ret
    mov al, [si]
    test al, al
    jz .none
    cmp al, 0E5h
    je .skip
    ; attributes: labels only in label searches; hidden, system and
    ; directories only when asked for
    mov al, [si+11]
    mov ah, [f_attr]
    test ah, 08h
    jz .not_label
    test al, 08h
    jz .skip
    jmp .names
.not_label:
    test al, 08h
    jnz .skip
    and al, 16h
    not ah
    test al, ah
    jnz .skip
.names:
    push si
    mov di, fname
    mov cx, 11
.char:
    mov al, [di]
    cmp al, '?'
    je .any
    cmp al, [si]
    jne .differs
.any:
    inc si
    inc di
    loop .char
    pop si
    clc
    ret
.differs:
    pop si
.skip:
    inc word [f_index]
    jmp .next
.none:
    mov ax, 12h
    stc
.ret:
    ret

; Exact name: f_index = 0, attributes 16h. CF: AX = 2 or a disk error.
find_file:
    mov word [f_index], 0
    mov byte [f_attr], 16h
    call dir_search
    jnc .ret
    cmp ax, 12h
    jne .error
    mov ax, 2
.error:
    stc
.ret:
    ret

; A free directory entry -> SI, f_index. CF: AX = 5 (full) or a disk error.
dir_free:
    mov word [f_index], 0
.next:
    mov ax, [f_index]
    cmp ax, [bp+D_ROOTENT]
    jae .full
    call dir_entry
    jc .ret
    mov al, [si]
    test al, al
    jz .found
    cmp al, 0E5h
    je .found
    inc word [f_index]
    jmp .next
.found:
    clc
    ret
.full:
    mov ax, 5
    stc
.ret:
    ret

; ======================================================================
; Handles and the system file table
; ======================================================================

o_mode db 0

; -> DI = a free SFT entry (taken). CF: AX = 4.
sft_new:
    mov di, sft_table
    mov cx, SFT_COUNT
.next:
    cmp byte [di+SF_REF], 0
    je .found
    add di, SFT_SIZE
    loop .next
    mov ax, 4
    stc
    ret
.found:
    push di
    push cx
    mov cx, SFT_SIZE
    xor al, al
    rep stosb
    pop cx
    pop di
    mov byte [di+SF_REF], 1
    mov word [di+SF_CURCI], 0FFFFh
    clc
    ret

; DI = SFT entry -> AL = its number
sft_number:
    mov ax, di
    sub ax, sft_table
    mov cl, SFT_SIZE
    div cl
    ret

; -> BX = a free handle of the current process. CF: AX = 4.
jft_new:
    push es
    push si
    push cx
    mov es, [cur_psp]
    mov cx, [es:32h]
    les si, [es:34h]
    xor bx, bx
.next:
    cmp bx, cx
    jae .none
    cmp byte [es:si+bx], 0FFh
    je .found
    inc bx
    jmp .next
.none:
    mov ax, 4
    stc
    jmp .ret
.found:
    clc
.ret:
    pop cx
    pop si
    pop es
    ret

; BX = handle, AL = SFT number to store in it.
jft_set:
    push es
    push si
    mov es, [cur_psp]
    les si, [es:34h]
    mov [es:si+bx], al
    pop si
    pop es
    ret

; BX = handle -> DI = its SFT entry. CF: AX = 6.
get_sft:
    push es
    push si
    mov es, [cur_psp]
    cmp bx, [es:32h]
    jae .bad
    les si, [es:34h]
    mov al, [es:si+bx]
    cmp al, SFT_COUNT
    jae .bad
    mov ah, SFT_SIZE
    mul ah
    add ax, sft_table
    mov di, ax
    cmp byte [di+SF_REF], 0
    je .bad
    clc
    jmp .ret
.bad:
    mov ax, 6
    stc
.ret:
    pop si
    pop es
    ret

; DI = file's SFT entry -> BP = its drive, ready. CF: AX = error.
sft_drive:
    mov dl, [di+SF_DEV]
    push di
    call drive_ready
    pop di
    ret

; Updates the directory entry of the file DI and writes everything back.
sft_commit:
    test byte [di+SF_FLAGS], F_DEVICE
    jnz .done
    test byte [di+SF_FLAGS], F_DIRTY
    jz .flush
    call sft_drive
    jc .ret
    test byte [di+SF_FLAGS], F_STAMP
    jnz .stamped
    call file_stamp
    mov [di+SF_TIME], ax
    mov [di+SF_DATE], dx
.stamped:
    mov ax, [di+SF_DIRIX]
    call dir_entry
    jc .ret
    or byte [di+SF_ATTR], 20h       ; archive
    mov al, [di+SF_ATTR]
    mov [si+11], al
    mov ax, [di+SF_TIME]
    mov [si+22], ax
    mov ax, [di+SF_DATE]
    mov [si+24], ax
    mov ax, [di+SF_FIRST]
    mov [si+26], ax
    mov ax, [di+SF_SIZE]
    mov [si+28], ax
    mov ax, [di+SF_SIZE+2]
    mov [si+30], ax
    call sec_mark
    and byte [di+SF_FLAGS], ~F_DIRTY
.flush:
    jmp flush_all
.done:
    clc
.ret:
    ret

; One handle less on SFT entry DI; the last one commits the file.
sft_close:
    cmp byte [di+SF_REF], 1
    jbe .last
    dec byte [di+SF_REF]
    ret
.last:
    push di
    call sft_commit
    pop di
    mov byte [di+SF_REF], 0         ; closed even if writing it failed
    ret

; Fills SFT entry DI from directory entry SI of drive BP.
sft_from_entry:
    push si
    push di
    mov al, [o_mode]
    mov [di+SF_MODE], al
    mov byte [di+SF_FLAGS], F_CLEAN
    mov al, [bp+D_NUM]
    mov [di+SF_DEV], al
    mov al, [si+11]
    mov [di+SF_ATTR], al
    mov ax, [si+22]
    mov [di+SF_TIME], ax
    mov ax, [si+24]
    mov [di+SF_DATE], ax
    mov ax, [si+26]
    mov [di+SF_FIRST], ax
    mov ax, [si+28]
    mov [di+SF_SIZE], ax
    mov ax, [si+30]
    mov [di+SF_SIZE+2], ax
    mov ax, [f_index]
    mov [di+SF_DIRIX], ax
    add di, SF_NAME
    mov cx, 11
    rep movsb
    pop di
    pop si
    ret

; Gives SFT entry DI a handle; the caller gets it in AX. CF: AX = 4.
attach_handle:
    call jft_new
    jc .full
    call sft_number
    call jft_set
    mov [r_ax], bx
    clc
    ret
.full:
    mov byte [di+SF_REF], 0
    stc
    ret

; Opens device p_dev on SFT entry DI.
open_device:
    mov al, [p_dev]
    cmp al, 3
    jae .unavailable
    mov [di+SF_DEV], al
    mov byte [di+SF_FLAGS], F_DEVICE | F_CLEAN
    mov al, [o_mode]
    mov [di+SF_MODE], al
    clc
    ret
.unavailable:                       ; no serial port, printer or clock device
    mov byte [di+SF_REF], 0
    mov ax, 5
    stc
    ret

fn_3D:                              ; open DS:DX with mode AL
    mov al, [r_ax]
    and al, 7
    cmp al, 2
    jbe .mode
    mov ax, 0Ch
    jmp set_error
.mode:
    mov [o_mode], al
    call path_from_dsdx
    call parse_path
    jc .error
    cmp byte [p_dev], 0
    jne .device
    cmp byte [p_wild], 0
    jne .not_found
    mov dl, [p_drive]
    call drive_ready
    jc .error
    call find_file
    jc .error
    test byte [si+11], 18h
    jnz .denied
    cmp byte [o_mode], 0
    je .allowed
    test byte [si+11], 01h
    jnz .denied
.allowed:
    push si
    call sft_new
    pop si
    jc .error
    call sft_from_entry
    call attach_handle
    jc .error
    ret
.device:
    call sft_new
    jc .error
    call open_device
    jc .error
    call attach_handle
    jc .error
    ret
.not_found:
    mov ax, 2
    jmp set_error
.denied:
    mov ax, 5
.error:
    jmp set_error

c_new db 0                          ; 5Bh: fail if the file exists

fn_5B:                              ; create a new file
    mov byte [c_new], 1
    jmp create
fn_3C:                              ; create or truncate DS:DX with attributes CX
    mov byte [c_new], 0
create:
    mov byte [o_mode], 2
    call path_from_dsdx
    call parse_path
    jnc .ok11
    jmp .error
.ok11:
    cmp byte [p_dev], 0
    je .ok12
    jmp .device
.ok12:
    cmp byte [p_wild], 0
    je .ok13
    jmp .bad_path
.ok13:
    mov dl, [p_drive]
    call drive_ready
    jnc .ok14
    jmp .error
.ok14:
    call find_file
    jnc .exists
    cmp ax, 2
    je .ok15
    jmp .error
.ok15:
    ; a new entry
    call dir_free
    jnc .ok16
    jmp .error
.ok16:
    mov di, si
    push si
    mov si, fname
    mov cx, 11
    rep movsb
    xor al, al
    mov cx, 21
    rep stosb
    pop si
    jmp .fill
.exists:
    cmp byte [c_new], 0
    je .replace
    mov ax, 50h
    jmp set_error
.replace:
    test byte [si+11], 19h
    jnz .denied
    mov ax, [si+26]
    call free_chain
.fill:
    mov al, [r_cx]
    and al, 27h
    mov [si+11], al
    push si
    call file_stamp
    pop si
    mov [si+22], ax
    mov [si+24], dx
    mov word [si+26], 0
    mov word [si+28], 0
    mov word [si+30], 0
    call sec_mark
    ; the new entry goes to the diskette now, as on DOS: a write-protected
    ; diskette fails here, not when the file is closed
    call flush_all
    jc .error
    mov ax, [f_index]
    call dir_entry
    jc .error
    push si
    call sft_new
    pop si
    jc .error
    call sft_from_entry
    and byte [di+SF_FLAGS], ~F_CLEAN
    call attach_handle
    jc .error
    ret
.device:
    call sft_new
    jc .error
    call open_device
    jc .error
    call attach_handle
    jc .error
    ret
.bad_path:
    mov ax, 3
    jmp set_error
.denied:
    mov ax, 5
.error:
    jmp set_error

fn_3E:                              ; close handle BX
    mov bx, [r_bx]
    call get_sft
    jc .error
    push bx
    call sft_close
    pop bx
    pushf
    push ax
    mov al, 0FFh
    call jft_set
    pop ax
    popf
    jc .error
    ret
.error:
    jmp set_error

fn_68:                              ; commit handle BX
    mov bx, [r_bx]
    call get_sft
    jc .error
    call sft_commit
    jc .error
    ret
.error:
    jmp set_error

; ---------- reading and writing ----------

io_sft  dw 0
io_seg  dw 0
io_off  dw 0
io_left dw 0
io_done dw 0
io_n    dw 0
alloc   db 0                    ; cluster_of: allocate missing clusters

fn_3F:                              ; read CX bytes from handle BX to DS:DX
    mov bx, [r_bx]
    call get_sft
    jc .error
    mov al, [di+SF_MODE]
    and al, 3
    cmp al, 1
    je .denied
    mov ax, [r_ds]
    mov [io_seg], ax
    mov ax, [r_dx]
    mov [io_off], ax
    mov ax, [r_cx]
    mov [io_left], ax
    mov [io_sft], di
    test byte [di+SF_FLAGS], F_DEVICE
    jnz .device
    call file_read
    jc .error
    mov [r_ax], ax
    ret
.device:
    cmp byte [di+SF_DEV], DEV_CON
    je .con
    mov word [r_ax], 0              ; NUL: end of file at once
    ret
.con:
    call con_handle_read
    mov [r_ax], ax
    ret
.denied:
    mov ax, 5
.error:
    jmp set_error

fn_40:                              ; write CX bytes from DS:DX to handle BX
    mov bx, [r_bx]
    call get_sft
    jc .error
    mov al, [di+SF_MODE]
    and al, 3
    jz .denied
    mov ax, [r_ds]
    mov [io_seg], ax
    mov ax, [r_dx]
    mov [io_off], ax
    mov ax, [r_cx]
    mov [io_left], ax
    mov [io_sft], di
    test byte [di+SF_FLAGS], F_DEVICE
    jnz .device
    call file_write
    jc .error
    mov [r_ax], ax
    ret
.device:
    mov ax, [r_cx]
    mov [r_ax], ax
    cmp byte [di+SF_DEV], DEV_CON
    jne .ret
    push ds
    mov cx, [io_left]
    mov si, [io_off]
    mov ds, [io_seg]
    jcxz .written
.char:
    lodsb
    call con_out
    loop .char
.written:
    pop ds
.ret:
    ret
.denied:
    mov ax, 5
.error:
    jmp set_error

con_avail dw 0                  ; characters of con_line not read yet
con_ptr   dw 0
con_line  db 128, 0
          times 130 db 0

; Reads from CON into io_seg:io_off: a whole line with editing (cooked),
; or keys as they come (raw). -> AX = bytes
con_handle_read:
    test byte [di+SF_FLAGS], F_RAW
    jnz .raw
    cmp word [con_avail], 0
    jne .deliver
    push di
    mov di, con_line
    call line_input
    pop di
    mov al, [con_line+1]
    xor ah, ah
    mov bx, ax
    mov byte [con_line+bx+3], 10    ; CR is already there; add LF
    add ax, 2
    mov [con_avail], ax
    mov word [con_ptr], con_line + 2
    mov al, 10
    call con_out
.deliver:
    mov cx, [io_left]
    cmp cx, [con_avail]
    jbe .count
    mov cx, [con_avail]
.count:
    sub [con_avail], cx
    mov si, [con_ptr]
    add [con_ptr], cx
    mov ax, cx
    mov es, [io_seg]
    mov di, [io_off]
    rep movsb
    push cs
    pop es
    ret
.raw:
    mov cx, [io_left]
    mov es, [io_seg]
    mov di, [io_off]
    xor bx, bx
.key:
    jcxz .raw_done
    call con_read
    stosb
    inc bx
    dec cx
    jmp .key
.raw_done:
    push cs
    pop es
    mov ax, bx
    ret

; Cluster number AX of the chain of file DI (drive BP), following the FAT
; from the last cluster found when possible. With [alloc] set, missing
; clusters are added. -> AX = cluster. CF: AX = error or ERR_FULL.
cluster_of:
    push bx
    push cx
    push dx
    mov dx, ax                      ; the index wanted
    mov cx, [di+SF_CURCI]
    cmp cx, 0FFFFh
    je .from_start
    cmp ax, cx
    jb .from_start
    mov bx, [di+SF_CURCL]
    jmp .walk
.from_start:
    xor cx, cx
    mov bx, [di+SF_FIRST]
    test bx, bx
    jnz .walk
    cmp byte [alloc], 0
    je .missing
    call cluster_alloc
    jc .ret
    mov [di+SF_FIRST], ax
    or byte [di+SF_FLAGS], F_DIRTY
    mov bx, ax
.walk:
    cmp cx, dx
    je .found
    mov ax, bx
    call fat_get
    cmp ax, 0FF8h
    jae .end
    cmp ax, 2
    jb .broken
    mov bx, ax
    inc cx
    jmp .walk
.end:
    cmp byte [alloc], 0
    je .missing
    call cluster_alloc
    jc .ret
    push dx
    mov dx, ax
    mov ax, bx
    call fat_set
    mov bx, dx
    pop dx
    inc cx
    jmp .walk
.found:
    mov [di+SF_CURCI], cx
    mov [di+SF_CURCL], bx
    mov ax, bx
    clc
    jmp .ret
.missing:
.broken:
    mov ax, ERR_FULL
    stc
.ret:
    pop dx
    pop cx
    pop bx
    ret

; The position of file DI (drive BP) -> AX = its sector, BX = the offset in
; it. CF: AX = error or ERR_FULL.
pos_sector:
    push cx
    push dx
    mov ax, [di+SF_POS]
    mov dx, [di+SF_POS+2]
    mov bx, [bp+D_CLBYTES]
    cmp dx, bx
    jae .far                        ; beyond any diskette
    div bx                          ; AX = cluster index, DX = offset
    push dx
    call cluster_of
    pop dx
    jc .ret
    sub ax, 2
    mov cl, [bp+D_SPC]
    xor ch, ch
    push dx
    mul cx
    pop dx
    add ax, [bp+D_DATALBA]
    mov bx, dx
    mov cl, 9
    shr dx, cl
    add ax, dx                      ; + sector in the cluster
    and bx, 511
    clc
    jmp .ret
.far:
    mov ax, ERR_FULL
    stc
.ret:
    pop dx
    pop cx
    ret

; Advances file DI by [io_n] bytes, and the transfer.
io_advance:
    mov ax, [io_n]
    add [io_off], ax
    sub [io_left], ax
    add [io_done], ax
    add [di+SF_POS], ax
    adc word [di+SF_POS+2], 0
    ret

; io_left bytes of file io_sft to io_seg:io_off -> AX = bytes read.
file_read:
    mov word [io_done], 0
    mov di, [io_sft]
    call sft_drive
    jc .ret
    mov di, [io_sft]
    mov byte [alloc], 0
.next:
    cmp word [io_left], 0
    je .done
    ; what is left of the file
    mov ax, [di+SF_SIZE]
    mov dx, [di+SF_SIZE+2]
    sub ax, [di+SF_POS]
    sbb dx, [di+SF_POS+2]
    jc .done
    mov cx, ax
    or ax, dx
    jz .done
    test dx, dx
    jz .small
    mov cx, 0FFFFh
.small:
    cmp cx, [io_left]
    jbe .limit
    mov cx, [io_left]
.limit:
    push cx
    call pos_sector
    pop cx
    jc .error
    mov dx, 512
    sub dx, bx
    cmp cx, dx
    jbe .count
    mov cx, dx
.count:
    mov [io_n], cx
    call sec_get
    jc .ret
    add si, bx
    mov es, [io_seg]
    mov di, [io_off]
    rep movsb
    push cs
    pop es
    mov di, [io_sft]
    call io_advance
    jmp .next
.error:
    cmp ax, ERR_FULL                ; the chain is shorter than the size
    jne .ret
.done:
    mov ax, [io_done]
    clc
.ret:
    ret

; io_left bytes from io_seg:io_off to file io_sft -> AX = bytes written
; (fewer when the diskette is full). 0 bytes: the file ends at the position.
file_write:
    mov word [io_done], 0
    mov di, [io_sft]
    call sft_drive
    jc .ret
    mov di, [io_sft]
    and byte [di+SF_FLAGS], ~F_CLEAN
    or byte [di+SF_FLAGS], F_DIRTY
    mov byte [alloc], 1
    cmp word [io_left], 0
    je truncate
.next:
    cmp word [io_left], 0
    je .done
    call pos_sector
    jc .error
    mov cx, 512
    sub cx, bx
    cmp cx, [io_left]
    jbe .count
    mov cx, [io_left]
.count:
    mov [io_n], cx
    call sec_get
    jc .ret
    add si, bx
    mov di, si
    push ds
    mov si, [io_off]
    mov ds, [io_seg]
    rep movsb
    pop ds
    call sec_mark
    mov di, [io_sft]
    call io_advance
    ; the size grows with the position
    mov ax, [di+SF_POS]
    mov dx, [di+SF_POS+2]
    cmp dx, [di+SF_SIZE+2]
    jb .next
    ja .grow
    cmp ax, [di+SF_SIZE]
    jbe .next
.grow:
    mov [di+SF_SIZE], ax
    mov [di+SF_SIZE+2], dx
    jmp .next
.error:
    cmp ax, ERR_FULL
    jne .ret
.done:
    mov ax, [io_done]
    clc
.ret:
    ret

; The file DI (drive BP) ends at its position: clusters past it are freed.
truncate:
    mov ax, [di+SF_POS]
    mov dx, [di+SF_POS+2]
    mov [di+SF_SIZE], ax
    mov [di+SF_SIZE+2], dx
    mov word [di+SF_CURCI], 0FFFFh
    mov cx, ax
    or cx, dx
    jnz .keep
    mov ax, [di+SF_FIRST]
    call free_chain
    mov word [di+SF_FIRST], 0
    jmp .done
.keep:
    ; the cluster holding the last byte stays, the rest goes
    sub ax, 1
    sbb dx, 0
    mov bx, [bp+D_CLBYTES]
    cmp dx, bx
    jae .done
    div bx
    call cluster_of
    jc .done
    mov bx, ax
    call fat_get
    xchg ax, bx
    mov dx, 0FFFh
    call fat_set
    mov ax, bx
    call free_chain
.done:
    xor ax, ax
    clc
    ret

fn_42:                              ; move the position of handle BX
    mov bx, [r_bx]
    call get_sft
    jc .error
    mov ax, [r_dx]
    mov dx, [r_cx]
    mov bl, [r_ax]
    cmp bl, 0
    je .set
    cmp bl, 1
    je .current
    cmp bl, 2
    je .end
    mov ax, 1
    jmp .error
.current:
    add ax, [di+SF_POS]
    adc dx, [di+SF_POS+2]
    jmp .set
.end:
    add ax, [di+SF_SIZE]
    adc dx, [di+SF_SIZE+2]
.set:
    test byte [di+SF_FLAGS], F_DEVICE
    jz .file
    xor ax, ax
    xor dx, dx
.file:
    mov [di+SF_POS], ax
    mov [di+SF_POS+2], dx
    mov [r_ax], ax
    mov [r_dx], dx
    ret
.error:
    jmp set_error

; ---------- names: delete, rename, attributes, date ----------

; pathbuf names an existing file: BP = drive, SI = entry. CF: AX = error.
existing_file:
    call parse_path
    jc .ret
    cmp byte [p_dev], 0
    jne .not_found
    cmp byte [p_wild], 0
    jne .not_found
    mov dl, [p_drive]
    call drive_ready
    jc .ret
    call find_file
    jc .ret
    test byte [si+11], 18h
    jnz .not_found
    clc
.ret:
    ret
.not_found:
    mov ax, 2
    stc
    ret

fn_41:                              ; delete DS:DX
    call path_from_dsdx
    call existing_file
    jc .error
    test byte [si+11], 01h
    jnz .denied
    mov byte [si], 0E5h
    call sec_mark
    mov ax, [si+26]
    call free_chain
    call flush_all
    ret
.denied:
    mov ax, 5
.error:
    jmp set_error

r_name times 11 db 0
r_drive db 0

fn_56:                              ; rename DS:DX to ES:DI
    ; the new name first: it must not exist
    mov ax, [r_es]
    mov si, [r_di]
    call path_copy
    call parse_path
    jc .error
    cmp byte [p_dev], 0
    jne .denied
    cmp byte [p_wild], 0
    jne .bad_path
    mov al, [p_drive]
    mov [r_drive], al
    mov si, fname
    mov di, r_name
    mov cx, 11
    rep movsb
    mov dl, [p_drive]
    call drive_ready
    jc .error
    call find_file
    jnc .denied
    cmp ax, 2
    jne .error
    ; then the old one
    call path_from_dsdx
    call existing_file
    jc .error
    mov al, [p_drive]
    cmp al, [r_drive]
    jne .other_drive
    mov di, si
    mov si, r_name
    mov cx, 11
    rep movsb
    call sec_mark
    call flush_all
    ret
.other_drive:
    mov ax, 11h
    jmp set_error
.bad_path:
    mov ax, 3
    jmp set_error
.denied:
    mov ax, 5
.error:
    jmp set_error

fn_43:                              ; get or set the attributes of DS:DX
    call path_from_dsdx
    call existing_file
    jc .error
    mov al, [r_ax]
    cmp al, 0
    je .get
    cmp al, 1
    je .set
    mov ax, 1
    jmp .error
.get:
    mov al, [si+11]
    xor ah, ah
    mov [r_cx], ax
    ret
.set:
    mov al, [r_cx]
    test al, 0D8h
    jnz .denied
    mov [si+11], al
    call sec_mark
    call flush_all
    ret
.denied:
    mov ax, 5
.error:
    jmp set_error

fn_57:                              ; date and time of handle BX
    mov bx, [r_bx]
    call get_sft
    jc .error
    mov al, [r_ax]
    cmp al, 0
    je .get
    cmp al, 1
    je .set
    mov ax, 1
    jmp .error
.get:
    mov ax, [di+SF_TIME]
    mov [r_cx], ax
    mov ax, [di+SF_DATE]
    mov [r_dx], ax
    ret
.set:
    mov ax, [r_cx]
    mov [di+SF_TIME], ax
    mov ax, [r_dx]
    mov [di+SF_DATE], ax
    or byte [di+SF_FLAGS], F_STAMP | F_DIRTY
    ret
.error:
    jmp set_error

; ---------- handles ----------

fn_45:                              ; duplicate handle BX
    mov bx, [r_bx]
    call get_sft
    jc .error
    call jft_new
    jc .error
    call sft_number
    call jft_set
    inc byte [di+SF_REF]
    mov [r_ax], bx
    ret
.error:
    jmp set_error

fn_46:                              ; handle CX becomes a copy of BX
    mov bx, [r_bx]
    call get_sft
    jc .error
    push di
    mov bx, [r_cx]
    push es
    mov es, [cur_psp]
    cmp bx, [es:32h]
    pop es
    jae .bad_handle
    call get_sft
    jc .free
    push bx
    call sft_close
    pop bx
.free:
    pop di
    call sft_number
    call jft_set
    inc byte [di+SF_REF]
    ret
.bad_handle:
    pop di
    mov ax, 6
.error:
    jmp set_error

fn_44:                              ; IOCTL
    mov al, [r_ax]
    cmp al, 08h
    jne .ok17
    jmp .removable
.ok17:
    cmp al, 09h
    jne .ok18
    jmp .remote
.ok18:
    cmp al, 0Eh
    jne .ok19
    jmp .map
.ok19:
    cmp al, 07h
    ja .unsupported
    cmp al, 2
    jb .handle
    cmp al, 6
    jae .handle
.unsupported:
    jmp fn_unsupported
.handle:
    mov bx, [r_bx]
    call get_sft
    jnc .ok20
    jmp .error
.ok20:
    mov al, [r_ax]
    cmp al, 0
    je .get_info
    cmp al, 1
    je .set_info
    cmp al, 6
    je .input_status
    mov byte [r_ax], 0FFh           ; 07h: always ready for output
    ret
.get_info:
    test byte [di+SF_FLAGS], F_DEVICE
    jz .file_info
    mov ax, 80D3h                   ; CON: console input and output
    cmp byte [di+SF_DEV], DEV_CON
    je .device_info
    mov ax, 8084h                   ; NUL
.device_info:
    test byte [di+SF_FLAGS], F_RAW
    jz .info
    or al, 20h
    jmp .info
.file_info:
    mov al, [di+SF_DEV]
    xor ah, ah
    test byte [di+SF_FLAGS], F_CLEAN
    jz .info
    or al, 40h
.info:
    mov [r_dx], ax
    ret
.set_info:
    test byte [di+SF_FLAGS], F_DEVICE
    jz .invalid
    cmp byte [r_dx+1], 0
    jne .invalid
    and byte [di+SF_FLAGS], ~F_RAW
    test byte [r_dx], 20h
    jz .ret
    or byte [di+SF_FLAGS], F_RAW
.ret:
    ret
.input_status:
    test byte [di+SF_FLAGS], F_DEVICE
    jz .file_status
    mov byte [r_ax], 0FFh
    cmp byte [di+SF_DEV], DEV_CON
    jne .ret
    call con_check
    jnz .ret
    mov byte [r_ax], 0
    ret
.file_status:                       ; ready until the end of the file
    mov byte [r_ax], 0FFh
    mov ax, [di+SF_POS]
    mov dx, [di+SF_POS+2]
    cmp dx, [di+SF_SIZE+2]
    jb .ret
    ja .eof
    cmp ax, [di+SF_SIZE]
    jb .ret
.eof:
    mov byte [r_ax], 0
    ret
.removable:                         ; diskettes are removable: AX = 0
    call ioctl_drive
    jc .error
    mov word [r_ax], 0
    ret
.remote:
    call ioctl_drive
    jc .error
    mov word [r_dx], 0
    ret
.map:                               ; one letter per drive
    call ioctl_drive
    jc .error
    mov byte [r_ax], 0
    ret
.invalid:
    mov ax, 1
.error:
    jmp set_error

; BL of the caller: drive (0 = default) -> CF, AX = 0Fh if it does not exist.
ioctl_drive:
    mov al, [r_bx]
    dec al
    cmp al, 0FFh
    jne .given
    mov al, [cur_drive]
.given:
    cmp al, [num_drives]
    jb .ok
    mov ax, 0Fh
    stc
    ret
.ok:
    clc
    ret

; ---------- directories (the root only) ----------

fn_47:                              ; current directory of drive DL: the root
    mov al, [r_dx]
    dec al
    cmp al, 0FFh
    jne .given
    mov al, [cur_drive]
.given:
    cmp al, [num_drives]
    jae .bad
    mov es, [r_ds]
    mov di, [r_si]
    mov byte [es:di], 0
    push cs
    pop es
    mov word [r_ax], 0100h
    ret
.bad:
    mov ax, 0Fh
    jmp set_error

fn_3B:                              ; change directory: only to the root
    call path_from_dsdx
    mov si, pathbuf
    cmp byte [si+1], ':'
    jne .path
    mov al, [si]
    sub al, 'A'
    cmp al, [num_drives]
    jae .bad
    add si, 2
.path:
    cmp byte [si], 0
    je .ok
    cmp byte [si], '\'
    je .slash
    cmp byte [si], '/'
    jne .bad
.slash:
    cmp byte [si+1], 0
    jne .bad
.ok:
    ret
.bad:
    mov ax, 3
    jmp set_error

; ---------- find first / next ----------
;
; The DTA keeps the search: drive + 1 (byte 0), the pattern (1-11), the
; attributes (12) and the next entry (13-14); then what was found: attribute
; (21), time (22), date (24), size (26) and name (30, ASCIIZ).

dta_off dw 80h
dta_seg dw 0

fn_4E:                              ; find the first match of DS:DX, attributes CX
    call path_from_dsdx
    call parse_path
    jc .error
    cmp byte [p_dev], 0
    je .file
    mov ax, 2
    jmp .error
.file:
    mov es, [dta_seg]
    mov di, [dta_off]
    mov al, [p_drive]
    inc al
    stosb
    mov si, fname
    mov cx, 11
    rep movsb
    mov al, [r_cx]
    stosb
    xor ax, ax
    stosw
    push cs
    pop es
    call find_next
    jc .not_found
    ret
.not_found:
    cmp ax, 12h
    jne .error
    mov ax, 2
.error:
    jmp set_error

fn_4F:                              ; find the next match
    call find_next
    jc .error
    ret
.error:
    jmp set_error

find_next:
    push ds
    mov si, [dta_off]
    mov ds, [dta_seg]
    mov di, p_drive
    lodsb
    dec al
    mov [es:di], al
    mov di, fname
    mov cx, 11
    rep movsb
    lodsb
    mov [es:f_attr], al
    lodsw
    mov [es:f_index], ax
    pop ds
    mov dl, [p_drive]
    cmp dl, [num_drives]
    jae .no_more
    call drive_ready
    jc .ret
    call dir_search
    jc .ret
    ; found: store it and where to go on
    mov es, [dta_seg]
    mov di, [dta_off]
    mov ax, [f_index]
    inc ax
    mov [es:di+13], ax
    mov al, [si+11]
    mov [es:di+21], al
    mov ax, [si+22]
    mov [es:di+22], ax
    mov ax, [si+24]
    mov [es:di+24], ax
    mov ax, [si+28]
    mov [es:di+26], ax
    mov ax, [si+30]
    mov [es:di+28], ax
    add di, 30
    call name_from_entry
    push cs
    pop es
    clc
.ret:
    ret
.no_more:
    mov ax, 12h
    stc
    ret

; Directory entry SI -> "NAME.EXT" at ES:DI (ASCIIZ).
name_from_entry:
    push si
    mov cx, 8
.name:
    lodsb
    cmp al, ' '
    je .name_end
    stosb
    loop .name
.name_end:
    pop si
    push si
    add si, 8
    cmp byte [si], ' '
    je .done
    mov al, '.'
    stosb
    mov cx, 3
.ext:
    lodsb
    cmp al, ' '
    je .done
    stosb
    loop .ext
.done:
    xor al, al
    stosb
    pop si
    ret

fn_36:                              ; free space on drive DL
    mov dl, [r_dx]
    dec dl
    cmp dl, 0FFh
    jne .given
    mov dl, [cur_drive]
.given:
    call drive_ready
    jc .bad
    call count_free
    mov [r_bx], ax
    mov al, [bp+D_SPC]
    xor ah, ah
    mov [r_ax], ax
    mov word [r_cx], 512
    mov ax, [bp+D_MAXCL]
    dec ax
    mov [r_dx], ax
    ret
.bad:
    mov word [r_ax], 0FFFFh
    ret

; ---------- parse a file name into an FCB ----------

fn_29:                              ; DS:SI -> FCB at ES:DI, options AL
    push ds
    mov es, [r_es]
    mov di, [r_di]
    mov bl, [r_ax]                  ; options
    mov si, [r_si]
    mov ds, [r_ds]
    xor dx, dx                      ; DL: wildcards, DH: invalid drive
    ; separators
.white:
    mov al, [si]
    cmp al, ' '
    je .skip_white
    cmp al, 9
    jne .separators
.skip_white:
    inc si
    jmp .white
.separators:
    test bl, 1
    jz .drive
    mov al, [si]
    cmp al, ':'
    je .sep
    cmp al, '.'
    je .sep
    cmp al, ';'
    je .sep
    cmp al, ','
    je .sep
    cmp al, '='
    je .sep
    cmp al, '+'
    jne .drive
.sep:
    inc si
    and bl, 0FEh                    ; only one separator
    jmp .white
.drive:
    cmp byte [si+1], ':'
    jne .no_drive
    mov al, [si]
    call upcase
    sub al, 'A' - 1
    cmp al, 1
    jb .bad_drive
    cmp al, [cs:num_drives]
    jbe .drive_ok
.bad_drive:
    mov dh, 0FFh
.drive_ok:
    mov [es:di], al
    add si, 2
    jmp .name
.no_drive:
    test bl, 2
    jnz .name
    mov byte [es:di], 0
.name:
    push di
    inc di
    mov cx, 8
    call fcb_part
    pop di
    cmp byte [si], '.'
    jne .no_ext
    inc si
    push di
    add di, 9
    mov cx, 3
    xor bh, bh
    call fcb_field
    pop di
    jmp .done
.no_ext:
    test bl, 8
    jnz .done
    push di
    add di, 9
    mov cx, 3
    mov al, ' '
    rep stosb
    pop di
.done:
    pop ds
    mov [r_si], si
    mov al, dl
    test dh, dh
    jz .result
    mov al, 0FFh
.result:
    mov [r_ax], al
    push cs
    pop es
    ret

; Name field of the FCB: CX characters at ES:DI; with option 4 set and no
; name in the text, the field is left alone.
fcb_part:
    mov bh, bl
    and bh, 4
fcb_field:
    ; BH: keep the field when the text has no name
    mov al, [si]
    call fcb_terminator
    jnc .fill
    test bh, bh
    jnz .ret
.fill:
.next:
    mov al, [si]
    call fcb_terminator
    jc .pad
    cmp al, '*'
    je .star
    cmp al, '?'
    jne .char
    mov dl, 1
.char:
    call upcase
    jcxz .drop
    stosb
    dec cx
.drop:
    inc si
    jmp .next
.star:
    mov dl, 1
    mov al, '?'
    rep stosb
    inc si
    jmp .next
.pad:
    mov al, ' '
    rep stosb
.ret:
    ret

; CF if AL ends a name in an FCB parse.
fcb_terminator:
    cmp al, ' '
    jbe .yes
    push di
    push cx
    push es
    push cs
    pop es
    mov di, fcb_terms
    mov cx, fcb_terms_end - fcb_terms
    repne scasb
    pop es
    pop cx
    pop di
    je .yes
    clc
    ret
.yes:
    stc
    ret

fcb_terms db '.:;,=+/"[]|<>\'
fcb_terms_end:

upcase:
    cmp al, 'a'
    jb .ret
    cmp al, 'z'
    ja .ret
    sub al, 20h
.ret:
    ret

; ======================================================================
; Programs: EXEC and terminate
; ======================================================================

ex_hdr   times 28 db 0          ; the first bytes of the file
ex_name  times 16 db 0          ; "A:\NAME.EXT"
ex_sft   dw 0
ex_env   dw 0
ex_psp   dw 0
ex_size  dw 0                   ; paragraphs of the program's block
ex_need  dw 0
ex_want  dw 0
ex_img   dw 0, 0                ; bytes of the .EXE load image
ex_load  dw 0                   ; segment where the image goes
ex_ss    dw 0
ex_sp    dw 0
ex_cs    dw 0
ex_ip    dw 0
ex_isexe db 0
ex_rel   dw 0, 0

fc_sseg  dw 0
fc_soff  dw 0
fc_dseg  dw 0
fc_doff  dw 0

; CX bytes from fc_sseg:fc_soff to fc_dseg:fc_doff
far_copy:
    push ds
    push es
    push si
    push di
    mov es, [fc_dseg]
    mov di, [fc_doff]
    mov si, [fc_soff]
    mov ds, [fc_sseg]
    rep movsb
    pop di
    pop si
    pop es
    pop ds
    ret

; Opens fname on drive p_drive for EXEC: ex_sft. CF: AX = error.
exec_open:
    mov dl, [p_drive]
    call drive_ready
    jc .ret
    mov word [f_index], 0
    mov byte [f_attr], 06h
    call dir_search
    jnc .found
    cmp ax, 12h
    jne .error
    mov ax, 2
.error:
    stc
.ret:
    ret
.found:
    push si
    call sft_new
    pop si
    jc .ret
    mov byte [o_mode], 0
    call sft_from_entry
    mov [ex_sft], di
    clc
    ret

; Reads CX bytes of the program file at DX:AX into fc_dseg:fc_doff.
; -> AX = bytes read. CF: AX = error.
exec_read:
    mov di, [ex_sft]
    mov [di+SF_POS], ax
    mov [di+SF_POS+2], dx
    mov [io_sft], di
    mov [io_left], cx
    mov ax, [fc_dseg]
    mov [io_seg], ax
    mov ax, [fc_doff]
    mov [io_off], ax
    call file_read
    ret

fn_4B:                              ; load and run DS:DX with parameters ES:BX
    cmp byte [r_ax], 0
    je .exec
    jmp fn_unsupported              ; load only (01h) and overlays (03h)
.exec:
    call path_from_dsdx
    call parse_path
    jnc .ok21
    jmp .error
.ok21:
    cmp byte [p_dev], 0
    je .ok22
    jmp .not_found
.ok22:
    cmp byte [p_wild], 0
    je .ok23
    jmp .not_found
.ok23:
    ; "A:\NAME.EXT" for the environment
    mov di, ex_name
    mov al, [p_drive]
    add al, 'A'
    stosb
    mov ax, ':'
    stosw
    mov si, fname
    call name_from_entry
    call exec_open
    jnc .ok24
    jmp .error
.ok24:
    ; the header
    mov word [fc_dseg], KSEG
    mov word [fc_doff], ex_hdr
    xor ax, ax
    xor dx, dx
    mov cx, 28
    call exec_read
    jnc .ok25
    jmp .close_error
.ok25:
    mov byte [ex_isexe], 0
    cmp ax, 28
    jb .com
    cmp word [ex_hdr], 'MZ'
    je .exe
    cmp word [ex_hdr], 'ZM'
    je .exe
.com:
    mov di, [ex_sft]
    cmp word [di+SF_SIZE+2], 0
    jne .too_big
    mov ax, [di+SF_SIZE]
    cmp ax, 0FF00h
    ja .too_big
    add ax, 100h + 100h + 15        ; PSP, file and some stack
    rcr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    mov [ex_need], ax
    mov word [ex_want], 0FFFFh
    jmp .memory
.too_big:
    mov ax, 8
    jmp .close_error
.exe:
    mov byte [ex_isexe], 1
    ; image = pages * 512 - unused part of the last page - header
    mov ax, [ex_hdr+4]
    mov bx, 512
    mul bx
    mov cx, [ex_hdr+2]
    jcxz .whole_pages
    sub ax, 512
    sbb dx, 0
    add ax, cx
    adc dx, 0
.whole_pages:
    push dx
    push ax
    mov ax, [ex_hdr+8]
    mov bx, 16
    mul bx
    mov bx, ax
    mov cx, dx
    pop ax
    pop dx
    sub ax, bx
    sbb dx, cx
    jc .bad_format
    mov [ex_img], ax
    mov [ex_img+2], dx
    ; in paragraphs, + the PSP
    add ax, 15
    adc dx, 0
    mov bx, 16
    call div32
    test dx, dx
    jnz .too_big
    add ax, 10h
    jc .too_big
    mov bx, ax
    add ax, [ex_hdr+0Ah]
    jc .too_big
    mov [ex_need], ax
    add bx, [ex_hdr+0Ch]
    jnc .want
    mov bx, 0FFFFh
.want:
    mov [ex_want], bx
    jmp .memory
.bad_format:
    mov ax, 0Bh
    jmp .close_error

.memory:
    call make_env
    jnc .ok26
    jmp .close_error
.ok26:
    mov bx, 0FFFFh
    call mem_alloc                  ; fails: BX = the largest block
    cmp ax, 8
    je .ok27
    jmp .free_env_error
.ok27:
    cmp bx, [ex_need]
    jae .ok28
    jmp .no_memory
.ok28:
    cmp bx, [ex_want]
    jbe .size
    mov bx, [ex_want]
.size:
    call mem_alloc
    jnc .ok29
    jmp .free_env_error
.ok29:
    mov [ex_psp], ax
    mov [ex_size], bx
    ; the new process owns both blocks
    push es
    dec ax
    mov es, ax
    mov ax, [ex_psp]
    mov [es:1], ax
    mov bx, [ex_env]
    dec bx
    mov es, bx
    mov [es:1], ax
    pop es
    call build_psp
    cmp byte [ex_isexe], 0
    jne .load_exe
    ; .COM: the whole file at PSP:0100
    mov ax, [ex_psp]
    mov [fc_dseg], ax
    mov word [fc_doff], 100h
    mov di, [ex_sft]
    mov cx, [di+SF_SIZE]
    xor ax, ax
    xor dx, dx
    call exec_read
    jnc .ok30
    jmp .free_error
.ok30:
    mov ax, [ex_psp]
    mov [ex_ss], ax
    mov [ex_cs], ax
    mov word [ex_ip], 100h
    mov ax, 0FFFEh
    cmp word [ex_size], 1000h
    jae .com_stack
    mov ax, [ex_size]
    mov cl, 4
    shl ax, cl
    sub ax, 2
.com_stack:
    mov [ex_sp], ax
    push es
    mov es, [ex_psp]
    mov bx, ax
    mov word [es:bx], 0             ; RET goes to PSP:0000 (INT 20h)
    pop es
    jmp .start

.load_exe:
    mov ax, [ex_psp]
    add ax, 10h
    mov [ex_load], ax
    mov [fc_dseg], ax
    mov word [fc_doff], 0
    ; the image from the end of the header, 32 KB at a time
    mov ax, [ex_hdr+8]
    mov bx, 16
    mul bx
.chunk:
    mov cx, [ex_img]
    mov bx, [ex_img+2]
    or bx, cx
    jz .relocate
    cmp word [ex_img+2], 0
    jne .full_chunk
    cmp cx, 8000h
    jbe .read_chunk
.full_chunk:
    mov cx, 8000h
.read_chunk:
    push ax
    push dx
    push cx
    call exec_read
    pop cx
    pop dx
    pop bx
    jnc .ok31
    jmp .free_error
.ok31:
    cmp ax, cx
    jb .relocate                    ; the file is shorter: what there is
    add bx, cx
    adc dx, 0
    mov ax, bx
    sub [ex_img], cx
    sbb word [ex_img+2], 0
    add word [fc_dseg], 800h
    jmp .chunk
.relocate:
    mov cx, [ex_hdr+6]
    mov ax, [ex_hdr+18h]
    xor dx, dx
    mov word [fc_dseg], KSEG
    mov word [fc_doff], ex_rel
.reloc_next:
    jcxz .exe_regs
    push cx
    push ax
    mov cx, 4
    call exec_read
    pop ax
    pop cx
    jnc .ok32
    jmp .free_error
.ok32:
    push es
    mov bx, [ex_rel+2]
    add bx, [ex_load]
    mov es, bx
    mov bx, [ex_rel]
    mov dx, [ex_load]
    add [es:bx], dx
    pop es
    xor dx, dx
    add ax, 4
    adc dx, 0
    loop .reloc_next
.exe_regs:
    mov ax, [ex_load]
    add ax, [ex_hdr+0Eh]
    mov [ex_ss], ax
    mov ax, [ex_hdr+10h]
    mov [ex_sp], ax
    mov ax, [ex_load]
    add ax, [ex_hdr+16h]
    mov [ex_cs], ax
    mov ax, [ex_hdr+14h]
    mov [ex_ip], ax

.start:
    mov di, [ex_sft]
    mov byte [di+SF_REF], 0
    ; the parent's stack, for its return
    push es
    mov es, [cur_psp]
    mov ax, [u_sp]
    mov [es:2Eh], ax
    mov ax, [u_ss]
    mov [es:30h], ax
    pop es
    mov ax, [ex_psp]
    mov [cur_psp], ax
    mov [dta_seg], ax
    mov word [dta_off], 80h
    dec byte [indos]
    cli
    mov ss, [ex_ss]
    mov sp, [ex_sp]
    sti
    mov bx, 0202h                   ; flags: interrupts on
    push bx
    push word [ex_cs]
    push word [ex_ip]
    mov ds, ax
    mov es, ax
    xor ax, ax
    xor bx, bx
    mov cx, 00FFh
    mov dx, ds
    xor si, si
    xor di, di
    xor bp, bp
    iret

.free_error:
    push ax
    mov ax, [ex_psp]
    call mem_free
    mov ax, [ex_env]
    call mem_free
    pop ax
    jmp .close_error
.no_memory:
    mov ax, 8
.free_env_error:
    push ax
    mov ax, [ex_env]
    call mem_free
    pop ax
.close_error:
    mov di, [ex_sft]
    mov byte [di+SF_REF], 0
.error:
    jmp set_error
.not_found:
    mov ax, 2
    jmp set_error

; The environment of the new program: the one in the parameter block, or
; the parent's, then a word 1 and the program's full name. -> ex_env
make_env:
    push es
    mov es, [r_es]
    mov bx, [r_bx]
    mov ax, [es:bx]
    test ax, ax
    jnz .source
    mov es, [cur_psp]
    mov ax, [es:2Ch]
.source:
    mov [fc_sseg], ax
    mov word [fc_soff], 0
    ; its length, up to the double zero
    mov es, ax
    xor di, di
    test ax, ax
    jz .length
.scan:
    cmp word [es:di], 0
    je .end
    inc di
    cmp di, 7FFEh
    jb .scan
.end:
    add di, 2
.length:
    pop es
    mov [ex_rel], di                ; bytes of strings (with the final zero)
    ; + the count word + the name
    push di
    mov di, ex_name
    mov cx, 16
    xor al, al
    repne scasb
    sub di, ex_name
    mov ax, di
    pop di
    add ax, di
    add ax, 4 + 15
    mov cl, 4
    shr ax, cl
    mov bx, ax
    call mem_alloc
    jc .ret
    mov [ex_env], ax
    mov [fc_dseg], ax
    mov word [fc_doff], 0
    mov cx, [ex_rel]
    jcxz .empty
    call far_copy
    jmp .name
.empty:
    push es                         ; no environment: an empty one
    mov es, ax
    mov word [es:0], 0
    pop es
    mov word [ex_rel], 2
.name:
    push es
    mov es, [ex_env]
    mov di, [ex_rel]
    mov ax, 1
    stosw
    mov si, ex_name
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    pop es
    clc
.ret:
    ret

; The PSP of the new program at ex_psp.
build_psp:
    push es
    mov es, [ex_psp]
    xor di, di
    mov cx, 128
    xor ax, ax
    rep stosw
    mov word [es:0], 20CDh
    mov ax, [ex_psp]
    add ax, [ex_size]
    mov [es:2], ax                  ; end of the program's memory
    mov byte [es:5], 9Ah            ; CALL 5 (CP/M): not supported
    mov word [es:6], cpm_entry
    mov word [es:8], KSEG
    ; INT 22h: where the parent continues; INT 23h and 24h as they are now
    mov ax, [r_ip]
    mov [es:0Ah], ax
    mov ax, [r_cs]
    mov [es:0Ch], ax
    push ds
    xor ax, ax
    mov ds, ax
    mov ax, [23h*4]
    mov [es:0Eh], ax
    mov ax, [23h*4+2]
    mov [es:10h], ax
    mov ax, [24h*4]
    mov [es:12h], ax
    mov ax, [24h*4+2]
    mov [es:14h], ax
    pop ds
    mov ax, [cur_psp]
    mov [es:16h], ax
    ; handles: the parent's, shared
    mov word [es:32h], 20
    mov word [es:34h], 18h
    mov [es:36h], es
    push ds
    mov ds, [cur_psp]
    lds si, [34h]
    mov di, 18h
    mov cx, 20
.handle:
    lodsb
    stosb
    cmp al, SFT_COUNT
    jae .no_ref
    push ax
    mov ah, SFT_SIZE
    mul ah
    mov bx, ax
    pop ax
    inc byte [cs:sft_table+bx+SF_REF]
.no_ref:
    loop .handle
    pop ds
    mov ax, [ex_env]
    mov [es:2Ch], ax
    mov word [es:50h], 21CDh        ; INT 21h / RETF
    mov byte [es:52h], 0CBh
    pop es
    ; FCBs and command tail from the parameter block
    push es
    mov es, [r_es]
    mov bx, [r_bx]
    mov ax, [ex_psp]
    mov [fc_dseg], ax
    mov ax, [es:bx+6]
    mov [fc_soff], ax
    mov ax, [es:bx+8]
    mov [fc_sseg], ax
    mov word [fc_doff], 5Ch
    mov cx, 16
    call far_copy
    mov ax, [es:bx+10]
    mov [fc_soff], ax
    mov ax, [es:bx+12]
    mov [fc_sseg], ax
    mov word [fc_doff], 6Ch
    mov cx, 16
    call far_copy
    mov ax, [es:bx+2]
    mov [fc_soff], ax
    mov ax, [es:bx+4]
    mov [fc_sseg], ax
    mov word [fc_doff], 80h
    push ds
    lds si, [es:bx+2]
    mov cl, [si]                    ; length of the tail
    pop ds
    xor ch, ch
    cmp cx, 126
    jbe .tail
    mov cx, 126
.tail:
    add cx, 2                       ; the length byte and the CR
    call far_copy
    pop es
    ret

; Program termination. AL = return code; the type comes from term_type.
term_type db 0
ret_code  dw 0

terminate:
    mov ah, [term_type]
    mov byte [term_type], 0
    mov [ret_code], ax
    mov ax, [cur_psp]
    cmp ax, [kpsp_seg]
    jne .process
    jmp dos_exit                    ; nothing above the kernel
.process:
    call flush_all
    mov es, [cur_psp]
    ; INT 22h, 23h and 24h back as they were when it started
    push ds
    mov ax, es
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov si, 0Ah
    mov di, 22h*4
    mov cx, 6
    cli
    rep movsw
    sti
    pop ds
    mov es, [cur_psp]
    mov ax, [es:0Ah]
    mov [term_ip], ax
    mov ax, [es:0Ch]
    mov [term_cs], ax
    cmp byte [ret_code+1], 3
    je .resident
    ; close its handles and free its memory
    xor bx, bx
.handle:
    push bx
    call get_sft
    jc .next
    push bx
    call sft_close
    pop bx
    mov al, 0FFh
    call jft_set
.next:
    pop bx
    inc bx
    cmp bx, 20
    jb .handle
    mov ax, [cur_psp]
    call mem_free_owner
.resident:
    push cs
    pop es
    ; back to the parent, in its EXEC call
    push es
    mov es, [cur_psp]
    mov ax, [es:16h]
    mov [cur_psp], ax
    mov es, ax
    mov ax, [es:2Eh]
    mov [u_sp], ax
    mov ax, [es:30h]
    mov [u_ss], ax
    mov ax, [cur_psp]
    mov [dta_seg], ax
    mov word [dta_off], 80h
    pop es
    push ds
    mov si, [u_sp]
    mov ds, [u_ss]
    mov di, r_ax
    mov cx, 12
    rep movsw
    pop ds
    mov ax, [term_ip]
    mov [r_ip], ax
    mov ax, [term_cs]
    mov [r_cs], ax
    and word [r_fl], 0FFFEh
    jmp dos_exit

term_ip dw 0
term_cs dw 0

fn_00:                              ; terminate
    xor ax, ax
    jmp terminate

fn_4C:                              ; terminate with return code AL
    mov al, [r_ax]
    jmp terminate

fn_31:                              ; terminate and stay resident, DX paragraphs
    mov ax, [cur_psp]
    mov bx, [r_dx]
    cmp bx, 6
    jae .keep
    mov bx, 6
.keep:
    call mem_resize
    mov byte [term_type], 3
    mov al, [r_ax]
    jmp terminate

fn_4D:                              ; return code of the last child
    mov ax, [ret_code]
    mov [r_ax], ax
    mov word [ret_code], 0
    ret

; ======================================================================
; The other interrupts
; ======================================================================

int20:                              ; terminate
    mov ax, 4C00h
    int 21h

int23:                              ; Ctrl-C: end the program
    mov byte [cs:term_type], 1
    mov ax, 4C00h
    int 21h

int27:                              ; terminate and stay resident, DX bytes
    add dx, 15
    rcr dx, 1
    shr dx, 1
    shr dx, 1
    shr dx, 1
    mov ax, 3100h
    int 21h

int29:                              ; fast console output
    push ds
    push cs
    pop ds
    call con_out
    pop ds
    iret

iret_stub:
    iret

int25:                              ; absolute disk read and write
    push cs
    pop ds
    mov si, msg_unsup_25
    jmp unsupported_int
int26:
    push cs
    pop ds
    mov si, msg_unsup_26
    jmp unsupported_int
cpm_entry:
    push cs
    pop ds
    mov si, msg_unsup_cpm
unsupported_int:
    call print_str
    mov ax, 4CFFh
    int 21h

; Default critical error handler: "Not ready reading drive A" and
; "Abort, Retry, Fail?" through the BIOS. AL = the choice.
int24:
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push cs
    pop ds
    push ax
    mov si, msg_crlf
    call print_str
    mov bx, di
    xor bh, bh
    cmp bl, 0Ch
    jbe .known
    mov bl, 0Ch
.known:
    shl bx, 1
    mov si, [crit_msgs+bx]
    call print_str
    pop ax
    push ax
    mov si, msg_reading
    test ah, 1
    jz .verb
    mov si, msg_writing
.verb:
    call print_str
    add al, 'A'
    call con_out
    mov si, msg_crlf
    call print_str
.ask:
    mov si, msg_arf
    call print_str
    xor ah, ah
    int 16h
    call upcase
    call con_out
    mov bl, 2
    cmp al, 'A'
    je .answer
    mov bl, 1
    cmp al, 'R'
    je .answer
    mov bl, 3
    cmp al, 'F'
    je .answer
    mov si, msg_crlf
    call print_str
    jmp .ask
.answer:
    mov si, msg_crlf
    call print_str
    pop ax
    mov al, bl
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    iret

; ======================================================================
; Data
; ======================================================================

cur_psp     dw 0
kpsp_seg    dw 0
first_mcb   dw 0
cur_drive   db 0
boot_drive  db 0
num_drives  db 0
verify      db 0
break_flag  db 0
last_error  dw 0
cur_year    dw 1980
cur_month   db 1
cur_day     db 1

drives      times MAX_DRIVES * D_SIZE db 0
sft_table   times SFT_COUNT * SFT_SIZE db 0

country_info:
    dw 0                            ; date format: month day year
    db '$', 0, 0, 0, 0              ; currency
    db ',', 0                       ; thousands
    db '.', 0                       ; decimals
    db '-', 0                       ; date
    db ':', 0                       ; time
    db 0                            ; currency before the amount
    db 2                            ; digits after the decimal point
    db 0                            ; 12-hour clock
    dw upcase_far, KSEG             ; case map routine
    db ',', 0                       ; data list separator
    times 10 db 0

upcase_far:
    call upcase
    retf

msg_unsup_fn  db 13, 10, 'DOS86: INT 21h function AH=', 0
msg_unsup_end db 'h is not supported', 13, 10, 0
msg_unsup_25  db 13, 10, 'DOS86: INT 25h (absolute disk read) is not supported', 13, 10, 0
msg_unsup_26  db 13, 10, 'DOS86: INT 26h (absolute disk write) is not supported', 13, 10, 0
msg_unsup_cpm db 13, 10, 'DOS86: CALL 5 (CP/M entry) is not supported', 13, 10, 0
msg_ctrl_c    db '^C', 13, 10, 0
msg_crlf      db 13, 10, 0
msg_reading   db ' reading drive ', 0
msg_writing   db ' writing drive ', 0
msg_arf       db 'Abort, Retry, Fail?', 0
msg_no_shell  db 13, 10, 'Bad or missing command interpreter', 13, 10, 0

crit_msgs:
    dw crit_0, crit_1, crit_2, crit_3, crit_4, crit_5, crit_6
    dw crit_7, crit_8, crit_9, crit_10, crit_11, crit_12
crit_0  db 'Write protect error', 0
crit_1  db 'Unknown unit error', 0
crit_2  db 'Not ready', 0
crit_3  db 'Unknown command error', 0
crit_4  db 'Data error', 0
crit_5  db 'Bad request structure length', 0
crit_6  db 'Seek error', 0
crit_7  db 'Unknown media type', 0
crit_8  db 'Sector not found', 0
crit_9  db 'Printer out of paper', 0
crit_10 db 'Write fault', 0
crit_11 db 'Read fault', 0
crit_12 db 'General failure', 0

; ======================================================================
; Start
; ======================================================================

vectors:
    db 20h
    dw int20
    db 21h
    dw int21
    db 22h
    dw shell_done
    db 23h
    dw int23
    db 24h
    dw int24
    db 25h
    dw int25
    db 26h
    dw int26
    db 27h
    dw int27
    db 28h
    dw iret_stub
    db 29h
    dw int29
    db 2Ah
    dw iret_stub
    db 2Fh
    dw iret_stub
    db 0

shell_name  db 'A:\COMMAND.COM', 0
master_env  db 'COMSPEC=A:\COMMAND.COM', 0, 0
master_env_end:
exec_block  dw 0, empty_tail, KSEG, blank_fcb, KSEG, blank_fcb, KSEG
empty_tail  db 0, 13
blank_fcb   db 0, '           ', 0, 0, 0, 0

init:
    cli
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, istack_top
    sti
    cld
    mov [boot_drive], dl
    mov [cur_drive], dl
    ; diskette drives (equipment word bits 6-7), at most two
    int 11h
    mov cl, 6
    shr ax, cl
    and al, 3
    inc al
    cmp al, MAX_DRIVES
    jbe .drives
    mov al, MAX_DRIVES
.drives:
    mov [num_drives], al
    mov bx, drives
    xor ax, ax
    mov di, fat_area
.drive:
    mov [bx+D_NUM], al
    mov [bx+D_FATBUF], di
    add di, 9 * 512
    add bx, D_SIZE
    inc al
    cmp al, MAX_DRIVES
    jb .drive
    ; CON for handles 0, 1 and 2
    mov byte [sft_table+SF_REF], 3
    mov byte [sft_table+SF_MODE], 2
    mov byte [sft_table+SF_FLAGS], F_DEVICE | F_CLEAN
    mov byte [sft_table+SF_DEV], DEV_CON
    ; interrupt vectors
    xor ax, ax
    mov es, ax
    mov si, vectors
.vector:
    lodsb
    test al, al
    jz .vectors_done
    mov bl, al
    xor bh, bh
    shl bx, 1
    shl bx, 1
    lodsw
    cli
    mov [es:bx], ax
    mov [es:bx+2], cs
    sti
    jmp .vector
.vectors_done:
    ; the kernel's own PSP
    mov ax, cs
    mov bx, kpsp
    mov cl, 4
    shr bx, cl
    add ax, bx
    mov [kpsp_seg], ax
    mov [cur_psp], ax
    mov [dta_seg], ax
    mov es, ax
    xor di, di
    mov cx, 128
    xor ax, ax
    rep stosw
    mov word [es:0], 20CDh
    mov [es:16h], es                ; its own parent
    mov word [es:32h], 20
    mov word [es:34h], 18h
    mov [es:36h], es
    mov di, 18h
    mov ax, 0000h                   ; handles 0, 1, 2: CON
    stosw
    stosb
    mov cx, 17
    mov al, 0FFh
    rep stosb
    ; free memory: from past the kernel to the top (INT 12h)
    mov ax, cs
    mov bx, kernel_end + 15
    mov cl, 4
    shr bx, cl
    add ax, bx
    mov [first_mcb], ax
    mov es, ax
    int 12h
    mov cl, 6
    shl ax, cl
    mov bx, es
    sub ax, bx
    dec ax
    mov byte [es:0], 'Z'
    mov word [es:1], 0
    mov [es:3], ax
    push cs
    pop es
    ; the master environment, owned by the kernel
    mov bx, (master_env_end - master_env + 15) / 16
    call mem_alloc
    mov es, [kpsp_seg]
    mov [es:2Ch], ax
    mov es, ax
    xor di, di
    mov si, master_env
    mov cx, master_env_end - master_env
    rep movsb
    push cs
    pop es
    mov al, [boot_drive]
    add al, 'A'
    mov [shell_name], al
    ; COMMAND.COM, again whenever it ends
shell:
    mov dx, shell_name
    mov bx, exec_block
    mov ax, 4B00h
    int 21h
    jc no_shell
shell_done:
    push cs
    pop ds
    push cs
    pop es
    cli
    mov ax, cs
    mov ss, ax
    mov sp, istack_top
    sti
    jmp shell
no_shell:
    mov si, msg_no_shell
    call print_str
.halt:
    sti
    hlt
    jmp .halt

image_end:

; ======================================================================
; Memory past the image (not in the file)
; ======================================================================

BSS         equ ((image_end - $$ + 15) / 16) * 16
kpsp        equ BSS                     ; the kernel's PSP, 256 bytes
track_buf   equ kpsp + 256              ; one track of 18 sectors
fat_area    equ track_buf + 18 * 512    ; a FAT of up to 9 sectors per drive
kstack      equ fat_area + MAX_DRIVES * 9 * 512
kstack_top  equ kstack + 2048
istack_top  equ kstack_top + 512
kernel_end  equ istack_top
