; command.asm - DOS86 command interpreter (COMMAND.COM)
;
; Shows the prompt, reads a line and runs it: a built-in command, a drive
; change (B:) or a program (.COM, then .EXE) from the current drive or the
; one given. Everything goes through INT 21h, so it is an ordinary program:
; the kernel starts it again if it ever ends.
;
; Built-in: CD CHDIR CLS COPY DATE DEL DIR ECHO ERASE EXIT MD MKDIR PAUSE
; RD REM REN RENAME RMDIR SET TIME TYPE VER VOL. Batch files, redirection
; and pipes are not supported.
org 100h

    jmp start

; ======================================================================
; Output
; ======================================================================

; DS:SI, ASCIIZ, to standard output
print:
    push ax
    push bx
    push cx
    push dx
    mov dx, si
    xor cx, cx
.length:
    cmp byte [si], 0
    je .write
    inc si
    inc cx
    jmp .length
.write:
    mov bx, 1
    mov ah, 40h
    int 21h
    pop dx
    pop cx
    pop bx
    pop ax
    ret

putc:                               ; AL
    push ax
    push dx
    mov dl, al
    mov ah, 02h
    int 21h
    pop dx
    pop ax
    ret

crlf:
    push si
    mov si, s_crlf
    call print
    pop si
    ret

; DX:AX in decimal into numbuf -> SI = the digits (ASCIIZ), CX = how many
dec32:
    push ax
    push bx
    push dx
    mov si, numbuf_end
    mov byte [si], 0
.digit:
    ; DX:AX / 10
    push ax
    mov ax, dx
    xor dx, dx
    mov bx, 10
    div bx
    mov cx, ax
    pop ax
    div bx
    add dl, '0'
    dec si
    mov [si], dl
    mov dx, cx
    mov cx, ax
    or cx, dx
    jnz .digit
    mov cx, numbuf_end
    sub cx, si
    pop dx
    pop bx
    pop ax
    ret

; DX:AX right-aligned in BL columns
print_num:
    push cx
    push si
    call dec32
.pad:
    cmp cl, bl
    jae .digits
    push ax
    mov al, ' '
    call putc
    pop ax
    inc cl
    jmp .pad
.digits:
    call print
    pop si
    pop cx
    ret

; AL (0-99) in two digits, with a leading zero
print_2:
    push ax
    push bx
    xor ah, ah
    mov bl, 10
    div bl
    add ax, '00'
    push ax
    call putc
    pop ax
    mov al, ah
    call putc
    pop bx
    pop ax
    ret

; AL (0-99) in two columns, with a leading space
print_2s:
    push ax
    push bx
    xor ah, ah
    mov bl, 10
    div bl
    add ax, '00'
    cmp al, '0'
    jne .tens
    mov al, ' '
.tens:
    push ax
    call putc
    pop ax
    mov al, ah
    call putc
    pop bx
    pop ax
    ret

; ======================================================================
; Line parsing
; ======================================================================

; SI -> past spaces and tabs
skip_blanks:
    cmp byte [si], ' '
    je .skip
    cmp byte [si], 9
    jne .ret
.skip:
    inc si
    jmp skip_blanks
.ret:
    ret

; A word from SI into DI (ASCIIZ), up to a blank, a switch or the end.
; -> SI past it, CX = its length
get_word:
    xor cx, cx
.next:
    mov al, [si]
    test al, al
    jz .end
    cmp al, ' '
    je .end
    cmp al, 9
    je .end
    cmp al, '/'
    je .end
    stosb
    inc si
    inc cx
    jmp .next
.end:
    mov byte [di], 0
    ret

; ZF = 1 if the strings at SI and DI are equal
str_equal:
    push si
    push di
.next:
    mov al, [si]
    cmp al, [di]
    jne .done
    test al, al
    jz .done
    inc si
    inc di
    jmp .next
.done:
    pop di
    pop si
    ret

; Splits the path at SI: drive (0-based) into AL, name part -> SI.
split_drive:
    mov ah, 19h
    int 21h
    cmp byte [si+1], ':'
    jne .ret
    mov al, [si]
    sub al, 'A'
    add si, 2
.ret:
    ret

; "X:" + the name at SI into DI (ASCIIZ). AL = drive.
make_path:
    push ax
    add al, 'A'
    stosb
    mov al, ':'
    stosb
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    pop ax
    ret

; 1 in AL if the ASCIIZ at SI has * or ?
has_wild:
    push si
    xor ah, ah
.next:
    lodsb
    test al, al
    jz .done
    cmp al, '*'
    je .yes
    cmp al, '?'
    jne .next
.yes:
    mov ah, 1
.done:
    mov al, ah
    pop si
    ret

; 1 in AL if the ASCIIZ at SI has a dot
has_dot:
    push si
.next:
    lodsb
    test al, al
    jz .no
    cmp al, '.'
    jne .next
    mov al, 1
    pop si
    ret
.no:
    pop si
    ret

; ======================================================================
; Start and the main loop
; ======================================================================

start:
    mov sp, stack_top
    ; keep only the memory this program needs
    mov bx, (program_end - $$ + 100h + 15) / 16
    mov ah, 4Ah
    int 21h
    mov ax, 3523h
    int 21h
    mov [old23], bx
    mov [old23+2], es
    push cs
    pop es
    call own_ctrl_c
    mov si, s_banner
    call print

main:
    cld
    push cs
    pop ds
    push cs
    pop es
    mov dx, dta
    mov ah, 1Ah
    int 21h
    ; prompt
    mov ah, 19h
    int 21h
    add al, 'A'
    call putc
    mov si, s_prompt
    call print
    mov dx, line_max
    mov ah, 0Ah
    int 21h
    mov al, 10
    call putc
    ; the line, in capitals, ending in 0 (and as typed, for programs)
    mov si, line
    mov cl, [line_count]
    xor ch, ch
    mov bx, cx
    mov byte [si+bx], 0
    mov di, line_typed
    push cx
    inc cx
    rep movsb
    pop cx
    mov si, line
.caps:
    jcxz .parsed
    mov al, [si]
    cmp al, 'a'
    jb .next_cap
    cmp al, 'z'
    ja .next_cap
    sub byte [si], 20h
.next_cap:
    inc si
    loop .caps
.parsed:
    mov si, line
    call skip_blanks
    cmp byte [si], 0
    je main
    mov [cmd_start], si
    mov di, cmd_word
    call get_word
    mov [args], si
    call run_command
    call crlf
    jmp main

; Runs the command in cmd_word with the arguments at [args].
run_command:
    ; a drive change, "B:"
    cmp byte [cmd_word+2], 0
    jne .builtin
    cmp byte [cmd_word+1], ':'
    jne .builtin
    mov dl, [cmd_word]
    sub dl, 'A'
    mov ah, 0Eh
    int 21h
    mov ah, 19h
    int 21h
    cmp al, dl
    je .done
    mov si, s_bad_drive
    call print
.done:
    ret
.builtin:
    mov bx, commands
.next:
    mov di, [bx]
    test di, di
    jnz .ok1
    jmp external
.ok1:
    mov si, cmd_word
    call str_equal
    je .found
    add bx, 4
    jmp .next
.found:
    mov si, [args]
    call skip_blanks
    jmp [bx+2]

commands:
    dw n_cd, c_cd, n_chdir, c_cd, n_cls, c_cls, n_copy, c_copy
    dw n_date, c_date, n_del, c_del, n_dir, c_dir, n_echo, c_echo
    dw n_erase, c_del, n_exit, c_exit, n_md, c_md, n_mkdir, c_md
    dw n_pause, c_pause, n_rd, c_md, n_rem, c_rem, n_ren, c_ren
    dw n_rename, c_ren, n_rmdir, c_md, n_set, c_set, n_time, c_time
    dw n_type, c_type, n_ver, c_ver, n_vol, c_vol
    dw 0

n_cd     db 'CD', 0
n_chdir  db 'CHDIR', 0
n_cls    db 'CLS', 0
n_copy   db 'COPY', 0
n_date   db 'DATE', 0
n_del    db 'DEL', 0
n_dir    db 'DIR', 0
n_echo   db 'ECHO', 0
n_erase  db 'ERASE', 0
n_exit   db 'EXIT', 0
n_md     db 'MD', 0
n_mkdir  db 'MKDIR', 0
n_pause  db 'PAUSE', 0
n_rd     db 'RD', 0
n_rem    db 'REM', 0
n_ren    db 'REN', 0
n_rename db 'RENAME', 0
n_rmdir  db 'RMDIR', 0
n_set    db 'SET', 0
n_time   db 'TIME', 0
n_type   db 'TYPE', 0
n_ver    db 'VER', 0
n_vol    db 'VOL', 0

; ---------- Ctrl-C ----------

own_ctrl_c:
    mov dx, on_ctrl_c
    mov ax, 2523h
    int 21h
    ret

kernel_ctrl_c:
    push ds
    lds dx, [old23]
    mov ax, 2523h
    int 21h
    pop ds
    ret

; Ctrl-C while the prompt or a built-in command waits for a key
on_ctrl_c:
    cli
    mov ax, cs
    mov ss, ax
    mov sp, stack_top
    sti
    jmp main

; ======================================================================
; Programs
; ======================================================================

external:
    mov si, cmd_word
    call has_wild
    test al, al
    jnz .bad
    mov si, cmd_word
    call has_dot
    test al, al
    jnz .with_extension
    ; NAME: try .COM, then .EXE, then say why a .BAT does not run
    mov si, ext_com
    call try_extension
    jnc .run
    mov si, ext_exe
    call try_extension
    jnc .run
    mov si, ext_bat
    call try_extension
    jc .bad
    mov si, s_no_batch
    call print
    ret
.with_extension:
    mov si, cmd_word
    mov di, prog_path
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    sub di, 5
    mov si, di
    mov di, ext_com
    call str_equal
    je .check
    mov di, ext_exe
    call str_equal
    jne .bad
.check:
    mov dx, prog_path
    xor cx, cx
    mov ah, 4Eh
    int 21h
    jnc .run
.bad:
    mov si, s_bad_command
    call print
    ret
.run:
    ; the command tail: what follows the name, as typed
    mov si, [args]
    add si, line_typed - line
    mov di, tail+1
    xor cx, cx
.tail:
    lodsb
    test al, al
    jz .tail_end
    cmp cx, 126
    jae .tail
    stosb
    inc cx
    jmp .tail
.tail_end:
    mov al, 13
    stosb
    mov [tail], cl
    ; the first two arguments as FCBs
    mov si, tail+1
    mov di, fcb1
    mov ax, 2901h
    int 21h
    mov di, fcb2
    mov ax, 2901h
    int 21h
    mov word [exec_block], 0
    mov word [exec_block+2], tail
    mov [exec_block+4], cs
    mov word [exec_block+6], fcb1
    mov [exec_block+8], cs
    mov word [exec_block+10], fcb2
    mov [exec_block+12], cs
    call kernel_ctrl_c
    mov dx, prog_path
    mov bx, exec_block
    mov ax, 4B00h
    int 21h
    push cs
    pop ds
    push cs
    pop es
    jnc .ran
    push ax
    call own_ctrl_c
    pop ax
    mov si, s_too_big
    cmp ax, 8
    je .error
    mov si, s_bad_command
.error:
    call print
    ret
.ran:
    call own_ctrl_c
    ret

; prog_path = cmd_word + the extension at SI, if that file exists. CF if not.
try_extension:
    push si
    mov si, cmd_word
    mov di, prog_path
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    dec di
    pop si
.ext:
    lodsb
    stosb
    test al, al
    jnz .ext
    mov dx, prog_path
    xor cx, cx
    mov ah, 4Eh
    int 21h
    ret

ext_com db '.COM', 0
ext_exe db '.EXE', 0
ext_bat db '.BAT', 0

; ======================================================================
; Built-in commands
; ======================================================================

c_rem:
c_exit:                             ; this is the permanent shell: stays
    ret

c_ver:
    mov si, s_version
    call print
    ret

c_cls:
    mov ax, 0600h                   ; scroll the whole screen away
    mov bh, 07h
    xor cx, cx
    mov dx, 184Fh
    int 10h
    mov ah, 02h
    xor bh, bh
    xor dx, dx
    int 10h
    ret

c_echo:
    cmp byte [si], 0
    jne .text
    mov si, s_echo_on
.text:
    call print
    call crlf
    ret

c_pause:
    mov si, s_strike
    call print
    mov ah, 08h
    int 21h
    call crlf
    ret

c_cd:
    cmp byte [si], 0
    jne .change
    mov ah, 19h                     ; show it: always the root
    int 21h
    add al, 'A'
    call putc
    mov si, s_root
    call print
    call crlf
    ret
.change:
    mov di, arg1
    call get_word
    mov dx, arg1
    mov ah, 3Bh
    int 21h
    jnc .ok
    mov si, s_bad_dir
    call print
.ok:
    ret

c_md:
    mov si, s_no_subdirs
    call print
    ret

c_set:
    cmp byte [si], 0
    je .show
    mov si, s_no_set
    call print
    ret
.show:
    push ds
    mov ds, [2Ch]
    xor si, si
.string:
    cmp byte [si], 0
    je .done
    call print
.skip:
    lodsb
    test al, al
    jnz .skip
    push ds
    push cs
    pop ds
    call crlf
    pop ds
    jmp .string
.done:
    pop ds
    ret

; ---------- VOL and the volume label ----------

; AL = drive -> prints " Volume in drive A is LABEL" or "has no label".
; CF if the drive could not be read (the error has been reported).
show_volume:
    push ax
    mov di, vol_path
    mov si, s_all
    call make_path
    mov dx, vol_path
    mov cx, 08h
    mov ah, 4Eh
    int 21h
    mov byte [vol_found], 1
    jnc .searched
    mov byte [vol_found], 0
    cmp ax, 2                       ; no label; anything else is a failure
    je .searched
    cmp ax, 12h
    je .searched
    pop ax
    cmp ax, 0Fh
    jne .failed
    mov si, s_bad_drive
    call print
.failed:
    stc
    ret
.searched:
    pop ax
    mov si, s_volume
    call print
    add al, 'A'
    call putc
    cmp byte [vol_found], 0
    je .none
    mov si, s_is
    call print
    mov si, dta+30                  ; the label without the dot of 8.3
.char:
    lodsb
    test al, al
    jz .end
    cmp al, '.'
    je .char
    call putc
    jmp .char
.end:
    call crlf
    clc
    ret
.none:
    mov si, s_no_label
    call print
    clc
    ret

c_vol:
    call split_drive
    call crlf
    call show_volume
    ret

; ---------- DIR ----------

dir_wide  db 0
dir_count dw 0
dir_drive db 0

c_dir:
    mov byte [dir_wide], 0
    mov byte [arg1], 0
.arg:
    call skip_blanks
    cmp byte [si], 0
    je .args_done
    cmp byte [si], '/'
    jne .path
    mov al, [si+1]
    cmp al, 'W'
    jne .bad_switch
    mov byte [dir_wide], 1
    add si, 2
    jmp .arg
.bad_switch:
    mov si, s_bad_switch
    call print
    ret
.path:
    mov di, arg1
    call get_word
    jmp .arg
.args_done:
    ; pattern: drive, and a name that defaults to *.* (NAME means NAME.*)
    mov si, arg1
    call split_drive
    mov [dir_drive], al
    mov di, arg2
    cmp byte [si], 0
    jne .name
    mov si, s_all
    call make_path
    jmp .header
.name:
    call make_path
    mov si, arg2
    call has_dot
    test al, al
    jnz .header
    dec di
    mov si, s_dot_all
.ext:
    lodsb
    stosb
    test al, al
    jnz .ext
.header:
    call crlf
    mov al, [dir_drive]
    call show_volume
    jnc .listing
    ret
.listing:
    mov si, s_dir_of
    call print
    mov al, [dir_drive]
    add al, 'A'
    call putc
    mov si, s_root
    call print
    call crlf
    call crlf
    mov word [dir_count], 0
    mov dx, arg2
    mov cx, 10h
    mov ah, 4Eh
    int 21h
    jc .none
.entry:
    inc word [dir_count]
    call dir_line
    mov ah, 4Fh
    int 21h
    jnc .entry
    cmp byte [dir_wide], 0          ; finish the last row of /W
    je .summary
    mov ax, [dir_count]
    xor dx, dx
    mov bx, 5
    div bx
    test dx, dx
    jz .summary
    call crlf
.summary:
    mov ax, [dir_count]
    xor dx, dx
    mov bl, 9
    call print_num
    mov si, s_files
    call print
    ; free bytes = sectors per cluster * free clusters * bytes per sector
    mov dl, [dir_drive]
    inc dl
    mov ah, 36h
    int 21h
    mul cx
    mul bx
    mov bl, 10
    call print_num
    mov si, s_bytes_free
    call print
    ret
.none:
    mov si, s_not_found
    call print
    ret

; One entry of DIR from the DTA
dir_line:
    ; name and extension, padded as 8 + 3
    mov si, dta+30
    mov cx, 8
.name:
    lodsb
    test al, al
    jz .pad_name
    cmp al, '.'
    je .pad_name
    call putc
    loop .name
    lodsb
.pad_name:
    jcxz .ext_start
.space:
    push ax
    mov al, ' '
    call putc
    pop ax
    loop .space
.ext_start:
    push ax
    mov al, ' '
    call putc
    pop ax
    mov cx, 3
    cmp al, '.'
    jne .pad_ext
.ext:
    lodsb
    test al, al
    jz .pad_ext
    call putc
    loop .ext
.pad_ext:
    jcxz .wide_or_long
.ext_space:
    mov al, ' '
    call putc
    loop .ext_space
.wide_or_long:
    cmp byte [dir_wide], 0
    je .long
    ; /W: five per row
    mov ax, [dir_count]
    xor dx, dx
    mov bx, 5
    div bx
    test dx, dx
    jz .row_end
    mov si, s_wide_gap
    call print
    ret
.row_end:
    call crlf
    ret
.long:
    test byte [dta+21], 10h
    jz .size
    mov si, s_dir_tag
    call print
    jmp .date
.size:
    mov ax, [dta+26]
    mov dx, [dta+28]
    mov bl, 9
    call print_num
.date:
    ; date: month (right-aligned), day, year
    mov si, s_2spaces
    call print
    mov ax, [dta+24]
    mov cl, 5
    shr ax, cl
    and al, 0Fh
    call print_2s
    mov al, '-'
    call putc
    mov al, [dta+24]
    and al, 1Fh
    call print_2
    mov al, '-'
    call putc
    mov ax, [dta+24]
    mov cl, 9
    shr ax, cl
    add ax, 80
    cmp ax, 100
    jb .year
    sub ax, 100
.year:
    call print_2
    ; time: 12-hour clock with a or p
    mov si, s_2spaces
    call print
    mov ax, [dta+22]
    mov cl, 11
    shr ax, cl
    mov ah, 'a'
    cmp al, 12
    jb .am
    mov ah, 'p'
    sub al, 12
.am:
    test al, al
    jnz .hour
    mov al, 12
.hour:
    push ax
    call print_2s
    mov al, ':'
    call putc
    mov ax, [dta+22]
    mov cl, 5
    shr ax, cl
    and al, 3Fh
    call print_2
    pop ax
    mov al, ah
    call putc
    call crlf
    ret

; ---------- TYPE ----------

c_type:
    cmp byte [si], 0
    jne .open
    mov si, s_required
    call print
    ret
.open:
    mov di, arg1
    call get_word
    mov dx, arg1
    mov ax, 3D00h
    int 21h
    jc .not_found
    mov bx, ax
.read:
    mov dx, buffer
    mov cx, 512
    mov ah, 3Fh
    int 21h
    jc .close
    test ax, ax
    jz .close
    ; up to an end-of-file mark (Ctrl-Z)
    mov cx, ax
    mov di, buffer
    mov al, 1Ah
    push cx
    repne scasb
    pop cx
    jne .write
    mov cx, di
    sub cx, buffer + 1
    push bx
    mov bx, 1
    mov ah, 40h
    int 21h
    pop bx
    jmp .close
.write:
    push bx
    mov bx, 1
    mov ah, 40h
    int 21h
    pop bx
    jmp .read
.close:
    mov ah, 3Eh
    int 21h
    ret
.not_found:
    call file_error
    ret

; AX = DOS error after open: the message
file_error:
    mov si, s_not_found
    cmp ax, 2
    je .print
    cmp ax, 3
    je .print
    mov si, s_denied
    cmp ax, 5
    je .print
    mov si, s_bad_drive
    cmp ax, 0Fh
    je .print
    mov si, s_failure
.print:
    call print
    ret

; ---------- names with wildcards ----------

; The 8.3 name at SI ("NAME.EXT" ASCIIZ) into FCB form (11 bytes) at DI.
to_fcb:
    push di
    mov al, ' '
    mov cx, 11
    rep stosb
    pop di
    push di
    mov cx, 8
.name:
    lodsb
    test al, al
    jz .done
    cmp al, '.'
    je .ext
    jcxz .name
    stosb
    dec cx
    jmp .name
.ext:
    pop di
    push di
    add di, 8
    mov cx, 3
.ext_char:
    lodsb
    test al, al
    jz .done
    jcxz .ext_char
    stosb
    dec cx
    jmp .ext_char
.done:
    pop di
    ret

; FCB-form name at SI to "NAME.EXT" (ASCIIZ) at DI
from_fcb:
    mov cx, 8
.name:
    lodsb
    cmp al, ' '
    je .name_end
    stosb
    loop .name
    jmp .ext
.name_end:
    dec cx
    add si, cx
.ext:
    cmp byte [si], ' '
    je .done
    mov al, '.'
    stosb
    mov cx, 3
.ext_char:
    lodsb
    cmp al, ' '
    je .done
    stosb
    loop .ext_char
.done:
    xor al, al
    stosb
    ret

; The name found (DTA) through the template pattern_fcb (? = keep that
; character) -> "X:NAME.EXT" at DI, drive AL.
apply_template:
    push ax
    push di
    mov si, dta+30
    mov di, found_fcb
    call to_fcb
    mov si, pattern_fcb
    mov di, found_fcb
    mov cx, 11
.char:
    lodsb
    cmp al, '?'
    je .keep
    mov [di], al
.keep:
    inc di
    loop .char
    pop di
    pop ax
    add al, 'A'
    stosb
    mov al, ':'
    stosb
    mov si, found_fcb
    call from_fcb
    ret

; The name at SI, maybe with * and ?, into pattern_fcb (with ?)
make_pattern:
    mov di, pattern_fcb
    mov ax, 2900h
    int 21h
    mov si, pattern_fcb + 1
    mov di, pattern_fcb
    mov cx, 11
    rep movsb
    ret

; "X:" + the name found (DTA) at DI, drive AL
found_path:
    add al, 'A'
    stosb
    mov al, ':'
    stosb
    mov si, dta+30
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    ret

; ---------- DEL ----------

del_drive db 0
del_count dw 0

c_del:
    cmp byte [si], 0
    jne .args
    mov si, s_required
    call print
    ret
.args:
    mov di, arg1
    call get_word
    mov si, arg1
    call split_drive
    mov [del_drive], al
    call make_pattern
    ; *.*: ask first
    mov si, pattern_fcb
    mov cx, 11
.all:
    lodsb
    cmp al, '?'
    jne .search
    loop .all
    mov si, s_all_files
    call print
    mov dx, answer_max
    mov ah, 0Ah
    int 21h
    call crlf
    mov al, [answer]
    and al, 0DFh
    cmp al, 'Y'
    je .search
    ret
.search:
    mov word [del_count], 0
    mov dx, arg1
    xor cx, cx
    mov ah, 4Eh
    int 21h
    jc .none
.file:
    mov al, [del_drive]
    mov di, arg2
    call found_path
    mov dx, arg2
    mov ah, 41h
    int 21h
    jnc .deleted
    mov si, s_denied
    call print
    jmp .next
.deleted:
    inc word [del_count]
.next:
    mov ah, 4Fh
    int 21h
    jnc .file
    ret
.none:
    mov si, s_not_found
    call print
    ret

; ---------- REN ----------

c_ren:
    mov di, arg1
    call get_word
    call skip_blanks
    mov di, arg2
    call get_word
    cmp byte [arg2], 0
    jne .names
    mov si, s_syntax
    call print
    ret
.names:
    mov si, arg1
    call split_drive
    mov [del_drive], al
    mov si, arg2                    ; the new name has no drive
    cmp byte [si+1], ':'
    jne .pattern
    add si, 2
.pattern:
    call make_pattern
    mov dx, arg1
    xor cx, cx
    mov ah, 4Eh
    int 21h
    jc .failed
.file:
    mov al, [del_drive]
    mov di, path1
    call found_path
    mov al, [del_drive]
    mov di, path2
    call apply_template
    mov dx, path1
    mov di, path2
    mov ah, 56h
    int 21h
    jc .failed
    mov ah, 4Fh
    int 21h
    jnc .file
    ret
.failed:
    mov si, s_duplicate
    call print
    ret

; ---------- COPY ----------

copy_src_drive db 0
copy_dst_drive db 0
copy_count     dw 0
copy_wild      db 0
src_handle     dw 0
dst_handle     dw 0

c_copy:
    mov di, arg1
    call get_word
    call skip_blanks
    mov di, arg2
    call get_word
    cmp byte [arg1], 0
    jne .args
    mov si, s_required
    call print
    ret
.args:
    mov word [copy_count], 0
    mov si, arg1
    call has_wild
    mov [copy_wild], al
    mov si, arg1
    call split_drive
    mov [copy_src_drive], al
    ; destination: a drive, a name or nothing (the current drive)
    mov si, arg2
    call split_drive
    mov [copy_dst_drive], al
    cmp byte [si], 0
    jne .dst_name
    mov si, s_all                   ; *.*: keep every name
.dst_name:
    call make_pattern
    mov dx, arg1
    xor cx, cx
    mov ah, 4Eh
    int 21h
    jnc .file
    mov si, s_not_found
    call print
    jmp .summary
.file:
    mov al, [copy_src_drive]
    mov di, path1
    call found_path
    mov al, [copy_dst_drive]
    mov di, path2
    call apply_template
    mov si, path1
    mov di, path2
    call str_equal
    jne .copy
    mov si, s_onto_itself
    call print
    jmp .summary
.copy:
    cmp byte [copy_wild], 0
    je .quiet
    mov si, path1
    call print
    call crlf
.quiet:
    call copy_file
    jc .summary
    inc word [copy_count]
    mov ah, 4Fh
    int 21h
    jnc .file
.summary:
    mov ax, [copy_count]
    xor dx, dx
    mov bl, 9
    call print_num
    mov si, s_copied
    call print
    ret

; path1 -> path2, with the same date and time. CF on an error (printed).
copy_file:
    mov dx, path1
    mov ax, 3D00h
    int 21h
    jnc .ok2
    jmp .open_error
.ok2:
    mov [src_handle], ax
    mov dx, path2
    xor cx, cx
    mov ah, 3Ch
    int 21h
    jc .create_error
    mov [dst_handle], ax
.block:
    mov bx, [src_handle]
    mov dx, buffer
    mov cx, BUFFER_SIZE
    mov ah, 3Fh
    int 21h
    jc .read_error
    test ax, ax
    jz .done
    mov cx, ax
    mov bx, [dst_handle]
    mov ah, 40h
    int 21h
    jc .full
    cmp ax, cx
    jb .full
    jmp .block
.done:
    mov bx, [src_handle]
    mov ax, 5700h
    int 21h
    mov bx, [dst_handle]
    mov ax, 5701h
    int 21h
    mov ah, 3Eh                     ; the data reaches the diskette here
    int 21h
    pushf
    mov bx, [src_handle]
    mov ah, 3Eh
    int 21h
    popf
    ret
.full:
    mov bx, [dst_handle]
    mov ah, 3Eh
    int 21h
    mov dx, path2
    mov ah, 41h
    int 21h
    mov si, s_disk_full
    jmp .close_source
.read_error:
    mov bx, [dst_handle]
    mov ah, 3Eh
    int 21h
    mov si, s_failure
.close_source:
    call print
    mov bx, [src_handle]
    mov ah, 3Eh
    int 21h
    stc
    ret
.create_error:
    mov bx, [src_handle]
    mov ah, 3Eh
    int 21h
    mov si, s_create_error
    call print
    stc
    ret
.open_error:
    call file_error
    stc
    ret

; ---------- DATE and TIME ----------

days db 'SunMonTueWedThuFriSat'
set_1 db 0                          ; the fields being set
set_2 db 0
set_3 db 0
set_4 db 0

c_date:
    cmp byte [si], 0
    jne .set
    mov si, s_cur_date
    call print
    mov ah, 2Ah
    int 21h
    push cx
    push dx
    xor ah, ah
    mov bl, 3
    mul bl
    mov si, days
    add si, ax
    mov cx, 3
.day:
    lodsb
    call putc
    loop .day
    mov al, ' '
    call putc
    pop dx
    pop cx
    mov al, dh
    call print_2s
    mov al, '-'
    call putc
    mov al, dl
    call print_2
    mov al, '-'
    call putc
    mov ax, cx
    xor dx, dx
    mov bl, 4
    call print_num
    call crlf
.ask:
    mov si, s_new_date
    call print
    mov dx, answer_max
    mov ah, 0Ah
    int 21h
    call crlf
    mov si, answer
    mov bl, [answer_count]
    xor bh, bh
    mov byte [si+bx], 0
    call skip_blanks
    cmp byte [si], 0
    je .done
.set:
    ; mm-dd-yy or mm-dd-yyyy, with - / or .
    call read_number
    jc .bad
    mov [set_1], al                 ; month
    call date_sep
    jc .bad
    call read_number
    jc .bad
    mov [set_2], al                 ; day
    call date_sep
    jc .bad
    call read_number
    jc .bad
    cmp byte [si], 0
    jne .bad
    cmp ax, 100
    jae .year
    add ax, 1900
    cmp ax, 1980
    jae .year
    add ax, 100
.year:
    mov cx, ax
    mov dh, [set_1]
    mov dl, [set_2]
    mov ah, 2Bh
    int 21h
    test al, al
    jnz .bad
.done:
    ret
.bad:
    mov si, s_bad_date
    call print
    mov si, [args]
    call skip_blanks
    cmp byte [si], 0
    je .ask
    ret

date_sep:
    mov al, [si]
    cmp al, '-'
    je .ok
    cmp al, '/'
    je .ok
    cmp al, '.'
    je .ok
    stc
    ret
.ok:
    inc si
    clc
    ret

; A decimal number at SI -> AX. CF if there is none.
read_number:
    xor ax, ax
    xor cx, cx
.digit:
    mov bl, [si]
    sub bl, '0'
    cmp bl, 9
    ja .end
    push bx
    mov bx, 10
    mul bx
    pop bx
    xor bh, bh
    add ax, bx
    inc si
    inc cx
    jmp .digit
.end:
    cmp cx, 1
    ret

c_time:
    cmp byte [si], 0
    jne .set
    mov si, s_cur_time
    call print
    mov ah, 2Ch
    int 21h
    mov al, ch
    call print_2s
    mov al, ':'
    call putc
    mov al, cl
    call print_2
    mov al, ':'
    call putc
    mov al, dh
    call print_2
    mov al, '.'
    call putc
    mov al, dl
    call print_2
    call crlf
.ask:
    mov si, s_new_time
    call print
    mov dx, answer_max
    mov ah, 0Ah
    int 21h
    call crlf
    mov si, answer
    mov bl, [answer_count]
    xor bh, bh
    mov byte [si+bx], 0
    call skip_blanks
    cmp byte [si], 0
    je .done
.set:
    ; hh[:mm[:ss[.hh]]]
    mov word [set_1], 0
    mov word [set_3], 0
    call read_number
    jc .bad
    mov [set_1], al                 ; hours
    cmp byte [si], ':'
    jne .apply
    inc si
    call read_number
    jc .bad
    mov [set_2], al                 ; minutes
    cmp byte [si], ':'
    jne .apply
    inc si
    call read_number
    jc .bad
    mov [set_3], al                 ; seconds
    cmp byte [si], '.'
    jne .apply
    inc si
    call read_number
    jc .bad
    mov [set_4], al                 ; hundredths
.apply:
    cmp byte [si], 0
    jne .bad
    mov ch, [set_1]
    mov cl, [set_2]
    mov dh, [set_3]
    mov dl, [set_4]
    mov ah, 2Dh
    int 21h
    test al, al
    jnz .bad
.done:
    ret
.bad:
    mov si, s_bad_time
    call print
    mov si, [args]
    call skip_blanks
    cmp byte [si], 0
    jne .ok3
    jmp .ask
.ok3:
    ret

; ======================================================================
; Data
; ======================================================================

s_banner      db 13, 10, 'DOS86 version 1.00', 13, 10, 0
s_version     db 13, 10, 'DOS86 Version 1.00', 13, 10, 0
s_prompt      db ':\>', 0
s_crlf        db 13, 10, 0
s_root        db ':\', 0
s_all         db '*.*', 0
s_dot_all     db '.*', 0
s_2spaces     db '  ', 0
s_wide_gap    db '    ', 0
s_dir_tag     db '   <DIR>  ', 0
s_bad_command db 'Bad command or file name', 13, 10, 0
s_bad_drive   db 'Invalid drive specification', 13, 10, 0
s_too_big     db 'Program too big to fit in memory', 13, 10, 0
s_no_batch    db 'Batch files are not supported by DOS86', 13, 10, 0
s_no_subdirs  db 'Subdirectories are not supported by DOS86', 13, 10, 0
s_no_set      db 'Changing the environment is not supported by DOS86', 13, 10, 0
s_bad_dir     db 'Invalid directory', 13, 10, 0
s_bad_switch  db 'Invalid switch', 13, 10, 0
s_echo_on     db 'ECHO is on', 0
s_strike      db 'Strike a key when ready . . . ', 0
s_volume      db ' Volume in drive ', 0
s_is          db ' is ', 0
s_no_label    db ' has no label', 13, 10, 0
s_dir_of      db ' Directory of  ', 0
s_files       db ' File(s)', 0
s_bytes_free  db ' bytes free', 13, 10, 0
s_not_found   db 'File not found', 13, 10, 0
s_denied      db 'Access denied', 13, 10, 0
s_failure     db 'General failure', 13, 10, 0
s_required    db 'Required parameter missing', 13, 10, 0
s_syntax      db 'Invalid number of parameters', 13, 10, 0
s_all_files   db 'All files in directory will be deleted!', 13, 10, 'Are you sure (Y/N)?', 0
s_duplicate   db 'Duplicate file name or file not found', 13, 10, 0
s_onto_itself db 'File cannot be copied onto itself', 13, 10, 0
s_disk_full   db 'Insufficient disk space', 13, 10, 0
s_create_error db 'File creation error', 13, 10, 0
s_copied      db ' File(s) copied', 13, 10, 0
s_cur_date    db 'Current date is ', 0
s_new_date    db 'Enter new date (mm-dd-yy): ', 0
s_bad_date    db 'Invalid date', 13, 10, 0
s_cur_time    db 'Current time is ', 0
s_new_time    db 'Enter new time: ', 0
s_bad_time    db 'Invalid time', 13, 10, 0

old23      dw 0, 0
cmd_start  dw 0
args       dw 0
exec_block dw 0, 0, 0, 0, 0, 0, 0
tail       times 128 db 0
fcb1       times 37 db 0
fcb2       times 37 db 0
numbuf     times 11 db 0
numbuf_end db 0
pattern_fcb times 16 db 0
found_fcb  times 12 db 0

line_max     db 127
line_count   db 0
line         times 129 db 0
line_typed   times 129 db 0
answer_max   db 40
answer_count db 0
answer       times 42 db 0

cmd_word   times 128 db 0
arg1       times 128 db 0
arg2       times 128 db 0
path1      times 80 db 0
path2      times 80 db 0
prog_path  times 80 db 0
dta        times 128 db 0
vol_path   times 8 db 0
vol_found  db 0

program_image_end:

; ======================================================================
; Memory past the file
; ======================================================================

BUFFER_SIZE equ 16384
buffer      equ program_image_end
stack_top   equ buffer + BUFFER_SIZE + 1024
program_end equ stack_top
