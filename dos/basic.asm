; basic.asm - CucsiCorp CBasic (BASIC.COM)
;
;   BASIC program[.BAS]
;
; A BASIC in the style of QBasic: SUB and FUNCTION, block IF, DO/LOOP,
; SELECT CASE, TYPE, integers (%), long integers (&), reals (! and #, both
; single precision) and strings ($), arrays, graphics (SCREEN 1 and 13),
; sound and files. Programs are written with EDIT and run with BASIC.
;
; How it works. The whole source is read into memory and compiled in two
; passes into a compact code for a stack machine: the first pass only
; collects the SUBs and FUNCTIONs (so they can be called before they are
; written), the second writes the code. Types are known when compiling, as
; in QBasic, so each operation of the machine already knows what it works
; on. Then the machine runs the code.
;
; Memory, above the program's own 64 KB: the source, the code, the data
; (variables, string descriptors, frames of SUBs), the strings (with a
; garbage collector), the names (only while compiling), and the rest for
; arrays.
org 100h

    jmp start

; ---------- types ----------
TY_INT      equ 1               ; 16 bits
TY_LNG      equ 2               ; 32 bits
TY_SNG      equ 3               ; IEEE single (also used for DOUBLE)
TY_STR      equ 4               ; descriptor: offset, length
TY_REC      equ 5               ; a TYPE record (by its type entry)

; ---------- names (compile time, in the names segment) ----------
N_NEXT      equ 0
N_KIND      equ 2
N_TYPE      equ 3               ; TY_*
N_SCOPE     equ 4               ; 0 module, n SUB/FUNCTION number
N_FLAGS     equ 5
N_ADDR      equ 6               ; data offset / frame offset / code address
N_X1        equ 8               ; extra: value of a CONST, array info...
N_X2        equ 10
N_LEN       equ 12
N_NAME      equ 13
NK_KEYWORD  equ 1               ; N_ADDR = keyword number
NK_VAR      equ 2
NK_ARRAY    equ 3               ; N_ADDR = its descriptor in data
NK_CONST    equ 4               ; N_X1:N_X2 = value
NK_LABEL    equ 5               ; N_ADDR = code address, N_X1 = fixup chain
NK_SUB      equ 6               ; N_X1 = its information record
NK_FUNC     equ 7
NK_TYPE     equ 8               ; a TYPE: N_X1 = size, N_X2 = first field
NK_FIELD    equ 9
NK_DEFFN    equ 10
NF_SHARED   equ 1               ; module variable visible in SUBs
NF_LOCAL    equ 2               ; in a frame (N_ADDR is a frame offset)
NF_PARAM    equ 4               ; a parameter: the frame holds its address
NF_DEFINED  equ 8               ; a label that has its address

HASH_SIZE   equ 512

; ---------- memory of the running program (data segment) ----------
DATA_GLOBALS equ 0              ; module variables from here up
DATA_GLOBALS_MAX equ 0C000h     ; the end of the module's variables
TEMP_COUNT  equ 512             ; temporary string descriptors
NTEMP_COUNT equ 1024            ; temporary numbers (arguments)
STR_HEAP_END equ 0FFF0h         ; the end of the string heap
LINES_MAX   equ 2000h           ; statements in the line table
DATA_POOL   equ 8000h           ; the DATA items, after the line table
INBUF_SIZE  equ 256             ; a line typed for INPUT
NUMBUF_SIZE equ 80              ; a number or a field as text
STACK_LIMIT equ bss_end + 512   ; the stack may not grow below this

; ---------- tokens ----------
TK_EOF      equ 0
TK_EOL      equ 1               ; end of a line
TK_NUM      equ 2               ; tok_type = TY_INT/LNG/SNG, tok_lo/hi
TK_STR      equ 3               ; tok_text, tok_len
TK_NAME     equ 4               ; tok_text, tok_len, tok_suffix
TK_KW       equ 5               ; tok_kw
TK_OP       equ 6               ; tok_op (character or OP_*)
TK_COLON    equ 7

; operators made of two characters
OP_LE       equ 'l'             ; <=
OP_GE       equ 'g'             ; >=
OP_NE       equ 'n'             ; <>

; runtime errors (QBasic numbers)
E_NEXT      equ 1               ; NEXT without FOR
E_SYNTAX    equ 2
E_RETURN    equ 3               ; RETURN without GOSUB
E_DATA      equ 4               ; out of DATA
E_FUNC      equ 5               ; illegal function call
E_OVERFLOW  equ 6
E_MEMORY    equ 7
E_LABEL     equ 8               ; label not defined
E_SUBSCRIPT equ 9
E_DUPDEF    equ 10
E_DIVZERO   equ 11
E_TYPE      equ 13
E_STRSPACE  equ 14
E_RESUME    equ 20
E_NORESUME  equ 19
E_BADFILE   equ 52
E_NOFILE    equ 53
E_FILEMODE  equ 54
E_OPEN      equ 55
E_DISKFULL  equ 61
E_EOF       equ 62
E_FILENUM   equ 64
E_EXISTS    equ 58
E_PATH      equ 76
E_STRLONG   equ 15
E_COMPLEX   equ 16
E_STACK     equ 28
E_BREAK     equ 255             ; Ctrl+C (cannot be trapped)

; ======================================================================
; Start
; ======================================================================

start:
    cld
    mov di, bss_start               ; the variables start at 0
    mov cx, bss_end - bss_start
    xor al, al
    rep stosb
    mov ax, cs                      ; the segments above the program
    add ax, 1000h
    mov [seg_src], ax
    add ax, 1000h
    mov [seg_code], ax
    add ax, 1000h
    mov [seg_data], ax
    add ax, 1000h
    mov [seg_str], ax
    add ax, 1000h
    mov [seg_lines], ax             ; line table, then the DATA items
    add ax, 1000h
    mov [seg_sym], ax
    mov [arena_start], ax           ; the names are not needed when running
    add ax, 1000h
    mov bx, [2]
    mov [arena_end], bx
    cmp ax, bx
    jb .memory
    mov si, m_memory
    jmp fatal
.memory:
    call get_args
    call load_source
    call scr_init
    call compile
    cmp word [err_count], 0
    jne .failed
    call run
    jmp exit_ok
.failed:
    mov ax, 4C01h
    int 21h

exit_ok:
    call files_close_all
    mov ax, 4C00h
    int 21h

; SI = message: "BASIC: message" and ends
fatal:
    push si
    mov si, m_basic
    call con_puts
    pop si
    call con_puts
    mov si, m_crlf
    call con_puts
    mov ax, 4C02h
    int 21h

; DS:SI ASCIIZ to standard output (before the screen is ours)
con_puts:
    push ax
    push dx
.next:
    lodsb
    or al, al
    jz .done
    mov dl, al
    mov ah, 02h
    int 21h
    jmp .next
.done:
    pop dx
    pop ax
    ret

; ---------- the command line ----------

get_args:
    mov si, 81h
.skip:
    lodsb
    cmp al, ' '
    je .skip
    cmp al, 9
    je .skip
    dec si
    mov di, src_name
    xor bx, bx                      ; BX = has a dot
.copy:
    lodsb
    cmp al, ' '
    jbe .end
    cmp al, 'a'
    jb .store
    cmp al, 'z'
    ja .store
    sub al, 20h
.store:
    cmp al, '.'
    jne .not_dot
    mov bx, 1
.not_dot:
    cmp al, '\'
    jne .not_dir
    xor bx, bx
.not_dir:
    stosb
    cmp di, src_name + 70
    jb .copy
.end:
    mov byte [di], 0
    cmp di, src_name
    jne .named
    mov si, m_usage
    call con_puts
    mov si, m_crlf
    call con_puts
    mov ax, 4C02h
    int 21h
.named:
    or bx, bx
    jnz .done
    mov si, m_ext_bas
.ext:
    lodsb
    stosb
    or al, al
    jnz .ext
.done:
    ret

; ---------- the source ----------

load_source:
    mov dx, src_name
    mov ax, 3D00h
    int 21h
    jnc .opened
    mov si, m_cannot_open
    call con_puts
    mov si, src_name
    jmp fatal
.opened:
    mov bx, ax
    push ds
    mov ds, [cs:seg_src]
    xor dx, dx
    mov cx, 0FFF0h
    mov ah, 3Fh
    int 21h
    pop ds
    jnc .read
    mov si, m_read_error
    jmp fatal
.read:
    cmp ax, 0FFF0h
    jb .fits
    mov si, m_too_long
    jmp fatal
.fits:
    mov [src_len], ax
    push es                         ; a 0 after it, and Ctrl-Z ends it
    mov es, [seg_src]
    mov di, ax
    mov byte [es:di], 0
    xor di, di
    mov cx, ax
    jcxz .no_eof
    mov al, 1Ah
    repne scasb
    jne .no_eof
    mov byte [es:di - 1], 0
.no_eof:
    pop es
    mov ah, 3Eh
    int 21h
    ret

; ======================================================================
; Errors
; ======================================================================

; A compile error: SI = message. Shows "NAME.BAS(line): message" (the first
; error only) and stops the compiler.
cerror:
    inc word [err_count]
    cmp word [err_count], 1
    jne .stop
    call scr_text_mode
    push si
    mov si, src_name
    call con_puts
    mov dl, '('
    mov ah, 02h
    int 21h
    mov ax, [lx_line]
    call con_number
    mov si, m_line_end
    call con_puts
    pop si
    call con_puts
    mov si, m_crlf
    call con_puts
.stop:
    mov sp, [compile_sp]            ; back out of the compiler
    ret

; AX unsigned in decimal to standard output
con_number:
    push ax
    push bx
    push cx
    push dx
    mov bx, 10
    xor cx, cx
.digit:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .digit
.put:
    pop dx
    add dl, '0'
    mov ah, 02h
    int 21h
    loop .put
    pop dx
    pop cx
    pop bx
    pop ax
    ret


; ======================================================================
; The lexer: the next token of the source into tok_*
; ======================================================================

; Reads the next token. Names are copied in capitals to tok_name; keywords
; become TK_KW.
next:
    cmp byte [tok], TK_EOL          ; past the end of a line: the next one
    jne .same_line
    inc word [lx_line]
.same_line:
    push si
    push di
    push ds
    mov si, [lx_pos]
    mov ds, [cs:seg_src]
.blank:
    mov al, [si]
    cmp al, ' '
    je .skip
    cmp al, 9
    je .skip
    cmp al, 13
    jne .not_blank
.skip:
    inc si
    jmp .blank
.not_blank:
    mov [cs:tok_start], si
    or al, al
    jnz .not_eof
    mov byte [cs:tok], TK_EOF
    jmp .done
.not_eof:
    cmp al, 10
    jne .not_eol
    inc si
    mov byte [cs:tok], TK_EOL
    jmp .done
.not_eol:
    cmp al, 27h                     ; ' comment: to the end of the line
    jne .not_comment
.comment:
    mov al, [si]
    or al, al
    jz .not_blank
    cmp al, 10
    je .not_blank
    inc si
    jmp .comment
.not_comment:
    cmp al, ':'
    jne .not_colon
    inc si
    mov byte [cs:tok], TK_COLON
    jmp .done
.not_colon:
    cmp al, '"'
    jne .not_string
    inc si
    mov [cs:tok_text], si
.string:
    mov al, [si]
    or al, al
    jz .string_end
    cmp al, 10
    je .string_end
    cmp al, 13
    je .string_end
    inc si
    cmp al, '"'
    jne .string
    dec si
    mov ax, si
    sub ax, [cs:tok_text]
    mov [cs:tok_len], ax
    inc si
    jmp .string_done
.string_end:                        ; no closing quote: the line ends it
    mov ax, si
    sub ax, [cs:tok_text]
    mov [cs:tok_len], ax
.string_done:
    mov byte [cs:tok], TK_STR
    jmp .done
.not_string:
    cmp al, '0'
    jb .not_digit
    cmp al, '9'
    jbe .number
.not_digit:
    cmp al, '.'
    jne .not_dot
    mov ah, [si + 1]
    cmp ah, '0'
    jb .operator
    cmp ah, '9'
    jbe .number
    jmp .operator
.not_dot:
    cmp al, '&'
    jne .not_amp
    mov ah, [si + 1]
    and ah, 0DFh
    cmp ah, 'H'
    je .number
    cmp ah, 'O'
    je .number
    jmp .operator
.not_amp:
    call is_letter
    jc .operator
    jmp .name
.number:
    call lex_number                 ; DS = source, SI at the number
    jmp .done
.operator:
    inc si
    mov ah, [si]
    mov byte [cs:tok], TK_OP
    cmp al, '<'
    jne .not_less
    cmp ah, '='
    jne .not_le
    mov al, OP_LE
    inc si
    jmp .op
.not_le:
    cmp ah, '>'
    jne .op
    mov al, OP_NE
    inc si
    jmp .op
.not_less:
    cmp al, '>'
    jne .op
    cmp ah, '='
    jne .op
    mov al, OP_GE
    inc si
.op:
    mov [cs:tok_op], al
    jmp .done
.name:
    mov di, tok_name                ; letters, digits and dots, in capitals
    xor cx, cx
.name_char:
    mov al, [si]
    call is_letter
    jnc .name_store
    cmp al, '0'
    jb .name_dot
    cmp al, '9'
    jbe .name_store
.name_dot:
    cmp al, '.'
    jne .name_end
.name_store:
    cmp al, 'a'
    jb .upper
    cmp al, 'z'
    ja .upper
    sub al, 20h
.upper:
    inc si
    cmp cx, 40
    jae .name_char
    mov [cs:di], al
    inc di
    inc cx
    jmp .name_char
.name_end:
    mov byte [cs:tok_suffix], 0     ; % & ! # $
    cmp al, '%'
    je .suffix
    cmp al, '&'
    je .suffix
    cmp al, '!'
    je .suffix
    cmp al, '#'
    je .suffix
    cmp al, '$'
    jne .no_suffix
.suffix:
    mov [cs:tok_suffix], al
    inc si
.no_suffix:
    mov [cs:tok_len], cx
    mov [cs:lx_pos_tmp], si
    push cs
    pop ds
    call lex_keyword
    mov si, [lx_pos_tmp]
    cmp byte [tok], TK_KW           ; REM: the rest of the line is a comment
    jne .done
    cmp byte [tok_kw], KW_REM
    jne .done
    mov ds, [cs:seg_src]
    jmp .comment
.done:
    pop ds
    mov [lx_pos], si
    pop di
    pop si
    ret

; AL: CF = 0 if it is a letter
is_letter:
    push ax
    and al, 0DFh
    cmp al, 'A'
    jb .no
    cmp al, 'Z'
    ja .no
    pop ax
    clc
    ret
.no:
    pop ax
    stc
    ret

; The name in tok_name (with tok_suffix): a keyword? -> TK_KW and tok_kw,
; or TK_NAME
lex_keyword:
    mov byte [tok], TK_NAME
    mov al, [tok_suffix]
    cmp al, '$'                     ; keywords take only $ (LEFT$)
    je .look
    or al, al
    jnz .ret
.look:
    push si                         ; key_buf is in use: kept aside
    push di
    push cx
    mov si, key_buf
    mov di, key_saved
    mov cx, [key_len]
    mov [key_saved_len], cx
    push ds
    pop es
    rep movsb
    call name_key                   ; tok_name + suffix -> key_buf
    xor al, al
    call sym_find_scope
    jc .back
    cmp byte [es:di + N_KIND], NK_KEYWORD
    jne .back
    mov al, [es:di + N_ADDR]
    mov [tok_kw], al
    mov byte [tok], TK_KW
.back:
    push ds
    pop es
    mov si, key_saved
    mov di, key_buf
    mov cx, [key_saved_len]
    mov [key_len], cx
    rep movsb
    pop cx
    pop di
    pop si
.ret:
    push ds
    pop es
    ret

; A number at DS:SI (the source): TK_NUM with tok_type and tok_lo/tok_hi
lex_number:
    mov byte [cs:tok], TK_NUM
    cmp byte [si], '&'
    jne .decimal
    mov bx, 16                      ; &H, &O
    mov al, [si + 1]
    and al, 0DFh
    cmp al, 'H'
    je .radix
    mov bx, 8
.radix:
    add si, 2
    xor ax, ax
    xor dx, dx
.radix_digit:
    mov cl, [si]
    sub cl, '0'
    cmp cl, 9
    jbe .radix_value
    mov cl, [si]
    and cl, 0DFh
    sub cl, 'A' - 10
    cmp cl, 10
    jb .radix_end
.radix_value:
    xor ch, ch
    cmp cx, bx
    jae .radix_end
    push cx                         ; DX:AX = DX:AX * base + digit
    push bx
    mov cx, ax
    mov ax, dx
    mul bx
    xchg ax, cx
    mul bx
    add dx, cx
    pop bx
    pop cx
    add ax, cx
    adc dx, 0
    inc si
    jmp .radix_digit
.radix_end:
    mov [cs:tok_lo], ax
    mov [cs:tok_hi], dx
    mov byte [cs:tok_type], TY_INT  ; &HFFFF is -1, as in QBasic
    or dx, dx
    jz .radix_suffix
    mov byte [cs:tok_type], TY_LNG
.radix_suffix:
    cmp byte [si], '&'
    jne .radix_int
    mov byte [cs:tok_type], TY_LNG
    inc si
    ret
.radix_int:
    cmp byte [si], '%'
    jne .ret
    inc si
.ret:
    ret
.decimal:
    ; the characters of the number go to num_buf; reals are converted by
    ; str_to_sng, integers here
    mov di, num_buf
    xor bx, bx                      ; BL = it has a dot or an exponent
.dec_char:
    mov al, [si]
    cmp al, '0'
    jb .dec_not_digit
    cmp al, '9'
    ja .dec_not_digit
.dec_store:
    cmp di, num_buf + 40
    jae .dec_skip
    mov [cs:di], al
    inc di
.dec_skip:
    inc si
    jmp .dec_char
.dec_not_digit:
    cmp al, '.'
    jne .dec_not_dot
    or bl, 1
    jmp .dec_store
.dec_not_dot:
    mov ah, al
    and ah, 0DFh
    cmp ah, 'E'
    je .exponent
    cmp ah, 'D'
    jne .dec_end
.exponent:
    or bl, 1
    mov byte [cs:di], 'E'
    inc di
    inc si
    mov al, [si]
    cmp al, '+'
    je .exp_sign
    cmp al, '-'
    jne .dec_char
.exp_sign:
    mov [cs:di], al
    inc di
    inc si
    jmp .dec_char
.dec_end:
    mov byte [cs:di], 0
    mov bh, 0                       ; BH = the suffix
    cmp al, '%'
    je .dec_suffix
    cmp al, '&'
    je .dec_suffix
    cmp al, '!'
    je .dec_suffix
    cmp al, '#'
    jne .dec_convert
.dec_suffix:
    mov bh, al
    inc si
.dec_convert:
    push si
    push ds
    push cs
    pop ds
    or bl, bl
    jnz .real
    cmp bh, '!'
    je .real
    cmp bh, '#'
    je .real
    mov si, num_buf                 ; an integer: 32 bits, or a real if larger
    call str_to_long
    jc .real
    mov [tok_lo], ax
    mov [tok_hi], dx
    mov byte [tok_type], TY_LNG
    cmp bh, '&'
    je .converted
    mov cx, ax                      ; fits in 16 bits (signed)?
    cwd
    cmp dx, [tok_hi]
    jne .long
    mov byte [tok_type], TY_INT
    jmp .converted
.long:
    cmp bh, '%'
    jne .converted
    mov byte [tok_type], TY_INT     ; 40000% is an overflow
    mov si, m_overflow
    call cerror
.real:
    mov si, num_buf
    call str_to_sng
    mov [tok_lo], ax
    mov [tok_hi], dx
    mov byte [tok_type], TY_SNG
.converted:
    pop ds
    pop si
    ret

; ASCIIZ decimal digits at SI -> DX:AX (unsigned up to 2^31-1). CF if
; larger (or not digits).
str_to_long:
    push bx
    push cx
    xor ax, ax
    xor dx, dx
.digit:
    mov cl, [si]
    or cl, cl
    jz .done
    sub cl, '0'
    cmp cl, 9
    ja .bad
    xor ch, ch
    mov bx, 10                      ; DX:AX * 10 + digit
    push cx
    mov cx, ax
    mov ax, dx
    mul bx
    jc .over_pop
    xchg ax, cx
    mul bx
    add dx, cx
    jc .over_pop
    pop cx
    add ax, cx
    adc dx, 0
    jc .bad
    test dx, 8000h
    jnz .bad
    inc si
    jmp .digit
.over_pop:
    pop cx
.bad:
    stc
    jmp .ret
.done:
    clc
.ret:
    pop cx
    pop bx
    ret

; Saves / restores the lexer (to look ahead)
lx_save:
    push si
    push di
    push cx
    mov si, lx_state
    mov di, lx_saved
    mov cx, lx_state_end - lx_state
    push ds
    pop es
    rep movsb
    pop cx
    pop di
    pop si
    ret

lx_restore:
    push si
    push di
    push cx
    mov si, lx_saved
    mov di, lx_state
    mov cx, lx_state_end - lx_state
    push ds
    pop es
    rep movsb
    pop cx
    pop di
    pop si
    ret


; ======================================================================
; Names
; ======================================================================

; tok_name + tok_suffix -> key_buf / key_len (the suffix is part of the
; name: A% and A$ are different variables)
name_key:
    push si
    push di
    push cx
    mov si, tok_name
    mov di, key_buf
    mov cx, [tok_len]
    push ds
    pop es
    rep movsb
    mov al, [tok_suffix]
    or al, al
    jz .no_suffix
    stosb
.no_suffix:
    mov ax, di
    sub ax, key_buf
    mov [key_len], ax
    pop cx
    pop di
    pop si
    ret

; key_buf with the type suffix of type AL instead of the one it has
; (used for typed names: A AS INTEGER is the variable A%)
key_with_type:
    push bx
    mov bx, [key_len]
    mov ah, [key_buf + bx - 1]
    cmp ah, '%'
    je .strip
    cmp ah, '&'
    je .strip
    cmp ah, '!'
    je .strip
    cmp ah, '#'
    je .strip
    cmp ah, '$'
    jne .add
.strip:
    dec bx
.add:
    xor ah, ah
    push bx
    mov bx, ax
    mov al, [type_suffix + bx]
    pop bx
    mov [key_buf + bx], al
    inc bx
    mov [key_len], bx
    pop bx
    ret

; key_buf in scope AL -> ES:DI = its entry (CF if there is none)
sym_find_scope:
    push bx
    push cx
    push si
    mov [find_scope], al
    call key_hash
    mov es, [seg_sym]
    mov di, [es:bx]
.entry:
    or di, di
    jz .none
    mov al, [es:di + N_LEN]
    cmp al, [key_len]
    jne .next
    mov al, [es:di + N_SCOPE]
    cmp al, [find_scope]
    jne .next
    push di
    add di, N_NAME
    mov si, key_buf
    mov cx, [key_len]
    repe cmpsb
    pop di
    je .found
.next:
    mov di, [es:di + N_NEXT]
    jmp .entry
.none:
    stc
    jmp .ret
.found:
    clc
.ret:
    pop si
    pop cx
    pop bx
    ret

; BX = the hash slot of key_buf
key_hash:
    push ax
    push cx
    push si
    push dx
    xor ax, ax
    mov si, key_buf
    mov cx, [key_len]
.char:
    mov dx, ax
    push cx
    mov cl, 5
    shl ax, cl
    pop cx
    add ax, dx
    xor dh, dh
    mov dl, [si]
    add ax, dx
    inc si
    loop .char
    and ax, HASH_SIZE - 1
    shl ax, 1
    mov bx, ax
    pop dx
    pop si
    pop cx
    pop ax
    ret

; A new entry for key_buf in scope AL, kind AH -> ES:DI (zeroed fields)
sym_add:
    push bx
    push cx
    push si
    push ax
    call key_hash
    mov es, [seg_sym]
    mov di, [sym_free]
    mov ax, [key_len]
    add ax, N_NAME
    add ax, di
    jc .full
    cmp ax, 0FFF0h
    jb .room
.full:
    mov si, m_too_many_names
    call cerror
.room:
    mov [sym_free], ax
    mov ax, [es:bx]
    mov [es:di + N_NEXT], ax
    mov [es:bx], di
    pop ax
    mov [es:di + N_SCOPE], al
    mov [es:di + N_KIND], ah
    xor ax, ax
    mov [es:di + N_TYPE], al
    mov [es:di + N_FLAGS], al
    mov [es:di + N_ADDR], ax
    mov [es:di + N_X1], ax
    mov [es:di + N_X2], ax
    mov cx, [key_len]
    mov [es:di + N_LEN], cl
    push di
    add di, N_NAME
    mov si, key_buf
    rep movsb
    pop di
    pop si
    pop cx
    pop bx
    ret

; Enters every keyword
init_names:
    mov es, [seg_sym]
    xor di, di
    mov cx, HASH_SIZE
    xor ax, ax
    rep stosw
    mov word [sym_free], HASH_SIZE * 2
    mov si, keywords
    mov bl, 1                       ; keyword numbers from 1
.next:
    mov cl, [si]
    or cl, cl
    jz .done
    xor ch, ch
    mov [key_len], cx
    inc si
    mov di, key_buf
    push ds
    pop es
    rep movsb
    push si
    push bx
    mov ax, NK_KEYWORD << 8
    call sym_add
    pop bx
    mov [es:di + N_ADDR], bl
    pop si
    inc bl
    jmp .next
.done:
    push ds
    pop es
    ret

; ======================================================================
; Writing code
; ======================================================================

emit_byte:                          ; AL
    push di
    push es
    mov es, [seg_code]
    mov di, [cp]
    stosb
    mov [cp], di
    cmp di, 0FFF0h
    pop es
    pop di
    jb .ok
    push si
    mov si, m_too_big
    call cerror
.ok:
    ret

emit_word:                          ; AX
    call emit_byte
    xchg al, ah
    call emit_byte
    xchg al, ah
    ret

; AL = opcode, BX = its word operand
emit_op_word:
    call emit_byte
    mov ax, bx
    jmp emit_word

; Puts word AX at code address BX
patch_word:
    push es
    mov es, [seg_code]
    mov [es:bx], ax
    pop es
    ret

; The next statement starts here: a marker for the machine (errors, line
; numbers, RESUME) and an entry in the line table
emit_stmt:
    push ax
    push bx
    push es
    mov es, [seg_lines]
    mov bx, [line_count]
    cmp bx, LINES_MAX
    jae .full
    shl bx, 1
    shl bx, 1
    mov ax, [cp]
    mov [es:bx], ax
    mov ax, [lx_line]
    mov [es:bx + 2], ax
    inc word [line_count]
.full:
    pop es
    mov al, OP_STMT
    call emit_byte
    pop bx
    pop ax
    ret


; ======================================================================
; The compiler
; ======================================================================

compile:
    mov [compile_sp], sp            ; cerror returns to compile's caller
    call init_names
    call init_strings
    mov di, deftype                 ; every letter: SINGLE
    mov cx, 26
    mov al, TY_SNG
    push ds
    pop es
    rep stosb
    ; pass 1: the SUBs and FUNCTIONs, their parameters and DEF types,
    ; the DATA items and where the module's labels are among them
    mov byte [pass], 1
    mov word [data_top_p1], DATA_POOL
    mov byte [option_base], 0
    call compile_pass
    mov ax, [data_top_p1]
    mov [data_end], ax
    ; pass 2: the code
    mov di, deftype
    mov cx, 26
    mov al, TY_SNG
    push ds
    pop es
    rep stosb
    mov byte [pass], 2
    mov word [cp], 0
    mov word [data_top], DATA_GLOBALS
    mov word [line_count], 0
    mov byte [scope], 0
    mov byte [option_base], 0
    call compile_pass
    call check_labels
    ret

; One pass over the source
compile_pass:
    mov word [lx_pos], 0
    mov word [lx_line], 1
    mov byte [tok], TK_EOF
    mov byte [ctl_depth], 0
    mov byte [in_sub], 0
    mov byte [main_ended], 0
    call next
.line:
    cmp byte [tok], TK_EOF
    je .end
    call compile_line
    jmp .line
.end:
    cmp byte [ctl_depth], 0
    je .closed
    call ctl_top                    ; a block left open
    mov bl, al
    xor bh, bh
    mov si, [ctl_open_msg + bx]
    call cerror
.closed:
    cmp byte [in_sub], 0
    je .main
    mov si, m_sub_open
    call cerror
.main:
    cmp byte [main_ended], 0
    jne .done
    mov al, OP_END
    call emit_byte
.done:
    ret

; One line: a line number or label, then statements separated by ':'
compile_line:
    cmp byte [tok], TK_NUM          ; a line number
    jne .label
    call define_line_number
    call next
    jmp .statements
.label:
    cmp byte [tok], TK_NAME         ; NAME: at the start of a line
    jne .statements
    call lx_save
    call next
    cmp byte [tok], TK_COLON
    je .is_label
    call lx_restore
    jmp .statements
.is_label:
    call lx_restore
    call define_name_label
    call next                       ; the name
    call next                       ; the colon
.statements:
    cmp byte [tok], TK_EOL
    je .eol
    cmp byte [tok], TK_EOF
    je .done
    cmp byte [tok], TK_COLON
    jne .statement
    call next
    jmp .statements
.statement:
    call statement
    cmp byte [tok], TK_COLON
    je .statements
    cmp byte [tok], TK_EOL
    je .eol
    cmp byte [tok], TK_EOF
    je .done
    mov si, m_expected_end
    call cerror
.eol:
    call next
.done:
    ret

; One statement (in pass 1 only SUB, FUNCTION, DEF types, TYPE and the
; end of a SUB matter: the rest is skipped)
statement:
    cmp byte [pass], 1
    jne .compile
    jmp pass1_statement
.compile:
    call emit_stmt
    call temps_reset_mark
    cmp byte [tok], TK_KW
    je .keyword
    cmp byte [tok], TK_NAME
    je .name
    cmp byte [tok], TK_OP           ; ? is PRINT
    jne .bad
    cmp byte [tok_op], '?'
    jne .bad
    jmp st_print
.bad:
    mov si, m_syntax
    call cerror
.name:
    jmp st_assign_or_call
.keyword:
    mov bl, [tok_kw]
    xor bh, bh
    shl bx, 1
    mov ax, [st_table + bx]
    or ax, ax
    jnz .known
    mov si, m_syntax
    call cerror
.known:
    jmp ax

; Pass 1: SUB/FUNCTION headers, DEFINT..., TYPE; everything else skipped
pass1_statement:
    cmp byte [tok], TK_KW
    jne .skip
    mov al, [tok_kw]
    cmp al, KW_SUB
    je .sub
    cmp al, KW_FUNCTION
    je .sub
    cmp al, KW_DATA
    jne .not_data
    jmp data_collect
.not_data:
    cmp al, KW_END
    jne .not_end
    call next
    cmp byte [tok], TK_KW
    jne .skip
    mov al, [tok_kw]
    cmp al, KW_SUB
    je .end_sub
    cmp al, KW_FUNCTION
    jne .skip
.end_sub:
    mov byte [in_sub], 0
    jmp .skip
.not_end:
    cmp al, KW_DEF
    jne .not_deffn
    call next
    cmp byte [tok], TK_NAME
    jne .skip
    mov byte [sub_kind], KW_FUNCTION
    call sub_header_named
    jmp .skip
.not_deffn:
    cmp al, KW_DEFINT
    jb .not_def
    cmp al, KW_DEFSTR
    ja .not_def
    jmp st_deftype
.not_def:
    cmp al, KW_TYPE
    jne .not_type
    jmp st_type
.not_type:
    cmp al, KW_DECLARE
    je .skip
.skip:                              ; to the end of the statement
    cmp byte [tok], TK_EOL
    je .ret
    cmp byte [tok], TK_EOF
    je .ret
    cmp byte [tok], TK_COLON
    je .ret
    call next
    jmp .skip
.ret:
    ret
.sub:
    call sub_header
    mov byte [in_sub], 1
    jmp .skip

; ---------- small helpers ----------

; The current token must be the operator AL; it is consumed
expect_op:
    cmp byte [tok], TK_OP
    jne .bad
    cmp [tok_op], al
    jne .bad
    jmp next
.bad:
    mov si, m_syntax
    call cerror

; CF = 0 and consumed if the current token is the operator AL
accept_op:
    cmp byte [tok], TK_OP
    jne .no
    cmp [tok_op], al
    jne .no
    call next
    clc
    ret
.no:
    stc
    ret

; The current token must be keyword AL; consumed
expect_kw:
    cmp byte [tok], TK_KW
    jne .bad
    cmp [tok_kw], al
    jne .bad
    jmp next
.bad:
    mov si, m_syntax
    call cerror

; CF = 0 and consumed if the current token is keyword AL
accept_kw:
    cmp byte [tok], TK_KW
    jne .no
    cmp [tok_kw], al
    jne .no
    call next
    clc
    ret
.no:
    stc
    ret

; CF = 0 if the statement ends here (: or the end of the line), or ELSE
at_end:
    cmp byte [tok], TK_EOL
    je .yes
    cmp byte [tok], TK_EOF
    je .yes
    cmp byte [tok], TK_COLON
    je .yes
    cmp byte [tok], TK_KW
    jne .no
    cmp byte [tok_kw], KW_ELSE
    je .yes
.no:
    stc
    ret
.yes:
    clc
    ret

expect_end:
    call at_end
    jnc .ok
    mov si, m_expected_end
    call cerror
.ok:
    ret

; ---------- labels ----------

define_line_number:
    mov ax, [tok_lo]                ; the number as a name: "#123"
    mov di, key_buf
    mov byte [di], '#'
    inc di
    push ds
    pop es
    call word_to_dec
    sub di, key_buf
    mov [key_len], di
    jmp define_label

define_name_label:
    mov byte [tok_suffix], 0
    call name_key
define_label:
    cmp byte [pass], 2
    je .pass2
    cmp byte [in_sub], 0            ; pass 1: a module label's place among
    jne .ret                        ; the DATA items (for RESTORE)
    xor al, al
    call sym_find_scope
    jnc .known
    xor al, al
    mov ah, NK_LABEL
    call sym_add
.known:
    cmp byte [es:di + N_KIND], NK_LABEL
    jne .ret
    mov ax, [data_top_p1]
    mov [es:di + N_X2], ax
    jmp .ret
.pass2:
    mov al, [scope]
    call sym_find_scope
    jnc .exists
    mov al, [scope]
    mov ah, NK_LABEL
    call sym_add
    jmp .set
.exists:
    cmp byte [es:di + N_KIND], NK_LABEL
    jne .dup
    test byte [es:di + N_FLAGS], NF_DEFINED
    jz .set
.dup:
    mov si, m_dup_label
    call cerror
.set:
    or byte [es:di + N_FLAGS], NF_DEFINED
    mov ax, [cp]
    mov [es:di + N_ADDR], ax
    mov bx, [es:di + N_X1]          ; the jumps written before it
    push ds
    pop es
.fix:
    or bx, bx
    jz .ret
    push es
    mov es, [seg_code]
    mov dx, [es:bx]
    mov [es:bx], ax
    pop es
    mov bx, dx
    jmp .fix
.ret:
    push ds
    pop es
    ret

; The label (line number or name) at the current token: its code address
; is emitted as the operand of the instruction just written, or chained
; to be fixed when it is defined
emit_label_ref:
    cmp byte [tok], TK_NUM
    jne .name
    mov ax, [tok_lo]
    mov di, key_buf
    mov byte [di], '#'
    inc di
    push ds
    pop es
    call word_to_dec
    sub di, key_buf
    mov [key_len], di
    jmp .look
.name:
    cmp byte [tok], TK_NAME
    je .named
    mov si, m_syntax
    call cerror
.named:
    mov byte [tok_suffix], 0
    call name_key
.look:
    call next
    mov al, [scope]
    call sym_find_scope
    jnc .found
    mov al, [scope]
    mov ah, NK_LABEL
    call sym_add
    mov ax, [lx_line]
    mov [es:di + N_X2], ax          ; where it was used, for the error
.found:
    cmp byte [es:di + N_KIND], NK_LABEL
    je .label
    push ds
    pop es
    mov si, m_label_undefined
    call cerror
.label:
    test byte [es:di + N_FLAGS], NF_DEFINED
    jz .forward
    mov ax, [es:di + N_ADDR]
    push ds
    pop es
    jmp emit_word
.forward:
    mov ax, [es:di + N_X1]          ; chained through the operands
    mov bx, [cp]
    mov [es:di + N_X1], bx
    push ds
    pop es
    jmp emit_word

; Every label used must exist
check_labels:
    mov es, [seg_sym]
    xor bx, bx
.slot:
    mov di, [es:bx]
.entry:
    or di, di
    jz .next_slot
    cmp byte [es:di + N_KIND], NK_LABEL
    jne .next
    test byte [es:di + N_FLAGS], NF_DEFINED
    jnz .next
    mov ax, [es:di + N_X2]
    mov [lx_line], ax
    push ds
    pop es
    mov si, m_label_undefined
    call cerror
.next:
    mov di, [es:di + N_NEXT]
    jmp .entry
.next_slot:
    add bx, 2
    cmp bx, HASH_SIZE * 2
    jb .slot
    push ds
    pop es
    ret

; AX in decimal at ES:DI (DI moves past it)
word_to_dec:
    push bx
    push cx
    push dx
    mov bx, 10
    xor cx, cx
.digit:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .digit
.put:
    pop ax
    add al, '0'
    stosb
    loop .put
    pop dx
    pop cx
    pop bx
    ret

; ---------- blocks: IF, FOR, DO, WHILE, SELECT, SUB ----------
;
; A stack of open blocks while compiling: kind, and three words (addresses
; and chains of jumps to fix).

CTL_IF      equ 0
CTL_FOR     equ 2
CTL_DO      equ 4
CTL_WHILE   equ 6
CTL_SELECT  equ 8
CTL_SIZE    equ 12
CTL_MAX     equ 32

; Opens a block of kind AL: BX = its record
ctl_push:
    mov bl, [ctl_depth]
    cmp bl, CTL_MAX
    jb .room
    mov si, m_too_deep
    call cerror
.room:
    inc byte [ctl_depth]
    xor bh, bh
    push ax
    mov ax, CTL_SIZE
    mul bx
    mov bx, ax
    add bx, ctl_stack
    pop ax
    mov [bx], al
    xor ax, ax
    mov [bx + 2], ax
    mov [bx + 4], ax
    mov [bx + 6], ax
    mov [bx + 8], ax
    mov [bx + 10], ax
    ret

; BX = the record of the innermost block, AL its kind (BX = kind index
; into ctl_open_msg when called as ctl_top)
ctl_top:
    mov bl, [ctl_depth]
    or bl, bl
    jnz .some
    xor bx, bx
    mov al, 0FFh
    ret
.some:
    dec bl
    xor bh, bh
    mov ax, CTL_SIZE
    mul bx
    mov bx, ax
    add bx, ctl_stack
    mov al, [bx]
    ret

; The innermost block must be of kind AL: BX = its record. It stays open.
ctl_expect:
    push ax
    call ctl_top
    pop dx
    cmp al, dl
    je .ok
    mov bl, dl
    xor bh, bh
    mov si, [ctl_close_msg + bx]
    call cerror
.ok:
    ret

ctl_pop:
    dec byte [ctl_depth]
    ret

; The innermost block of kind AL (for EXIT): BX = its record. CF if none.
ctl_find:
    mov cl, [ctl_depth]
    xor ch, ch
    jcxz .none
.next:
    dec cx
    push ax
    mov ax, CTL_SIZE
    mul cx
    mov bx, ax
    add bx, ctl_stack
    pop ax
    cmp [bx], al
    je .found
    or cx, cx
    jnz .next
.none:
    stc
    ret
.found:
    clc
    ret

; Emits a jump (opcode AL) whose target is chained at word [BX] (to be
; fixed by fix_chain)
emit_jump_chain:
    call emit_byte
    mov ax, [bx]
    push ax
    mov ax, [cp]
    mov [bx], ax
    pop ax
    jmp emit_word

; Every jump chained from word [BX] goes to the current address
fix_chain:
    mov bx, [bx]
    mov ax, [cp]
.next:
    or bx, bx
    jz .done
    push es
    mov es, [seg_code]
    mov dx, [es:bx]
    mov [es:bx], ax
    pop es
    mov bx, dx
    jmp .next
.done:
    ret


; ======================================================================
; Expressions: code that leaves the value on the machine's stack.
; AL = its type.
; ======================================================================

expr:
    call ex_xor
.loop:
    mov ah, KW_EQV
    call ex_logic_op
    jnc .loop
    mov ah, KW_IMP
    call ex_logic_op
    jnc .loop
    ret

ex_xor:
    call ex_or
.loop:
    mov ah, KW_XOR
    call ex_logic_op
    jnc .loop
    ret

ex_or:
    call ex_and
.loop:
    mov ah, KW_OR
    call ex_logic_op
    jnc .loop
    ret

ex_and:
    call ex_not
.loop:
    mov ah, KW_AND
    call ex_logic_op
    jnc .loop
    ret

; AL = left type. If the token is keyword AH: compiles the right side
; (the next level down) and the operation. CF if it is not that keyword.
ex_logic_op:
    cmp byte [tok], TK_KW
    jne .no
    cmp [tok_kw], ah
    jne .no
    push ax
    call next
    pop ax
    push ax                         ; AH = operator, AL = left type
    call logic_int_type             ; the left side as INT or LONG
    mov [ex_left], al
    pop ax
    push ax
    push word [ex_left]
    cmp ah, KW_AND
    je .and_level
    cmp ah, KW_OR
    je .or_level
    cmp ah, KW_XOR
    je .xor_level
    call ex_xor                     ; EQV, IMP: the XOR level
    jmp .right
.and_level:
    call ex_not
    jmp .right
.or_level:
    call ex_and
    jmp .right
.xor_level:
    call ex_or
.right:
    call logic_int_type
    pop bx                          ; BL = left type
    cmp al, bl
    je .same
    cmp al, TY_LNG                  ; one INT, one LONG: both LONG
    je .left_long
    mov al, OP_I2L                  ; the right one up
    call emit_byte
    mov al, TY_LNG
    jmp .same
.left_long:
    mov al, OP_I2L_U2               ; hmm: left INT under a LONG
    call emit_byte
    mov al, TY_LNG
.same:
    pop bx                          ; BH = operator
    push ax
    mov bl, bh
    xor bh, bh
    sub bl, KW_AND
    shl bl, 1
    cmp al, TY_LNG
    jne .int
    inc bl
.int:
    mov al, [logic_ops + bx]
    call emit_byte
    pop ax
    clc
    ret
.no:
    stc
    ret

; AL = type on the stack: converted to INT or LONG for a logical
; operation (reals go to LONG). AL = the new type.
logic_int_type:
    cmp al, TY_STR
    jne .numeric
    jmp type_mismatch
.numeric:
    cmp al, TY_SNG
    jne .done
    mov al, OP_S2L
    call emit_byte
    mov al, TY_LNG
.done:
    ret

ex_not:
    mov al, KW_NOT
    call accept_kw
    jc ex_rel
    call ex_not
    call logic_int_type
    push ax
    mov bl, OP_NOT_I
    cmp al, TY_LNG
    jne .op
    mov bl, OP_NOT_L
.op:
    mov al, bl
    call emit_byte
    pop ax
    ret

; Comparisons: = <> < > <= >=, for numbers and strings. Result INT.
ex_rel:
    call ex_add
.loop:
    cmp byte [tok], TK_OP
    jne .done
    mov ah, [tok_op]
    mov bl, CC_EQ
    cmp ah, '='
    je .op
    mov bl, CC_NE
    cmp ah, OP_NE
    je .op
    mov bl, CC_LT
    cmp ah, '<'
    je .op
    mov bl, CC_GT
    cmp ah, '>'
    je .op
    mov bl, CC_LE
    cmp ah, OP_LE
    je .op
    mov bl, CC_GE
    cmp ah, OP_GE
    jne .done
.op:
    push bx
    push ax
    call next
    call ex_add
    pop bx                          ; BL = left type
    call balance                    ; AL = common type
    pop bx                          ; BL = condition
    mov ah, OP_CMP_I
    cmp al, TY_INT
    je .emit
    mov ah, OP_CMP_L
    cmp al, TY_LNG
    je .emit
    mov ah, OP_CMP_S
    cmp al, TY_SNG
    je .emit
    mov ah, OP_CMP_STR
.emit:
    mov al, ah
    call emit_byte
    mov al, bl
    call emit_byte
    mov al, TY_INT
    jmp .loop
.done:
    ret

; Left operand of type BL under a right one of type AL: both made the same
; type (numbers: the larger of the two). AL = that type. Strings must
; meet strings.
balance:
    cmp al, TY_STR
    je .right_str
    cmp bl, TY_STR
    je .mismatch
    cmp al, bl
    je .same
    ja .left_up
    ; the right (on top) goes up to BL
    push bx
    mov ah, bl
    call convert                    ; AL -> AH
    pop bx
    mov al, bl
    ret
.left_up:                           ; the left (under the right) goes up
    mov ah, OP_I2L_U2
    cmp bl, TY_INT
    jne .left_long
    cmp al, TY_LNG
    je .under
    mov ah, OP_I2S_U2
    jmp .under
.left_long:
    mov ah, OP_L2S_U2
.under:
    push ax
    mov al, ah
    call emit_byte
    pop ax
.same:
    ret
.right_str:
    cmp bl, TY_STR
    je .same
.mismatch:
    jmp type_mismatch

; Converts the value on top of the stack from type AL to type AH
convert:
    cmp al, ah
    je .done
    cmp al, TY_STR
    je .mismatch
    cmp ah, TY_STR
    je .mismatch
    push bx
    mov bl, al                      ; table index: from * 4 + to
    dec bl
    shl bl, 1
    shl bl, 1
    add bl, ah
    dec bl
    xor bh, bh
    mov al, [convert_ops + bx]
    pop bx
    or al, al
    jz .done
    call emit_byte
.done:
    ret
.mismatch:
    jmp type_mismatch

type_mismatch:
    mov si, m_type_mismatch
    call cerror

; + and - (and string concatenation)
ex_add:
    call ex_mod
.loop:
    cmp byte [tok], TK_OP
    jne .done
    mov ah, [tok_op]
    cmp ah, '+'
    je .op
    cmp ah, '-'
    jne .done
.op:
    push ax                         ; AH = operator, AL = left type
    call next
    call ex_mod
    pop bx
    push bx
    call balance
    pop bx
    cmp al, TY_STR
    jne .numbers
    cmp bh, '+'
    je .concat
    jmp type_mismatch
.concat:
    push ax
    mov al, OP_CAT
    call emit_byte
    pop ax
    jmp .loop
.numbers:
    mov ah, OP_ADD_I
    cmp bh, '+'
    je .arith
    mov ah, OP_SUB_I
.arith:
    call emit_arith                 ; AH = the INT opcode
    jmp .loop
.done:
    ret

; Emits the arithmetic opcode AH (the INT one) for type AL: the LONG and
; SINGLE ones follow it
emit_arith:
    push ax
    cmp al, TY_INT
    je .emit
    inc ah
    cmp al, TY_LNG
    je .emit
    inc ah
.emit:
    mov al, ah
    call emit_byte
    pop ax
    ret

ex_mod:
    call ex_idiv
.loop:
    push ax
    mov al, KW_MOD
    call accept_kw
    pop ax
    jc .done
    call int_operand
    push ax
    call ex_idiv
    call int_operand
    pop bx
    call balance
    mov ah, OP_MOD_I
    call emit_arith
    jmp .loop
.done:
    ret

; AL = type: rounded to an integer type for \ and MOD (reals: LONG)
int_operand:
    cmp al, TY_STR
    jne .numeric
    jmp type_mismatch
.numeric:
    cmp al, TY_SNG
    jne .done
    mov al, OP_S2L
    call emit_byte
    mov al, TY_LNG
.done:
    ret

ex_idiv:
    call ex_mul
.loop:
    cmp byte [tok], TK_OP
    jne .done
    cmp byte [tok_op], '\'
    jne .done
    push ax
    call next
    pop ax
    call int_operand
    push ax
    call ex_mul
    call int_operand
    pop bx
    call balance
    mov ah, OP_IDIV_I
    call emit_arith
    jmp .loop
.done:
    ret

ex_mul:
    call ex_neg
.loop:
    cmp byte [tok], TK_OP
    jne .done
    mov ah, [tok_op]
    cmp ah, '*'
    je .op
    cmp ah, '/'
    jne .done
.op:
    push ax
    call next
    call ex_neg
    pop bx
    push bx
    cmp bh, '/'
    jne .multiply
    ; /: always real
    mov ah, TY_SNG
    call convert
    mov al, TY_SNG
    cmp bl, TY_SNG
    je .div
    mov ah, OP_I2S_U2
    cmp bl, TY_INT
    je .div_left
    mov ah, OP_L2S_U2
.div_left:
    push ax
    mov al, ah
    call emit_byte
    pop ax
.div:
    pop bx
    push ax
    mov al, OP_DIV_S
    call emit_byte
    pop ax
    jmp .loop
.multiply:
    call balance
    pop bx
    cmp al, TY_STR
    jne .mul_ok
    jmp type_mismatch
.mul_ok:
    mov ah, OP_MUL_I
    call emit_arith
    jmp .loop
.done:
    ret

; Unary minus and plus
ex_neg:
    mov al, '-'
    call accept_op
    jc .not_minus
    call ex_neg
    cmp al, TY_STR
    jne .numeric
    jmp type_mismatch
.numeric:
    mov ah, OP_NEG_I
    jmp emit_arith
.not_minus:
    mov al, '+'
    call accept_op
    jc ex_pow
    jmp ex_neg

; ^ (always real)
ex_pow:
    call ex_primary
.loop:
    cmp byte [tok], TK_OP
    jne .done
    cmp byte [tok_op], '^'
    jne .done
    push ax
    call next
    pop ax
    mov ah, TY_SNG
    call convert
    call ex_primary
    mov ah, TY_SNG
    call convert
    mov al, OP_POW_S
    call emit_byte
    mov al, TY_SNG
    jmp .loop
.done:
    ret

ex_primary:
    mov al, [tok]
    cmp al, TK_NUM
    jne .not_num
    mov al, [tok_type]
    push ax
    mov bx, [tok_lo]
    cmp al, TY_INT
    jne .wide
    mov al, OP_PUSH_I
    call emit_op_word
    jmp .num_done
.wide:
    mov al, OP_PUSH_L
    call emit_op_word
    mov ax, [tok_hi]
    call emit_word
.num_done:
    call next
    pop ax
    ret
.not_num:
    cmp al, TK_STR
    jne .not_str
    call string_constant            ; BX = its block, CX = length
    mov al, OP_PUSH_CSTR
    call emit_op_word
    mov ax, cx
    call emit_word
    call next
    mov al, TY_STR
    ret
.not_str:
    cmp al, TK_OP
    jne .not_paren
    cmp byte [tok_op], '('
    jne .bad
    call next
    call expr
    push ax
    mov al, ')'
    call expect_op
    pop ax
    ret
.not_paren:
    cmp al, TK_KW
    jne .not_kw
    jmp builtin_function
.not_kw:
    cmp al, TK_NAME
    jne .bad
    jmp name_value
.bad:
    mov si, m_syntax
    call cerror

; The string of the current TK_STR token as a constant in the strings
; segment (not moved, never freed): BX = its offset, CX = its length
string_constant:
    mov cx, [tok_len]
    push si
    push di
    push ds
    push es
    mov es, [seg_str]
    mov di, [str_const_top]
    mov ax, cx
    mov [es:di], ax                 ; a block header like the others
    mov word [es:di + 2], 0FFFFh
    add di, 4
    mov bx, di
    mov si, [tok_text]
    mov ds, [cs:seg_src]
    rep movsb
    pop es
    pop ds
    mov [str_const_top], di
    cmp di, 8000h                   ; half of the segment at most
    jb .ok
    mov si, m_too_many_strings
    call cerror
.ok:
    mov cx, [tok_len]
    pop di
    pop si
    ret

; ======================================================================
; Names in expressions: constants, variables, arrays, FUNCTIONs
; ======================================================================

; The value of the name at the current token. AL = type.
name_value:
    call name_key
    ; a constant (from the module) ?
    call find_const
    jc .not_const
    push ax
    call next
    pop ax
    ret
.not_const:
    ; a FUNCTION ?
    call find_function
    jc .not_function
    jmp call_function
.not_function:
    ; a DEF FN ?
    ; a variable or an array element
    call compile_ref                ; the reference, code for its address
    jmp ref_load

; key_buf a CONST? Emits its value: AL = type, CF if not a constant
find_const:
    push di
    xor al, al
    call sym_find_scope
    jc .none
    cmp byte [es:di + N_KIND], NK_CONST
    jne .none
    mov bx, [es:di + N_X1]
    mov dx, [es:di + N_X2]
    mov al, [es:di + N_TYPE]
    push ds
    pop es
    push ax
    cmp al, TY_INT
    jne .wide
    mov al, OP_PUSH_I
    call emit_op_word
    jmp .done
.wide:
    cmp al, TY_STR
    jne .number
    mov al, OP_PUSH_CSTR            ; BX = block, DX = length
    call emit_op_word
    mov ax, dx
    call emit_word
    jmp .done
.number:
    mov al, OP_PUSH_L
    call emit_op_word
    mov ax, dx
    call emit_word
.done:
    pop ax
    pop di
    clc
    ret
.none:
    push ds
    pop es
    pop di
    stc
    ret

; key_buf (any suffix) a FUNCTION? DI = its entry, CF if not
find_function:
    call proc_lookup
    jc .ret
    cmp byte [es:di + N_KIND], NK_FUNC
    jne .none
    clc
.ret:
    ret
.none:
    call proc_key_back
    stc
    ret

; ---------- references ----------
;
; compile_ref parses a variable, an array element or a field, and leaves
; in r_* how to reach it; for an element it has already written the code
; that pushes its address.

R_GLOBAL    equ 1               ; r_addr in the data segment
R_LOCAL     equ 2               ; r_addr in the frame
R_PARAM     equ 3               ; the frame at r_addr holds its address
R_FAR       equ 4               ; its far address is on the stack
R_STRDESC   equ 5               ; a string element: its descriptor on the stack

compile_ref:
    call name_key
    call next
    cmp byte [tok], TK_OP           ; NAME( : an array
    jne .scalar
    cmp byte [tok_op], '('
    jne .scalar
    jmp array_ref
.scalar:
    call find_var                   ; ES:DI = the entry
    call ref_from_entry
    jmp field_suffix

; key_buf: the variable (created if new) -> ES:DI = its entry (ES = names)
find_var:
    ; a name declared AS type (key without suffix) comes first
    call key_typed                  ; key_buf with its type suffix
    mov al, [scope]
    call sym_find_scope
    jnc .found
    cmp byte [scope], 0
    je .new
    ; in a SUB: a module variable that is SHARED
    xor al, al
    call sym_find_scope
    jc .new
    cmp byte [es:di + N_KIND], NK_VAR
    jne .new
    cmp byte [deffn_mode], 0        ; DEF FN sees every module variable
    jne .found
    test byte [es:di + N_FLAGS], NF_SHARED
    jnz .found
.new:
    mov al, [scope]
    cmp byte [deffn_mode], 0        ; new names in a DEF FN: the module's
    je .add
    xor al, al
.add:
    push word [scope]
    mov [scope], al
    mov ah, NK_VAR
    call sym_add
    mov al, [key_type]
    mov [es:di + N_TYPE], al
    call alloc_var
    pop ax
    mov [scope], al
.found:
    cmp byte [es:di + N_KIND], NK_VAR
    je .ok
    push ds
    pop es
    mov si, m_dup_def
    call cerror
.ok:
    ret

; key_buf (the name and its suffix, if any) -> key_buf with the suffix of
; its type: the one written, a declaration AS, or the DEF type of its
; first letter. key_type = the type.
key_typed:
    mov bx, [key_len]
    mov al, [key_buf + bx - 1]
    mov ah, TY_INT
    cmp al, '%'
    jne .skip32
    jmp .written
.skip32:
    mov ah, TY_LNG
    cmp al, '&'
    je .written
    mov ah, TY_SNG
    cmp al, '!'
    je .written
    cmp al, '#'
    je .double
    mov ah, TY_STR
    cmp al, '$'
    je .written
    ; no suffix: declared AS (an entry with this bare key)?
    mov al, [scope]
    call sym_find_scope
    jc .shared_as
    cmp byte [es:di + N_KIND], NK_VAR
    je .as_found
    cmp byte [es:di + N_KIND], NK_ARRAY
    jne .deftype
.as_found:
    mov al, [es:di + N_TYPE]
    mov [key_type], al
    push ds
    pop es
    ret                             ; the key stays bare
.shared_as:
    cmp byte [scope], 0
    je .deftype
    xor al, al
    call sym_find_scope
    jc .deftype
    test byte [es:di + N_FLAGS], NF_SHARED
    jz .deftype
    cmp byte [es:di + N_KIND], NK_VAR
    je .as_found
    cmp byte [es:di + N_KIND], NK_ARRAY
    je .as_found
.deftype:
    push ds
    pop es
    mov bl, [key_buf]
    sub bl, 'A'
    cmp bl, 26
    jb .letter
    xor bl, bl
.letter:
    xor bh, bh
    mov al, [deftype + bx]
    mov [key_type], al
    jmp key_with_type
.double:
    mov [key_type], ah              ; # is single precision
    mov bx, [key_len]
    mov byte [key_buf + bx - 1], '!'
    ret
.written:
    mov [key_type], ah
    ret

; Storage for the variable ES:DI of type [N_TYPE] (and record type N_X1):
; global data, or the frame of the SUB
alloc_var:
    mov al, [es:di + N_TYPE]
    call type_size                  ; CX = bytes
    cmp byte [scope], 0
    jne .local
    mov ax, [data_top]
    mov [es:di + N_ADDR], ax
    add ax, cx
    jc .full
    mov [data_top], ax
    cmp ax, DATA_GLOBALS_MAX
    jb .ok
.full:
    push ds
    pop es
    mov si, m_out_of_data
    call cerror
.local:
    or byte [es:di + N_FLAGS], NF_LOCAL
    mov ax, [frame_size]
    mov [es:di + N_ADDR], ax
    add ax, cx
    mov [frame_size], ax
    cmp byte [es:di + N_TYPE], TY_STR
    jne .ok
    mov byte [sub_strings], 1
.ok:
    ret

; AL = type (ES:DI = entry, for records) -> CX = its size in bytes
type_size:
    mov cx, 2
    cmp al, TY_INT
    je .done
    mov cx, 4
    cmp al, TY_REC
    jne .done
    push es
    push bx
    mov bx, [es:di + N_X1]          ; the TYPE's entry
    mov cx, [es:bx + N_X1]          ; its size
    pop bx
    pop es
.done:
    ret

; The entry ES:DI of a scalar variable -> r_*
ref_from_entry:
    mov al, [es:di + N_TYPE]
    mov [r_type], al
    mov ax, [es:di + N_X1]
    mov [r_rec], ax
    mov ax, [es:di + N_ADDR]
    mov [r_addr], ax
    mov byte [r_kind], R_GLOBAL
    test byte [es:di + N_FLAGS], NF_PARAM
    jz .not_param
    mov byte [r_kind], R_PARAM
    jmp .done
.not_param:
    test byte [es:di + N_FLAGS], NF_LOCAL
    jz .done
    mov byte [r_kind], R_LOCAL
.done:
    push ds
    pop es
    ret


; The value of the reference r_* onto the stack. AL = type.
ref_load:
    mov al, [r_type]
    cmp al, TY_REC
    jne .scalar
    mov si, m_type_mismatch         ; a whole record has no value
    call cerror
.scalar:
    mov bl, [r_kind]
    dec bl
    xor bh, bh
    shl bl, 1
    shl bl, 1                       ; kind * 4 + type
    add bl, al
    dec bl
    mov al, [load_ops + bx]
    or al, al
    jz .no_operand
    call emit_byte
    cmp byte [r_kind], R_FAR
    jae .no_operand
    mov ax, [r_addr]
    call emit_word
.no_operand:
    mov al, [r_type]
    ret

; Stores the value on the stack (of type AL, converted) into r_* (for
; R_FAR / R_STRDESC the address was pushed before the value)
ref_store:
    mov ah, [r_type]
    cmp ah, TY_REC
    jne .scalar
    mov si, m_type_mismatch
    call cerror
.scalar:
    call convert
    mov al, [r_type]
    mov bl, [r_kind]
    dec bl
    xor bh, bh
    shl bl, 1
    shl bl, 1
    add bl, al
    dec bl
    mov al, [store_ops + bx]
    or al, al
    jz .done
    call emit_byte
    cmp byte [r_kind], R_FAR
    jae .done
    mov ax, [r_addr]
    call emit_word
.done:
    ret

; The address of r_* onto the stack, as a far pointer (for parameters)
ref_address:
    mov al, [r_kind]
    cmp al, R_GLOBAL
    jne .not_global
    mov al, OP_ADDR_G
    jmp .operand
.not_global:
    cmp al, R_LOCAL
    jne .not_local
    mov al, OP_ADDR_L
    jmp .operand
.not_local:
    cmp al, R_PARAM
    jne .not_param
    mov al, OP_LDP_ADDR
.operand:
    call emit_byte
    mov ax, [r_addr]
    jmp emit_word
.not_param:
    cmp al, R_STRDESC
    jne .done
    mov al, OP_NEAR_ADDR            ; a descriptor in the data segment
    jmp emit_byte
.done:
    ret



; ======================================================================
; Statements
; ======================================================================

; NAME ...: an assignment, or a SUB called without CALL
st_assign_or_call:
    call name_key
    call proc_lookup
    jc st_assign
    cmp byte [es:di + N_KIND], NK_SUB
    jne .assign
    push ds
    pop es
    call next
    jmp call_sub_args               ; arguments without parentheses
.assign:
    call proc_key_back
st_assign:
    call compile_ref
    call ref_save                   ; (the expression has references too)
    mov al, '='
    call expect_op
    call expr
    call ref_restore
    call ref_store
    jmp temps_free

; Keeps r_* under the return address / takes it back
ref_save:
    pop bx
    push word [r_addr]
    push word [r_rec]
    push word [r_kind]              ; (r_kind and r_type)
    jmp bx
ref_restore:
    pop bx
    pop word [r_kind]
    pop word [r_rec]
    pop word [r_addr]
    jmp bx

st_let:
    call next
    cmp byte [tok], TK_NAME
    je st_assign
    mov si, m_syntax
    call cerror

; ---------- PRINT ----------

st_print:
    call next
    mov al, OP_OUT_SCREEN           ; PRINT #n: to a file
    cmp byte [tok], TK_OP
    jne .out
    cmp byte [tok_op], '#'
    jne .out
    call next
    call expr
    mov ah, TY_INT
    call convert
    mov al, ','
    call expect_op
    mov al, OP_OUT_FILE
.out:
    call emit_byte
    mov byte [print_nl], 1
.item:
    call at_end
    jnc .end
    mov byte [print_nl], 0
    mov al, ';'
    call accept_op
    jnc .item
    mov al, ','
    call accept_op
    jc .not_comma
    mov al, OP_PRINT_COMMA
    call emit_byte
    jmp .item
.not_comma:
    cmp byte [tok], TK_KW
    jne .value
    mov al, [tok_kw]
    mov bl, OP_PRINT_TAB
    cmp al, KW_TAB
    je .tab
    mov bl, OP_PRINT_SPC
    cmp al, KW_SPC
    jne .value
.tab:
    push bx
    call next
    mov al, '('
    call expect_op
    call expr
    mov ah, TY_INT
    call convert
    mov al, ')'
    call expect_op
    pop ax
    call emit_byte
    jmp .item
.value:
    mov byte [print_nl], 1
    call expr
    mov bl, al
    xor bh, bh
    mov al, [print_ops + bx - 1]
    call emit_byte
    jmp .item
.end:
    cmp byte [print_nl], 0
    je .no_nl
    mov al, OP_PRINT_NL
    call emit_byte
.no_nl:
    mov al, OP_OUT_SCREEN
    call emit_byte
    jmp temps_free

; ---------- IF ----------

; Compiles a condition and a jump past the code that follows when it is
; false: BX = the address of the jump's operand
condition_jump:
    call expr
    mov bl, OP_JZ_I
    cmp al, TY_INT
    je .op
    mov bl, OP_JZ_L
    cmp al, TY_LNG
    je .op
    mov bl, OP_JZ_S
    cmp al, TY_SNG
    je .op
    jmp type_mismatch
.op:
    mov al, bl
    call emit_byte
    mov bx, [cp]
    xor ax, ax
    jmp emit_word

; The same, jumping when true: BX = the operand
condition_jump_true:
    call expr
    mov bl, OP_JNZ_I
    cmp al, TY_INT
    je .op
    mov bl, OP_JNZ_L
    cmp al, TY_LNG
    je .op
    mov bl, OP_JNZ_S
    cmp al, TY_SNG
    je .op
    jmp type_mismatch
.op:
    mov al, bl
    call emit_byte
    mov bx, [cp]
    xor ax, ax
    jmp emit_word

st_if:
    call next
    call condition_jump
    push bx                         ; the jump when false
    call temps_free
    cmp byte [tok], TK_KW
    jne .then
    cmp byte [tok_kw], KW_GOTO
    jne .then
    call next                       ; IF c GOTO label
    jmp .goto
.then:
    mov al, KW_THEN
    call expect_kw
    cmp byte [tok], TK_EOL          ; nothing after THEN: a block
    je .block
    cmp byte [tok], TK_EOF
    je .block
    cmp byte [tok], TK_NUM          ; IF c THEN 100
    jne .single
.goto:
    mov al, OP_JMP
    call emit_byte
    call emit_label_ref
    jmp .else_part
.single:                            ; statements up to ELSE or the line end
    call single_statements
.else_part:
    cmp byte [tok], TK_KW
    jne .no_else
    cmp byte [tok_kw], KW_ELSE
    jne .no_else
    call next
    mov al, OP_JMP                  ; the THEN part jumps over the ELSE part
    call emit_byte
    mov ax, [cp]
    push ax
    xor ax, ax
    call emit_word
    pop cx
    pop bx                          ; the false jump: here
    push cx
    mov ax, [cp]
    call patch_word
    cmp byte [tok], TK_NUM          ; ELSE 100
    jne .else_statements
    mov al, OP_JMP
    call emit_byte
    call emit_label_ref
    jmp .else_done
.else_statements:
    call single_statements
.else_done:
    pop bx
    mov ax, [cp]
    jmp patch_word
.no_else:
    pop bx
    mov ax, [cp]
    jmp patch_word
.block:
    mov al, CTL_IF
    call ctl_push
    pop ax
    mov [bx + 4], ax                ; the pending jump to the next part
    ret

; Statements of a single-line IF: until ELSE or the end of the line
single_statements:
.next:
    call statement
    cmp byte [tok], TK_COLON
    jne .done
    call next
    call at_end
    jc .next
.done:
    ret

st_elseif:
    mov al, CTL_IF
    call ctl_expect
    push bx
    call next
    mov al, OP_JMP                  ; the part before goes to END IF
    add bx, 2
    call emit_jump_chain
    pop bx
    push bx
    mov ax, [cp]                    ; the pending jump: here
    mov bx, [bx + 4]
    or bx, bx
    jz .no_pending
    call patch_word
.no_pending:
    call condition_jump
    mov ax, bx
    pop bx
    mov [bx + 4], ax
    call temps_free
    mov al, KW_THEN
    jmp expect_kw

st_else:
    mov al, CTL_IF
    call ctl_expect
    push bx
    call next
    mov al, OP_JMP
    add bx, 2
    call emit_jump_chain
    pop bx
    mov ax, [cp]
    push bx
    mov bx, [bx + 4]
    or bx, bx
    jz .none
    call patch_word
.none:
    pop bx
    mov word [bx + 4], 0
    ret

; END, END IF, END SELECT, END SUB, END FUNCTION, END TYPE, END DEF
st_end:
    call next
    cmp byte [tok], TK_KW
    jne .program
    mov al, [tok_kw]
    cmp al, KW_IF
    je .end_if
    cmp al, KW_SELECT
    jne .not_select
    jmp end_select
.not_select:
    cmp al, KW_SUB
    jne .not_sub
    jmp end_sub
.not_sub:
    cmp al, KW_FUNCTION
    jne .not_function
    jmp end_sub
.not_function:
    cmp al, KW_TYPE
    jne .program
    call next                       ; (a TYPE was handled in pass 1)
    ret
.program:
    mov al, OP_END
    jmp emit_byte
.end_if:
    call next
    mov al, CTL_IF
    call ctl_expect
    push bx
    mov ax, [cp]
    mov bx, [bx + 4]
    or bx, bx
    jz .no_pending
    call patch_word
.no_pending:
    pop bx
    add bx, 2
    call fix_chain
    jmp ctl_pop

; ---------- loops ----------

; FOR v = a TO b [STEP s]
st_for:
    call next
    cmp byte [tok], TK_NAME
    je .name
    mov si, m_syntax
    call cerror
.name:
    call compile_ref
    mov al, [r_kind]
    cmp al, R_FAR
    jb .scalar
    mov si, m_for_variable
    call cerror
.scalar:
    mov al, [r_type]
    cmp al, TY_STR
    jb .numeric
    jmp type_mismatch
.numeric:
    mov al, CTL_FOR
    call ctl_push
    mov [for_rec], bx
    mov al, [r_kind]
    mov [bx + 1], al
    mov al, [r_type]
    mov [bx + 3], al
    mov ax, [r_addr]
    mov [bx + 8], ax
    call ctl_exit_chain
    mov word [bx], 0
    mov al, '='
    call expect_op
    call expr                       ; v = a
    push ax
    call for_ref_var
    pop ax
    call ref_store
    ; the limit and the step: hidden variables of the same type
    call hidden_var                 ; AX = its address, DL = its kind
    mov bx, [for_rec]
    mov [bx + 10], ax
    mov [bx + 2], dl                ; (kind of the hidden ones)
    mov al, KW_TO
    call expect_kw
    call expr
    call store_limit
    mov al, KW_STEP
    call accept_kw
    jc .step_one
    call expr
    jmp .step
.step_one:
    mov al, OP_PUSH_I
    mov bx, 1
    call emit_op_word
    mov al, TY_INT
.step:
    call store_step
    mov al, OP_JMP                  ; to the test, at NEXT
    call emit_byte
    mov bx, [for_rec]
    mov ax, [cp]
    mov [bx + 4], ax
    xor ax, ax
    call emit_word
    mov ax, [cp]                    ; the body starts here
    mov bx, [for_rec]
    mov [bx + 6], ax
    jmp temps_free

; The value on the stack (type AL) into the FOR's limit / step
store_limit:
    xor cx, cx
    jmp store_hidden
store_step:
    mov cx, 4
store_hidden:
    push ax
    call for_ref_hidden
    pop ax
    jmp ref_store

; Storage for two hidden values of type AL (limit and step, or the value
; of a SELECT): AX = the first, DL = R_GLOBAL or R_LOCAL
hidden_var:
    cmp byte [scope], 0
    jne .local
    mov ax, [data_top]
    add word [data_top], 8
    mov dl, R_GLOBAL
    ret
.local:
    mov ax, [frame_size]
    add word [frame_size], 8
    mov dl, R_LOCAL
    ret

st_next:
    call next
.one:
    mov al, CTL_FOR
    call ctl_expect
    mov [for_rec], bx
    cmp byte [tok], TK_NAME         ; NEXT v: must be the FOR's variable
    jne .increment
    call compile_ref
    mov bx, [for_rec]
    mov ax, [r_addr]
    cmp ax, [bx + 8]
    jne .wrong
    mov al, [r_kind]
    cmp al, [bx + 1]
    je .increment
.wrong:
    mov si, m_next_without_for
    call cerror
.increment:
    ; v = v + step
    mov bx, [for_rec]
    call for_ref_var
    call ref_load
    call for_ref_step
    call ref_load
    mov ah, OP_ADD_I
    call emit_arith
    push ax
    call for_ref_var
    pop ax
    call ref_store
    ; the test: here
    mov bx, [for_rec]
    mov ax, [cp]
    mov bx, [bx + 4]
    call patch_word
    mov bx, [for_rec]
    call for_ref_var
    call ref_load
    call for_ref_limit
    call ref_load
    call for_ref_step
    call ref_load
    mov ah, OP_FORTEST_I            ; leaves -1 to go on
    call emit_arith
    mov al, OP_JNZ_I
    mov bx, [for_rec]
    mov bx, [bx + 6]
    call emit_op_word
    call for_exits                  ; EXIT FOR: here
    call ctl_pop
    mov al, ','                     ; NEXT j, i
    call accept_op
    jc .skip31
    jmp .one
.skip31:
    ret

for_ref_var:
    mov bx, [for_rec]
    mov al, [bx + 1]
    mov [r_kind], al
    mov al, [bx + 3]
    mov [r_type], al
    mov ax, [bx + 8]
    mov [r_addr], ax
    ret

for_ref_limit:
    xor cx, cx
    jmp for_ref_hidden
for_ref_step:
    mov cx, 4
for_ref_hidden:
    mov bx, [for_rec]
    mov al, [bx + 2]
    mov [r_kind], al
    mov al, [bx + 3]
    mov [r_type], al
    mov ax, [bx + 10]
    add ax, cx
    mov [r_addr], ax
    ret

; EXIT FOR jumps: chained in exit_chains by depth
for_exits:
    call ctl_exit_chain
    jmp fix_chain

; BX = the address of the EXIT chain of the innermost block
ctl_exit_chain:
    mov bl, [ctl_depth]
    dec bl
    xor bh, bh
    shl bx, 1
    add bx, exit_chains
    ret

; DO [WHILE|UNTIL c] ... LOOP [WHILE|UNTIL c]
st_do:
    call next
    mov al, CTL_DO
    call ctl_push
    mov ax, [cp]
    mov [bx + 2], ax
    push bx
    call ctl_exit_chain
    mov word [bx], 0
    pop bx
    mov al, KW_WHILE
    call accept_kw
    jc .not_while
    call condition_jump
    jmp .chain
.not_while:
    mov al, KW_UNTIL
    call accept_kw
    jc .done
    call condition_jump_true
.chain:
    ; the jump out goes in the EXIT chain
    push bx
    call ctl_exit_chain
    mov ax, [bx]
    pop dx
    mov [bx], dx
    mov bx, dx
    call patch_word
    call temps_free
.done:
    ret

st_loop:
    call next
    mov al, CTL_DO
    call ctl_expect
    mov dx, [bx + 2]                ; the top
    push dx
    mov al, KW_WHILE
    call accept_kw
    jc .not_while
    call condition_jump_true
    jmp .back
.not_while:
    mov al, KW_UNTIL
    call accept_kw
    jc .always
    call condition_jump
.back:
    pop ax
    call patch_word
    call temps_free
    jmp .out
.always:
    pop bx
    mov al, OP_JMP
    call emit_op_word
.out:
    call ctl_exit_chain
    call fix_chain
    jmp ctl_pop

; WHILE c ... WEND
st_while:
    call next
    mov al, CTL_WHILE
    call ctl_push
    mov ax, [cp]
    mov [bx + 2], ax
    push bx
    call ctl_exit_chain
    mov word [bx], 0
    pop bx
    call condition_jump
    push bx
    call ctl_top
    pop word [bx + 4]
    jmp temps_free

st_wend:
    call next
    mov al, CTL_WHILE
    call ctl_expect
    push bx
    mov al, OP_JMP
    mov bx, [bx + 2]
    call emit_op_word
    pop bx
    mov ax, [cp]
    mov bx, [bx + 4]
    call patch_word
    call ctl_exit_chain
    call fix_chain
    jmp ctl_pop

; EXIT FOR / DO / SUB / FUNCTION
st_exit:
    call next
    cmp byte [tok], TK_KW
    jne .bad
    mov al, [tok_kw]
    push ax
    call next
    pop ax
    cmp al, KW_SUB
    je .sub
    cmp al, KW_FUNCTION
    je .sub
    cmp al, KW_DEF
    je .sub
    mov ah, CTL_FOR
    cmp al, KW_FOR
    je .loop
    mov ah, CTL_DO
    cmp al, KW_DO
    jne .bad
.loop:
    mov al, ah
    call ctl_find                   ; BX = the record, CX = its depth
    jc .bad
    mov bx, cx
    shl bx, 1
    add bx, exit_chains
    mov al, OP_JMP
    jmp emit_jump_chain
.sub:
    cmp byte [in_sub], 0
    je .bad
    mov bx, sub_exit_chain
    mov al, OP_JMP
    jmp emit_jump_chain
.bad:
    mov si, m_syntax
    call cerror

; ---------- jumps ----------

st_goto:
    call next
    mov al, OP_JMP
    call emit_byte
    jmp emit_label_ref

st_gosub:
    call next
    mov al, OP_GOSUB
    call emit_byte
    jmp emit_label_ref

st_return:
    call next
    mov al, OP_RETURN
    jmp emit_byte

st_stop:
st_system:
    call next
    mov al, OP_END
    jmp emit_byte

; ---------- SELECT CASE ----------

st_select:
    call next
    mov al, KW_CASE
    call expect_kw
    call expr
    push ax
    mov al, CTL_SELECT
    call ctl_push
    mov [for_rec], bx
    pop ax
    mov [bx + 3], al                ; its type
    push ax
    call hidden_var
    mov bx, [for_rec]
    mov [bx + 8], ax
    mov [bx + 1], dl
    pop ax
    cmp al, TY_STR                  ; a string in the frame
    jne .not_str
    cmp dl, R_LOCAL
    jne .not_str
    mov byte [sub_strings], 1
.not_str:
    push ax
    call select_ref
    pop ax
    call ref_store
    jmp temps_free

; r_* = the hidden value of the SELECT at [for_rec]
select_ref:
    mov bx, [for_rec]
    mov al, [bx + 1]
    mov [r_kind], al
    mov al, [bx + 3]
    mov [r_type], al
    mov ax, [bx + 8]
    mov [r_addr], ax
    ret

st_case:
    call next
    mov al, CTL_SELECT
    call ctl_expect
    mov [for_rec], bx
    cmp word [bx + 10], 0           ; not the first CASE: the one before
    je .first                       ; ends here, jumping to END SELECT
    mov al, OP_JMP
    add bx, 4
    call emit_jump_chain
.first:
    mov bx, [for_rec]
    inc word [bx + 10]
    mov ax, [cp]                    ; the previous test fails to here
    mov bx, [bx + 6]
    or bx, bx
    jz .no_pending
    call patch_word
.no_pending:
    mov bx, [for_rec]
    mov word [bx + 6], 0
    mov al, KW_ELSE
    call accept_kw
    jc .skip30
    jmp .done
.skip30:
    mov byte [case_items], 0
.item:
    mov al, KW_IS
    call accept_kw
    jc .not_is
    mov ah, [tok_op]                ; IS relop value
    call next
    mov bl, CC_EQ
    cmp ah, '='
    je .is
    mov bl, CC_NE
    cmp ah, OP_NE
    je .is
    mov bl, CC_LT
    cmp ah, '<'
    je .is
    mov bl, CC_GT
    cmp ah, '>'
    je .is
    mov bl, CC_LE
    cmp ah, OP_LE
    je .is
    mov bl, CC_GE
.is:
    push bx
    call select_ref
    call ref_load
    push ax
    call expr
    pop bx
    call balance
    pop bx
    call emit_compare
    jmp .combine
.not_is:
    call select_ref                 ; value [TO value]
    call ref_load
    push ax
    call expr
    pop bx
    call balance
    push ax
    mov al, KW_TO
    call accept_kw
    pop ax
    jnc .range
    mov bl, CC_EQ
    call emit_compare
    jmp .combine
.range:
    mov bl, CC_GE
    call emit_compare
    call select_ref
    call ref_load
    push ax
    call expr
    pop bx
    call balance
    mov bl, CC_LE
    call emit_compare
    mov al, OP_AND_I
    call emit_byte
.combine:
    cmp byte [case_items], 0
    je .first_item
    mov al, OP_OR_I
    call emit_byte
.first_item:
    inc byte [case_items]
    mov al, ','
    call accept_op
    jc .skip29
    jmp .item
.skip29:
    mov al, OP_JZ_I                 ; no match: to the next CASE
    call emit_byte
    mov bx, [for_rec]
    mov ax, [cp]
    mov [bx + 6], ax
    xor ax, ax
    call emit_word
    call temps_free
.done:
    ret

; The comparison opcode for type AL with condition BL. AL = TY_INT after.
emit_compare:
    mov ah, OP_CMP_I
    cmp al, TY_INT
    je .emit
    mov ah, OP_CMP_L
    cmp al, TY_LNG
    je .emit
    mov ah, OP_CMP_S
    cmp al, TY_SNG
    je .emit
    mov ah, OP_CMP_STR
.emit:
    mov al, ah
    call emit_byte
    mov al, bl
    call emit_byte
    mov al, TY_INT
    ret

end_select:
    call next
    mov al, CTL_SELECT
    call ctl_expect
    push bx
    mov ax, [cp]
    mov bx, [bx + 6]
    or bx, bx
    jz .none
    call patch_word
.none:
    pop bx
    add bx, 4
    call fix_chain
    jmp ctl_pop

; ---------- screen ----------

; Optional numeric arguments separated by commas (up to 4): each present
; one is pushed as an INT, and AL = a bit mask of those present
optional_ints:
    xor cx, cx                      ; CL = mask, CH = position
.next:
    call at_end
    jnc .done
    cmp byte [tok], TK_OP
    jne .value
    cmp byte [tok_op], ','
    jne .value
    push cx
    call next
    pop cx
    inc ch
    jmp .next
.value:
    push cx
    call expr
    mov ah, TY_INT
    call convert
    pop cx
    mov al, 1
    push cx
    mov cl, ch
    shl al, cl
    pop cx
    or cl, al
    mov al, ','
    push cx
    call accept_op
    pop cx
    jc .done
    inc ch
    jmp .next
.done:
    mov al, cl
    ret

st_cls:
    call next
    call optional_ints
    push ax
    mov al, OP_CLS
    call emit_byte
    pop ax
    jmp emit_byte

st_locate:
    call next
    call optional_ints
    push ax
    mov al, OP_LOCATE
    call emit_byte
    pop ax
    jmp emit_byte

st_color:
    call next
    call optional_ints
    push ax
    mov al, OP_COLOR
    call emit_byte
    pop ax
    jmp emit_byte

st_beep:
    call next
    mov al, OP_BEEP
    jmp emit_byte

st_randomize:
    call next
    call at_end
    jnc .timer
    call expr
    mov ah, TY_SNG
    call convert
    mov al, OP_RANDOMIZE
    jmp emit_byte
.timer:
    mov al, OP_RANDOMIZE_TIMER
    jmp emit_byte

st_sleep:
    call next
    call at_end
    jnc .forever
    call expr
    mov ah, TY_INT
    call convert
    jmp .op
.forever:
    mov al, OP_PUSH_I
    xor bx, bx
    call emit_op_word
.op:
    mov al, OP_SLEEP
    jmp emit_byte

; ---------- INPUT ----------

; INPUT [;] ["prompt" ; | ,] var, var...
st_input:
    call next
    cmp byte [tok], TK_OP           ; INPUT #n: a file
    jne .console
    cmp byte [tok_op], '#'
    jne .console
    jmp input_file
.console:
    mov ax, [cp]                    ; "Redo from start" comes back here
    mov [input_retry], ax
    xor cl, cl                      ; CL bit 0: ;  bit 1: no "? "
    mov al, ';'
    push cx
    call accept_op
    pop cx
    jc .prompt
    or cl, 1
.prompt:
    cmp byte [tok], TK_STR
    jne .no_prompt
    push cx
    call string_constant
    mov al, OP_PUSH_CSTR
    call emit_op_word
    mov ax, cx
    call emit_word
    call next
    pop cx
    mov al, ';'
    push cx
    call accept_op
    pop cx
    jnc .prompted
    mov al, ','
    push cx
    call expect_op
    pop cx
    or cl, 2                        ; , : no question mark
    jmp .prompted
.no_prompt:
    mov al, OP_PUSH_I               ; no prompt
    xor bx, bx
    push cx
    call emit_op_word
    pop cx
    or cl, 4
.prompted:
    mov al, OP_INPUT_BEGIN
    call emit_byte
    mov al, cl
    call emit_byte
.var:
    call compile_ref
    mov al, [r_type]
    mov bl, al
    xor bh, bh
    mov al, [input_ops + bx - 1]
    call emit_byte
    mov al, [r_type]
    call ref_store
    mov al, ','
    call accept_op
    jnc .var
    mov al, OP_INPUT_END
    mov bx, [input_retry]
    call emit_op_word
    jmp temps_free

; LINE INPUT [;] ["prompt" ;] var$ (st_line comes here at INPUT)
st_line_input:
    call next
    cmp byte [tok], TK_OP
    jne .console
    cmp byte [tok_op], '#'
    jne .console
    jmp line_input_file
.console:
    xor cl, cl
    mov al, ';'
    push cx
    call accept_op
    pop cx
    jc .prompt
    or cl, 1
.prompt:
    cmp byte [tok], TK_STR
    jne .no_prompt
    push cx
    call string_constant
    mov al, OP_PUSH_CSTR
    call emit_op_word
    mov ax, cx
    call emit_word
    call next
    mov al, ';'
    call expect_op
    pop cx
    jmp .read
.no_prompt:
    push cx
    mov al, OP_PUSH_I
    xor bx, bx
    call emit_op_word
    pop cx
.read:
    mov al, OP_LINE_INPUT
    call emit_byte
    mov al, cl
    call emit_byte
    call compile_ref
    cmp byte [r_type], TY_STR
    je .store
    jmp type_mismatch
.store:
    mov al, TY_STR
    call ref_store
    jmp temps_free


; ---------- DEFINT, DEFLNG, DEFSNG, DEFDBL, DEFSTR ----------

st_deftype:
    mov al, [tok_kw]
    sub al, KW_DEFINT
    mov bl, al
    xor bh, bh
    mov al, [deftype_of + bx]
    mov [def_new], al
    call next
.range:
    cmp byte [tok], TK_NAME
    jne .bad
    mov al, [tok_name]
    mov ah, al
    push ax
    call next
    mov al, '-'
    call accept_op
    pop ax
    jc .set
    cmp byte [tok], TK_NAME
    jne .bad
    mov ah, [tok_name]
    push ax
    call next
    pop ax
.set:
    cmp al, ah
    ja .bad
    mov bl, al
    sub bl, 'A'
    xor bh, bh
    mov cl, ah
    sub cl, al
    xor ch, ch
    inc cx
    mov al, [def_new]
.letter:
    mov [deftype + bx], al
    inc bx
    loop .letter
    mov al, ','
    call accept_op
    jnc .range
    ret
.bad:
    mov si, m_syntax
    call cerror

; ---------- types after AS ----------

; After AS: AL = the type, BX = the record's TYPE entry (TY_REC)
as_type:
    mov al, KW_AS
    call expect_kw
    cmp byte [tok], TK_KW
    jne .record
    mov al, [tok_kw]
    mov ah, TY_INT
    cmp al, KW_INTEGER
    je .simple
    mov ah, TY_LNG
    cmp al, KW_LONG
    je .simple
    mov ah, TY_SNG
    cmp al, KW_SINGLE
    je .simple
    cmp al, KW_DOUBLE
    je .simple
    mov ah, TY_STR
    cmp al, KW_STRING
    jne .bad
    call next
    mov al, '*'                     ; STRING * n is a plain string here
    call accept_op
    jc .str
    call next
.str:
    mov al, TY_STR
    xor bx, bx
    ret
.simple:
    push ax
    call next
    pop ax
    mov al, ah
    xor bx, bx
    ret
.record:
    cmp byte [tok], TK_NAME
    jne .bad
    call type_key
    xor al, al
    call sym_find_scope
    jc .unknown
    cmp byte [es:di + N_KIND], NK_TYPE
    jne .unknown
    mov bx, di
    push ds
    pop es
    call next
    mov al, TY_REC
    ret
.unknown:
    push ds
    pop es
    mov si, m_unknown_type
    call cerror
.bad:
    mov si, m_syntax
    call cerror

; key_buf = "@NAME": the name of a TYPE
type_key:
    call name_key
    push si
    push di
    push cx
    mov si, key_buf
    add si, [key_len]
    dec si
    mov di, si
    inc di
    mov cx, [key_len]
    push ds
    pop es
    std
    rep movsb
    cld
    mov byte [key_buf], '@'
    inc word [key_len]
    pop cx
    pop di
    pop si
    ret

; ---------- TYPE ... END TYPE (pass 1 builds it, pass 2 skips it) ----------

st_type:
    call next
    cmp byte [pass], 1
    je .define
.skip:                              ; to END TYPE
    cmp byte [tok], TK_EOF
    je .done
    cmp byte [tok], TK_KW
    jne .skip_next
    cmp byte [tok_kw], KW_END
    jne .skip_next
    call next
    mov al, KW_TYPE
    call accept_kw
    jnc .done
.skip_next:
    call next
    jmp .skip
.done:
    ret
.define:
    cmp byte [tok], TK_NAME
    je .named
    mov si, m_syntax
    call cerror
.named:
    call type_key
    xor al, al
    mov ah, NK_TYPE
    call sym_add
    mov [type_entry], di
    push ds
    pop es
    call next
    mov word [type_offset], 0
.field_line:
    cmp byte [tok], TK_EOL
    jne .not_eol
    call next
    jmp .field_line
.not_eol:
    cmp byte [tok], TK_EOF
    jne .not_eof
    mov si, m_type_open
    call cerror
.not_eof:
    cmp byte [tok], TK_KW
    jne .field
    cmp byte [tok_kw], KW_END
    jne .field
    call next
    mov al, KW_TYPE
    call expect_kw
    mov es, [seg_sym]
    mov di, [type_entry]
    mov ax, [type_offset]
    mov [es:di + N_X1], ax
    push ds
    pop es
    ret
.field:
    cmp byte [tok], TK_NAME
    je .field_named
    mov si, m_syntax
    call cerror
.field_named:
    mov ax, [type_entry]            ; key: the TYPE's entry (2 bytes) + name
    call field_key
    push word [key_len]
    call next
    call as_type                    ; AL = type, BX = record
    pop cx
    cmp al, TY_STR
    jne .field_ok
    mov si, m_string_field
    call cerror
.field_ok:
    push ax
    push bx
    call field_key_again
    xor al, al
    mov ah, NK_FIELD
    call sym_add
    pop bx
    pop ax
    mov [es:di + N_TYPE], al
    mov [es:di + N_X1], bx
    mov dx, [type_offset]
    mov [es:di + N_ADDR], dx
    call type_size                  ; CX = size (ES:DI = entry)
    add [type_offset], cx
    push ds
    pop es
    jmp .field_line

; key_buf = the 2 bytes of AX (a TYPE entry) + tok_name; saved for
; field_key_again
field_key:
    mov [field_type_entry], ax
    call name_key
    push si
    push di
    push cx
    mov cx, [key_len]
    mov si, key_buf + 79
    sub si, 80 - 1
    add si, cx
    dec si                          ; the last character
    mov di, si
    add di, 2
    push ds
    pop es
    std
    rep movsb
    cld
    mov ax, [field_type_entry]
    mov [key_buf], ax
    add word [key_len], 2
    mov si, key_buf                 ; kept for field_key_again
    mov di, field_key_buf
    mov cx, [key_len]
    mov [field_key_len], cx
    rep movsb
    pop cx
    pop di
    pop si
    ret

field_key_again:
    push si
    push di
    push cx
    mov si, field_key_buf
    mov di, key_buf
    mov cx, [field_key_len]
    mov [key_len], cx
    push ds
    pop es
    rep movsb
    pop cx
    pop di
    pop si
    ret

; .field after a record reference (r_type = TY_REC)
field_suffix:
.next:
    cmp byte [r_type], TY_REC
    jne .done
    cmp byte [tok], TK_OP
    jne .done
    cmp byte [tok_op], '.'
    jne .done
    call next
    cmp byte [tok], TK_NAME
    je .name
    mov si, m_syntax
    call cerror
.name:
    mov ax, [r_rec]
    call field_key
    call next
    call apply_field
    jmp .next
.done:
    ret

; key_buf = a field key of the record r_rec: r_* moves to the field
apply_field:
    xor al, al
    call sym_find_scope
    jnc .found
    push ds
    pop es
    mov si, m_no_field
    call cerror
.found:
    mov al, [es:di + N_TYPE]
    mov [r_type], al
    mov ax, [es:di + N_X1]
    mov [r_rec], ax
    mov dx, [es:di + N_ADDR]        ; its offset in the record
    push ds
    pop es
    mov al, [r_kind]
    cmp al, R_PARAM
    jne .not_param
    push dx
    mov al, OP_LDP_ADDR             ; the record's address, then + offset
    call emit_byte
    mov ax, [r_addr]
    call emit_word
    pop dx
    mov byte [r_kind], R_FAR
    jmp .far
.not_param:
    cmp al, R_FAR
    jne .direct
.far:
    or dx, dx
    jz .done
    mov al, OP_ADD_OFF
    mov bx, dx
    call emit_op_word
    jmp .done
.direct:
    add [r_addr], dx                ; global or local: a fixed address
.done:
    ret

; ---------- DIM ----------

st_dim:
    call next
    mov byte [dim_shared], 0
    mov al, KW_SHARED
    call accept_kw
    jc .item
    mov byte [dim_shared], 1
.item:
    cmp byte [tok], TK_NAME
    je .name
    mov si, m_syntax
    call cerror
.name:
    call name_key
    mov si, key_buf                 ; keep the name as written
    mov di, dim_key
    mov cx, [key_len]
    mov [dim_key_len], cx
    push ds
    pop es
    rep movsb
    call next
    mov byte [dim_dims], 0
    mov al, '('
    call accept_op
    jc .no_bounds
.bound:
    call expr                       ; lower [TO upper]
    mov ah, TY_INT
    call convert
    mov al, KW_TO
    call accept_kw
    jnc .upper
    ; only the upper bound: the lower one is 0, pushed under it
    mov al, OP_PUSH_I
    mov bl, [option_base]
    xor bh, bh
    call emit_op_word
    mov al, OP_SWAP_W
    call emit_byte
    jmp .counted
.upper:
    call expr
    mov ah, TY_INT
    call convert
.counted:
    inc byte [dim_dims]
    mov al, ','
    call accept_op
    jnc .bound
    mov al, ')'
    call expect_op
.no_bounds:
    call dim_restore_key
    mov byte [dim_type], 0
    mov word [dim_rec], 0
    cmp byte [tok], TK_KW
    jne .typed_by_name
    cmp byte [tok_kw], KW_AS
    jne .typed_by_name
    call as_type
    mov [dim_type], al
    mov [dim_rec], bx
    call dim_restore_key            ; the bare name
    jmp .declare
.typed_by_name:
    call dim_restore_key
    call key_typed_new              ; the suffix, or the DEF type
.declare:
    cmp byte [dim_dims], 0
    jne .array
    ; a scalar
    mov al, [scope]
    call sym_find_scope
    jc .new_scalar
    push ds
    pop es
    mov si, m_dup_def
    call cerror
.new_scalar:
    mov al, [scope]
    mov ah, NK_VAR
    call sym_add
    mov al, [dim_type]
    mov [es:di + N_TYPE], al
    mov ax, [dim_rec]
    mov [es:di + N_X1], ax
    call alloc_var
    call dim_shared_flag
    push ds
    pop es
    jmp .more
.array:
    call array_key
    mov al, [scope]
    call sym_find_scope
    jnc .exists
    mov al, [scope]
    mov ah, NK_ARRAY
    call sym_add
    mov al, [dim_type]
    mov [es:di + N_TYPE], al
    mov ax, [dim_rec]
    mov [es:di + N_X2], ax
    call alloc_array_desc
    call dim_shared_flag
.exists:
    cmp byte [es:di + N_KIND], NK_ARRAY
    je .dim_code
    push ds
    pop es
    mov si, m_dup_def
    call cerror
.dim_code:
    mov al, [dim_dims]
    mov [es:di + N_X1], al
    call array_operands             ; opcode family base in AL...
    push ds
    pop es
    mov al, [arr_op_kind]
    add al, OP_DIM_G
    cmp byte [dim_redim], 0
    je .dim_op
    add al, OP_REDIM_G - OP_DIM_G
.dim_op:
    call emit_byte
    call emit_array_operands
.more:
    mov al, ','
    call accept_op
    jc .done
    jmp .item
.done:
    ret

dim_restore_key:
    push si
    push di
    push cx
    mov si, dim_key
    mov di, key_buf
    mov cx, [dim_key_len]
    mov [key_len], cx
    push ds
    pop es
    rep movsb
    pop cx
    pop di
    pop si
    ret

; DIM SHARED: the module variable is visible in SUBs
dim_shared_flag:
    cmp byte [dim_shared], 0
    je .done
    or byte [es:di + N_FLAGS], NF_SHARED
.done:
    ret

; key_buf as written -> with its type suffix (written or DEF type), for a
; new name. dim_type = the type.
key_typed_new:
    mov bx, [key_len]
    mov al, [key_buf + bx - 1]
    mov ah, TY_INT
    cmp al, '%'
    je .written
    mov ah, TY_LNG
    cmp al, '&'
    je .written
    mov ah, TY_SNG
    cmp al, '!'
    je .written
    cmp al, '#'
    je .double
    mov ah, TY_STR
    cmp al, '$'
    je .written
    mov bl, [key_buf]
    sub bl, 'A'
    cmp bl, 26
    jb .letter
    xor bl, bl
.letter:
    xor bh, bh
    mov al, [deftype + bx]
    mov [dim_type], al
    jmp key_with_type
.double:
    mov byte [key_buf + bx - 1], '!'
.written:
    mov [dim_type], ah
    ret

; key_buf + "(": the key of an array
array_key:
    mov bx, [key_len]
    mov byte [key_buf + bx], '('
    inc word [key_len]
    ret

ARR_DESC    equ 40              ; segment, element size, dimensions...

; Room for the descriptor of the array ES:DI (global or in the frame)
alloc_array_desc:
    mov cx, ARR_DESC
    cmp byte [scope], 0
    jne .local
    mov ax, [data_top]
    mov [es:di + N_ADDR], ax
    add [data_top], cx
    ret
.local:
    or byte [es:di + N_FLAGS], NF_LOCAL
    mov ax, [frame_size]
    mov [es:di + N_ADDR], ax
    add [frame_size], cx
    cmp byte [es:di + N_TYPE], TY_STR
    jne .ret
    mov byte [sub_strings], 1
.ret:
    ret

; The array entry ES:DI -> arr_op_kind (0 global, 1 local, 2 parameter),
; arr_addr, arr_type, arr_size (element size), arr_dims
array_operands:
    mov byte [arr_op_kind], 0
    test byte [es:di + N_FLAGS], NF_PARAM
    jz .not_param
    mov byte [arr_op_kind], 2
    jmp .kind
.not_param:
    test byte [es:di + N_FLAGS], NF_LOCAL
    jz .kind
    mov byte [arr_op_kind], 1
.kind:
    mov ax, [es:di + N_ADDR]
    mov [arr_addr], ax
    mov al, [es:di + N_TYPE]
    mov [arr_type], al
    mov ax, [es:di + N_X2]
    mov [arr_rec], ax
    push di
    mov bx, ax
    mov cx, 2
    cmp byte [arr_type], TY_INT
    je .size
    mov cx, 4
    cmp byte [arr_type], TY_REC
    jne .size
    mov cx, [es:bx + N_X1]
.size:
    pop di
    mov [arr_size], cx
    mov al, [es:di + N_X1]
    mov [arr_dims], al
    ret

; The operands of DIM / element: address, dimensions, type, element size
emit_array_operands:
    mov ax, [arr_addr]
    call emit_word
    mov al, [arr_dims]
    call emit_byte
    mov al, [arr_type]
    call emit_byte
    mov ax, [arr_size]
    jmp emit_word

; NAME( indices ): an element (key_buf = the name as written; the '(' is
; the current token)
array_ref:
    call next                       ; past (
    call find_array                 ; ES:DI = the entry (created if new)
    push di
    xor cx, cx
.index:
    push cx
    call expr
    mov ah, TY_INT
    call convert
    pop cx
    inc cx
    mov al, ','
    push cx
    call accept_op
    pop cx
    jnc .index
    push cx
    mov al, ')'
    call expect_op
    pop cx
    pop di
    mov es, [seg_sym]
    cmp byte [es:di + N_X1], 0      ; first use without DIM: its dimensions
    jne .known
    mov [es:di + N_X1], cl
.known:
    cmp [es:di + N_X1], cl
    je .count_ok
    push ds
    pop es
    mov si, m_wrong_dims
    call cerror
.count_ok:
    call array_operands
    push ds
    pop es
    mov al, [arr_op_kind]
    add al, OP_AELEM_G
    call emit_byte
    call emit_array_operands
    mov al, [arr_type]
    mov [r_type], al
    mov ax, [arr_rec]
    mov [r_rec], ax
    mov byte [r_kind], R_FAR
    cmp byte [arr_type], TY_STR
    jne .numeric
    mov byte [r_kind], R_STRDESC
.numeric:
    jmp field_suffix

; key_buf (as written) -> ES:DI = the array (created as A(10) if new)
find_array:
    push word [key_len]             ; declared AS: the bare name with (
    call array_key
    mov al, [scope]
    call sym_find_scope
    jnc .as_found
    cmp byte [scope], 0
    je .not_as
    xor al, al
    call sym_find_scope
    jc .not_as
    test byte [es:di + N_FLAGS], NF_SHARED
    jnz .as_found
.not_as:
    push ds
    pop es
    pop word [key_len]
    call key_typed                  ; the type: written or DEF
    call array_key
    mov al, [scope]
    call sym_find_scope
    jnc .found
    cmp byte [scope], 0
    je .new
    xor al, al
    call sym_find_scope
    jc .new
    test byte [es:di + N_FLAGS], NF_SHARED
    jnz .found
.new:
    mov al, [scope]
    mov ah, NK_ARRAY
    call sym_add
    mov al, [key_type]
    mov [es:di + N_TYPE], al
    call alloc_array_desc
    ret
.as_found:
    add sp, 2
.found:
    cmp byte [es:di + N_KIND], NK_ARRAY
    je .ok
    push ds
    pop es
    mov si, m_dup_def
    call cerror
.ok:
    ret

; ---------- CONST ----------

st_const:
    call next
.item:
    cmp byte [tok], TK_NAME
    je .name
    mov si, m_syntax
    call cerror
.name:
    call name_key
    mov si, key_buf
    mov di, dim_key
    mov cx, [key_len]
    mov [dim_key_len], cx
    push ds
    pop es
    rep movsb
    call next
    mov al, '='
    call expect_op
    cmp byte [tok], TK_STR          ; a string: only a literal
    jne .number
    call string_constant
    mov [const_lo], bx
    mov [const_hi], cx
    call next
    mov al, TY_STR
    jmp .define
.number:
    call const_eval                 ; AL = type, const_lo/hi = value
.define:
    push ax
    call dim_restore_key
    mov al, [scope]
    call sym_find_scope
    jc .new
    push ds
    pop es
    mov si, m_dup_def
    call cerror
.new:
    mov al, [scope]
    mov ah, NK_CONST
    call sym_add
    pop ax
    mov [es:di + N_TYPE], al
    mov ax, [const_lo]
    mov [es:di + N_X1], ax
    mov ax, [const_hi]
    mov [es:di + N_X2], ax
    push ds
    pop es
    mov al, ','
    call accept_op
    jnc .item
    ret

; A constant expression: compiled, run by the machine, then the code is
; taken back. AL = its type, const_lo/const_hi = its value.
const_eval:
    push word [cp]
    call expr
    push ax
    mov bl, OP_CONST_END1
    cmp al, TY_INT
    je .end
    mov bl, OP_CONST_END2
    cmp al, TY_STR
    jne .end
    jmp type_mismatch
.end:
    mov al, bl
    call emit_byte
    pop ax
    pop bx                          ; where it starts
    push ax
    push bx
    call vm_eval                    ; runs the code at BX
    pop bx
    mov [cp], bx
    pop ax
    ret

; ---------- SUB and FUNCTION ----------

; Pass 1: SUB name [(params)] / FUNCTION name[suffix] [(params)]
sub_header:
    mov al, [tok_kw]
    mov [sub_kind], al
    call next
; (DEF FN enters here, at the name, with sub_kind = KW_FUNCTION)
sub_header_named:
    cmp byte [tok], TK_NAME
    je .named
    mov si, m_syntax
    call cerror
.named:
    call name_key
    call key_typed_new              ; the key always has its type
    xor al, al
    call sym_find_scope
    jc .new
    push ds
    pop es
    mov si, m_dup_def
    call cerror
.new:
    mov ah, NK_SUB
    cmp byte [sub_kind], KW_SUB
    je .kind
    mov ah, NK_FUNC
.kind:
    xor al, al
    call sym_add
    mov [sub_entry], di
    inc byte [sub_count]
    mov al, [sub_count]
    mov [es:di + N_X2], al          ; its number (the scope of its names)
    ; its type (FUNCTION): the suffix or the DEF type
    push ds
    pop es
    call key_typed_new
    mov es, [seg_sym]
    mov di, [sub_entry]
    mov al, [dim_type]
    mov [es:di + N_TYPE], al
    ; the information block: chain, defined, count, parameters
    mov bx, [sym_free]
    mov [es:di + N_X1], bx
    mov word [es:bx], 0
    mov byte [es:bx + 2], 0
    mov byte [es:bx + 3], 0
    lea ax, [bx + 4 + 4 * 16]       ; room for 16 parameters
    mov [sym_free], ax
    mov [sub_info], bx
    push ds
    pop es
    call next
    mov al, '('
    call accept_op
    jc .done
    mov al, ')'
    call accept_op
    jnc .done
.param:
    call param_decl                 ; AL = type, AH = 1 for an array, BX = rec
    push es
    mov es, [seg_sym]
    mov di, [sub_info]
    mov cl, [es:di + 3]
    cmp cl, 16
    jb .room
    pop es
    mov si, m_too_many_params
    call cerror
.room:
    inc byte [es:di + 3]
    xor ch, ch
    shl cx, 1
    shl cx, 1
    add di, cx
    mov [es:di + 4], al
    mov [es:di + 5], ah
    mov [es:di + 6], bx
    pop es
    mov al, ','
    call accept_op
    jnc .param
    mov al, ')'
    call expect_op
.done:
    ret

; A parameter: name[suffix] [()] [AS type]. AL = type, AH = 1 if an
; array, BX = record type. key_buf = its key (typed, or bare with AS).
param_decl:
    cmp byte [tok], TK_NAME
    je .named
    mov si, m_syntax
    call cerror
.named:
    call name_key
    mov si, key_buf
    mov di, dim_key
    mov cx, [key_len]
    mov [dim_key_len], cx
    push ds
    pop es
    rep movsb
    call next
    mov byte [param_array], 0
    mov al, '('
    call accept_op
    jc .no_array
    mov al, ')'
    call expect_op
    mov byte [param_array], 1
.no_array:
    cmp byte [tok], TK_KW
    jne .by_name
    cmp byte [tok_kw], KW_AS
    jne .by_name
    call as_type
    mov [dim_type], al
    mov [dim_rec], bx
    call dim_restore_key
    jmp .done
.by_name:
    call dim_restore_key
    call key_typed_new
    mov word [dim_rec], 0
.done:
    mov al, [dim_type]
    mov ah, [param_array]
    mov bx, [dim_rec]
    ret

; Pass 2: SUB / FUNCTION: the code starts here
st_sub:
    cmp byte [in_sub], 0
    je .ok
    mov si, m_sub_in_sub
    call cerror
.ok:
    cmp byte [main_ended], 0        ; the module's code ends before it
    jne .ended
    mov al, OP_END
    call emit_byte
    mov byte [main_ended], 1
.ended:
    mov al, [tok_kw]
    mov [sub_kind], al
    call next
; At the name (DEF FN enters here with tok_kw = KW_FUNCTION)
st_sub_named:
    mov al, [tok_kw]
    mov [sub_kind], al
    mov byte [sub_strings], 0
    call name_key
    call key_typed_new
    xor al, al
    call sym_find_scope
    mov [sub_entry], di
    mov al, [es:di + N_X2]
    mov [scope], al
    mov al, [es:di + N_TYPE]
    mov [sub_type], al
    mov bx, [es:di + N_X1]
    mov [sub_info], bx
    mov ax, [cp]                    ; its address; earlier calls fixed
    mov [es:di + N_ADDR], ax
    mov byte [es:bx + 2], 1
    mov bx, [es:bx]
    push ds
    pop es
.fix:
    or bx, bx
    jz .fixed
    push es
    mov es, [seg_code]
    mov dx, [es:bx]
    mov [es:bx], ax
    pop es
    mov bx, dx
    jmp .fix
.fixed:
    mov byte [in_sub], 1
    mov word [sub_exit_chain], 0
    mov word [frame_size], 0
    cmp byte [sub_kind], KW_FUNCTION
    jne .no_result
    ; the result: a local named like the FUNCTION
    call key_typed_new
    mov al, [scope]
    mov ah, NK_VAR
    call sym_add
    mov al, [sub_type]
    mov [es:di + N_TYPE], al
    or byte [es:di + N_FLAGS], NF_LOCAL
    mov word [es:di + N_ADDR], 0
    push ds
    pop es
    mov word [frame_size], 4
.no_result:
    call next
    mov al, '('
    call accept_op
    jc .params_done
    mov al, ')'
    call accept_op
    jnc .params_done
.param:
    call param_decl
    push ax
    push bx
    mov ah, NK_VAR
    pop bx
    pop ax
    push ax
    push bx
    cmp ah, 1
    jne .scalar_param
    call array_key
    mov al, [scope]
    mov ah, NK_ARRAY
    call sym_add
    pop bx
    pop ax
    mov [es:di + N_TYPE], al
    mov [es:di + N_X2], bx
    jmp .param_storage
.scalar_param:
    mov al, [scope]
    mov ah, NK_VAR
    call sym_add
    pop bx
    pop ax
    mov [es:di + N_TYPE], al
    mov [es:di + N_X1], bx
.param_storage:
    or byte [es:di + N_FLAGS], NF_PARAM
    mov ax, [frame_size]
    mov [es:di + N_ADDR], ax
    add word [frame_size], 4
    push ds
    pop es
    mov al, ','
    call accept_op
    jnc .param
    mov al, ')'
    call expect_op
.params_done:
    mov al, KW_STATIC
    call accept_kw
    mov al, OP_ENTER                ; frame size (fixed at END SUB), count
    call emit_byte
    mov ax, [cp]
    mov [enter_operand], ax
    xor ax, ax
    call emit_word
    mov es, [seg_sym]
    mov bx, [sub_info]
    mov al, [es:bx + 3]
    push ds
    pop es
    mov ah, 0                       ; flags: 1 FUNCTION (its result comes
    cmp byte [sub_kind], KW_FUNCTION ; first in the frame), 2 has strings
    jne .count
    mov ah, 1
.count:
    call emit_byte
    mov al, ah
    jmp emit_byte

; END SUB / END FUNCTION
end_sub:
    call next
end_sub_body:
    cmp byte [in_sub], 0
    jne .ok
    mov si, m_syntax
    call cerror
.ok:
    mov bx, sub_exit_chain
    call fix_chain
    mov al, OP_LEAVE
    cmp byte [sub_kind], KW_FUNCTION
    jne .leave
    mov bl, [sub_type]
    xor bh, bh
    mov al, [leave_ops + bx - 1]
.leave:
    call emit_byte
    mov bx, [enter_operand]
    mov ax, [frame_size]
    call patch_word
    cmp byte [sub_strings], 0       ; strings in the frame: freed at LEAVE
    je .no_strings
    push es
    mov es, [seg_code]
    or byte [es:bx + 3], 2
    pop es
.no_strings:
    mov byte [in_sub], 0
    mov byte [scope], 0
    ret

; Skipped in pass 2 (the headers were read in pass 1)
st_declare:
.skip:
    call at_end
    jnc .done
    call next
    jmp .skip
.done:
    ret

; SHARED a, b() [AS type]: module variables visible in this SUB
st_shared:
    call next
.item:
    cmp byte [tok], TK_NAME
    je .name
    mov si, m_syntax
    call cerror
.name:
    call name_key
    mov si, key_buf
    mov di, dim_key
    mov cx, [key_len]
    mov [dim_key_len], cx
    push ds
    pop es
    rep movsb
    call next
    mov byte [param_array], 0
    mov al, '('
    call accept_op
    jc .not_array
    mov al, ')'
    call expect_op
    mov byte [param_array], 1
.not_array:
    cmp byte [tok], TK_KW
    jne .by_name
    cmp byte [tok_kw], KW_AS
    jne .by_name
    call as_type
    call dim_restore_key
    jmp .look
.by_name:
    call dim_restore_key
    call key_typed_new
.look:
    cmp byte [param_array], 0
    je .scalar
    call array_key
.scalar:
    xor al, al                      ; the module's
    call sym_find_scope
    jnc .alias
    push ds
    pop es
    mov si, m_shared_unknown
    call cerror
.alias:
    mov ax, [es:di + N_ADDR]        ; the same storage, in this scope
    mov bl, [es:di + N_TYPE]
    mov bh, [es:di + N_KIND]
    mov cx, [es:di + N_X1]
    mov dx, [es:di + N_X2]
    push ax
    push bx
    push cx
    push dx
    mov al, [scope]
    mov ah, bh
    call sym_add
    pop dx
    pop cx
    pop bx
    pop ax
    mov [es:di + N_ADDR], ax
    mov [es:di + N_TYPE], bl
    mov [es:di + N_X1], cx
    mov [es:di + N_X2], dx
    push ds
    pop es
    mov al, ','
    call accept_op
    jc .skip28
    jmp .item
.skip28:
    ret

; A SUB or FUNCTION named key_buf (as written): the key gets its type
; suffix like the definition's. ES:DI = the entry, or CF (key_buf back as
; it was, ES = DS).
proc_lookup:
    push si
    push di
    push cx
    mov si, key_buf
    mov di, proc_saved
    mov cx, [key_len]
    mov [proc_saved_len], cx
    push ds
    pop es
    rep movsb
    pop cx
    pop di
    pop si
    push word [dim_type]
    call key_typed_new
    pop ax
    mov [dim_type], al
    xor al, al
    call sym_find_scope
    jc .none
    cmp byte [es:di + N_KIND], NK_SUB
    je .found
    cmp byte [es:di + N_KIND], NK_FUNC
    je .found
.none:
    call proc_key_back
    stc
    ret
.found:
    clc
    ret

; key_buf as it was before proc_lookup (ES = DS)
proc_key_back:
    push si
    push di
    push cx
    mov si, proc_saved
    mov di, key_buf
    mov cx, [proc_saved_len]
    mov [key_len], cx
    push ds
    pop es
    rep movsb
    pop cx
    pop di
    pop si
    ret

; CALL name [(args)]
st_call:
    call next
    call name_key
    call proc_lookup
    jc .bad
    cmp byte [es:di + N_KIND], NK_SUB
    jne .bad
    push ds
    pop es
    call next
    mov byte [call_parens], 0
    mov al, '('
    call accept_op
    jc call_sub_go
    mov byte [call_parens], 1
    jmp call_sub_go
.bad:
    push ds
    pop es
    mov si, m_no_sub
    call cerror

; A SUB call without CALL: the arguments follow without parentheses
call_sub_args:
    mov byte [call_parens], 0
; ES:DI = the SUB's entry (in the names segment, DI kept)
call_sub_go:
    call call_args
    mov al, [call_parens]
    or al, al
    jz .no_parens
    mov al, ')'
    call expect_op
.no_parens:
    jmp emit_call

; A FUNCTION in an expression: name[(args)]. AL = its type.
call_function:
    call call_state_save            ; (inside another call's arguments)
    mov es, [seg_sym]
    mov al, [es:di + N_TYPE]
    push ax
    push ds
    pop es
    call next
    mov byte [call_parens], 0
    mov al, '('
    call accept_op
    jc .args
    mov byte [call_parens], 1
.args:
    call call_args
    cmp byte [call_parens], 0
    je .call
    mov al, ')'
    call expect_op
.call:
    call emit_call
    call mark_strings
    pop ax
    call call_state_restore
    ret

; The state of the call being compiled, kept under the return address
call_state_save:
    pop bx
    push word [call_entry]
    push word [call_info]
    push word [arg_rec]
    push word [call_parens]         ; call_parens, call_arg
    push word [arg_type]            ; arg_type, arg_array
    jmp bx

; ... and back (AX is kept)
call_state_restore:
    pop bx
    pop word [arg_type]
    pop word [call_parens]
    pop word [arg_rec]
    pop word [call_info]
    pop word [call_entry]
    jmp bx

; The arguments of the SUB/FUNCTION whose entry is DI (names segment),
; one for each parameter, as addresses
call_args:
    mov [call_entry], di
    mov es, [seg_sym]
    mov bx, [es:di + N_X1]
    mov [call_info], bx
    push ds
    pop es
    mov al, OP_ARGS
    call emit_byte
    mov byte [call_arg], 0
.next:
    mov es, [seg_sym]
    mov bx, [call_info]
    mov al, [call_arg]
    cmp al, [es:bx + 3]
    jae .done
    xor ah, ah
    shl ax, 1
    shl ax, 1
    add bx, ax
    mov al, [es:bx + 4]
    mov [arg_type], al
    mov al, [es:bx + 5]
    mov [arg_array], al
    mov ax, [es:bx + 6]
    mov [arg_rec], ax
    push ds
    pop es
    cmp byte [call_arg], 0
    je .first
    mov al, ','
    call expect_op
.first:
    call compile_arg
    inc byte [call_arg]
    jmp .next
.done:
    push ds
    pop es
    ret

; One argument for a parameter of type arg_type (arg_array, arg_rec)
compile_arg:
    cmp byte [arg_array], 0
    je .scalar
    ; an array: name()
    cmp byte [tok], TK_NAME
    je .skip27
    jmp .bad
.skip27:
    call name_key
    call next
    mov al, '('
    call expect_op
    mov al, ')'
    call expect_op
    call find_array
    call array_operands
    push ds
    pop es
    mov al, [arr_op_kind]
    mov bl, OP_ADDR_G
    cmp al, 0
    je .addr
    mov bl, OP_ADDR_L
    cmp al, 1
    je .addr
    mov bl, OP_LDP_ADDR
.addr:
    mov al, bl
    mov bx, [arr_addr]
    jmp emit_op_word
.scalar:
    cmp byte [tok], TK_NAME         ; a variable of the same type: by reference
    jne .value
    call name_key                   ; (not a CONST or a FUNCTION)
    xor al, al
    call sym_find_scope
    jc .not_const
    cmp byte [es:di + N_KIND], NK_CONST
    jne .not_const
    push ds
    pop es
    jmp .value
.not_const:
    push ds
    pop es
    call find_function
    jnc .value
.variable:
    push ds
    pop es
    call lx_mark
    push word [cp]
    call compile_ref
    pop bx
    cmp byte [tok], TK_OP
    jne .check_end
    cmp byte [tok_op], ','
    je .ends
    cmp byte [tok_op], ')'
    je .ends
.check_end:
    call at_end
    jc .undo
.ends:
    mov al, [r_type]
    cmp al, [arg_type]
    jne .undo
    cmp al, TY_REC
    jne .by_ref
    mov ax, [r_rec]
    cmp ax, [arg_rec]
    jne .undo
.by_ref:
    add sp, 4                       ; the mark
    jmp ref_address
.undo:
    mov [cp], bx
    call lx_back
.value:
    mov al, [arg_type]
    cmp al, TY_REC
    je .bad
    call expr
    mov ah, [arg_type]
    call convert
    mov al, [arg_type]
    mov bl, OP_TEMPREF_I
    cmp al, TY_INT
    je .temp
    mov bl, OP_TEMPREF_L
    cmp al, TY_STR
    jne .temp
    mov bl, OP_TEMPREF_STR
.temp:
    mov al, bl
    jmp emit_byte
.bad:
    mov si, m_bad_argument
    call cerror

; OP_CALL to the SUB/FUNCTION [call_entry]: its address, or chained
emit_call:
    mov al, OP_CALL
    call emit_byte
    mov es, [seg_sym]
    mov di, [call_entry]
    mov bx, [es:di + N_X1]
    cmp byte [es:bx + 2], 0
    je .forward
    mov ax, [es:di + N_ADDR]
    push ds
    pop es
    jmp emit_word
.forward:
    mov ax, [es:bx]
    mov dx, [cp]
    mov [es:bx], dx
    push ds
    pop es
    jmp emit_word


; ---------- DEF FN, DEF SEG ----------

; DEF SEG [= n] / DEF FNname[(params)] = expression
st_def:
    call next
    cmp byte [tok], TK_KW
    jne .fn
    cmp byte [tok_kw], KW_SEG
    jne .fn
    call next
    mov al, '='
    call accept_op
    jc .default
    call expr
    mov ah, TY_LNG
    call convert
    mov al, OP_DEF_SEG
    jmp emit_byte
.default:
    mov al, OP_DEF_SEG_DATA
    jmp emit_byte
.fn:
    cmp byte [in_sub], 0
    je .module
    mov si, m_syntax
    call cerror
.module:
    mov al, OP_JMP                  ; the module's code jumps over it
    call emit_byte
    push word [cp]
    xor ax, ax
    call emit_word
    mov byte [tok_kw], KW_FUNCTION  ; the start of a FUNCTION...
    mov byte [deffn_mode], 1
    call st_sub_named
    mov al, '='
    call expect_op
    call expr                       ; ...whose result is the expression
    mov ah, [sub_type]
    call convert
    mov al, [sub_type]
    mov bl, al
    xor bh, bh
    mov al, [store_ops + (R_LOCAL - 1) * 4 + bx - 1]
    call emit_byte
    xor ax, ax
    call emit_word
    call end_sub_body
    mov byte [deffn_mode], 0
    pop bx
    mov ax, [cp]
    jmp patch_word

; ---------- screen and graphics ----------

st_screen:
    call next
    call optional_ints
    push ax
    mov al, OP_SCREEN
    call emit_byte
    pop ax
    jmp emit_byte

st_width:
    call next
    call optional_ints
    push ax
    mov al, OP_WIDTH
    call emit_byte
    pop ax
    jmp emit_byte

st_palette:
    call next
    call at_end
    jnc .reset
    call expr
    mov ah, TY_INT
    call convert
    mov al, ','
    call expect_op
    call expr
    mov ah, TY_LNG
    call convert
    mov al, OP_PALETTE
    jmp emit_byte
.reset:
    mov al, OP_PALETTE_RESET
    jmp emit_byte

; VIEW PRINT [top TO bottom]
st_view:
    call next
    mov al, KW_PRINT
    call expect_kw
    call at_end
    jnc .all
    call expr
    mov ah, TY_INT
    call convert
    mov al, KW_TO
    call expect_kw
    call expr
    mov ah, TY_INT
    call convert
    mov al, OP_VIEW_PRINT
    jmp emit_byte
.all:
    mov al, OP_PUSH_I
    xor bx, bx
    call emit_op_word
    mov al, OP_PUSH_I
    xor bx, bx
    call emit_op_word
    mov al, OP_VIEW_PRINT
    jmp emit_byte

; [STEP] (x, y): pushes x and y as INT. AL = 1 with STEP.
coord_pair:
    xor al, al
    push ax
    mov al, KW_STEP
    call accept_kw
    pop ax
    jc .paren
    mov al, 1
.paren:
    push ax
    mov al, '('
    call expect_op
    call expr
    mov ah, TY_INT
    call convert
    mov al, ','
    call expect_op
    call expr
    mov ah, TY_INT
    call convert
    mov al, ')'
    call expect_op
    pop ax
    ret

; ,color or nothing: pushes the color (or -1) as INT
optional_color:
    mov al, ','
    call accept_op
    jc .none
    cmp byte [tok], TK_OP
    jne .value
    cmp byte [tok_op], ','
    je .none_comma
.value:
    call at_end
    jnc .none
    call expr
    mov ah, TY_INT
    jmp convert
.none_comma:
.none:
    mov al, OP_PUSH_I
    mov bx, -1
    jmp emit_op_word

; PSET / PRESET [STEP](x, y)[, color]
st_pset:
    mov al, [tok_kw]
    push ax
    call next
    call coord_pair
    push ax
    call optional_color
    pop ax
    pop bx
    cmp bl, KW_PRESET
    jne .pset
    or al, 2
.pset:
    push ax
    mov al, OP_PSET
    call emit_byte
    pop ax
    jmp emit_byte

; LINE [[STEP](x1, y1)]-[STEP](x2, y2)[, [color][, [B|BF]]], or LINE INPUT
st_line:
    call next
    cmp byte [tok], TK_KW
    jne .graphics
    cmp byte [tok_kw], KW_INPUT
    jne .graphics
    jmp st_line_input
.graphics:
    xor cl, cl                      ; flags: 1 first STEP, 2 no first
    cmp byte [tok], TK_OP           ; point, 4 second STEP, 8 B, 16 BF
    jne .first
    cmp byte [tok_op], '-'
    jne .first
    or cl, 2
    push cx
    mov al, OP_PUSH_I               ; (the last point, at run time)
    xor bx, bx
    call emit_op_word
    mov al, OP_PUSH_I
    xor bx, bx
    call emit_op_word
    pop cx
    jmp .dash
.first:
    push cx
    call coord_pair
    pop cx
    or cl, al
.dash:
    push cx
    mov al, '-'
    call expect_op
    call coord_pair
    pop cx
    or al, al
    jz .no_step2
    or cl, 4
.no_step2:
    push cx
    call optional_color
    pop cx
    mov al, ','
    push cx
    call accept_op
    pop cx
    jc .emit
    cmp byte [tok], TK_NAME         ; B or BF
    jne .emit
    cmp word [tok_len], 1
    jne .bf
    cmp byte [tok_name], 'B'
    jne .bad
    or cl, 8
    jmp .box
.bf:
    cmp word [tok_len], 2
    jne .bad
    cmp word [tok_name], 'BF'
    jne .bad
    or cl, 16
.box:
    push cx
    call next
    pop cx
    mov al, ','                     ; a style: accepted and ignored
    push cx
    call accept_op
    jc .no_style
    call expr
    mov al, OP_POP1
    call emit_byte
.no_style:
    pop cx
.emit:
    push cx
    mov al, OP_LINE
    call emit_byte
    pop cx
    mov al, cl
    jmp emit_byte
.bad:
    mov si, m_syntax
    call cerror

; CIRCLE [STEP](x, y), r[, [color][, [start][, [end][, aspect]]]]
st_circle:
    call next
    call coord_pair
    push ax
    mov al, ','
    call expect_op
    call expr
    mov ah, TY_SNG
    call convert
    call optional_color
    pop cx                          ; CL: 1 STEP, 2 start, 4 end, 8 aspect
    mov ch, 2
.optional:
    mov al, ','
    push cx
    call accept_op
    pop cx
    jc .rest
    cmp byte [tok], TK_OP
    jne .value
    cmp byte [tok_op], ','
    je .missing
.value:
    push cx
    call expr
    mov ah, TY_SNG
    call convert
    pop cx
    or cl, ch
    jmp .next
.missing:
    push cx
    mov al, OP_PUSH_L
    xor bx, bx
    call emit_op_word
    xor ax, ax
    call emit_word
    pop cx
.next:
    shl ch, 1
    cmp ch, 16
    jb .optional
    jmp .emit
.rest:                              ; the ones not given: 0
    cmp ch, 16
    jae .emit
    push cx
    mov al, OP_PUSH_L
    xor bx, bx
    call emit_op_word
    xor ax, ax
    call emit_word
    pop cx
    shl ch, 1
    jmp .rest
.emit:
    push cx
    mov al, OP_CIRCLE
    call emit_byte
    pop cx
    mov al, cl
    jmp emit_byte

; PAINT [STEP](x, y)[, [paint][, border]]
st_paint:
    call next
    call coord_pair
    push ax
    call optional_color
    call optional_color
    mov al, OP_PAINT
    call emit_byte
    pop ax
    jmp emit_byte

; An array for GET / PUT: name or name(index): its far address
graphics_array:
    cmp byte [tok], TK_NAME
    je .name
    mov si, m_syntax
    call cerror
.name:
    call lx_mark
    call name_key
    call next
    cmp byte [tok], TK_OP
    jne .whole
    cmp byte [tok_op], '('
    jne .whole
    call lx_back
    call compile_ref
    cmp byte [r_kind], R_FAR
    je .ok
    jmp type_mismatch
.whole:
    add sp, 4                       ; (the mark is not needed)
    call find_array
    call array_operands
    push ds
    pop es
    cmp byte [arr_type], TY_STR
    jb .numeric
    jmp type_mismatch
.numeric:
    mov al, [arr_op_kind]
    add al, OP_AFIRST_G
    call emit_byte
    call emit_array_operands
.ok:
    ret

; GET (x1, y1)-(x2, y2), array
st_get:
    call next
    call coord_pair
    mov al, '-'
    call expect_op
    call coord_pair
    mov al, ','
    call expect_op
    call graphics_array
    mov al, OP_GET
    jmp emit_byte

; PUT (x, y), array[, PSET|PRESET|AND|OR|XOR]
st_put:
    call next
    call coord_pair
    mov al, ','
    call expect_op
    call graphics_array
    mov bl, 4                       ; XOR
    mov al, ','
    call accept_op
    jc .emit
    cmp byte [tok], TK_KW
    jne .bad
    mov al, [tok_kw]
    mov bl, 0
    cmp al, KW_PSET
    je .action
    mov bl, 1
    cmp al, KW_PRESET
    je .action
    mov bl, 2
    cmp al, KW_AND
    je .action
    mov bl, 3
    cmp al, KW_OR
    je .action
    mov bl, 4
    cmp al, KW_XOR
    jne .bad
.action:
    push bx
    call next
    pop bx
.emit:
    push bx
    mov al, OP_PUT
    call emit_byte
    pop ax
    jmp emit_byte
.bad:
    mov si, m_syntax
    call cerror

; ---------- sound ----------

st_sound:
    call next
    call expr
    mov ah, TY_SNG
    call convert
    mov al, ','
    call expect_op
    call expr
    mov ah, TY_SNG
    call convert
    mov al, OP_SOUND
    jmp emit_byte

st_play:
    call next
    call string_expr
    mov al, OP_PLAY
    jmp emit_byte

; An expression that must be a string
string_expr:
    call expr
    cmp al, TY_STR
    je .ok
    jmp type_mismatch
.ok:
    ret

; An expression converted to INT
int_expr:
    call expr
    mov ah, TY_INT
    jmp convert

; ---------- memory and ports ----------

st_poke:
    call next
    call expr
    mov ah, TY_LNG
    call convert
    mov al, ','
    call expect_op
    call int_expr
    mov al, OP_POKE
    jmp emit_byte

st_out:
    call next
    call expr
    mov ah, TY_LNG
    call convert
    mov al, ','
    call expect_op
    call int_expr
    mov al, OP_OUT
    jmp emit_byte

; SWAP a, b
st_swap:
    call next
    call compile_ref
    mov al, [r_type]
    cmp al, TY_REC
    jne .ok
    jmp type_mismatch
.ok:
    push ax
    call ref_address
    mov al, ','
    call expect_op
    cmp byte [tok], TK_NAME
    je .second
    mov si, m_syntax
    call cerror
.second:
    call compile_ref
    pop ax
    cmp al, [r_type]
    je .same
    jmp type_mismatch
.same:
    push ax
    call ref_address
    pop ax
    mov bl, OP_SWAP_2
    cmp al, TY_INT
    je .op
    mov bl, OP_SWAP_4
    cmp al, TY_STR
    jne .op
    mov bl, OP_SWAP_STR
.op:
    mov al, bl
    jmp emit_byte

; ---------- errors ----------

; ON ERROR GOTO label | 0, ON n GOTO / GOSUB labels
st_on:
    call next
    cmp byte [tok], TK_KW
    jne .computed
    cmp byte [tok_kw], KW_ERROR
    jne .computed
    call next
    mov al, KW_GOTO
    call expect_kw
    cmp byte [tok], TK_NUM          ; GOTO 0: off
    jne .label
    cmp word [tok_lo], 0
    jne .label
    call next
    mov al, OP_ON_ERROR
    xor bx, bx
    jmp emit_op_word
.label:
    mov al, OP_ON_ERROR
    call emit_byte
    jmp module_label_ref
.computed:
    call int_expr
    mov bl, OP_ON_GOTO
    mov al, KW_GOTO
    call accept_kw
    jnc .count
    mov al, KW_GOSUB
    call expect_kw
    mov bl, OP_ON_GOSUB
.count:
    mov al, bl
    call emit_byte
    mov ax, [cp]                    ; the count, fixed after the labels
    mov [on_count_at], ax
    xor al, al
    call emit_byte
    xor cl, cl
.target:
    push cx
    call emit_label_ref
    pop cx
    inc cl
    mov al, ','
    push cx
    call accept_op
    pop cx
    jnc .target
    push es
    mov es, [seg_code]
    mov bx, [on_count_at]
    mov [es:bx], cl
    pop es
    ret

; A label of the module (for ON ERROR, RESTORE) even inside a SUB
module_label_ref:
    mov al, [scope]
    push ax
    mov byte [scope], 0
    call emit_label_ref
    pop ax
    mov [scope], al
    ret

; RESUME [NEXT | 0 | label]
st_resume:
    call next
    call at_end
    jnc .same
    mov al, KW_NEXT
    call accept_kw
    jc .not_next
    mov al, OP_RESUME_NEXT
    jmp emit_byte
.not_next:
    cmp byte [tok], TK_NUM
    jne .label
    cmp word [tok_lo], 0
    jne .label
    call next
.same:
    mov al, OP_RESUME
    jmp emit_byte
.label:
    mov al, OP_RESUME_LABEL
    call emit_byte
    jmp module_label_ref

st_error:
    call next
    call int_expr
    mov al, OP_ERROR
    jmp emit_byte

; ---------- DATA, READ, RESTORE ----------

; Pass 1: the items of DATA go to the pool, each as a length and its text.
; Pass 2 skips them.
data_collect:
    push ds
    push es
    mov es, [seg_lines]
    mov di, [data_top_p1]
    mov si, [lx_pos]
    mov ds, [cs:seg_src]
.item:
    mov al, [si]                    ; leading blanks
    cmp al, ' '
    je .skip_blank
    cmp al, 9
    jne .start
.skip_blank:
    inc si
    jmp .item
.start:
    mov bx, di                      ; the length byte
    inc di
    cmp al, '"'
    jne .plain
    inc si
.quoted:
    mov al, [si]
    or al, al
    jz .item_end
    cmp al, 10
    je .item_end
    cmp al, 13
    je .item_end
    inc si
    cmp al, '"'
    je .after_quote
    call .store
    jmp .quoted
.after_quote:                       ; to the comma or the end
    mov al, [si]
    cmp al, ','
    je .item_end
    or al, al
    jz .item_end
    cmp al, 10
    je .item_end
    cmp al, ':'
    je .item_end
    inc si
    jmp .after_quote
.plain:
    mov al, [si]
    or al, al
    jz .trim
    cmp al, 10
    je .trim
    cmp al, 13
    je .trim
    cmp al, ','
    je .trim
    cmp al, ':'
    je .trim
    inc si
    call .store
    jmp .plain
.trim:                              ; trailing blanks
    mov ax, di
    dec ax
    cmp ax, bx
    je .item_end
    mov al, [es:di - 1]
    cmp al, ' '
    je .drop
    cmp al, 9
    jne .item_end
.drop:
    dec di
    jmp .trim
.item_end:
    mov ax, di
    sub ax, bx
    dec ax
    mov [es:bx], al
    cmp byte [si], ','
    jne .done
    inc si
    jmp .item
.done:
    pop es
    pop ds
    mov [data_top_p1], di
    cmp di, 0FFF0h
    jb .fits
    mov si, m_too_much_data
    call cerror
.fits:
    mov [lx_pos], si
    jmp next
.store:                             ; (pass 2 only skips the items)
    cmp byte [cs:pass], 2
    je .full
    cmp di, 0FFF0h
    jae .full
    stosb
.full:
    ret

; READ var, var...
st_read:
    call next
.var:
    call compile_ref
    mov al, [r_type]
    cmp al, TY_REC
    jne .ok
    jmp type_mismatch
.ok:
    mov bl, al
    xor bh, bh
    mov al, [read_ops + bx - 1]
    call emit_byte
    mov al, [r_type]
    call ref_store
    mov al, ','
    call accept_op
    jnc .var
    ret

; RESTORE [label]
st_restore:
    call next
    call at_end
    jnc .start
    cmp byte [tok], TK_NUM
    jne .name
    mov ax, [tok_lo]
    mov di, key_buf
    mov byte [di], '#'
    inc di
    push ds
    pop es
    call word_to_dec
    sub di, key_buf
    mov [key_len], di
    jmp .look
.name:
    mov byte [tok_suffix], 0
    call name_key
.look:
    call next
    xor al, al
    call sym_find_scope
    jc .undefined
    cmp byte [es:di + N_KIND], NK_LABEL
    jne .undefined
    mov bx, [es:di + N_X2]          ; the pool position (pass 1)
    push ds
    pop es
    mov al, OP_RESTORE
    jmp emit_op_word
.undefined:
    push ds
    pop es
    mov si, m_label_undefined
    call cerror
.start:
    mov al, OP_RESTORE
    mov bx, DATA_POOL
    jmp emit_op_word

; ---------- files ----------

; OPEN name FOR INPUT|OUTPUT|APPEND AS [#]n
st_open:
    call next
    call string_expr
    mov al, KW_FOR
    call expect_kw
    cmp byte [tok], TK_KW
    jne .bad
    mov al, [tok_kw]
    mov bl, 1
    cmp al, KW_INPUT
    je .mode
    mov bl, 2
    cmp al, KW_OUTPUT
    je .mode
    mov bl, 3
    cmp al, KW_APPEND
    jne .bad
.mode:
    push bx
    call next
    mov al, KW_AS
    call expect_kw
    mov al, '#'
    call accept_op
    call int_expr
    mov al, OP_OPEN
    call emit_byte
    pop ax
    jmp emit_byte
.bad:
    mov si, m_syntax
    call cerror

; CLOSE [[#]n, ...]
st_close:
    call next
    call at_end
    jnc .all
.one:
    mov al, '#'
    call accept_op
    call int_expr
    mov al, OP_CLOSE
    call emit_byte
    mov al, ','
    call accept_op
    jnc .one
    ret
.all:
    mov al, OP_CLOSE_ALL
    jmp emit_byte

; INPUT #n, var, var...
input_file:
    call next                       ; the #
    call int_expr
    mov al, ','
    call expect_op
    mov al, OP_INPUT_FILE
    call emit_byte
.var:
    call compile_ref
    mov al, [r_type]
    cmp al, TY_REC
    jne .ok
    jmp type_mismatch
.ok:
    mov bl, al
    xor bh, bh
    mov al, [input_ops + bx - 1]
    call emit_byte
    mov al, [r_type]
    call ref_store
    mov al, ','
    call accept_op
    jnc .var
    mov al, OP_INPUT_END
    xor bx, bx
    jmp emit_op_word

; LINE INPUT #n, var$
line_input_file:
    call next
    call int_expr
    mov al, ','
    call expect_op
    mov al, OP_LINE_INPUT_FILE
    call emit_byte
    call compile_ref
    cmp byte [r_type], TY_STR
    je .store
    jmp type_mismatch
.store:
    mov al, TY_STR
    jmp ref_store

; WRITE [#n,] items: numbers without spaces, strings in quotes, commas
st_write:
    call next
    mov al, OP_OUT_SCREEN
    cmp byte [tok], TK_OP
    jne .out
    cmp byte [tok_op], '#'
    jne .out
    call next
    call int_expr
    mov al, ','
    call expect_op
    mov al, OP_OUT_FILE
.out:
    call emit_byte
    call at_end
    jnc .end
.item:
    call expr
    mov bl, al
    xor bh, bh
    mov al, [write_ops + bx - 1]
    call emit_byte
    mov al, ','
    call accept_op
    jc .end
    mov al, OP_WRITE_COMMA
    call emit_byte
    jmp .item
.end:
    mov al, OP_PRINT_NL
    call emit_byte
    mov al, OP_OUT_SCREEN
    jmp emit_byte

st_kill:
    call next
    call string_expr
    mov al, OP_KILL
    jmp emit_byte

; ---------- arrays ----------

; REDIM: like DIM, but the array may already have its storage
st_redim:
    mov byte [dim_redim], 1
    call st_dim
    mov byte [dim_redim], 0
    ret

; ERASE a, b...
st_erase:
    call next
.one:
    cmp byte [tok], TK_NAME
    je .name
    mov si, m_syntax
    call cerror
.name:
    call name_key
    call next
    call find_array
    call array_operands
    push ds
    pop es
    mov al, [arr_op_kind]
    add al, OP_ERASE_G
    call emit_byte
    mov ax, [arr_addr]
    call emit_word
    mov al, ','
    call accept_op
    jnc .one
    ret

; OPTION BASE 0 | 1
st_option:
    call next
    mov al, KW_BASE
    call expect_kw
    cmp byte [tok], TK_NUM
    jne .bad
    mov al, [tok_lo]
    cmp al, 1
    ja .bad
    mov [option_base], al
    push ax
    call next
    pop ax
    mov al, OP_OPTION_BASE
    call emit_byte
    mov al, [option_base]
    jmp emit_byte
.bad:
    mov si, m_syntax
    call cerror

; Statements accepted and ignored: DECLARE (pass 1 did it), REM
st_skip:
.next:
    call at_end
    jnc .done
    call next
    jmp .next
.done:
    ret

; ======================================================================
; Built-in functions
; ======================================================================
;
; Each one is described in fn_specs: keyword, opcode, result type (0 =
; the type of its numeric argument, whose INT/LONG/SINGLE opcodes are
; consecutive), and its arguments:
;   S string   I integer   L long   F single
;   N numeric (picks the opcode)   X a character: a code or a string
;   A anything (dropped)   ] the rest is optional (MID$'s length)

builtin_function:
    mov al, [tok_kw]
    mov si, fn_specs
.find:
    mov ah, [si]
    or ah, ah
    jz .special
    cmp ah, al
    je .found
    add si, 3
.skip_spec:
    lodsb
    or al, al
    jnz .skip_spec
    mov al, [tok_kw]
    jmp .find
.special:
    cmp al, KW_INSTR
    jne .not_instr
    jmp fn_instr
.not_instr:
    cmp al, KW_RND
    jne .not_rnd
    jmp fn_rnd
.not_rnd:
    cmp al, KW_LBOUND
    jne .not_lbound
    jmp fn_bound
.not_lbound:
    cmp al, KW_UBOUND
    jne .not_ubound
    jmp fn_bound
.not_ubound:
    mov si, m_syntax
    call cerror
.found:
    mov al, [si + 1]
    mov [fn_op], al
    mov al, [si + 2]
    mov [fn_result], al
    add si, 3
    mov byte [fn_type], 0
    push si
    call next
    pop si
    cmp byte [si], 0
    je .emit
    mov al, '('
    push si
    call expect_op
    pop si
    xor cl, cl                      ; arguments done
.arg:
    lodsb
    or al, al
    jz .close
    cmp al, ']'
    jne .required
    cmp byte [tok], TK_OP           ; optional: absent if ')' follows
    jne .optional_given
    cmp byte [tok_op], ')'
    jne .optional_given
    mov al, OP_PUSH_I
    mov bx, 32767
    push si
    call emit_op_word
    pop si
    jmp .close
.optional_given:
    lodsb
.required:
    or cl, cl
    jz .first
    push ax
    push si
    push cx
    mov al, ','
    call expect_op
    pop cx
    pop si
    pop ax
.first:
    inc cl
    push si
    push cx
    call fn_argument
    pop cx
    pop si
    jmp .arg
.close:
    push si
    mov al, ')'
    call expect_op
    pop si
.emit:
    mov al, [fn_op]
    or al, al
    jz .no_op
    mov bl, [fn_type]               ; a numeric argument picks the opcode
    or bl, bl
    jz .op
    dec bl
    add al, bl
.op:
    call emit_byte
.no_op:
    mov al, [fn_result]
    or al, al
    jnz .ret
    mov al, [fn_type]
.ret:
    ret

; One argument of kind AL
fn_argument:
    push ax
    push word [fn_op]               ; (an argument may call a function too)
    mov al, [fn_type]
    push ax
    call expr
    pop bx
    mov [fn_type], bl
    pop word [fn_op]
    pop bx
    cmp bl, 'S'
    jne .not_s
    cmp al, TY_STR
    je .ok
    jmp type_mismatch
.not_s:
    cmp bl, 'A'
    jne .not_any
    mov bl, OP_POP1
    cmp al, TY_INT
    je .drop
    cmp al, TY_STR
    je .drop
    mov bl, OP_POP2
.drop:
    mov al, bl
    jmp emit_byte
.not_any:
    cmp bl, 'X'
    jne .not_x
    cmp al, TY_STR
    jne .x_number
    mov al, OP_ASC
    jmp emit_byte
.x_number:
    mov ah, TY_INT
    jmp convert
.not_x:
    cmp al, TY_STR
    jne .numeric
    jmp type_mismatch
.numeric:
    mov ah, TY_INT
    cmp bl, 'I'
    je .convert
    mov ah, TY_LNG
    cmp bl, 'L'
    je .convert
    mov ah, TY_SNG
    cmp bl, 'F'
    je .convert
    mov [fn_type], al               ; N
.ok:
    ret
.convert:
    jmp convert

; INSTR([start,] s1, s2)
fn_instr:
    call next
    mov al, '('
    call expect_op
    call expr
    cmp al, TY_STR
    je .no_start
    mov ah, TY_INT
    call convert
    mov al, ','
    call expect_op
    call string_expr
    jmp .second
.no_start:                          ; start 1, under the string
    mov al, OP_PUSH_I
    mov bx, 1
    call emit_op_word
    mov al, OP_SWAP_W
    call emit_byte
.second:
    mov al, ','
    call expect_op
    call string_expr
    mov al, ')'
    call expect_op
    mov al, OP_INSTR
    call emit_byte
    mov al, TY_INT
    ret

; RND [(n)]
fn_rnd:
    call next
    mov al, '('
    call accept_op
    jc .none
    call expr
    mov ah, TY_SNG
    call convert
    mov al, ')'
    call expect_op
    jmp .op
.none:
    mov al, OP_PUSH_L               ; 1.0
    xor bx, bx
    call emit_op_word
    mov ax, 3F80h
    call emit_word
.op:
    mov al, OP_RND
    call emit_byte
    mov al, TY_SNG
    ret

; LBOUND / UBOUND (array[, dimension])
fn_bound:
    mov al, [tok_kw]
    push ax
    call next
    mov al, '('
    call expect_op
    cmp byte [tok], TK_NAME
    je .name
    mov si, m_syntax
    call cerror
.name:
    call name_key
    call next
    call find_array
    call array_operands
    push ds
    pop es
    mov al, ','
    call accept_op
    jc .first
    call int_expr
    jmp .close
.first:
    mov al, OP_PUSH_I
    mov bx, 1
    call emit_op_word
.close:
    mov al, ')'
    call expect_op
    pop bx
    mov al, [arr_op_kind]
    add al, OP_LBOUND_G
    cmp bl, KW_LBOUND
    je .op
    add al, 3
.op:
    call emit_byte
    mov ax, [arr_addr]
    call emit_word
    mov al, TY_INT
    ret

; ======================================================================
; Saving the lexer position on the stack (nestable)
; ======================================================================

; Pushes (under the return address) where the current token starts
lx_mark:
    pop bx
    push word [lx_line]
    push word [tok_start]
    jmp bx

; Back to the token saved by lx_mark (and drops the mark)
lx_back:
    pop bx
    pop word [lx_pos]
    pop word [lx_line]
    push bx
    jmp next

; The statement's strings are freed by the next OP_STMT
temps_free:
temps_reset_mark:
mark_strings:
    ret

; ======================================================================
; The machine
; ======================================================================
;
; While it runs: DS:SI = the next instruction (DS = the code segment),
; ES = the data segment, BP = the frame of the SUB running (0 in the
; module), SS:SP = the stack, which holds the values being computed: an
; INT is one word, a LONG or SINGLE two (the low word on top), a string
; the address of its descriptor in the data segment, a far address two
; words (the offset on top). The machine's own variables are reached
; through CS.

GOSUB_MARK  equ 0C5B1h

run:
    call rt_init
    mov byte [running], 1
    mov [run_sp], sp
    mov ds, [cs:seg_code]
    mov es, [cs:seg_data]
    xor si, si
    xor bp, bp
next_op:
    lodsb
    xor ah, ah
    mov bx, ax
    shl bx, 1
    jmp [cs:optable + bx]

; Data segment, strings and arrays for a new run
rt_init:
    mov es, [seg_data]              ; all variables start at 0 / ""
    xor di, di
    mov cx, 8000h
    xor ax, ax
    rep stosw
    mov ax, [data_top]
    inc ax
    and al, 0FEh
    mov [temp_base], ax
    mov [temp_top], ax
    mov [temp_area], ax
    add ax, TEMP_COUNT * 4
    mov [temp_end], ax
    mov [ntemp_base], ax
    mov [ntemp_top], ax
    add ax, NTEMP_COUNT * 4
    mov [ntemp_end], ax
    mov [frame_base], ax
    mov [frame_top], ax
    mov word [sarr_top], 0FFF0h
    mov word [sarr_pinned], 0FFF0h
    mov ax, [str_const_top]
    inc ax
    and al, 0FEh
    mov [heap_start], ax
    mov [str_top], ax
    mov ax, [arena_start]
    mov [arena_top], ax
    mov [arena_pinned], ax
    mov word [data_ptr], DATA_POOL
    mov ax, [seg_data]
    mov [def_seg], ax
    mov word [rnd_seed], 0
    mov word [rnd_seed + 2], 5
    mov byte [rt_base], 0
    mov word [on_error], 0
    mov byte [in_handler], 0
    mov byte [out_file], 0
    mov word [module_sp], sp
    mov byte [play_octave], 4
    mov byte [play_length], 4
    mov byte [play_tempo], 120
    mov byte [play_style], 7
    push ds
    pop es
    ret

; ---------- control ----------

op_end:
    mov sp, [cs:run_sp]
    push cs
    pop ds
    push cs
    pop es
    call scr_end
    ret

op_stmt:
    lea ax, [si - 1]
    mov [cs:stmt_ip], ax
    mov [cs:stmt_sp], sp
    or bp, bp
    jnz .in_sub
    mov [cs:module_ip], ax
    mov [cs:module_sp], sp
.in_sub:
    mov ax, [cs:ntemp_base]
    mov [cs:ntemp_top], ax
    dec byte [cs:break_count]       ; Ctrl+Break, now and then
    jnz .no_break
    call check_break
.no_break:
    mov ax, [cs:temp_base]
    cmp ax, [cs:temp_top]
    jne .free
    jmp next_op
.free:
    call temps_release
    jmp next_op

op_jmp:
    lodsw
    mov si, ax
    jmp next_op

op_jz_i:
    pop cx
    lodsw
    jcxz .jump
    jmp next_op
.jump:
    mov si, ax
    jmp next_op

op_jnz_i:
    pop cx
    lodsw
    jcxz .no
    mov si, ax
.no:
    jmp next_op

op_jz_l:
    pop cx
    pop dx
    lodsw
    or cx, dx
    jz .jump
    jmp next_op
.jump:
    mov si, ax
    jmp next_op

op_jnz_l:
    pop cx
    pop dx
    lodsw
    or cx, dx
    jz .no
    mov si, ax
.no:
    jmp next_op

op_jz_s:
    pop cx
    pop dx
    lodsw
    and dh, 7Fh                     ; -0 is 0
    or cx, dx
    jz .jump
    jmp next_op
.jump:
    mov si, ax
    jmp next_op

op_jnz_s:
    pop cx
    pop dx
    lodsw
    and dh, 7Fh
    or cx, dx
    jz .no
    mov si, ax
.no:
    jmp next_op

op_gosub:
    lodsw
    push si
    mov bx, GOSUB_MARK
    push bx
    mov si, ax
    jmp next_op

op_return:
    pop ax
    cmp ax, GOSUB_MARK
    je .ok
    mov al, E_RETURN
    jmp rt_error
.ok:
    pop si
    jmp next_op

; ON n GOTO / GOSUB: count, then the addresses
op_on_goto:
    xor dx, dx
    jmp on_common
op_on_gosub:
    mov dx, 1
on_common:
    pop bx
    lodsb
    xor ah, ah
    mov cx, ax                      ; past the table
    shl cx, 1
    add cx, si
    dec bx
    cmp bx, ax
    jae .none                       ; 0 or more than the count: next
    shl bx, 1
    mov ax, [si + bx]
    or dx, dx
    jz .go
    push cx
    mov bx, GOSUB_MARK
    push bx
.go:
    mov si, ax
    jmp next_op
.none:
    mov si, cx
    jmp next_op

op_push_i:
    lodsw
    push ax
    jmp next_op

op_push_l:
    lodsw
    mov bx, ax
    lodsw
    push ax
    push bx
    jmp next_op

op_pop1:
    pop ax
    jmp next_op

op_pop2:
    add sp, 4
    jmp next_op

op_swap_w:
    pop ax
    pop bx
    push ax
    push bx
    jmp next_op

op_nop:
    jmp next_op

op_bad:
    mov al, E_SYNTAX
    jmp rt_error

; ---------- variables ----------

op_ld_g_i:
    lodsw
    mov bx, ax
    push word [es:bx]
    jmp next_op
op_ld_g_l:
    lodsw
    mov bx, ax
    push word [es:bx + 2]
    push word [es:bx]
    jmp next_op
op_ld_g_str:
    lodsw
    push ax
    jmp next_op

op_ld_l_i:
    lodsw
    add ax, bp
    mov bx, ax
    push word [es:bx]
    jmp next_op
op_ld_l_l:
    lodsw
    add ax, bp
    mov bx, ax
    push word [es:bx + 2]
    push word [es:bx]
    jmp next_op
op_ld_l_str:
    lodsw
    add ax, bp
    push ax
    jmp next_op

op_ld_p_i:
    lodsw
    add ax, bp
    mov bx, ax
    les bx, [es:bx]
    push word [es:bx]
    mov es, [cs:seg_data]
    jmp next_op
op_ld_p_l:
    lodsw
    add ax, bp
    mov bx, ax
    les bx, [es:bx]
    push word [es:bx + 2]
    push word [es:bx]
    mov es, [cs:seg_data]
    jmp next_op
op_ld_p_str:
    lodsw
    add ax, bp
    mov bx, ax
    push word [es:bx]
    jmp next_op

op_ld_f_i:
    pop bx
    pop es
    push word [es:bx]
    mov es, [cs:seg_data]
    jmp next_op
op_ld_f_l:
    pop bx
    pop es
    push word [es:bx + 2]
    push word [es:bx]
    mov es, [cs:seg_data]
    jmp next_op

op_st_g_i:
    lodsw
    mov bx, ax
    pop word [es:bx]
    jmp next_op
op_st_g_l:
    lodsw
    mov bx, ax
    pop word [es:bx]
    pop word [es:bx + 2]
    jmp next_op
op_st_g_str:
    lodsw
    mov di, ax
    pop bx
    call str_assign
    jmp next_op

op_st_l_i:
    lodsw
    add ax, bp
    mov bx, ax
    pop word [es:bx]
    jmp next_op
op_st_l_l:
    lodsw
    add ax, bp
    mov bx, ax
    pop word [es:bx]
    pop word [es:bx + 2]
    jmp next_op
op_st_l_str:
    lodsw
    add ax, bp
    mov di, ax
    pop bx
    call str_assign
    jmp next_op

op_st_p_i:
    lodsw
    add ax, bp
    mov bx, ax
    les bx, [es:bx]
    pop word [es:bx]
    mov es, [cs:seg_data]
    jmp next_op
op_st_p_l:
    lodsw
    add ax, bp
    mov bx, ax
    les bx, [es:bx]
    pop word [es:bx]
    pop word [es:bx + 2]
    mov es, [cs:seg_data]
    jmp next_op
op_st_p_str:
    lodsw
    add ax, bp
    mov bx, ax
    mov di, [es:bx]
    pop bx
    call str_assign
    jmp next_op

op_st_f_i:
    pop ax
    pop bx
    pop es
    mov [es:bx], ax
    mov es, [cs:seg_data]
    jmp next_op
op_st_f_l:
    pop ax
    pop dx
    pop bx
    pop es
    mov [es:bx], ax
    mov [es:bx + 2], dx
    mov es, [cs:seg_data]
    jmp next_op
op_st_d_str:
    pop bx
    pop di
    call str_assign
    jmp next_op

; far addresses (for parameters, SWAP, records)
op_addr_g:
    lodsw
    push word [cs:seg_data]
    push ax
    jmp next_op
op_addr_l:
    lodsw
    add ax, bp
    push word [cs:seg_data]
    push ax
    jmp next_op
op_ldp_addr:
    lodsw
    add ax, bp
    mov bx, ax
    push word [es:bx + 2]
    push word [es:bx]
    jmp next_op
op_near_addr:
    pop ax
    push word [cs:seg_data]
    push ax
    jmp next_op
op_add_off:
    lodsw
    pop bx
    add ax, bx
    push ax
    jmp next_op

; ---------- conversions ----------

op_i2l:
    pop ax
    cwd
    push dx
    push ax
    jmp next_op
op_i2s:
    pop ax
    call i2f
    push dx
    push ax
    jmp next_op
op_l2i:
    pop ax
    pop dx
    call long_to_int
    push ax
    jmp next_op
op_l2s:
    pop ax
    pop dx
    call l2f
    push dx
    push ax
    jmp next_op
op_s2i:
    pop ax
    pop dx
    call f2l_round
    call long_to_int
    push ax
    jmp next_op
op_s2l:
    pop ax
    pop dx
    call f2l_round
    push dx
    push ax
    jmp next_op
op_i2l_u2:
    pop cx
    pop bx
    pop ax
    cwd
    push dx
    push ax
    push bx
    push cx
    jmp next_op
op_i2s_u2:
    pop cx
    pop bx
    pop ax
    call i2f
    push dx
    push ax
    push bx
    push cx
    jmp next_op
op_l2s_u2:
    pop cx
    pop bx
    pop ax
    pop dx
    call l2f
    push dx
    push ax
    push bx
    push cx
    jmp next_op

; DX:AX -> AX, or overflow
long_to_int:
    push dx
    push ax
    cwd
    pop ax
    pop bx
    cmp dx, bx
    jne err_overflow
    ret

err_overflow:
    mov al, E_OVERFLOW
    jmp rt_error
err_divzero:
    mov al, E_DIVZERO
    jmp rt_error
err_func:
    mov al, E_FUNC
    jmp rt_error
err_subscript:
    mov al, E_SUBSCRIPT
    jmp rt_error
err_memory:
    mov al, E_MEMORY
    jmp rt_error

; ---------- arithmetic ----------

op_add_i:
    pop bx
    pop ax
    add ax, bx
    jo err_overflow
    push ax
    jmp next_op
op_add_l:
    pop bx
    pop cx
    pop ax
    pop dx
    add ax, bx
    adc dx, cx
    jo err_overflow
    push dx
    push ax
    jmp next_op
op_add_s:
    pop bx
    pop cx
    pop ax
    pop dx
    call fadd
    push dx
    push ax
    jmp next_op

op_sub_i:
    pop bx
    pop ax
    sub ax, bx
    jo err_overflow
    push ax
    jmp next_op
op_sub_l:
    pop bx
    pop cx
    pop ax
    pop dx
    sub ax, bx
    sbb dx, cx
    jo err_overflow
    push dx
    push ax
    jmp next_op
op_sub_s:
    pop bx
    pop cx
    pop ax
    pop dx
    xor ch, 80h
    call fadd
    push dx
    push ax
    jmp next_op

op_mul_i:
    pop bx
    pop ax
    imul bx
    jo err_overflow
    push ax
    jmp next_op
op_mul_l:
    pop bx
    pop cx
    pop ax
    pop dx
    call lmul
    push dx
    push ax
    jmp next_op
op_mul_s:
    pop bx
    pop cx
    pop ax
    pop dx
    call fmul
    push dx
    push ax
    jmp next_op

op_div_s:
    pop bx
    pop cx
    pop ax
    pop dx
    call fdiv
    push dx
    push ax
    jmp next_op

op_pow_s:
    pop bx
    pop cx
    pop ax
    pop dx
    call fpow
    push dx
    push ax
    jmp next_op

op_mod_i:
    pop bx
    pop ax
    or bx, bx
    jnz .skip26
    jmp err_divzero
.skip26:
    cmp bx, -1
    je .zero
    cwd
    idiv bx
    push dx
    jmp next_op
.zero:
    mov ax, 0
    push ax
    jmp next_op
op_mod_l:
    pop bx
    pop cx
    pop ax
    pop dx
    call ldiv
    push cx
    push bx
    jmp next_op

op_idiv_i:
    pop bx
    pop ax
    or bx, bx
    jnz .skip25
    jmp err_divzero
.skip25:
    cmp bx, -1
    je .negate
    cwd
    idiv bx
    push ax
    jmp next_op
.negate:
    neg ax
    jno .skip24
    jmp err_overflow
.skip24:
    push ax
    jmp next_op
op_idiv_l:
    pop bx
    pop cx
    pop ax
    pop dx
    call ldiv
    push dx
    push ax
    jmp next_op

op_neg_i:
    pop ax
    neg ax
    jno .skip23
    jmp err_overflow
.skip23:
    push ax
    jmp next_op
op_neg_l:
    pop ax
    pop dx
    neg dx
    neg ax
    sbb dx, 0
    jno .skip22
    jmp err_overflow
.skip22:
    push dx
    push ax
    jmp next_op
op_neg_s:
    pop ax
    pop dx
    mov cx, dx
    and ch, 7Fh
    or cx, ax
    jz .zero
    xor dh, 80h
.zero:
    push dx
    push ax
    jmp next_op

; var, limit, step -> -1 while the loop goes on
op_fortest_i:
    pop cx
    pop bx
    pop ax
    or cx, cx
    js .down
    cmp ax, bx
    jg .end
.go:
    mov ax, -1
    push ax
    jmp next_op
.down:
    cmp ax, bx
    jge .go
.end:
    mov ax, 0
    push ax
    jmp next_op

op_fortest_l:
    pop ax                          ; the step: only its sign
    pop cx
    pop bx                          ; limit in CX:BX... (lo, hi)
    pop di
    pop ax                          ; var in DX:AX
    pop dx
    or cx, cx                       ; (CX = the step's high word)
    js .down
    cmp dx, di                      ; var <= limit ?
    jl .go
    jg .end
    cmp ax, bx
    jbe .go
    jmp .end
.down:
    cmp dx, di
    jg .go
    jl .end
    cmp ax, bx
    jae .go
.end:
    mov ax, 0
    push ax
    jmp next_op
.go:
    mov ax, -1
    push ax
    jmp next_op

op_fortest_s:
    pop ax
    pop di                          ; the step's high word (its sign)
    pop bx
    pop cx                          ; the limit in CX:BX
    pop ax
    pop dx                          ; the variable in DX:AX
    push di
    call fcmp                       ; AL = 0 less, 1 equal, 2 greater
    pop di
    test di, di
    js .down
    cmp al, 2
    je .end
.go:
    mov ax, -1
    push ax
    jmp next_op
.down:
    or al, al
    jnz .go
.end:
    mov ax, 0
    push ax
    jmp next_op

; ---------- comparisons ----------
;
; The result of a comparison as AL = 0 (less), 1 (equal), 2 (greater);
; the condition (the operand) picks which ones are true.

CC_EQ       equ 0
CC_NE       equ 1
CC_LT       equ 2
CC_GT       equ 3
CC_LE       equ 4
CC_GE       equ 5

op_cmp_i:
    pop bx
    pop ax
    cmp ax, bx
    mov al, 1
    je cmp_finish
    mov al, 0
    jl cmp_finish
    mov al, 2
    jmp cmp_finish

op_cmp_l:
    pop bx
    pop cx
    pop ax
    pop dx
    cmp dx, cx
    jl .less
    jg .greater
    cmp ax, bx
    jb .less
    ja .greater
    mov al, 1
    jmp cmp_finish
.less:
    mov al, 0
    jmp cmp_finish
.greater:
    mov al, 2
    jmp cmp_finish

op_cmp_s:
    pop bx
    pop cx
    pop ax
    pop dx
    call fcmp
    jmp cmp_finish

op_cmp_str:
    pop bx
    pop di
    call str_compare
cmp_finish:
    mov cl, al
    mov ah, 1
    shl ah, cl                      ; 1, 2 or 4
    lodsb
    mov bl, al
    xor bh, bh
    test ah, [cs:cc_masks + bx]
    jz .false
    mov ax, -1
    push ax
    jmp next_op
.false:
    mov ax, 0
    push ax
    jmp next_op

cc_masks    db 2, 5, 1, 4, 3, 6

; ---------- logic ----------

op_and_i:
    pop bx
    pop ax
    and ax, bx
    push ax
    jmp next_op
op_and_l:
    pop bx
    pop cx
    pop ax
    pop dx
    and ax, bx
    and dx, cx
    push dx
    push ax
    jmp next_op
op_or_i:
    pop bx
    pop ax
    or ax, bx
    push ax
    jmp next_op
op_or_l:
    pop bx
    pop cx
    pop ax
    pop dx
    or ax, bx
    or dx, cx
    push dx
    push ax
    jmp next_op
op_xor_i:
    pop bx
    pop ax
    xor ax, bx
    push ax
    jmp next_op
op_xor_l:
    pop bx
    pop cx
    pop ax
    pop dx
    xor ax, bx
    xor dx, cx
    push dx
    push ax
    jmp next_op
op_eqv_i:
    pop bx
    pop ax
    xor ax, bx
    not ax
    push ax
    jmp next_op
op_eqv_l:
    pop bx
    pop cx
    pop ax
    pop dx
    xor ax, bx
    xor dx, cx
    not ax
    not dx
    push dx
    push ax
    jmp next_op
op_imp_i:
    pop bx
    pop ax
    not ax
    or ax, bx
    push ax
    jmp next_op
op_imp_l:
    pop bx
    pop cx
    pop ax
    pop dx
    not ax
    not dx
    or ax, bx
    or dx, cx
    push dx
    push ax
    jmp next_op
op_not_i:
    pop ax
    not ax
    push ax
    jmp next_op
op_not_l:
    pop ax
    pop dx
    not ax
    not dx
    push dx
    push ax
    jmp next_op

; ---------- 32-bit integers ----------

; DX:AX * CX:BX (signed) -> DX:AX, or overflow
lmul:
    push si
    push di
    xor si, si                      ; SI = the sign of the result
    or dx, dx
    jns .a_pos
    not si
    neg dx
    neg ax
    sbb dx, 0
.a_pos:
    or cx, cx
    jns .b_pos
    not si
    neg cx
    neg bx
    sbb cx, 0
.b_pos:
    or dx, dx                       ; both high words: too big
    jz .a_small
    or cx, cx
    jnz .over
    xchg ax, bx                     ; make A the one with the high word 0
    xchg dx, cx
.a_small:
    ; A = AX (16 bits), B = CX:BX
    mov di, ax
    mul bx                          ; AX * BL..
    push dx
    push ax
    mov ax, di
    mul cx
    or dx, dx
    jnz .over_pop
    pop bx                          ; low word
    pop dx
    add dx, ax
    jc .over
    mov ax, bx
    test dx, 8000h                  ; must fit in 31 bits (or be -2^31)
    jz .sign
    or si, si
    jz .over
    cmp dx, 8000h
    jne .over
    or ax, ax
    jnz .over
.sign:
    or si, si
    jz .done
    neg dx
    neg ax
    sbb dx, 0
.done:
    pop di
    pop si
    ret
.over_pop:
    add sp, 4
.over:
    pop di
    pop si
    jmp err_overflow

; DX:AX / CX:BX (signed): quotient DX:AX, remainder CX:BX (with the sign
; of the dividend)
ldiv:
    push si
    push di
    push bp
    mov si, cx
    or si, bx
    jnz .not_zero
    pop bp
    pop di
    pop si
    jmp err_divzero
.not_zero:
    xor si, si                      ; bit 0: negate the quotient, bit 1:
    or dx, dx                       ; negate the remainder
    jns .a_pos
    xor si, 3
    neg dx
    neg ax
    sbb dx, 0
.a_pos:
    or cx, cx
    jns .b_pos
    xor si, 1
    neg cx
    neg bx
    sbb cx, 0
.b_pos:
    ; unsigned 32 / 32, bit by bit: DX:AX dividend, CX:BX divisor
    xor di, di                      ; remainder in DI:BP
    xor bp, bp
    push si
    mov si, 32
.bit:
    shl ax, 1
    rcl dx, 1
    rcl bp, 1
    rcl di, 1
    cmp di, cx
    jb .next
    ja .sub
    cmp bp, bx
    jb .next
.sub:
    sub bp, bx
    sbb di, cx
    inc ax
.next:
    dec si
    jnz .bit
    pop si
    test si, 1
    jz .q_pos
    neg dx
    neg ax
    sbb dx, 0
.q_pos:
    mov cx, di
    mov bx, bp
    test si, 2
    jz .r_pos
    neg cx
    neg bx
    sbb cx, 0
.r_pos:
    cmp dx, 8000h                   ; -2^31 / -1
    jne .ok
    or ax, ax
    jnz .ok
    test si, 1
    jnz .ok
    pop bp
    pop di
    pop si
    jmp err_overflow
.ok:
    pop bp
    pop di
    pop si
    ret

; ---------- SUB and FUNCTION calls ----------
;
; A call: the arguments (far addresses, the first one deepest), then
; CALL, whose ENTER moves them into a new frame. The frame is in the data
; segment, above the caller's; the caller's state goes on the stack.

op_call:
    lodsw
    push si
    mov si, ax
    jmp next_op

; ENTER size, number of parameters, flags (1 FUNCTION, 2 strings)
op_enter:
    lodsw
    mov [cs:enter_size], ax
    lodsb
    mov dl, al
    lodsb
    mov dh, al
    pop word [cs:enter_ret]
    cmp sp, STACK_LIMIT
    jae .skip21
    jmp .stack
.skip21:
    mov di, [cs:frame_top]
    mov bx, di
    add bx, [cs:enter_size]
    jc .full
    cmp bx, [cs:sarr_top]
    jae .full
    mov cx, [cs:enter_size]
    shr cx, 1
    xor ax, ax
    rep stosw
    mov bx, [cs:frame_top]          ; the new frame
    xor ax, ax
    test dh, 1
    jz .no_result
    mov al, 4
.no_result:
    mov cl, dl
    xor ch, ch
    jcxz .args_done
    shl cx, 1
    shl cx, 1
    add ax, cx
    add ax, bx
    mov di, ax                      ; past the last parameter
    mov cl, dl
.arg:
    sub di, 4
    pop word [es:di]
    pop word [es:di + 2]
    loop .arg
.args_done:
    push word [cs:enter_ret]
    push bp
    push word [cs:temp_base]
    push word [cs:ntemp_base]
    push word [cs:arena_top]
    push word [cs:sarr_top]
    push dx
    mov bp, bx
    add bx, [cs:enter_size]
    mov [cs:frame_top], bx
    mov ax, [cs:temp_top]
    mov [cs:temp_base], ax
    mov ax, [cs:ntemp_top]
    mov [cs:ntemp_base], ax
    jmp next_op
.full:
    jmp err_memory
.stack:
    mov al, E_STACK
    jmp rt_error

op_leave:
    mov byte [cs:leave_kind], 0
    jmp leave_go
op_leave_i:
    mov ax, [es:bp]
    mov [cs:leave_lo], ax
    mov byte [cs:leave_kind], 1
    jmp leave_go
op_leave_l:
    mov ax, [es:bp]
    mov [cs:leave_lo], ax
    mov ax, [es:bp + 2]
    mov [cs:leave_hi], ax
    mov byte [cs:leave_kind], 2
    jmp leave_go
op_leave_str:
    mov byte [cs:leave_kind], 4
leave_go:
    call temps_release              ; the callee's temporaries
    mov ax, [cs:ntemp_base]
    mov [cs:ntemp_top], ax
    cmp byte [cs:leave_kind], 4
    jne .not_str
    ; the result moves to a new temporary of the caller
    call temp_new                   ; DI = the descriptor
    mov ax, [es:bp]
    mov [es:di], ax
    mov cx, [es:bp + 2]
    mov [es:di + 2], cx
    mov word [es:bp + 2], 0
    mov [cs:leave_lo], di
    jcxz .not_str
    cmp ax, [cs:heap_start]
    jb .not_str
    push ds
    mov ds, [cs:seg_str]
    mov bx, ax
    mov [bx - 2], di
    pop ds
.not_str:
    pop dx                          ; flags
    test dh, 2
    jz .no_strings
    mov bx, sp
    mov ax, [ss:bx]                 ; the caller's sarr_top
    call frame_strings_free
.no_strings:
    pop ax                          ; sarr_top
    cmp ax, [cs:sarr_pinned]        ; (not below a module array made
    jbe .sarr                       ; while in the SUB)
    mov ax, [cs:sarr_pinned]
.sarr:
    mov [cs:sarr_top], ax
    pop ax
    cmp ax, [cs:arena_pinned]
    jae .arena
    mov ax, [cs:arena_pinned]
.arena:
    mov [cs:arena_top], ax
    pop word [cs:ntemp_base]
    pop word [cs:temp_base]
    mov [cs:frame_top], bp
    pop bp
    pop si
    mov al, [cs:leave_kind]
    or al, al
    jz .done
    cmp al, 1
    je .int
    cmp al, 2
    je .long
    push word [cs:leave_lo]         ; the string's descriptor
    jmp next_op
.long:
    push word [cs:leave_hi]
.int:
    push word [cs:leave_lo]
.done:
    jmp next_op

op_args:
    jmp next_op

; A value as an argument: kept in a temporary, its address passed
op_tempref_i:
    pop ax
    call ntemp_new
    mov [es:bx], ax
    push word [cs:seg_data]
    push bx
    jmp next_op
op_tempref_l:
    pop ax
    pop dx
    call ntemp_new
    mov [es:bx], ax
    mov [es:bx + 2], dx
    push word [cs:seg_data]
    push bx
    jmp next_op
op_tempref_str:
    pop bx
    call str_own_temp               ; BX = a temporary with the string
    push word [cs:seg_data]
    push bx
    jmp next_op

; BX = a free numeric temporary
ntemp_new:
    mov bx, [cs:ntemp_top]
    cmp bx, [cs:ntemp_end]
    jae .full
    add word [cs:ntemp_top], 4
    ret
.full:
    mov al, E_COMPLEX
    jmp rt_error

; ---------- constants while compiling ----------

; Runs the code at BX (a CONST's expression) up to CONST_END
vm_eval:
    push si
    push di
    push bp
    push ds
    push es
    mov [eval_sp], sp
    mov byte [in_eval], 1
    mov es, [seg_data]
    mov ds, [seg_code]
    mov si, bx
    xor bp, bp
    jmp next_op
op_const_end1:
    pop ax
    cwd
    jmp eval_done
op_const_end2:
    pop ax
    pop dx
eval_done:
    mov [cs:const_lo], ax
    mov [cs:const_hi], dx
    mov sp, [cs:eval_sp]
    mov byte [cs:in_eval], 0
    pop es
    pop ds
    pop bp
    pop di
    pop si
    ret

; ======================================================================
; Runtime errors
; ======================================================================

; AL = the error number. With ON ERROR GOTO, the handler runs (in the
; module: a SUB that failed is left); otherwise the message and the end.
rt_error:
    push cs
    pop ds
    cld
    cmp byte [in_eval], 0
    je .running
    mov byte [in_eval], 0           ; a CONST that cannot be computed
    mov si, m_bad_const
    jmp cerror
.running:
    cmp byte [running], 0           ; while compiling: a number too large
    jne .run_time
    mov si, m_overflow
    jmp cerror
.run_time:
    xor ah, ah
    mov [err_code], ax
    cmp al, E_BREAK                 ; Ctrl+C cannot be trapped
    je .fatal
    cmp word [on_error], 0
    je .fatal
    cmp byte [in_handler], 0
    jne .fatal
    mov byte [in_handler], 1
    mov ax, [stmt_ip]
    or bp, bp
    jz .module
    mov ax, [module_ip]             ; the statement that called the SUB
.module:
    mov [err_ip], ax
    mov sp, [module_sp]
    xor bp, bp
    mov ax, [frame_base]
    mov [frame_top], ax
    mov ax, [temp_area]
    mov [temp_base], ax
    mov ax, [ntemp_end]
    sub ax, NTEMP_COUNT * 4
    mov [ntemp_base], ax
    mov [ntemp_top], ax
    mov byte [out_file], 0
    mov si, [on_error]
    mov es, [seg_data]
    mov ds, [seg_code]
    jmp next_op
.fatal:
    mov sp, [run_sp]
    push cs
    pop es
    call scr_error_mode             ; text mode, at a new line
    mov ax, [err_code]
    call error_message              ; SI = its text
    call con_puts
    mov ax, [stmt_ip]
    call line_of                    ; AX = its line
    or ax, ax
    jz .no_line
    push ax
    mov si, m_in_line
    call con_puts
    pop ax
    call con_number
.no_line:
    mov si, m_crlf
    call con_puts
    call files_close_all
    mov ax, 4C01h
    int 21h

; AX = an error number -> SI = its message
error_message:
    mov si, error_texts
.next:
    mov bl, [si]
    or bl, bl
    jz .unknown
    inc si
    cmp bl, al
    je .found
.skip:
    lodsb
    or al, al
    jnz .skip
    mov al, [err_code]
    jmp .next
.found:
    ret
.unknown:
    mov si, m_unprintable
    ret

; AX = a code address -> AX = the line of its statement (0 if none)
line_of:
    push es
    mov es, [seg_lines]
    xor bx, bx
    mov cx, [line_count]
    xor dx, dx
    jcxz .done
.entry:
    cmp [es:bx], ax
    ja .done
    mov dx, [es:bx + 2]
    add bx, 4
    loop .entry
.done:
    mov ax, dx
    pop es
    ret

; AX = a code address -> AX = the address of the next statement
next_stmt_of:
    push es
    mov es, [cs:seg_lines]
    xor bx, bx
    mov cx, [cs:line_count]
    jcxz .none
.entry:
    cmp [es:bx], ax
    ja .found
    add bx, 4
    loop .entry
.none:
    pop es
    mov ax, -1
    ret
.found:
    mov ax, [es:bx]
    pop es
    ret

op_on_error:
    lodsw
    mov [cs:on_error], ax
    jmp next_op

op_error:
    pop ax
    or ah, ah
    jnz .bad
    or al, al
    jz .bad
    jmp rt_error
.bad:
    jmp err_func

op_resume:
    call resume_check
    mov si, [cs:err_ip]
    jmp next_op
op_resume_next:
    call resume_check
    mov ax, [cs:err_ip]
    call next_stmt_of
    cmp ax, -1
    jne .found
    jmp op_end
.found:
    mov si, ax
    jmp next_op
op_resume_label:
    call resume_check
    lodsw
    mov si, ax
    jmp next_op

resume_check:
    cmp byte [cs:in_handler], 0
    je .bad
    mov byte [cs:in_handler], 0
    ret
.bad:
    mov al, E_RESUME
    jmp rt_error

; ======================================================================
; Arrays
; ======================================================================
;
; Descriptor (ARR_DESC bytes, in the data segment): +0 the segment of the
; elements (numbers) or the offset of their descriptors in the data
; segment (strings), 0 = no storage yet; +2 element size; +4 dimensions;
; +5 type; +6 number of elements; +8 per dimension: lower bound, count.

A_DATA      equ 0
A_SIZE      equ 2
A_DIMS      equ 4
A_TYPE      equ 5
A_COUNT     equ 6
A_BOUNDS    equ 8

; The descriptor's address (operand word; kind 0 global, 1 local, 2
; parameter) -> BX
desc_of_g:
    lodsw
    mov bx, ax
    ret
desc_of_l:
    lodsw
    add ax, bp
    mov bx, ax
    ret
desc_of_p:
    lodsw
    add ax, bp
    mov bx, ax
    mov bx, [es:bx]
    ret

; The rest of the operands: dimensions, type, size -> arr_dims, arr_t,
; arr_esize
array_operands_rt:
    lodsb
    mov [cs:rt_dims], al
    lodsb
    mov [cs:rt_type], al
    lodsw
    mov [cs:rt_esize], ax
    ret

op_dim_g:
    call desc_of_g
    jmp dim_common
op_dim_l:
    call desc_of_l
    jmp dim_common
op_dim_p:
    call desc_of_p
dim_common:
    call array_operands_rt
    cmp word [es:bx + A_DATA], 0
    je dim_bounds
    mov al, E_DUPDEF
    jmp rt_error
op_redim_g:
    call desc_of_g
    jmp redim_common
op_redim_l:
    call desc_of_l
    jmp redim_common
op_redim_p:
    call desc_of_p
redim_common:
    call array_operands_rt
    call array_free
; The bounds are on the stack (lower, upper for each dimension, the last
; one on top)
dim_bounds:
    mov cl, [cs:rt_dims]
    xor ch, ch
    mov [es:bx + A_DIMS], cl
    mov al, [cs:rt_type]
    mov [es:bx + A_TYPE], al
    mov ax, [cs:rt_esize]
    mov [es:bx + A_SIZE], ax
    mov di, cx
    dec di
    shl di, 1
    shl di, 1
    add di, bx
.dim:
    pop dx                          ; upper
    pop ax                          ; lower
    mov [es:di + A_BOUNDS], ax
    sub dx, ax
    jo .bad
    inc dx
    jle .bad
    mov [es:di + A_BOUNDS + 2], dx
    sub di, 4
    loop .dim
    jmp array_alloc
.bad:
    jmp err_subscript

; Storage for the array whose bounds are set (BX = descriptor)
array_alloc:
    mov cl, [es:bx + A_DIMS]
    xor ch, ch
    lea di, [bx + A_BOUNDS + 2]
    mov ax, 1
    xor dx, dx
.count:                             ; DX:AX = the number of elements
    push cx
    mov cx, [es:di]
    push dx
    mul cx
    mov [cs:rt_lo], ax
    mov [cs:rt_hi], dx
    pop ax
    mul cx
    or dx, dx
    jz .skip20
    jmp .too_big
.skip20:
    add [cs:rt_hi], ax
    jnc .skip19
    jmp .too_big
.skip19:
    mov ax, [cs:rt_lo]
    mov dx, [cs:rt_hi]
    pop cx
    add di, 4
    loop .count
    or dx, dx
    jz .skip18
    jmp .too_big_2
.skip18:
    mov [es:bx + A_COUNT], ax
    cmp byte [es:bx + A_TYPE], TY_STR
    je .strings
    ; numbers: paragraphs in the arena
    mul word [es:bx + A_SIZE]       ; DX:AX bytes
    add ax, 15
    adc dx, 0
    mov cx, 4
.para:
    shr dx, 1
    rcr ax, 1
    loop .para
    or dx, dx
    jz .skip17
    jmp .too_big_2
.skip17:
    mov cx, ax                      ; paragraphs
    mov ax, [cs:arena_top]
    add ax, cx
    jc .too_big_2
    cmp ax, [cs:arena_end]
    ja .too_big_2
    mov dx, [cs:arena_top]
    mov [cs:arena_top], ax
    mov [es:bx + A_DATA], dx
    or bp, bp                       ; a module array made inside a SUB
    jz .zero
    cmp bx, [cs:frame_base]
    jae .zero
    mov [cs:arena_pinned], ax
.zero:
    push es
    push di
    mov es, dx
.zero_para:
    xor di, di
    push cx
    mov cx, 8
    xor ax, ax
    rep stosw
    pop cx
    mov ax, es
    inc ax
    mov es, ax
    loop .zero_para
    pop di
    pop es
    jmp next_op
.strings:
    shl ax, 1
    jc .too_big_2
    shl ax, 1
    jc .too_big_2
    mov cx, ax
    mov ax, [cs:sarr_top]
    sub ax, cx
    jc .too_big_2
    cmp ax, [cs:frame_top]
    jbe .too_big_2
    mov [cs:sarr_top], ax
    mov [es:bx + A_DATA], ax
    or bp, bp
    jz .zero_str
    cmp bx, [cs:frame_base]
    jae .zero_str
    mov [cs:sarr_pinned], ax
.zero_str:
    mov di, ax
    shr cx, 1
    xor ax, ax
    rep stosw
    jmp next_op
.too_big:
    pop cx
.too_big_2:
    mov word [es:bx + A_DATA], 0
    jmp err_memory

; Frees the storage of the array BX (if any): its strings, and the arena
; or string area when it is the last thing there
array_free:
    mov ax, [es:bx + A_DATA]
    or ax, ax
    jz .done
    cmp byte [es:bx + A_TYPE], TY_STR
    je .strings
    ; numbers: the arena goes back if this was the last block
    push ax
    mov ax, [es:bx + A_COUNT]
    mul word [es:bx + A_SIZE]
    add ax, 15
    adc dx, 0
    mov cx, 4
.para:
    shr dx, 1
    rcr ax, 1
    loop .para
    pop dx
    add ax, dx
    cmp ax, [cs:arena_top]
    jne .clear
    mov [cs:arena_top], dx
    jmp .clear
.strings:
    push bx
    mov di, ax
    mov cx, [es:bx + A_COUNT]
.str:
    call str_free
    add di, 4
    loop .str
    pop bx
    mov ax, [es:bx + A_DATA]
    cmp ax, [cs:sarr_top]
    jne .clear
    mov cx, [es:bx + A_COUNT]
    shl cx, 1
    shl cx, 1
    add [cs:sarr_top], cx
.clear:
    mov word [es:bx + A_DATA], 0
.done:
    ret

op_erase_g:
    call desc_of_g
    jmp erase_common
op_erase_l:
    call desc_of_l
    jmp erase_common
op_erase_p:
    call desc_of_p
erase_common:
    call array_free
    jmp next_op

; Element: the indices are on the stack (the last on top)
op_aelem_g:
    call desc_of_g
    jmp aelem_common
op_aelem_l:
    call desc_of_l
    jmp aelem_common
op_aelem_p:
    call desc_of_p
aelem_common:
    call array_operands_rt
    cmp word [es:bx + A_DATA], 0
    jne .ready
    call array_make
.ready:
    mov cl, [es:bx + A_DIMS]
    cmp cl, [cs:rt_dims]
    je .skip16
    jmp .bad
.skip16:
    xor ch, ch
    mov di, cx                      ; the last dimension's bounds
    dec di
    shl di, 1
    shl di, 1
    add di, bx
    ; linear = (i_last - l) ; then linear * n_i + (i_i - l_i) going down
    pop ax
    sub ax, [es:di + A_BOUNDS]
    jno .skip15
    jmp .bad
.skip15:
    cmp ax, [es:di + A_BOUNDS + 2]
    jb .skip14
    jmp .bad
.skip14:
    xor dx, dx
    dec cx
    jz .linear
.dim:
    sub di, 4
    push ax                         ; DX:AX * n
    push dx
    mov ax, [es:di + A_BOUNDS + 2]
    pop dx
    mul dx                          ; high part * n
    or dx, dx
    jnz .bad_pop
    mov [cs:rt_hi], ax
    pop ax
    mul word [es:di + A_BOUNDS + 2]
    add dx, [cs:rt_hi]
    mov [cs:rt_lo], ax
    mov [cs:rt_hi], dx
    pop ax                          ; this index
    sub ax, [es:di + A_BOUNDS]
    jo .bad
    cmp ax, [es:di + A_BOUNDS + 2]
    jae .bad
    add ax, [cs:rt_lo]
    mov dx, [cs:rt_hi]
    adc dx, 0
    loop .dim
.linear:
    cmp byte [es:bx + A_TYPE], TY_STR
    je .string
    ; DX:AX * size -> segment and offset
    mov cx, [es:bx + A_SIZE]
    push ax
    mov ax, dx
    mul cx
    mov di, ax
    pop ax
    mul cx
    add dx, di                      ; DX:AX = bytes
    mov cx, ax
    and cx, 15
    shr dx, 1
    rcr ax, 1
    shr dx, 1
    rcr ax, 1
    shr dx, 1
    rcr ax, 1
    shr dx, 1
    rcr ax, 1
    add ax, [es:bx + A_DATA]
    push ax
    push cx
    jmp next_op
.string:
    shl ax, 1
    shl ax, 1
    add ax, [es:bx + A_DATA]
    push ax
    jmp next_op
.bad_pop:
    add sp, 2
.bad:
    jmp err_subscript

; Storage for an array used without DIM (BX = descriptor)
array_make:
    mov cl, [cs:rt_dims]
    xor ch, ch
    mov [es:bx + A_DIMS], cl
    mov al, [cs:rt_type]
    mov [es:bx + A_TYPE], al
    mov ax, [cs:rt_esize]
    mov [es:bx + A_SIZE], ax
    lea di, [bx + A_BOUNDS]
    mov al, [cs:rt_base]
    xor ah, ah
    mov dx, 11
    sub dx, ax
.dim:
    mov [es:di], ax
    mov [es:di + 2], dx
    add di, 4
    loop .dim
    ; array_alloc ends at next_op: run it with SI pointing at a RET
    push bx                         ; (the dispatch changes BX)
    push si
    push ds
    push cs
    pop ds
    mov si, array_make_back
    jmp array_alloc
array_make_back:
    db OP_MAKE_BACK
op_make_back:
    pop ds
    pop si
    pop bx
    ret

; The first element (GET/PUT with a whole array): its far address
op_afirst_g:
    call desc_of_g
    jmp afirst_common
op_afirst_l:
    call desc_of_l
    jmp afirst_common
op_afirst_p:
    call desc_of_p
afirst_common:
    call array_operands_rt
    cmp word [es:bx + A_DATA], 0
    jne .ready
    call array_make
.ready:
    push word [es:bx + A_DATA]
    mov ax, 0
    push ax
    jmp next_op

; LBOUND / UBOUND: the dimension is on the stack
op_lbound_g:
    call desc_of_g
    xor dx, dx
    jmp bound_common
op_lbound_l:
    call desc_of_l
    xor dx, dx
    jmp bound_common
op_lbound_p:
    call desc_of_p
    xor dx, dx
    jmp bound_common
op_ubound_g:
    call desc_of_g
    mov dx, 1
    jmp bound_common
op_ubound_l:
    call desc_of_l
    mov dx, 1
    jmp bound_common
op_ubound_p:
    call desc_of_p
    mov dx, 1
bound_common:
    pop cx
    cmp word [es:bx + A_DATA], 0
    je .bad
    dec cx
    mov al, [es:bx + A_DIMS]
    xor ah, ah
    cmp cx, ax
    jae .bad
    shl cx, 1
    shl cx, 1
    add bx, cx
    mov ax, [es:bx + A_BOUNDS]
    or dx, dx
    jz .push
    add ax, [es:bx + A_BOUNDS + 2]
    dec ax
.push:
    push ax
    jmp next_op
.bad:
    jmp err_subscript

op_option_base:
    lodsb
    mov [cs:rt_base], al
    jmp next_op

; SWAP: two far addresses on the stack
op_swap_2:
    pop di
    pop es
    pop bx
    pop ds
    mov ax, [bx]
    xchg ax, [es:di]
    mov [bx], ax
    jmp swap_done
op_swap_4:
    pop di
    pop es
    pop bx
    pop ds
    mov ax, [bx]
    xchg ax, [es:di]
    mov [bx], ax
    mov ax, [bx + 2]
    xchg ax, [es:di + 2]
    mov [bx + 2], ax
swap_done:
    mov ds, [cs:seg_code]
    mov es, [cs:seg_data]
    jmp next_op
op_swap_str:
    pop di
    pop ax
    pop bx
    pop ax
    call str_swap
    jmp next_op

; ---------- Ctrl+Break ----------

check_break:                        ; Ctrl+C waiting in the keyboard?
    push ax
    mov ah, 01h
    int 16h
    jz .no
    cmp al, 3
    jne .no
    mov ah, 00h
    int 16h
    pop ax
    mov al, E_BREAK
    jmp rt_error
.no:
    pop ax
    ret

; ======================================================================
; Strings
; ======================================================================
;
; A string variable is a descriptor in the data segment: offset and
; length of its characters in the strings segment. That segment starts
; with the 256 one-character strings (CHR$), then the constants of the
; program, then the heap: blocks of [length][owner][characters], where
; owner is the address of the descriptor that owns the block (0 = free).
; When the heap is full the live blocks are moved down (each one's owner
; is updated) and the free ones disappear.
;
; Strings made while computing an expression belong to temporary
; descriptors, freed when the next statement starts. Assigning a
; temporary to a variable just passes the block over; a constant is not
; copied at all.

; The one-character strings, and where the constants start
init_strings:
    push es
    mov es, [seg_str]
    xor di, di
    xor ax, ax
.char:
    stosb
    inc al
    jnz .char
    pop es
    mov word [str_const_top], 256
    ret

; DI = a new temporary descriptor (empty)
temp_new:
    mov di, [cs:temp_top]
    cmp di, [cs:temp_end]
    jae .full
    add word [cs:temp_top], 4
    mov word [es:di], 0
    mov word [es:di + 2], 0
    ret
.full:
    mov al, E_COMPLEX
    jmp rt_error

; Frees the temporaries of the running statement
temps_release:
    push di
    push ax
    mov di, [cs:temp_base]
.next:
    cmp di, [cs:temp_top]
    jae .done
    call str_free
    add di, 4
    jmp .next
.done:
    mov ax, [cs:temp_base]
    mov [cs:temp_top], ax
    pop ax
    pop di
    ret

; Frees the block of the descriptor ES:DI (if it has one) and empties it
str_free:
    push ax
    push bx
    push cx
    mov cx, [es:di + 2]
    jcxz .empty
    mov bx, [es:di]
    cmp bx, [cs:heap_start]
    jb .empty
    push ds
    mov ds, [cs:seg_str]
    cmp [bx - 2], di                ; (only if it is really its owner)
    jne .not_owner
    mov word [bx - 2], 0
    add cx, bx                      ; the last block: the heap shrinks
    cmp cx, [cs:str_top]
    jne .not_owner
    sub bx, 4
    mov [cs:str_top], bx
.not_owner:
    pop ds
.empty:
    mov word [es:di], 0
    mov word [es:di + 2], 0
    pop cx
    pop bx
    pop ax
    ret

; Room for CX characters: AX = their offset in the strings segment (the
; owner is left 0: the caller sets it). Blocks may move.
str_alloc:
    push bx
    push dx
    mov bx, [cs:str_top]
    mov ax, bx
    add ax, 4
    jc .collect
    add ax, cx
    jc .collect
    cmp ax, STR_HEAP_END
    jbe .room
.collect:
    call str_collect
    mov bx, [cs:str_top]
    mov ax, bx
    add ax, 4
    jc .full
    add ax, cx
    jc .full
    cmp ax, STR_HEAP_END
    ja .full
.room:
    mov [cs:str_top], ax
    push ds
    mov ds, [cs:seg_str]
    mov [bx], cx
    mov word [bx + 2], 0
    pop ds
    lea ax, [bx + 4]
    pop dx
    pop bx
    ret
.full:
    mov al, E_STRSPACE
    jmp rt_error

; Garbage collection: the live blocks move down
str_collect:
    push ax
    push bx
    push cx
    push si
    push di
    push ds
    push es
    mov ds, [cs:seg_str]
    mov es, [cs:seg_str]
    mov si, [cs:heap_start]         ; SI = the block looked at
    mov di, si                      ; DI = where live blocks go
.block:
    cmp si, [cs:str_top]
    jae .done
    mov cx, [si]                    ; length
    mov bx, [si + 2]                ; owner
    or bx, bx
    jz .dead
    push ds                         ; is the owner still pointing here?
    mov ds, [cs:seg_data]
    lea ax, [si + 4]
    cmp [bx], ax
    jne .dead_pop
    lea ax, [di + 4]                ; yes: its new place
    mov [bx], ax
    pop ds
    add cx, 4
    cmp si, di
    je .same
    rep movsb
    jmp .block
.same:
    add si, cx
    mov di, si
    jmp .block
.dead_pop:
    pop ds
.dead:
    add si, cx
    add si, 4
    jmp .block
.done:
    mov [cs:str_top], di
    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; A new temporary with room for CX characters: DI = the descriptor, AX =
; the offset of the characters (CX = 0: no block)
str_new_temp:
    call temp_new
    jcxz .empty
    call str_alloc
    mov [es:di], ax
    mov [es:di + 2], cx
    push ds
    push bx
    mov ds, [cs:seg_str]
    mov bx, ax
    mov [bx - 2], di
    pop bx
    pop ds
.empty:
    ret

; The descriptor ES:DI takes the value of the descriptor at BX (the data
; segment; any of them may be a temporary)
str_assign:
    cmp di, bx
    je .done
    cmp bx, [cs:temp_area]          ; from a temporary: its block passes
    jb .not_temp
    cmp bx, [cs:temp_end]
    jae .not_temp
    call str_free
    mov ax, [es:bx]
    mov cx, [es:bx + 2]
    mov [es:di], ax
    mov [es:di + 2], cx
    mov word [es:bx], 0
    mov word [es:bx + 2], 0
    jcxz .done
    cmp ax, [cs:heap_start]
    jb .done
    push ds
    mov ds, [cs:seg_str]
    mov bx, ax
    mov [bx - 2], di
    pop ds
.done:
    ret
.not_temp:
    mov cx, [es:bx + 2]
    jcxz .shared
    mov ax, [es:bx]
    cmp ax, [cs:heap_start]
    jae .copy
.shared:                            ; empty or a constant: no copy
    call str_free
    mov ax, [es:bx]
    mov [es:di], ax
    mov [es:di + 2], cx
    ret
.copy:
    push si
    call str_alloc                  ; may move the source: read it after
    push ax
    call str_free
    pop ax
    mov [es:di], ax
    mov [es:di + 2], cx
    push ds
    push es
    push di
    mov si, [es:bx]
    mov ds, [cs:seg_str]
    mov es, [cs:seg_str]
    mov bx, ax
    mov [bx - 2], di
    mov di, ax
    rep movsb
    pop di
    pop es
    pop ds
    pop si
    ret

; BX = a string descriptor -> BX = a temporary that owns its own copy
; (the same one if it is a temporary already)
str_own_temp:
    cmp bx, [cs:temp_area]
    jb .copy
    cmp bx, [cs:temp_end]
    jb .done
.copy:
    push di
    call temp_new
    call str_assign
    mov bx, di
    pop di
.done:
    ret

; SWAP of the descriptors at BX and DI
str_swap:
    mov ax, [es:bx]
    mov cx, [es:bx + 2]
    xchg ax, [es:di]
    xchg cx, [es:di + 2]
    mov [es:bx], ax
    mov [es:bx + 2], cx
    call .owner                     ; the owners follow
    xchg bx, di
.owner:
    mov cx, [es:di + 2]
    jcxz .ret
    mov ax, [es:di]
    cmp ax, [cs:heap_start]
    jb .ret
    push ds
    push bx
    mov ds, [cs:seg_str]
    mov bx, ax
    mov [bx - 2], di
    pop bx
    pop ds
.ret:
    ret

; Compares the strings at DI and BX: AL = 0 less, 1 equal, 2 greater
str_compare:
    push si
    push ds
    push es
    mov cx, [es:di + 2]
    mov dx, [es:bx + 2]
    mov si, [es:di]
    mov di, [es:bx]
    mov ds, [cs:seg_str]
    mov es, [cs:seg_str]
    mov bx, cx                      ; the shorter length
    cmp bx, dx
    jbe .len
    mov bx, dx
.len:
    xchg cx, bx
    jcxz .lengths
    repe cmpsb
    jne .differ
.lengths:
    cmp bx, dx
    mov al, 1
    je .done
    mov al, 0
    jb .done
    mov al, 2
    jmp .done
.differ:
    mov al, 0
    jb .done
    mov al, 2
.done:
    pop es
    pop ds
    pop si
    ret

; Frees the strings of a frame being left: blocks owned by descriptors in
; [BP, frame_top) or in [sarr_top, AX) (local string arrays)
frame_strings_free:
    push si
    push ds
    mov dx, ax
    mov ds, [cs:seg_str]
    mov si, [cs:heap_start]
.block:
    cmp si, [cs:str_top]
    jae .done
    mov cx, [si]
    mov bx, [si + 2]
    or bx, bx
    jz .next
    cmp bx, bp
    jb .not_frame
    cmp bx, [cs:frame_top]
    jb .owned
.not_frame:
    cmp bx, [cs:sarr_top]
    jb .next
    cmp bx, dx
    jae .next
.owned:
    push ds
    mov ds, [cs:seg_data]
    lea ax, [si + 4]
    cmp [bx], ax
    pop ds
    jne .next
    mov word [si + 2], 0
.next:
    add si, cx
    add si, 4
    jmp .block
.done:
    pop ds
    pop si
    ret

; ---------- string operations ----------

; A constant: a temporary that points at it
op_push_cstr:
    call temp_new
    lodsw
    mov [es:di], ax
    lodsw
    mov [es:di + 2], ax
    push di
    jmp next_op

op_cat:
    pop word [cs:cat_right]
    pop word [cs:cat_left]
    mov bx, [cs:cat_left]
    mov cx, [es:bx + 2]
    jcxz .right_only
    mov bx, [cs:cat_right]
    mov ax, [es:bx + 2]
    or ax, ax
    jz .left_only
    add cx, ax
    jo .too_long
    call str_new_temp               ; (blocks may move: read them after)
    push di
    push si
    push ds
    push es
    mov dx, ax
    mov bx, [cs:cat_left]
    mov si, [es:bx]
    mov cx, [es:bx + 2]
    mov bx, [cs:cat_right]
    push word [es:bx]
    push word [es:bx + 2]
    mov di, dx
    mov ds, [cs:seg_str]
    mov es, [cs:seg_str]
    rep movsb
    pop cx
    pop si
    rep movsb
    pop es
    pop ds
    pop si
    jmp next_op
.right_only:
    push word [cs:cat_right]
    jmp next_op
.left_only:
    push word [cs:cat_left]
    jmp next_op
.too_long:
    mov al, E_STRLONG
    jmp rt_error

; LEN(s)
op_len:
    pop bx
    push word [es:bx + 2]
    jmp next_op

; ASC(s)
op_asc:
    pop bx
    mov cx, [es:bx + 2]
    jcxz .bad
    mov bx, [es:bx]
    push ds
    mov ds, [cs:seg_str]
    mov al, [bx]
    pop ds
    xor ah, ah
    push ax
    jmp next_op
.bad:
    jmp err_func

; CHR$(n): one of the 256 strings at the start of the segment
op_chr:
    pop ax
    or ah, ah
    jnz .bad
    call temp_new
    mov [es:di], ax
    mov word [es:di + 2], 1
    push di
    jmp next_op
.bad:
    jmp err_func

; A substring of the string at BX: from CX characters at DX (offset in
; the string). A constant's piece is the constant itself; a block's is a
; copy. Pushes the new temporary.
substring:
    jcxz .empty
    mov ax, [es:bx]
    add ax, dx
    cmp ax, [cs:heap_start]
    jae .copy
    call temp_new
    mov [es:di], ax
    mov [es:di + 2], cx
    pop ax                          ; (return address)
    push di
    jmp ax
.empty:
    call temp_new
    pop ax
    push di
    jmp ax
.copy:
    push bx
    push dx
    call str_new_temp               ; DI = temporary, AX = its characters
    pop dx
    pop bx
    push si
    push ds
    push es
    push di
    mov si, [es:bx]
    add si, dx
    mov di, ax
    mov ds, [cs:seg_str]
    mov es, [cs:seg_str]
    rep movsb
    pop di
    pop es
    pop ds
    pop si
    pop ax
    push di
    jmp ax

; LEFT$(s, n)
op_left:
    pop cx
    pop bx
    or cx, cx
    js .bad
    cmp cx, [es:bx + 2]
    jbe .ok
    mov cx, [es:bx + 2]
.ok:
    xor dx, dx
    call substring
    jmp next_op
.bad:
    jmp err_func

; RIGHT$(s, n)
op_right:
    pop cx
    pop bx
    or cx, cx
    js .bad
    mov dx, [es:bx + 2]
    cmp cx, dx
    jbe .ok
    mov cx, dx
.ok:
    sub dx, cx
    call substring
    jmp next_op
.bad:
    jmp err_func

; MID$(s, start, length)
op_mid:
    pop cx                          ; length
    pop dx                          ; start
    pop bx
    or cx, cx
    js .bad
    cmp dx, 1
    jl .bad
    dec dx
    mov ax, [es:bx + 2]
    sub ax, dx                      ; what is left from start
    jg .some
    xor cx, cx
    jmp .ok
.some:
    cmp cx, ax
    jbe .ok
    mov cx, ax
.ok:
    call substring
    jmp next_op
.bad:
    jmp err_func

; SPACE$(n)
op_space:
    pop cx
    mov al, ' '
    jmp fill_string
; STRING$(n, code)
op_string:
    pop ax
    pop cx
    or ah, ah
    jnz fill_bad
fill_string:
    or cx, cx
    js fill_bad
    push ax
    call str_new_temp
    pop bx
    push di
    push es
    mov es, [cs:seg_str]
    mov di, ax
    mov al, bl
    rep stosb
    pop es
    jmp next_op
fill_bad:
    jmp err_func

; UCASE$ / LCASE$: a copy, changed
op_ucase:
    mov dx, 'az'
    jmp case_common
op_lcase:
    mov dx, 'AZ'
case_common:
    pop bx
    push dx
    mov cx, [es:bx + 2]
    push bx
    call str_new_temp
    pop bx
    pop dx
    push di
    jcxz .done
    push si
    push ds
    push es
    mov si, [es:bx]
    mov di, ax
    mov ds, [cs:seg_str]
    mov es, [cs:seg_str]
.char:
    lodsb
    cmp al, dl
    jb .store
    cmp al, dh
    ja .store
    xor al, 20h
.store:
    stosb
    loop .char
    pop es
    pop ds
    pop si
.done:
    jmp next_op

; LTRIM$ / RTRIM$
op_ltrim:
    pop bx
    mov cx, [es:bx + 2]
    xor dx, dx
    push ds
    mov ds, [cs:seg_str]
    mov di, [es:bx]
.lead:
    jcxz .done
    cmp byte [di], ' '
    jne .done
    inc di
    inc dx
    dec cx
    jmp .lead
.done:
    pop ds
    call substring
    jmp next_op

op_rtrim:
    pop bx
    mov cx, [es:bx + 2]
    xor dx, dx
    push ds
    mov ds, [cs:seg_str]
    mov di, [es:bx]
    add di, cx
.trail:
    jcxz .done
    cmp byte [di - 1], ' '
    jne .done
    dec di
    dec cx
    jmp .trail
.done:
    pop ds
    call substring
    jmp next_op

; INSTR(start, s, find)
op_instr:
    pop bx                          ; the one to find
    pop di                          ; where
    pop dx                          ; start
    cmp dx, 1
    jl .bad
    push si
    push ds
    push es
    mov cx, [es:di + 2]
    mov ax, [es:bx + 2]
    mov si, [es:di]
    mov di, [es:bx]
    dec dx
    cmp dx, cx
    ja .zero                        ; start past the end
    or ax, ax
    jz .found                       ; "" is found at start
    sub cx, ax                      ; the last place it can start
    jb .zero
    mov bx, ax
    mov ds, [cs:seg_str]
    mov es, [cs:seg_str]
.pos:
    cmp dx, cx
    ja .zero
    push si
    push di
    push cx
    add si, dx
    mov cx, bx
    repe cmpsb
    pop cx
    pop di
    pop si
    je .found
    inc dx
    jmp .pos
.found:
    inc dx
    mov ax, dx
    jmp .result
.zero:
    xor ax, ax
.result:
    pop es
    pop ds
    pop si
    push ax
    jmp next_op
.bad:
    jmp err_func

; ======================================================================
; Real numbers: IEEE single precision in DX:AX (the second operand in
; CX:BX). Reached through CS, as they run with any DS.
; ======================================================================

; DX:AX -> DX:AX = the mantissa with its leading 1 at bit 31, CX = the
; biased exponent (0: the number is 0), BH = the sign (0 or 80h)
funpack:
    mov bh, dh
    and bh, 80h
    mov cx, dx
    shl cx, 1
    mov cl, ch
    xor ch, ch
    or cx, cx
    jz .zero
    cmp cx, 255
    je .infinite
    and dx, 7Fh
    or dl, 80h
    mov dh, dl
    mov dl, ah
    mov ah, al
    xor al, al
    ret
.zero:
    xor ax, ax
    xor dx, dx
    ret
.infinite:
    jmp err_overflow

; DX:AX = mantissa (bit 31 set, 8 more bits for rounding), CX = biased
; exponent (signed), BH = sign -> DX:AX the number, rounded to nearest
fpack:
    test al, 80h
    jz .rounded
    test al, 7Fh
    jnz .up
    test ah, 1
    jz .rounded
.up:
    add ax, 100h
    adc dx, 0
    jnc .rounded
    mov dx, 8000h
    inc cx
.rounded:
    cmp cx, 0
    jle .zero
    cmp cx, 255
    jge .over
    mov al, ah
    mov ah, dl
    mov dl, dh
    and dl, 7Fh
    mov dh, cl
    shr dh, 1
    jnc .even
    or dl, 80h
.even:
    or dh, bh
    ret
.zero:
    xor ax, ax
    xor dx, dx
    ret
.over:
    jmp err_overflow

; DX:AX + CX:BX
fadd:
    push si
    push di
    push bp
    push dx
    push ax
    mov dx, cx
    mov ax, bx
    call funpack
    mov si, dx                      ; B in SI:DI, exponent BP, sign
    mov di, ax
    mov bp, cx
    mov [cs:fb_sign], bh
    pop ax
    pop dx
    call funpack                    ; A in DX:AX, CX, BH
    or bp, bp
    jnz .skip13                           ; B = 0
    jmp .a
.skip13:
    or cx, cx
    jnz .skip12                         ; A = 0
    jmp .b
.skip12:
    cmp cx, bp                      ; A gets the larger exponent
    jae .order
    xchg dx, si
    xchg ax, di
    xchg cx, bp
    mov bl, [cs:fb_sign]
    mov [cs:fb_sign], bh
    mov bh, bl
.order:
    sub bp, cx
    neg bp                          ; BP = how far B shifts right
    cmp bp, 32
    jae .a
    xor bl, bl                      ; BL = bits lost (sticky)
    cmp bp, 16
    jb .shift
    or di, di
    jz .word_gone
    mov bl, 1
.word_gone:
    mov di, si
    xor si, si
    sub bp, 16
.shift:
    or bp, bp
    jz .aligned
.shift_bit:
    shr si, 1
    rcr di, 1
    adc bl, 0
    dec bp
    jnz .shift_bit
.aligned:
    or bl, bl
    jz .no_sticky
    or di, 1
.no_sticky:
    cmp bh, [cs:fb_sign]
    jne .subtract
    add ax, di
    adc dx, si
    jnc .pack
    rcr dx, 1                       ; the carry comes back in
    rcr ax, 1
    jnc .carry_ok
    or al, 1
.carry_ok:
    inc cx
    jmp .pack
.subtract:
    sub ax, di
    sbb dx, si
    jnc .normalize
    neg dx                          ; B was larger: the sign changes
    neg ax
    sbb dx, 0
    mov bh, [cs:fb_sign]
.normalize:
    mov bp, dx
    or bp, ax
    jz .zero
.norm_bit:
    test dh, 80h
    jnz .pack
    shl ax, 1
    rcl dx, 1
    dec cx
    jmp .norm_bit
.pack:
    call fpack
    jmp .ret
.zero:
    xor ax, ax
    xor dx, dx
    jmp .ret
.b:
    mov dx, si
    mov ax, di
    mov cx, bp
    mov bh, [cs:fb_sign]
    jmp .pack
.a:
    or cx, cx
    jz .zero
    jmp .pack
.ret:
    pop bp
    pop di
    pop si
    ret

; DX:AX - CX:BX
fsub:
    xor ch, 80h
    call fadd
    xor ch, 80h
    ret

; DX:AX * CX:BX
fmul:
    push si
    push di
    push bp
    push dx
    push ax
    mov dx, cx
    mov ax, bx
    call funpack
    or cx, cx
    jnz .skip11
    jmp .zero_pop
.skip11:
    mov si, dx
    mov di, ax
    mov [cs:ft_exp], cx
    mov [cs:ft_sign], bh
    pop ax
    pop dx
    call funpack
    or cx, cx
    jnz .skip10
    jmp .zero
.skip10:
    xor [cs:ft_sign], bh
    add cx, [cs:ft_exp]
    sub cx, 127
    mov [cs:ft_exp], cx
    mov [cs:ma_h], dx
    mov [cs:ma_l], ax
    mul di                          ; low * low
    mov [cs:w0], ax
    mov bx, dx
    xor cx, cx
    xor bp, bp
    mov ax, [cs:ma_h]
    mul di                          ; high * low
    add bx, ax
    adc cx, dx
    adc bp, 0
    mov ax, [cs:ma_l]
    mul si                          ; low * high
    add bx, ax
    adc cx, dx
    adc bp, 0
    mov [cs:w1], bx
    mov ax, [cs:ma_h]
    mul si                          ; high * high
    add ax, cx
    adc dx, bp
    mov cx, [cs:ft_exp]
    test dh, 80h
    jnz .top
    shl word [cs:w1], 1
    rcl ax, 1
    rcl dx, 1
    jmp .sticky
.top:
    inc cx
.sticky:
    mov bx, [cs:w0]
    or bx, [cs:w1]
    jz .pack
    or al, 1
.pack:
    mov bh, [cs:ft_sign]
    call fpack
    jmp .ret
.zero_pop:
    add sp, 4
.zero:
    xor ax, ax
    xor dx, dx
.ret:
    pop bp
    pop di
    pop si
    ret

; DX:AX / CX:BX
fdiv:
    push si
    push di
    push bp
    push dx
    push ax
    mov dx, cx
    mov ax, bx
    call funpack
    or cx, cx
    jnz .skip9
    jmp .by_zero
.skip9:
    mov si, dx
    mov di, ax
    mov [cs:ft_exp], cx
    mov [cs:ft_sign], bh
    pop ax
    pop dx
    call funpack
    or cx, cx
    jz .zero
    xor [cs:ft_sign], bh
    sub cx, [cs:ft_exp]
    add cx, 127
    xor bp, bp                      ; the bit above DX:AX
    cmp dx, si
    ja .start
    jb .smaller
    cmp ax, di
    jae .start
.smaller:
    shl ax, 1
    rcl dx, 1
    rcl bp, 1
    dec cx
.start:
    mov [cs:ft_exp], cx
    xor cx, cx                      ; the quotient in CX:BX
    xor bx, bx
    mov word [cs:fcount], 32
.bit:
    shl bx, 1
    rcl cx, 1
    or bp, bp
    jnz .sub
    cmp dx, si
    jb .next
    ja .sub
    cmp ax, di
    jb .next
.sub:
    sub ax, di
    sbb dx, si
    or bl, 1
.next:
    xor bp, bp
    shl ax, 1
    rcl dx, 1
    rcl bp, 1
    dec word [cs:fcount]
    jnz .bit
    or ax, dx
    or ax, bp
    jz .exact
    or bl, 1
.exact:
    mov dx, cx
    mov ax, bx
    mov cx, [cs:ft_exp]
    mov bh, [cs:ft_sign]
    call fpack
    jmp .ret
.by_zero:
    add sp, 4
    pop bp
    pop di
    pop si
    jmp err_divzero
.zero:
    xor ax, ax
    xor dx, dx
.ret:
    pop bp
    pop di
    pop si
    ret

; Compares DX:AX with CX:BX: AL = 0 less, 1 equal, 2 greater
fcmp:
    push si
    push dx
    push cx
    mov si, dx                      ; (SI only used here)
    and si, 7FFFh
    or si, ax
    jnz .a_nonzero
    and dh, 7Fh                     ; A = 0: the sign does not matter
.a_nonzero:
    mov si, cx
    and si, 7FFFh
    or si, bx
    jnz .b_nonzero
    and ch, 7Fh
.b_nonzero:
    mov si, dx
    xor si, cx
    js .signs                       ; different signs
    test dh, 80h
    jnz .negative
    cmp dx, cx
    jb .less
    ja .greater
    cmp ax, bx
    jb .less
    ja .greater
    jmp .equal
.negative:
    cmp dx, cx
    ja .less
    jb .greater
    cmp ax, bx
    ja .less
    jb .greater
.equal:
    mov al, 1
    jmp .ret
.signs:
    test dh, 80h
    jnz .less
.greater:
    mov al, 2
    jmp .ret
.less:
    mov al, 0
.ret:
    pop cx
    pop dx
    pop si
    ret

; AX (integer) -> DX:AX real
i2f:
    cwd
; DX:AX (long) -> DX:AX real
l2f:
    push cx
    push bx
    mov bx, dx
    or bx, ax
    jz .done
    xor bh, bh
    or dx, dx
    jns .positive
    mov bh, 80h
    neg dx
    neg ax
    sbb dx, 0
.positive:
    mov cx, 127 + 31
.norm:
    test dh, 80h
    jnz .pack
    shl ax, 1
    rcl dx, 1
    dec cx
    jmp .norm
.pack:
    call fpack
.done:
    pop bx
    pop cx
    ret

; DX:AX real -> DX:AX long, rounded (half to even, like CINT); overflow
; if it does not fit
f2l_round:
    mov byte [cs:f2l_mode], 1
    jmp f2l
; ... truncated (FIX)
f2l_trunc:
    mov byte [cs:f2l_mode], 0
f2l:
    push cx
    push bx
    push si
    call funpack
    or cx, cx
    jz .zero
    sub cx, 127 + 31                ; CX = the shift (negative: right)
    jl .right
    jg .over
    cmp dx, 8000h                   ; 2^31: only -2^31 fits
    jne .over
    or ax, ax
    jnz .over
    or bh, bh
    jz .over
    jmp .done
.right:
    neg cx
    cmp cx, 34
    jae .zero
    xor si, si                      ; SI: bit 0 = round bit, bit 1 sticky
.shift:
    test si, 1
    jz .no_sticky
    or si, 2
.no_sticky:
    and si, 0FFFEh
    shr dx, 1
    rcr ax, 1
    adc si, 0
    loop .shift
    cmp byte [cs:f2l_mode], 0
    je .sign
    test si, 1
    jz .sign
    test si, 2
    jnz .up
    test al, 1
    jz .sign
.up:
    add ax, 1
    adc dx, 0
.sign:
    test dh, 80h
    jnz .over
    or bh, bh
    jz .done
    neg dx
    neg ax
    sbb dx, 0
.done:
    pop si
    pop bx
    pop cx
    ret
.zero:
    xor ax, ax
    xor dx, dx
    jmp .done
.over:
    pop si
    pop bx
    pop cx
    jmp err_overflow

; FIX as a real: DX:AX without its fraction. CF = 1 if there was one.
ffix:
    push cx
    push bx
    push si
    mov cx, dx
    shl cx, 1
    mov cl, ch
    xor ch, ch
    cmp cx, 127
    jb .small
    cmp cx, 150
    jae .whole
    neg cx
    add cx, 150                     ; bits of fraction
    mov bx, 0FFFFh                  ; the mask in BX:SI
    mov si, 0FFFFh
.mask:
    shl si, 1
    rcl bx, 1
    loop .mask
    mov cx, ax
    and ax, si
    cmp cx, ax
    jne .had_dx
    mov cx, dx
    and dx, bx
    cmp cx, dx
    jne .had
.whole:
    clc
    jmp .ret
.had_dx:
    and dx, bx
.had:
    stc
    jmp .ret
.small:                             ; below 1: 0 (with a fraction, unless 0)
    mov cx, dx
    and cx, 7FFFh
    or cx, ax
    xor ax, ax
    xor dx, dx
    or cx, cx
    jz .whole
    stc
.ret:
    pop si
    pop bx
    pop cx
    ret

; INT: the largest whole number not above DX:AX
ffloor:
    push dx
    call ffix
    pop cx
    jnc .done
    test ch, 80h
    jz .done
    mov cx, [cs:c_one + 2]          ; negative with a fraction: one less
    mov bx, [cs:c_one]
    call fsub
.done:
    ret

; Loads the constant at CS:BX into CX:BX
fconst:
    mov cx, [cs:bx + 2]
    mov bx, [cs:bx]
    ret

; DX:AX * the constant at CS:BX (and + / - / / )
fmul_c:
    call fconst
    jmp fmul
fadd_c:
    call fconst
    jmp fadd
fdiv_c:
    call fconst
    jmp fdiv

; The real at CS:BX into DX:AX
fload:
    mov ax, [cs:bx]
    mov dx, [cs:bx + 2]
    ret

; DX:AX into the real at CS:BX
fstore:
    mov [cs:bx], ax
    mov [cs:bx + 2], dx
    ret

; Multiplies DX:AX by 2^CX (CX signed): changes the exponent
fscale:
    push bx
    push cx
    mov bx, dx
    and bx, 7FFFh
    or bx, ax
    jz .done
    mov bx, dx
    shl bx, 1
    mov bl, bh
    xor bh, bh                      ; exponent
    add bx, cx
    cmp bx, 0
    jle .zero
    cmp bx, 255
    jge .over
    shl dx, 1                       ; put it back (keeping the sign)
    rcl byte [cs:fs_sign], 1
    mov dh, bl
    shr byte [cs:fs_sign], 1
    rcr dx, 1
.done:
    pop cx
    pop bx
    ret
.zero:
    xor ax, ax
    xor dx, dx
    jmp .done
.over:
    pop cx
    pop bx
    jmp err_overflow

; ---------- functions ----------

; SQR: Newton's method from a guess with half the exponent
fsqrt:
    test dh, 80h
    jz .positive
    mov cx, dx
    and cx, 7FFFh
    or cx, ax
    jz .zero
    jmp err_func
.positive:
    mov cx, dx
    or cx, ax
    jz .zero
    mov bx, fx
    call fstore
    mov cx, dx                      ; guess: exponent halved
    shl cx, 1
    mov cl, ch
    xor ch, ch
    sub cx, 127
    sar cx, 1
    add cx, 127
    shl cx, 1
    shl cx, 1
    shl cx, 1
    shl cx, 1
    shl cx, 1
    shl cx, 1
    shl cx, 1
    and dx, 7Fh
    or dx, cx
    mov word [cs:fcount2], 5
.iterate:                           ; y = (y + x / y) / 2
    mov bx, fy
    call fstore
    mov cx, dx
    mov bx, ax
    mov ax, [cs:fx]
    mov dx, [cs:fx + 2]
    call fdiv
    mov cx, [cs:fy + 2]
    mov bx, [cs:fy]
    call fadd
    mov cx, -1
    call fscale
    dec word [cs:fcount2]
    jnz .iterate
.zero:
    ret

; SIN and COS: reduced to [-pi/4, pi/4] and a quadrant
fsin:
    xor cx, cx
    jmp sincos
fcos:
    mov cx, 1
sincos:
    mov [cs:quadrant], cx
    mov bx, fx
    call fstore
    mov bx, c_two_over_pi           ; k = the nearest whole number of pi/2
    call fmul_c
    call f2l_round
    add [cs:quadrant], ax
    call l2f
    mov bx, fk
    call fstore
    mov bx, c_pio2_1                ; r = x - k * pi/2 (in two parts)
    call fmul_c
    mov cx, dx
    mov bx, ax
    mov ax, [cs:fx]
    mov dx, [cs:fx + 2]
    call fsub
    push dx
    push ax
    mov bx, fk
    call fload
    mov bx, c_pio2_2
    call fmul_c
    mov cx, dx
    mov bx, ax
    pop ax
    pop dx
    call fsub
    mov bx, fx                      ; x = r
    call fstore
    mov bx, fx
    call fload
    mov cx, dx
    mov bx, ax
    call fmul
    mov bx, fx2                     ; r^2
    call fstore
    test byte [cs:quadrant], 1
    jnz .cos
    ; sin r = r * (1 - r2/6 * (1 - r2/20 * (1 - r2/42)))
    mov bx, c_sin_coefs
    call poly_odd
    jmp .sign
.cos:
    mov bx, c_cos_coefs
    call poly_even
.sign:
    test byte [cs:quadrant], 2
    jz .done
    mov cx, dx
    and cx, 7FFFh
    or cx, ax
    jz .done
    xor dh, 80h
.done:
    ret

; The polynomial c0 + c1 r2 + c2 r2^2 + ... (coefficients at CS:BX,
; ending with a 0 word pair... count first) in r2 = [fx2]. Horner.
poly_even:
    push si
    mov si, bx
    mov cx, [cs:si]                 ; count
    add si, 2
    mov [cs:fcount2], cx
    mov bx, si
    call fload
    add si, 4
.term:
    dec word [cs:fcount2]
    jz .done
    mov cx, [cs:fx2 + 2]
    mov bx, [cs:fx2]
    call fmul
    mov bx, si
    call fadd_c
    add si, 4
    jmp .term
.done:
    pop si
    ret

; The same times x = [fx] (an odd polynomial)
poly_odd:
    call poly_even
    mov cx, [cs:fx + 2]
    mov bx, [cs:fx]
    jmp fmul

; TAN = SIN / COS
ftan:
    push dx
    push ax
    call fcos
    mov bx, ftmp
    call fstore
    pop ax
    pop dx
    call fsin
    mov cx, [cs:ftmp + 2]
    mov bx, [cs:ftmp]
    jmp fdiv

; ATN
fatn:
    mov bl, dh
    and bl, 80h
    mov [cs:atn_sign], bl
    and dh, 7Fh
    mov byte [cs:atn_flags], 0
    mov cx, [cs:c_one + 2]          ; above 1: pi/2 - ATN(1/x)
    mov bx, [cs:c_one]
    call fcmp_keep
    cmp bl, 1                       ; ATN(1) = pi/4 exactly
    jne .not_one
    mov ax, [cs:c_pio2]
    mov dx, [cs:c_pio2 + 2]
    mov cx, -1
    call fscale
    jmp .sign
.not_one:
    cmp bl, 2
    jne .small
    or byte [cs:atn_flags], 1
    mov cx, dx
    mov bx, ax
    mov ax, [cs:c_one]
    mov dx, [cs:c_one + 2]
    call fdiv
.small:
    mov cx, [cs:c_tan15 + 2]        ; above tan 15: shifted by 30 degrees
    mov bx, [cs:c_tan15]
    call fcmp_keep
    cmp bl, 2
    jne .series
    or byte [cs:atn_flags], 2
    mov bx, fx                      ; (x * sqrt3 - 1) / (x + sqrt3)
    call fstore
    mov bx, c_sqrt3
    call fmul_c
    mov cx, [cs:c_one + 2]
    mov bx, [cs:c_one]
    call fsub
    mov bx, ftmp
    call fstore
    mov bx, fx
    call fload
    mov bx, c_sqrt3
    call fadd_c
    mov cx, dx
    mov bx, ax
    mov ax, [cs:ftmp]
    mov dx, [cs:ftmp + 2]
    call fdiv
.series:
    mov bx, fx
    call fstore
    mov cx, dx
    mov bx, ax
    call fmul
    mov bx, fx2
    call fstore
    mov bx, c_atn_coefs
    call poly_odd
    test byte [cs:atn_flags], 2
    jz .not_shifted
    mov bx, c_pio6
    call fadd_c
.not_shifted:
    test byte [cs:atn_flags], 1
    jz .sign
    mov cx, dx
    mov bx, ax
    mov ax, [cs:c_pio2]
    mov dx, [cs:c_pio2 + 2]
    call fsub
.sign:
    or dh, [cs:atn_sign]
    ret

; EXP: 2^n * e^r
fexp:
    mov cx, [cs:c_exp_max + 2]
    mov bx, [cs:c_exp_max]
    call fcmp_keep
    cmp bl, 2
    jne .not_big
    jmp err_overflow
.not_big:
    mov cx, [cs:c_exp_min + 2]
    mov bx, [cs:c_exp_min]
    call fcmp_keep
    or bl, bl
    jnz .not_small
    xor ax, ax
    xor dx, dx
    ret
.not_small:
    mov bx, fx
    call fstore
    mov bx, c_log2e
    call fmul_c
    call f2l_round
    mov [cs:exp_n], ax
    call l2f
    mov bx, fk
    call fstore
    mov bx, c_ln2_1                 ; r = x - n ln2 (in two parts)
    call fmul_c
    mov cx, dx
    mov bx, ax
    mov ax, [cs:fx]
    mov dx, [cs:fx + 2]
    call fsub
    push dx
    push ax
    mov bx, fk
    call fload
    mov bx, c_ln2_2
    call fmul_c
    mov cx, dx
    mov bx, ax
    pop ax
    pop dx
    call fsub
    mov bx, fx2                     ; e^r = 1 + r (1 + r/2 (1 + r/3 ...)):
    call fstore                     ; Horner in r with 1/n!
    mov bx, c_exp_coefs
    call poly_even
    mov cx, [cs:exp_n]
    jmp fscale

; Compares DX:AX with CX:BX keeping DX:AX: BL = the result
fcmp_keep:
    push ax
    call fcmp
    mov bl, al
    pop ax
    ret

; LOG
flog:
    test dh, 80h
    jz .skip8
    jmp .bad
.skip8:
    mov cx, dx
    or cx, ax
    jnz .skip7
    jmp .bad
.skip7:
    mov cx, dx                      ; x = m * 2^e, m in [1, 2)
    shl cx, 1
    mov cl, ch
    xor ch, ch
    sub cx, 127
    mov [cs:exp_n], cx
    and dx, 807Fh
    or dx, 3F80h
    mov cx, [cs:c_sqrt2 + 2]        ; m above sqrt 2: m / 2
    mov bx, [cs:c_sqrt2]
    call fcmp_keep
    cmp bl, 2
    jne .m_ok
    mov cx, -1
    call fscale
    inc word [cs:exp_n]
.m_ok:
    mov bx, fx                      ; f = (m - 1) / (m + 1)
    call fstore
    mov bx, c_one
    call fadd_c
    mov bx, ftmp
    call fstore
    mov bx, fx
    call fload
    mov cx, [cs:c_one + 2]
    mov bx, [cs:c_one]
    call fsub
    mov cx, [cs:ftmp + 2]
    mov bx, [cs:ftmp]
    call fdiv
    mov bx, fx
    call fstore
    mov cx, dx
    mov bx, ax
    call fmul
    mov bx, fx2
    call fstore
    mov bx, c_log_coefs             ; 2 (f + f^3/3 + f^5/5 + f^7/7)
    call poly_odd
    mov cx, 1
    call fscale
    mov bx, ftmp
    call fstore
    mov ax, [cs:exp_n]
    call i2f
    mov bx, c_ln2
    call fmul_c
    mov cx, [cs:ftmp + 2]
    mov bx, [cs:ftmp]
    jmp fadd
.bad:
    jmp err_func

; DX:AX ^ CX:BX: by multiplying for whole powers, else EXP(b * LOG(a))
fpow:
    mov [cs:fy], bx
    mov [cs:fy + 2], cx
    mov [cs:fx], ax
    mov [cs:fx + 2], dx
    mov dx, cx
    mov ax, bx
    call ffix
    jnc .skip6
    jmp .real
.skip6:
    mov bx, dx                      ; |b| up to 1024: multiplying
    and bx, 7FFFh
    cmp bx, 4480h                   ; 1024.0
    jbe .skip5
    jmp .real
.skip5:
    call f2l_trunc
    mov [cs:pow_n], ax
    or ax, ax
    jns .positive
    neg ax
.positive:
    mov [cs:pow_k], ax
    mov ax, [cs:c_one]
    mov dx, [cs:c_one + 2]
    mov bx, ftmp                    ; result
    call fstore
.bit:
    cmp word [cs:pow_k], 0
    je .done_int
    shr word [cs:pow_k], 1
    jnc .square
    mov bx, ftmp
    call fload
    mov cx, [cs:fx + 2]
    mov bx, [cs:fx]
    call fmul
    mov bx, ftmp
    call fstore
.square:
    cmp word [cs:pow_k], 0
    je .done_int
    mov bx, fx
    call fload
    mov cx, dx
    mov bx, ax
    call fmul
    mov bx, fx
    call fstore
    jmp .bit
.done_int:
    mov bx, ftmp
    call fload
    cmp word [cs:pow_n], 0
    jge .ret
    mov cx, dx
    mov bx, ax
    mov ax, [cs:c_one]
    mov dx, [cs:c_one + 2]
    call fdiv
.ret:
    ret
.real:
    mov ax, [cs:fx]
    mov dx, [cs:fx + 2]
    mov cx, dx
    and cx, 7FFFh
    or cx, ax
    jz .ret                         ; 0 ^ b = 0
    test dh, 80h
    jz .log
    jmp err_func
.log:
    call flog
    mov cx, [cs:fy + 2]
    mov bx, [cs:fy]
    call fmul
    jmp fexp

; ---------- RND ----------
;
; x = (x * 214013 + 2531011) mod 2^24, RND = x / 2^24

frnd_next:
    mov ax, [cs:rnd_seed]
    mov dx, [cs:rnd_seed + 2]
    mov bx, 4335h                   ; 214013 = 3:4335h
    mov cx, ax
    mul bx                          ; low * low
    push ax
    push dx
    mov ax, cx
    mov bx, 3
    mul bx                          ; low * high
    pop cx
    add cx, ax
    mov ax, [cs:rnd_seed + 2]
    mov bx, 4335h
    mul bx                          ; high * low
    add cx, ax
    pop ax
    add ax, 9DC3h                   ; 2531011 = 26:9DC3h
    adc cx, 26h
    and cx, 0FFh
    mov [cs:rnd_seed], ax
    mov [cs:rnd_seed + 2], cx
    ret

; The seed as a real in [0, 1)
frnd_value:
    mov ax, [cs:rnd_seed]
    mov dx, [cs:rnd_seed + 2]
    call l2f
    mov cx, -24
    jmp fscale

op_rnd:
    pop ax
    pop dx
    test dh, 80h                    ; negative: a new seed from it
    jz .not_negative
    call rnd_reseed
    jmp .next
.not_negative:
    mov cx, dx
    and cx, 7FFFh
    or cx, ax
    jz .same                        ; 0: the last one again
.next:
    call frnd_next
.same:
    call frnd_value
    push dx
    push ax
    jmp next_op

; DX:AX (a real) -> the seed
rnd_reseed:
    xor ax, dx
    mov [cs:rnd_seed + 1], ax
    and byte [cs:rnd_seed + 3], 0
    ret

op_randomize:
    pop ax
    pop dx
    call rnd_reseed
    jmp next_op

op_randomize_timer:
    call timer_value
    call rnd_reseed
    jmp next_op

; TIMER: seconds since midnight
timer_value:
    push ds
    xor ax, ax
    mov ds, ax
    mov ax, [46Ch]
    mov dx, [46Eh]
    pop ds
    call l2f
    mov bx, c_tick
    jmp fmul_c

op_timer:
    call timer_value
    push dx
    push ax
    jmp next_op

; ---------- the numeric functions ----------

op_abs_i:
    pop ax
    or ax, ax
    jns .ok
    neg ax
    jo .over
.ok:
    push ax
    jmp next_op
.over:
    jmp err_overflow
op_abs_l:
    pop ax
    pop dx
    or dx, dx
    jns .ok
    neg dx
    neg ax
    sbb dx, 0
    jo .over
.ok:
    push dx
    push ax
    jmp next_op
.over:
    jmp err_overflow
op_abs_s:
    pop ax
    pop dx
    and dh, 7Fh
    push dx
    push ax
    jmp next_op

op_sgn_i:
    pop ax
    call sgn_ax
    push ax
    jmp next_op
op_sgn_l:
    pop ax
    pop dx
    or ax, ax
    jz .low_zero
    or dx, 1                        ; any bit, keeping the sign
.low_zero:
    mov ax, dx
    call sgn_ax
    push ax
    jmp next_op
op_sgn_s:
    pop ax
    pop dx
    mov cx, dx
    and cx, 7FFFh
    or cx, ax
    jz .zero
    mov ax, 1
    test dh, 80h
    jz .push
    neg ax
    jmp .push
.zero:
    xor ax, ax
.push:
    push ax
    jmp next_op

sgn_ax:
    or ax, ax
    jz .ret
    mov ax, 1
    jns .ret
    neg ax
.ret:
    ret

op_int_s:
    pop ax
    pop dx
    call ffloor
    push dx
    push ax
    jmp next_op
op_fix_s:
    pop ax
    pop dx
    call ffix
    push dx
    push ax
    jmp next_op

; A function of one real (BX = the routine)
real_function:
    pop ax
    pop dx
    call bx
    push dx
    push ax
    jmp next_op

op_sin:
    mov bx, fsin
    jmp real_function
op_cos:
    mov bx, fcos
    jmp real_function
op_tan:
    mov bx, ftan
    jmp real_function
op_atn:
    mov bx, fatn
    jmp real_function
op_sqr:
    mov bx, fsqrt
    jmp real_function
op_exp:
    mov bx, fexp
    jmp real_function
op_log:
    mov bx, flog
    jmp real_function

; ---------- numbers as text ----------

; DX:AX (long) in decimal at CS:DI (sign: a space or -), DI past it
format_long:
    push bx
    push cx
    mov byte [cs:di], ' '
    or dx, dx
    jns .positive
    mov byte [cs:di], '-'
    neg dx
    neg ax
    sbb dx, 0
.positive:
    inc di
    mov bx, 10
    xor cx, cx
.digit:                             ; DX:AX / 10
    push ax
    mov ax, dx
    xor dx, dx
    div bx
    mov [cs:fmt_hi], ax
    pop ax
    div bx
    push dx
    inc cx
    mov dx, [cs:fmt_hi]
    push ax
    or ax, dx
    pop ax
    jnz .digit
.put:
    pop ax
    add al, '0'
    mov [cs:di], al
    inc di
    loop .put
    pop cx
    pop bx
    ret

; DX:AX (real) as text at CS:DI, as PRINT shows it (7 digits), DI past it
format_real:
    push si
    mov byte [cs:di], ' '
    test dh, 80h
    jz .positive
    mov byte [cs:di], '-'
    and dh, 7Fh
.positive:
    inc di
    mov cx, dx
    or cx, ax
    jnz .not_zero
    mov byte [cs:di], '0'
    inc di
    pop si
    ret
.not_zero:
    push di
    ; the decimal exponent, about: binary exponent * log10(2)
    mov cx, dx
    shl cx, 1
    mov cl, ch
    xor ch, ch
    sub cx, 127
    push ax
    push dx
    mov ax, cx
    mov cx, 77
    imul cx
    sar ax, 1
    sar ax, 1
    sar ax, 1
    sar ax, 1
    sar ax, 1
    sar ax, 1
    sar ax, 1
    sar ax, 1
    mov [cs:fmt_e10], ax
    pop dx
    pop ax
    mov bx, fx
    call fstore
    mov byte [cs:fmt_iter], 0
.scale:
    ; y = x * 10^(7 - e10), to be in [1e7, 1e8): 8 digits, rounded to 7
    mov bx, fx
    call fload
    mov cx, 7
    sub cx, [cs:fmt_e10]
    call scale10
    inc byte [cs:fmt_iter]          ; (a value on the edge: no going back
    cmp byte [cs:fmt_iter], 3       ; and forth)
    ja .in_range
    mov cx, [cs:c_p8 + 2]
    mov bx, [cs:c_p8]
    call fcmp_keep
    cmp bl, 0
    je .below_e8
    inc word [cs:fmt_e10]
    jmp .scale
.below_e8:
    mov cx, [cs:c_e7 + 2]
    mov bx, [cs:c_e7]
    call fcmp_keep
    cmp bl, 0
    jne .in_range
    dec word [cs:fmt_e10]
    jmp .scale
.in_range:
    call f2l_round
    add ax, 5                       ; / 10, rounded
    adc dx, 0
    mov bx, 10
    push ax
    mov ax, dx
    xor dx, dx
    div bx
    mov cx, ax
    pop ax
    div bx
    mov dx, cx
    cmp dx, 98h                     ; 10000000 = 98:9680h
    jb .digits
    ja .ten
    cmp ax, 9680h
    jb .digits
.ten:
    mov ax, 4240h                   ; 1000000
    mov dx, 0Fh
    inc word [cs:fmt_e10]
.digits:
    mov di, fmt_digits              ; seven digits
    call format_long
    mov si, fmt_digits + 1
    mov cx, 7                       ; without the zeros at the end
.strip:
    mov bx, cx
    cmp byte [cs:si + bx - 1], '0'
    jne .stripped
    loop .strip
.stripped:
    pop di
    mov ax, [cs:fmt_e10]
    cmp ax, 7
    jge .scientific
    cmp ax, -3
    jl .scientific
    or ax, ax
    js .fraction
    ; digits, padded with zeros up to e10 + 1, then the rest after a dot
    inc ax
    xor bx, bx
.int_part:
    cmp bx, ax
    jae .int_done
    mov dl, '0'
    cmp bx, cx
    jae .put_int
    mov dl, [cs:si + bx]
.put_int:
    mov [cs:di], dl
    inc di
    inc bx
    jmp .int_part
.int_done:
    cmp bx, cx
    jae .done
    mov byte [cs:di], '.'
    inc di
.frac_digits:
    mov dl, [cs:si + bx]
    mov [cs:di], dl
    inc di
    inc bx
    cmp bx, cx
    jb .frac_digits
    jmp .done
.fraction:                          ; .000ddd
    mov byte [cs:di], '.'
    inc di
    neg ax
    dec ax
.zeros:
    or ax, ax
    jz .after_zeros
    mov byte [cs:di], '0'
    inc di
    dec ax
    jmp .zeros
.after_zeros:
    xor bx, bx
    jmp .frac_digits
.scientific:                        ; d.dddE+xx
    mov dl, [cs:si]
    mov [cs:di], dl
    inc di
    cmp cx, 1
    je .exponent
    mov byte [cs:di], '.'
    inc di
    mov bx, 1
.sci_digits:
    mov dl, [cs:si + bx]
    mov [cs:di], dl
    inc di
    inc bx
    cmp bx, cx
    jb .sci_digits
.exponent:
    mov byte [cs:di], 'E'
    inc di
    mov ax, [cs:fmt_e10]
    mov dl, '+'
    or ax, ax
    jns .exp_sign
    mov dl, '-'
    neg ax
.exp_sign:
    mov [cs:di], dl
    inc di
    mov bl, 10
    div bl
    add ax, '00'
    mov [cs:di], al
    mov [cs:di + 1], ah
    add di, 2
.done:
    pop si
    ret

; DX:AX * 10^CX (CX signed): multiplying by 10, 100, 10^4, 10^8, 10^16,
; 10^32 for the bits of |CX|, or dividing for a negative CX
scale10:
    push si
    mov si, fdiv
    or cx, cx
    jns .positive
    neg cx
    jmp .go
.positive:
    mov si, fmul
.go:
    mov bx, c_p1
.bit:
    or cx, cx
    jz .done
    shr cx, 1
    jnc .next
    push cx
    push bx
    call fconst
    call si
    pop bx
    pop cx
.next:
    add bx, 4
    jmp .bit
.done:
    pop si
    ret

; Text at DS:SI (spaces, sign, digits, a dot, E or D and an exponent, or
; &H / &O) -> BL = TY_LNG with DX:AX when it is a whole number that fits,
; else BL = TY_SNG with DX:AX. SI past it. CF if there were no digits.
text_to_number:
    push cx
    push di
.blank:
    lodsb
    cmp al, ' '
    je .blank
    cmp al, 9
    je .blank
    mov byte [cs:num_neg], 0
    cmp al, '-'
    jne .not_minus
    mov byte [cs:num_neg], 1
    jmp .sign_done
.not_minus:
    cmp al, '+'
    je .sign_done
    dec si
.sign_done:
    cmp byte [si], '&'
    jne .decimal
    mov bx, 16
    mov al, [si + 1]
    and al, 0DFh
    cmp al, 'H'
    je .radix
    mov bx, 8
    cmp al, 'O'
    je .radix
    jmp .bad
.radix:
    add si, 2
    xor ax, ax
    xor dx, dx
    xor di, di                      ; digits seen
.radix_digit:
    mov cl, [si]
    sub cl, '0'
    cmp cl, 9
    jbe .radix_value
    mov cl, [si]
    and cl, 0DFh
    sub cl, 'A' - 10
    cmp cl, 10
    jb .radix_end
.radix_value:
    xor ch, ch
    cmp cx, bx
    jae .radix_end
    push cx
    push bx
    mov cx, ax
    mov ax, dx
    mul bx
    xchg ax, cx
    mul bx
    add dx, cx
    pop bx
    pop cx
    add ax, cx
    adc dx, 0
    inc si
    inc di
    jmp .radix_digit
.radix_end:
    or di, di
    jnz .skip4
    jmp .bad
.skip4:
    or dx, dx                       ; &HFFFF is -1
    jz .skip3
    jmp .long
.skip3:
    cwd
    jmp .long
.decimal:
    ; up to 9 significant digits in mantissa, the rest counted
    mov word [cs:num_mant], 0
    mov word [cs:num_mant + 2], 0
    mov word [cs:num_e10], 0
    mov byte [cs:num_digits], 0     ; significant digits kept
    mov byte [cs:num_real], 0
    xor di, di                      ; digits seen
.int_digit:
    mov al, [si]
    sub al, '0'
    cmp al, 9
    ja .int_end
    inc si
    inc di
    call num_add_digit
    jmp .int_digit
.int_end:
    cmp byte [si], '.'
    jne .exponent
    inc si
    mov byte [cs:num_real], 1
.frac_digit:
    mov al, [si]
    sub al, '0'
    cmp al, 9
    ja .exponent
    inc si
    inc di
    call num_add_digit
    dec word [cs:num_e10]
    jmp .frac_digit
.exponent:
    or di, di
    jnz .skip2
    jmp .bad
.skip2:
    mov al, [si]
    and al, 0DFh
    cmp al, 'E'
    je .has_exp
    cmp al, 'D'
    jne .suffix
.has_exp:
    mov byte [cs:num_real], 1
    inc si
    xor cx, cx                      ; the exponent
    xor bx, bx                      ; its sign
    cmp byte [si], '-'
    jne .exp_plus
    inc bx
    inc si
    jmp .exp_digit
.exp_plus:
    cmp byte [si], '+'
    jne .exp_digit
    inc si
.exp_digit:
    mov al, [si]
    sub al, '0'
    cmp al, 9
    ja .exp_end
    inc si
    cmp cx, 1000
    jae .exp_digit
    xor ah, ah
    push ax
    mov ax, 10
    mul cx
    pop cx
    add cx, ax
    jmp .exp_digit
.exp_end:
    or bx, bx
    jz .exp_add
    neg cx
.exp_add:
    add [cs:num_e10], cx
.suffix:
    mov al, [si]                    ; a type suffix is allowed
    cmp al, '!'
    je .real_suffix
    cmp al, '#'
    je .real_suffix
    cmp al, '%'
    je .skip_suffix
    cmp al, '&'
    jne .value
.skip_suffix:
    inc si
    jmp .value
.real_suffix:
    inc si
    mov byte [cs:num_real], 1
.value:
    mov ax, [cs:num_mant]
    mov dx, [cs:num_mant + 2]
    cmp byte [cs:num_real], 0
    jne .real
    cmp word [cs:num_e10], 0        ; digits dropped: too big for a long
    jne .real
    test dh, 80h
    jnz .real
    cmp byte [cs:num_neg], 0
    je .long_positive
    neg dx
    neg ax
    sbb dx, 0
.long_positive:
    mov bl, TY_LNG
    jmp .ok
.long:
    cmp byte [cs:num_neg], 0
    je .long_positive
    neg dx
    neg ax
    sbb dx, 0
    jmp .long_positive
.real:
    call l2f
    mov cx, [cs:num_e10]
    cmp cx, 60
    jg .over
    cmp cx, -60
    jl .tiny
    call scale10
    jmp .real_sign
.tiny:
    xor ax, ax
    xor dx, dx
.real_sign:
    cmp byte [cs:num_neg], 0
    je .real_done
    mov cx, dx
    or cx, ax
    jz .real_done
    xor dh, 80h
.real_done:
    mov bl, TY_SNG
.ok:
    clc
    jmp .ret
.over:
    jmp err_overflow
.bad:
    xor ax, ax
    xor dx, dx
    mov bl, TY_LNG
    stc
.ret:
    pop di
    pop cx
    ret

; One more digit (AL) for text_to_number
num_add_digit:
    cmp byte [cs:num_digits], 0     ; leading zeros do not count
    jne .count
    or al, al
    jz .ret
.count:
    cmp byte [cs:num_digits], 9
    jb .keep
    inc word [cs:num_e10]           ; dropped: one more power of ten
    ret
.keep:
    inc byte [cs:num_digits]
    push bx
    push cx
    push dx
    xor ah, ah
    push ax
    mov ax, [cs:num_mant]
    mov bx, 10
    mul bx
    mov [cs:num_mant], ax
    mov cx, dx
    mov ax, [cs:num_mant + 2]
    mul bx
    add ax, cx
    mov [cs:num_mant + 2], ax
    pop ax
    add [cs:num_mant], ax
    adc word [cs:num_mant + 2], 0
    pop dx
    pop cx
    pop bx
.ret:
    ret

; The compiler's number reader: ASCIIZ digits at SI -> DX:AX real
str_to_sng:
    push bx
    call text_to_number
    cmp bl, TY_SNG
    pop bx
    je .done
    call l2f
.done:
    ret

; STR$ of each type: the text, as a temporary string
op_str_i:
    pop ax
    cwd
    jmp str_long
op_str_l:
    pop ax
    pop dx
str_long:
    mov di, numbuf
    call format_long
    jmp numbuf_string
op_str_s:
    pop ax
    pop dx
    mov di, numbuf
    call format_real
; The text from numbuf up to DI as a temporary string (pushed)
numbuf_string:
    mov cx, di
    sub cx, numbuf
    call str_new_temp
    push di
    push si
    push ds
    push es
    mov es, [cs:seg_str]
    mov di, ax
    push cs
    pop ds
    mov si, numbuf
    rep movsb
    pop es
    pop ds
    pop si
    jmp next_op

; VAL(s)
op_val:
    pop bx
    call string_to_numbuf
    push si
    push ds
    push cs
    pop ds
    mov si, numbuf
    call text_to_number
    pop ds
    pop si
    cmp bl, TY_SNG
    je .push
    call l2f
.push:
    push dx
    push ax
    jmp next_op

; The string at BX (data segment) into numbuf, ASCIIZ (at most 60)
string_to_numbuf:
    push si
    push ds
    push es
    mov cx, [es:bx + 2]
    cmp cx, 60
    jbe .len
    mov cx, 60
.len:
    mov si, [es:bx]
    mov ds, [cs:seg_str]
    push cs
    pop es
    mov di, numbuf
    rep movsb
    mov byte [es:di], 0
    pop es
    pop ds
    pop si
    ret

; HEX$ / OCT$ of a long
op_hex:
    mov cl, 4
    mov bx, 0Fh
    jmp radix_string
op_oct:
    mov cl, 3
    mov bx, 7
radix_string:
    pop ax
    pop dx
    mov di, numbuf + 12
.digit:
    push ax
    and ax, bx
    add al, '0'
    cmp al, '9'
    jbe .store
    add al, 'A' - '9' - 1
.store:
    dec di
    mov [cs:di], al
    pop ax
    push cx
    xor ch, ch
.shift:
    shr dx, 1
    rcr ax, 1
    loop .shift
    pop cx
    push ax
    or ax, dx
    pop ax
    jnz .digit
    push si                         ; the digits move to numbuf
    push ds
    push es
    push cs
    pop ds
    push cs
    pop es
    mov si, di
    mov di, numbuf
    mov cx, numbuf + 12
    sub cx, si
    rep movsb
    pop es
    pop ds
    pop si
    jmp numbuf_string

; ======================================================================
; The screen
; ======================================================================
;
; SCREEN 0: text 80x25 in B800 (written directly). SCREEN 13: 320x200
; with 256 colors. SCREEN 1: 320x200 with 4 colors, on the same VGA mode
; (colors 0-3 are DAC entries 0-3, set to a CGA palette). In graphics
; modes the text is 40x25, drawn by the BIOS. The text cursor (row, col)
; is kept here; col = cols means "the next character goes on a new line".

scr_init:
    mov byte [scr_mode], 0
    mov byte [scr_cols], 80
    mov byte [scr_attr], 07h
    mov byte [view_top], 0
    mov byte [view_bottom], 24
    mov ah, 03h                     ; continue where COS left the cursor
    xor bh, bh
    int 10h
    mov [cur_row], dh
    mov [cur_col], dl
    ret

; Before printing a message of the system: text mode, at a new line
scr_error_mode:
    cmp byte [scr_mode], 0
    je .text
    call scr_set_text
.text:
    cmp byte [cur_col], 0
    je .sync
    call scr_newline
.sync:
    call scr_sync
    ret

; Text mode for a compile error (nothing has been drawn yet)
scr_text_mode:
    ret

; At the end of the program: graphics wait for a key, then text mode
scr_end:
    cmp byte [scr_mode], 0
    je .text
    mov ah, 00h
    int 16h
    call scr_set_text
.text:
    call scr_sync
    ret

; Mode 03h, clear, cursor home
scr_set_text:
    mov ax, 0003h
    int 10h
    mov byte [cs:scr_mode], 0
    mov byte [cs:scr_cols], 80
    mov byte [cs:scr_attr], 07h
    mov byte [cs:view_top], 0
    mov byte [cs:view_bottom], 24
    mov byte [cs:cur_row], 0
    mov byte [cs:cur_col], 0
    ret

; The hardware cursor where ours is
scr_sync:
    push ax
    push bx
    push dx
    mov dh, [cs:cur_row]
    mov dl, [cs:cur_col]
    cmp dl, [cs:scr_cols]
    jb .ok
    mov dl, [cs:scr_cols]
    dec dl
.ok:
    mov ah, 02h
    xor bh, bh
    int 10h
    pop dx
    pop bx
    pop ax
    ret

; Writes AL at the cursor and moves on (control characters act)
scr_putc:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    cmp al, 13
    je .newline
    cmp al, 10
    je .newline
    cmp al, 7
    je .bell
    cmp al, 9
    je .tab
    mov ah, [cs:cur_col]
    cmp ah, [cs:scr_cols]           ; a line that was full: a new one
    jb .here
    push ax
    call scr_newline
    pop ax
.here:
    call scr_char
    inc byte [cs:cur_col]
    jmp .done
.newline:
    call scr_newline
    jmp .done
.bell:
    call beep
    jmp .done
.tab:
    mov al, ' '
    call scr_putc
    test byte [cs:cur_col], 7
    jz .done
    mov ah, [cs:cur_col]
    cmp ah, [cs:scr_cols]
    jb .tab
.done:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; AL at (cur_row, cur_col), without moving
scr_char:
    push es
    push di
    call .draw
    pop di
    pop es
    ret
.draw:
    cmp byte [cs:scr_mode], 0
    jne .graphics
    mov bl, al
    mov al, [cs:cur_row]
    mov ah, 80
    mul ah
    add al, [cs:cur_col]
    adc ah, 0
    shl ax, 1
    mov di, ax
    mov ax, 0B800h
    mov es, ax
    mov al, bl
    mov ah, [cs:scr_attr]
    mov [es:di], ax
    ret
.graphics:
    push ax
    call scr_sync
    pop ax
    mov ah, 09h
    mov bl, [cs:scr_fg]
    xor bh, bh
    mov cx, 1
    int 10h
    ret

; To the start of the next line, scrolling the text window if needed
scr_newline:
    mov byte [cs:cur_col], 0
    mov al, [cs:cur_row]
    cmp al, [cs:view_bottom]
    jae .scroll
    inc byte [cs:cur_row]
    ret
.scroll:
    mov al, [cs:view_bottom]
    mov [cs:cur_row], al
; Scrolls the text window one line up
scr_scroll:
    push ds
    push es
    push si
    cmp byte [cs:scr_mode], 0
    jne .graphics
    mov ax, 0B800h
    mov ds, ax
    mov es, ax
    mov al, [cs:view_top]
    mov ah, 160
    mul ah
    mov di, ax
    lea si, [di + 160]
    mov al, [cs:view_bottom]
    sub al, [cs:view_top]
    mov ah, 80
    mul ah
    mov cx, ax
    rep movsw
    mov cx, 80
    mov al, ' '
    mov ah, [cs:scr_attr]
    rep stosw
    jmp .done
.graphics:
    mov ax, 0A000h
    mov ds, ax
    mov es, ax
    mov al, [cs:view_top]
    xor ah, ah
    mov cx, 2560
    mul cx
    mov di, ax
    lea si, [di + 2560]
    mov al, [cs:view_bottom]
    sub al, [cs:view_top]
    xor ah, ah
    mov cx, 1280
    mul cx
    mov cx, ax
    rep movsw
    mov cx, 1280
    xor ax, ax
    rep stosw
.done:
    pop si
    pop es
    pop ds
    ret

; Clears rows AL..AH (text: with the attribute)
scr_clear_rows:
    push ax
    push bx
    push cx
    push di
    push es
    mov bx, ax
    cmp byte [cs:scr_mode], 0
    jne .graphics
    mov ax, 0B800h
    mov es, ax
    mov al, bl
    mov ah, 160
    mul ah
    mov di, ax
    mov al, bh
    sub al, bl
    inc al
    mov ah, 80
    mul ah
    mov cx, ax
    mov al, ' '
    mov ah, [cs:scr_attr]
    rep stosw
    jmp .done
.graphics:
    mov ax, 0A000h
    mov es, ax
    mov al, bl
    xor ah, ah
    mov cx, 2560
    mul cx
    mov di, ax
    mov al, bh
    sub al, bl
    inc al
    xor ah, ah
    mov cx, 1280
    mul cx
    mov cx, ax
    xor ax, ax
    rep stosw
.done:
    pop es
    pop di
    pop cx
    pop bx
    pop ax
    ret

; ---------- statements ----------

; CLS [n]
op_cls:
    lodsb
    test al, 1
    jz .default
    pop ax
    cmp ax, 2
    ja .bad
    or ax, ax
    jz .all
.default:
    cmp byte [cs:scr_mode], 0
    jne .all
    mov al, [cs:view_top]
    mov ah, [cs:view_bottom]
    call scr_clear_rows
    jmp .home
.all:
    mov al, 0
    mov ah, 24
    call scr_clear_rows
.home:
    mov al, [cs:view_top]
    mov [cs:cur_row], al
    mov byte [cs:cur_col], 0
    call scr_sync
    mov word [cs:gfx_x], 160
    mov word [cs:gfx_y], 100
    jmp next_op
.bad:
    jmp err_func

; LOCATE [row][, col][, cursor]...: the mask of those given
op_locate:
    lodsb
    mov dl, al
    test dl, 10h                    ; start, stop, cursor: shape (ignored)
    jz .no_stop
    pop ax
.no_stop:
    test dl, 8
    jz .no_start
    pop ax
.no_start:
    test dl, 4
    jz .no_cursor
    pop ax
    call cursor_visible
.no_cursor:
    test dl, 2
    jz .no_col
    pop ax
    dec ax
    cmp al, [cs:scr_cols]
    jae .bad
    or ah, ah
    jnz .bad
    mov [cs:cur_col], al
.no_col:
    test dl, 1
    jz .done
    pop ax
    dec ax
    or ah, ah
    jnz .bad
    cmp al, 24
    ja .bad
    mov [cs:cur_row], al
.done:
    call scr_sync
    jmp next_op
.bad:
    jmp err_func

; AX = 0: the cursor off, else on
cursor_visible:
    push cx
    mov cx, 0607h
    or ax, ax
    jnz .set
    mov cx, 2000h
.set:
    mov ah, 01h
    int 10h
    pop cx
    ret

; COLOR [a][, b][, c]
op_color:
    lodsb
    mov dl, al
    test dl, 4
    jz .no_border
    pop ax
.no_border:
    xor cx, cx                      ; CL = second (if any), CH = given
    test dl, 2
    jz .no_second
    pop cx
    mov ch, 1
.no_second:
    xor bx, bx
    test dl, 1
    jz .no_first
    pop bx
    mov bh, 1
.no_first:
    mov al, [cs:scr_mode]
    cmp al, 0
    je .text
    cmp al, 1
    je .cga
    ; SCREEN 13: COLOR foreground
    or bh, bh
    jz .done
    mov [cs:scr_fg], bl
    jmp .done
.cga:                               ; SCREEN 1: COLOR background, palette
    or bh, bh
    jz .palette
    mov al, bl
    and al, 15
    mov ah, 0
    call dac_ega16
.palette:
    or ch, ch
    jz .done
    and cl, 1
    mov [cs:cga_palette], cl
    call cga_colors
    jmp .done
.text:
    mov al, [cs:scr_attr]
    or bh, bh
    jz .text_bg
    and al, 70h                     ; foreground 0-15, +16 blinks
    mov ah, bl
    and ah, 0Fh
    or al, ah
    test bl, 10h
    jz .text_bg
    or al, 80h
.text_bg:
    or ch, ch
    jz .text_done
    and al, 8Fh
    and cl, 7
    shl cl, 1
    shl cl, 1
    shl cl, 1
    shl cl, 1
    or al, cl
.text_done:
    mov [cs:scr_attr], al
.done:
    jmp next_op

; DAC entry AH = the EGA color AL (0-15)
dac_ega16:
    push bx
    mov bl, al
    xor bh, bh
    mov al, [cs:ega16 + bx]
    pop bx
; DAC entry AH = the EGA color AL (0-63: rgbRGB)
dac_ega64:
    push ax
    push bx
    push cx
    push dx
    mov bl, al
    mov al, ah
    mov dx, 3C8h
    out dx, al
    inc dx
    mov cl, 2                       ; red: bits 2 and 5
    call .component
    mov cl, 1                       ; green: bits 1 and 4
    call .component
    mov cl, 0                       ; blue: bits 0 and 3
    call .component
    pop dx
    pop cx
    pop bx
    pop ax
    ret
.component:
    mov al, bl
    shr al, cl
    mov bh, al
    and al, 1
    mov ch, 42
    mul ch
    test bh, 8                      ; the low-intensity bit, 3 above
    jz .out
    add al, 21
.out:
    out dx, al
    ret

ega16       db 0, 1, 2, 3, 4, 5, 20, 7, 56, 57, 58, 59, 60, 61, 62, 63

; SCREEN 1's colors 1-3 from the CGA palette chosen
cga_colors:
    push ax
    push bx
    mov bl, [cs:cga_palette]
    xor bh, bh
    shl bx, 1
    add bx, bx
    mov ah, 1
.color:
    mov al, [cs:cga_sets + bx]
    call dac_ega16
    inc bx
    inc ah
    cmp ah, 4
    jb .color
    pop bx
    pop ax
    ret

cga_sets    db 2, 4, 6, 0               ; palette 0: green, red, brown
            db 3, 5, 7, 0               ; palette 1: cyan, magenta, white

; SCREEN mode
op_screen:
    lodsb
    mov dl, al
    test dl, 8
    jz .no4
    pop ax
.no4:
    test dl, 4
    jz .no3
    pop ax
.no3:
    test dl, 2
    jz .no2
    pop ax
.no2:
    test dl, 1
    jz .done
    pop ax
    cmp ax, 0
    je .text
    cmp ax, 1
    je .cga
    cmp ax, 13
    je .vga
    jmp err_func
.text:
    cmp byte [cs:scr_mode], 0
    je .done
    call scr_set_text
    jmp .done
.cga:
    cmp byte [cs:scr_mode], 1
    je .done
    call gfx_mode
    mov byte [cs:scr_mode], 1
    mov byte [cs:scr_fg], 3
    mov byte [cs:cga_palette], 1
    mov ax, 0                       ; background black
    call dac_ega16
    call cga_colors
    jmp .done
.vga:
    cmp byte [cs:scr_mode], 13
    je .done
    call gfx_mode
    mov byte [cs:scr_mode], 13
    mov byte [cs:scr_fg], 15
.done:
    jmp next_op

; Mode 13h with a clean state
gfx_mode:
    mov ax, 0013h
    int 10h
    mov byte [cs:scr_cols], 40
    mov byte [cs:view_top], 0
    mov byte [cs:view_bottom], 24
    mov byte [cs:cur_row], 0
    mov byte [cs:cur_col], 0
    mov word [cs:gfx_x], 160
    mov word [cs:gfx_y], 100
    ret

op_width:
    lodsb
    test al, 2
    jz .no_rows
    pop bx
.no_rows:
    test al, 1
    jz .done
    pop bx
.done:
    jmp next_op

; VIEW PRINT top TO bottom (0, 0: the whole screen)
op_view_print:
    pop bx
    pop ax
    or ax, ax
    jnz .rows
    mov ax, 1
    mov bx, 25
.rows:
    dec ax
    dec bx
    cmp ax, bx
    ja .bad
    cmp bx, 24
    ja .bad
    mov [cs:view_top], al
    mov [cs:view_bottom], bl
    mov [cs:cur_row], al
    mov byte [cs:cur_col], 0
    call scr_sync
    jmp next_op
.bad:
    jmp err_func

; PALETTE attribute, color
op_palette:
    pop ax                          ; the color (long: low word on top)
    pop dx
    pop bx                          ; the attribute
    cmp byte [cs:scr_mode], 0
    je .text
    cmp byte [cs:scr_mode], 1
    je .cga
    ; SCREEN 13: red + 256 * green + 65536 * blue
    push dx
    push ax
    mov al, bl
    mov dx, 3C8h
    out dx, al
    inc dx
    pop ax
    push ax
    and al, 3Fh
    out dx, al
    pop ax
    mov al, ah
    and al, 3Fh
    out dx, al
    pop ax
    and al, 3Fh
    out dx, al
    jmp next_op
.cga:
    cmp bx, 3
    ja .bad
    mov ah, bl
    and al, 15
    call dac_ega16
    jmp next_op
.text:
    mov bh, al
    mov ax, 1000h
    int 10h
    jmp next_op
.bad:
    jmp err_func

op_palette_reset:
    cmp byte [cs:scr_mode], 1
    jne .not_cga
    xor ax, ax
    call dac_ega16
    call cga_colors
    jmp next_op
.not_cga:
    xor ah, ah
.entry:
    mov al, ah
    call dac_ega16
    inc ah
    cmp ah, 16
    jb .entry
    jmp next_op

; ---------- PRINT ----------

op_out_screen:
    mov byte [cs:out_file], 0
    call scr_sync
    jmp next_op

op_out_file:
    pop ax
    call file_slot                  ; BX = its slot
    cmp byte [cs:bx + F_MODE], 2
    jb .bad
    mov [cs:out_file], al
    jmp next_op
.bad:
    mov al, E_FILEMODE
    jmp rt_error

; AL to where PRINT goes
out_char:
    cmp byte [cs:out_file], 0
    jne .file
    jmp scr_putc
.file:
    push bx
    push ax
    mov al, [cs:out_file]
    call file_slot
    pop ax
    call file_putc
    pop bx
    ret

; The column where PRINT is (0-based)
out_column:
    cmp byte [cs:out_file], 0
    jne .file
    mov al, [cs:cur_col]
    ret
.file:
    push bx
    mov al, [cs:out_file]
    call file_slot
    mov al, [cs:bx + F_COL]
    pop bx
    ret

; The characters of numbuf up to DI
out_numbuf:
    push si
    mov si, numbuf
.char:
    cmp si, di
    jae .done
    mov al, [cs:si]
    call out_char
    inc si
    jmp .char
.done:
    pop si
    ret

op_print_i:
    pop ax
    cwd
    jmp print_long
op_print_l:
    pop ax
    pop dx
print_long:
    mov di, numbuf
    call format_long
    jmp print_number
op_print_s:
    pop ax
    pop dx
    mov di, numbuf
    call format_real
print_number:
    mov byte [cs:di], ' '
    inc di
    call out_numbuf
    jmp next_op

op_print_str:
    pop bx
    call out_string
    jmp next_op

; The string at BX to where PRINT goes
out_string:
    push si
    push ds
    mov cx, [es:bx + 2]
    mov si, [es:bx]
    mov ds, [cs:seg_str]
    jcxz .done
.char:
    lodsb
    call out_char
    loop .char
.done:
    pop ds
    pop si
    ret

op_print_nl:
    cmp byte [cs:out_file], 0
    jne .file
    call scr_newline
    jmp next_op
.file:
    mov al, 13
    call out_char
    mov al, 10
    call out_char
    jmp next_op

op_print_comma:
    call out_column
    xor ah, ah
    mov bl, 14
    div bl
    inc al
    mul bl                          ; the next zone
    cmp byte [cs:out_file], 0
    jne .spaces
    mov bl, [cs:scr_cols]
    sub bl, 14
    cmp al, bl
    jbe .spaces
    call scr_newline
    jmp next_op
.spaces:
    mov cl, al
.space:
    call out_column
    cmp al, cl
    jae .done
    mov al, ' '
    call out_char
    jmp .space
.done:
    jmp next_op

op_print_tab:
    pop cx
    dec cx
    jns .ok
    xor cx, cx
.ok:
    cmp byte [cs:out_file], 0
    jne .move
    mov al, [cs:scr_cols]
    xor ah, ah
    xchg ax, cx
    xor dx, dx
    div cx
    mov cx, dx
    call out_column
    xor ah, ah
    cmp ax, cx
    jbe .move
    call scr_newline
.move:
    call out_column
    xor ah, ah
    cmp ax, cx
    jae .done
    mov al, ' '
    call out_char
    jmp .move
.done:
    jmp next_op

op_print_spc:
    pop cx
    or cx, cx
    jle .done
.space:
    mov al, ' '
    call out_char
    loop .space
.done:
    jmp next_op

; WRITE: numbers without the leading space, strings in quotes
op_write_i:
    pop ax
    cwd
    jmp write_long
op_write_l:
    pop ax
    pop dx
write_long:
    mov di, numbuf
    call format_long
    jmp write_number
op_write_s:
    pop ax
    pop dx
    mov di, numbuf
    call format_real
write_number:
    push si
    mov si, numbuf
    cmp byte [cs:si], ' '
    jne .char
    inc si
.char:
    cmp si, di
    jae .done
    mov al, [cs:si]
    call out_char
    inc si
    jmp .char
.done:
    pop si
    jmp next_op
op_write_str:
    pop bx
    mov al, '"'
    call out_char
    call out_string
    mov al, '"'
    call out_char
    jmp next_op
op_write_comma:
    mov al, ','
    call out_char
    jmp next_op

; ---------- the keyboard ----------

; INKEY$: "", a character, or CHR$(0) + the scan code
op_inkey:
    mov ah, 01h
    int 16h
    jz .none
    mov ah, 00h
    int 16h
    or al, al
    jz .extended
    cmp al, 0E0h
    je .extended
    call temp_new
    xor ah, ah
    mov [es:di], ax                 ; one of the CHR$ strings
    mov word [es:di + 2], 1
    push di
    jmp next_op
.extended:
    push ax
    mov cx, 2
    call str_new_temp
    pop bx
    push di
    push es
    mov es, [cs:seg_str]
    mov di, ax
    mov byte [es:di], 0
    mov [es:di + 1], bh
    pop es
    jmp next_op
.none:
    call temp_new
    push di
    jmp next_op

; INPUT$(n): n keys
op_input_keys:
    pop cx
    or cx, cx
    jle .bad
    call str_new_temp
    push di
    push es
    mov es, [cs:seg_str]
    mov di, ax
.key:
    mov ah, 00h
    int 16h
    stosb
    loop .key
    pop es
    jmp next_op
.bad:
    jmp err_func

op_csrlin:
    mov al, [cs:cur_row]
    xor ah, ah
    inc ax
    push ax
    jmp next_op

op_pos:
    pop ax
    mov al, [cs:cur_col]
    cmp al, [cs:scr_cols]
    jb .ok
    mov al, [cs:scr_cols]
    dec al
.ok:
    xor ah, ah
    inc ax
    push ax
    jmp next_op

; A line from the keyboard into inbuf (Enter ends it; Backspace)
read_line:
    push si
    call scr_sync
    xor si, si
.key:
    mov ah, 00h
    int 16h
    cmp al, 13
    je .enter
    cmp al, 8
    je .back
    cmp al, 27
    je .escape
    cmp al, ' '
    jb .key
    cmp si, INBUF_SIZE - 1
    jae .key
    mov [cs:inbuf + si], al
    inc si
    call scr_putc
    call scr_sync
    jmp .key
.back:
    or si, si
    jz .key
    dec si
    call scr_back
    jmp .key
.escape:
    or si, si
    jz .key
    dec si
    call scr_back
    jmp .escape
.enter:
    mov byte [cs:inbuf + si], 0
    mov [cs:inbuf_len], si
    pop si
    ret

; Erases the character before the cursor
scr_back:
    cmp byte [cs:cur_col], 0
    jne .same_row
    cmp byte [cs:cur_row], 0
    je .done
    dec byte [cs:cur_row]
    mov al, [cs:scr_cols]
    mov [cs:cur_col], al
.same_row:
    dec byte [cs:cur_col]
    mov al, ' '
    call scr_char
    call scr_sync
.done:
    ret

; ---------- INPUT ----------

; INPUT_BEGIN flags (1: ;  2: no "? "  4: no prompt): the prompt (a string
; or 0) is on the stack. Reads the line.
op_input_begin:
    lodsb
    mov dl, al
    pop bx
    test dl, 4
    jnz .no_prompt
    push dx
    call out_string
    pop dx
.no_prompt:
    test dl, 2
    jnz .no_question
    mov al, '?'
    call scr_putc
    mov al, ' '
    call scr_putc
.no_question:
    push dx
    call read_line
    pop dx
    test dl, 1
    jnz .stay
    call scr_newline
.stay:
    call scr_sync
    mov word [cs:in_pos], 0
    mov byte [cs:in_err], 0
    mov byte [cs:in_fields], 0
    mov byte [cs:in_src], 0
    jmp next_op

; INPUT #n: the fields come from the file
op_input_file:
    pop ax
    call file_slot
    cmp byte [cs:bx + F_MODE], 1
    jne .bad
    mov [cs:in_src], al
    mov byte [cs:in_err], 0
    mov byte [cs:in_fields], 0
    jmp next_op
.bad:
    mov al, E_FILEMODE
    jmp rt_error

; The next field into numbuf (ASCIIZ). CX = its length.
input_field:
    cmp byte [cs:in_src], 0
    je .console
    jmp file_field
.console:
    push si
    push di
    mov si, [cs:in_pos]
    mov di, numbuf
.blank:
    mov al, [cs:inbuf + si]
    cmp al, ' '
    jne .start
    inc si
    jmp .blank
.start:
    or al, al                       ; nothing left
    jnz .some
    cmp byte [cs:in_fields], 0
    je .end
    mov byte [cs:in_err], 1
    jmp .end
.some:
    cmp al, '"'
    jne .plain
    inc si
.quoted:
    mov al, [cs:inbuf + si]
    or al, al
    jz .end
    inc si
    cmp al, '"'
    je .after_quote
    call .store
    jmp .quoted
.after_quote:
    mov al, [cs:inbuf + si]
    or al, al
    jz .end
    cmp al, ','
    je .end
    cmp al, ' '
    jne .junk
    inc si
    jmp .after_quote
.junk:
    mov byte [cs:in_err], 1
    jmp .end
.plain:
    mov al, [cs:inbuf + si]
    or al, al
    jz .trim
    cmp al, ','
    je .trim
    call .store
    inc si
    jmp .plain
.trim:
    cmp di, numbuf
    je .end
    cmp byte [cs:di - 1], ' '
    jne .end
    dec di
    jmp .trim
.end:
    cmp byte [cs:inbuf + si], ','
    jne .no_comma
    inc si
.no_comma:
    mov [cs:in_pos], si
    mov byte [cs:di], 0
    mov cx, di
    sub cx, numbuf
    inc byte [cs:in_fields]
    pop di
    pop si
    ret
.store:
    cmp di, numbuf + NUMBUF_SIZE - 1
    jae .full
    mov [cs:di], al
    inc di
.full:
    ret

; The field as a number: BL = type, DX:AX (in_err if it is not one)
input_number:
    mov byte [cs:in_numeric], 1
    call input_field
    mov byte [cs:in_numeric], 0
    push si
    push ds
    push cs
    pop ds
    mov si, numbuf
    call text_to_number
    jc .bad
    cmp byte [si], 0
    je .ok
.bad:
    cmp byte [cs:numbuf], 0         ; an empty field is 0
    je .zero
    mov byte [cs:in_err], 1
.zero:
    xor ax, ax
    xor dx, dx
    mov bl, TY_LNG
.ok:
    pop ds
    pop si
    ret

op_input_i:
    call input_number
    call number_to_long
    call long_to_int_soft
    push ax
    jmp next_op
op_input_l:
    call input_number
    call number_to_long
    push dx
    push ax
    jmp next_op
op_input_s:
    call input_number
    cmp bl, TY_SNG
    je .real
    call l2f
.real:
    push dx
    push ax
    jmp next_op
op_input_str:
    call input_field
    call numbuf_to_temp
    jmp next_op

; BL = type, DX:AX -> DX:AX long (a real rounded)
number_to_long:
    cmp bl, TY_SNG
    jne .done
    call f2l_round
.done:
    ret

; DX:AX -> AX; too big for an integer: in_err (INPUT) / overflow
long_to_int_soft:
    push dx
    push ax
    cwd
    pop ax
    pop bx
    cmp dx, bx
    je .ok
    cmp byte [cs:in_src], 0
    jne .over
    mov byte [cs:in_err], 1
    xor ax, ax
.ok:
    ret
.over:
    jmp err_overflow

; numbuf (CX characters) as a temporary string, pushed (returns with it
; under the return address)
numbuf_to_temp:
    call str_new_temp
    pop bx
    push di
    push bx
    push si
    push ds
    push es
    mov es, [cs:seg_str]
    mov di, ax
    push cs
    pop ds
    mov si, numbuf
    rep movsb
    pop es
    pop ds
    pop si
    ret

; INPUT_END retry: wrong input on the keyboard: "Redo from start"
op_input_end:
    lodsw
    cmp byte [cs:in_src], 0
    je .console
    mov byte [cs:in_src], 0
    jmp next_op
.console:
    cmp byte [cs:in_err], 0
    jne .redo
    mov bx, [cs:in_pos]             ; more fields than variables?
.extra:
    mov cl, [cs:inbuf + bx]
    or cl, cl
    jz .ok
    cmp cl, ' '
    jne .redo
    inc bx
    jmp .extra
.redo:
    push ax
    mov si, m_redo
.char:
    mov al, [cs:si]
    or al, al
    jz .said
    call scr_putc
    inc si
    jmp .char
.said:
    call scr_newline
    pop si
    jmp next_op
.ok:
    jmp next_op

; LINE INPUT flags: the prompt (or 0) on the stack
op_line_input:
    lodsb
    mov dl, al
    pop bx
    or bx, bx
    jz .no_prompt
    push dx
    call out_string
    pop dx
.no_prompt:
    push dx
    call read_line
    pop dx
    test dl, 1
    jnz .stay
    call scr_newline
.stay:
    call scr_sync
    mov cx, [cs:inbuf_len]
    push si
    push ds
    push cs
    pop ds
    mov si, inbuf
    call text_to_temp
    pop ds
    pop si
    push di
    jmp next_op

; CX characters at DS:SI -> DI = a temporary string with them
text_to_temp:
    push ax
    push bx
    push cx
    push ds
    call str_new_temp
    pop ds
    push es
    push di
    mov es, [cs:seg_str]
    mov di, ax
    rep movsb
    pop di
    pop es
    pop cx
    pop bx
    pop ax
    ret

; ---------- READ ----------

; The next DATA item: CX = its length, DS:SI = its text (DS = the lines
; segment); data_ptr moves past it
data_item:
    mov bx, [cs:data_ptr]
    cmp bx, [cs:data_end]
    jae .out
    mov ds, [cs:seg_lines]
    mov cl, [bx]
    xor ch, ch
    lea si, [bx + 1]
    lea ax, [si]
    add ax, cx
    mov [cs:data_ptr], ax
    ret
.out:
    mov al, E_DATA
    jmp rt_error

; READ into a number: BL = type, DX:AX
read_number:
    push si
    push ds
    call data_item
    push cs
    pop es
    mov di, numbuf
    cmp cx, NUMBUF_SIZE - 1
    jbe .len
    mov cx, NUMBUF_SIZE - 1
.len:
    rep movsb
    mov byte [es:di], 0
    mov es, [cs:seg_data]
    push cs
    pop ds
    mov si, numbuf
    call text_to_number
    jc .bad
    cmp byte [si], 0
    jne .bad
    pop ds
    pop si
    ret
.bad:
    pop ds
    pop si
    mov al, E_SYNTAX
    jmp rt_error

op_read_i:
    call read_number
    call number_to_long
    call long_to_int
    push ax
    jmp next_op
op_read_l:
    call read_number
    call number_to_long
    push dx
    push ax
    jmp next_op
op_read_s:
    call read_number
    cmp bl, TY_SNG
    je .real
    call l2f
.real:
    push dx
    push ax
    jmp next_op
op_read_str:
    push si
    push ds
    call data_item
    call text_to_temp
    pop ds
    pop si
    push di
    jmp next_op

op_restore:
    lodsw
    mov [cs:data_ptr], ax
    jmp next_op

; ---------- memory, ports, time ----------

op_def_seg:
    pop ax
    pop dx
    mov [cs:def_seg], ax
    jmp next_op
op_def_seg_data:
    mov ax, [cs:seg_data]
    mov [cs:def_seg], ax
    jmp next_op

op_peek:
    pop bx
    pop dx
    push es
    mov es, [cs:def_seg]
    mov al, [es:bx]
    pop es
    xor ah, ah
    push ax
    jmp next_op

op_poke:
    pop ax
    pop bx
    pop dx
    push es
    mov es, [cs:def_seg]
    mov [es:bx], al
    pop es
    jmp next_op

op_inp:
    pop dx
    in al, dx
    xor ah, ah
    push ax
    jmp next_op

op_out:
    pop ax                          ; the value
    pop dx                          ; the port (low word of a long)
    pop bx
    out dx, al
    jmp next_op

op_beep:
    call beep
    jmp next_op

; SLEEP n: n seconds or until a key (0: until a key)
op_sleep:
    pop ax
    or ax, ax
    jle .key
    mov bx, 182                     ; ticks = n * 18.2
    mul bx
    mov bx, 10
    div bx
    mov cx, ax
    call ticks_now
    add ax, cx
    mov cx, ax
.wait:
    mov ah, 01h
    int 16h
    jnz .done
    call ticks_now
    sub ax, cx
    js .wait
    jmp .done
.key:
    mov ah, 01h
    int 16h
    jz .key
.done:
    jmp next_op

; AX = the low word of the BIOS tick count
ticks_now:
    push ds
    xor ax, ax
    mov ds, ax
    mov ax, [46Ch]
    pop ds
    ret

; DATE$ and TIME$ from COS
op_date:
    mov ah, 2Ah
    int 21h                         ; CX year, DH month, DL day
    mov di, numbuf
    mov al, dh
    call two_digits
    mov byte [cs:di], '-'
    inc di
    mov al, dl
    call two_digits
    mov byte [cs:di], '-'
    inc di
    mov ax, cx
    mov bl, 100
    div bl
    push ax
    call two_digits
    pop ax
    mov al, ah
    call two_digits
    jmp numbuf_string
op_time:
    mov ah, 2Ch
    int 21h                         ; CH hours, CL minutes, DH seconds
    mov di, numbuf
    mov al, ch
    call two_digits
    mov byte [cs:di], ':'
    inc di
    mov al, cl
    call two_digits
    mov byte [cs:di], ':'
    inc di
    mov al, dh
    call two_digits
    jmp numbuf_string

; AL (0-99) as two digits at CS:DI
two_digits:
    xor ah, ah
    push bx
    mov bl, 10
    div bl
    add ax, '00'
    mov [cs:di], al
    mov [cs:di + 1], ah
    add di, 2
    pop bx
    ret

op_fre:
    mov ax, STR_HEAP_END
    sub ax, [cs:str_top]
    xor dx, dx
    call l2f
    push dx
    push ax
    jmp next_op

; ======================================================================
; Files
; ======================================================================
;
; Numbers 1 to FILE_MAX. Each one has a slot (handle, mode, column and a
; buffer of FBUF_SIZE bytes).

F_HANDLE    equ 0
F_MODE      equ 2               ; 0 closed, 1 input, 2 output, 3 append
F_COL       equ 3
F_POS       equ 4               ; next byte in the buffer
F_LEN       equ 6               ; bytes in the buffer
F_EOF       equ 8               ; the file has no more bytes
F_BUF       equ 10
FBUF_SIZE   equ 128
F_SIZE      equ F_BUF + FBUF_SIZE
FILE_MAX    equ 8

; AX = a file number -> AL = it, BX = its slot (CS). Bad number: error.
file_slot:
    or ah, ah
    jnz .bad
    or al, al
    jz .bad
    cmp al, FILE_MAX
    ja .bad
    push ax
    push dx
    dec al
    mov bl, F_SIZE
    mul bl
    mov bx, ax
    add bx, file_slots
    pop dx
    pop ax
    ret
.bad:
    mov al, E_FILENUM
    jmp rt_error

; OPEN mode: the name and the number are on the stack
op_open:
    lodsb
    mov dl, al
    pop ax
    call file_slot
    cmp byte [cs:bx + F_MODE], 0
    je .free
    mov al, E_OPEN
    jmp rt_error
.free:
    pop di                          ; the name
    push bx
    push dx
    mov bx, di
    call string_to_numbuf
    pop dx
    pop bx
    push ds
    push cs
    pop ds
    mov [bx + F_MODE], dl
    mov word [bx + F_POS], 0
    mov word [bx + F_LEN], 0
    mov byte [bx + F_EOF], 0
    mov byte [bx + F_COL], 0
    mov ax, 3D00h
    cmp dl, 1
    je .open
    mov ax, 3D01h
    cmp dl, 3
    je .append
    mov ah, 3Ch                     ; OUTPUT: a new file
    xor cx, cx
    mov dx, numbuf
    int 21h
    jc .error
    jmp .opened
.append:
    mov dx, numbuf
    int 21h
    jnc .at_end
    mov ah, 3Ch                     ; not there: a new one
    xor cx, cx
    int 21h
    jc .error
    jmp .opened
.at_end:
    mov [bx + F_HANDLE], ax
    push bx
    mov bx, ax
    mov ax, 4202h
    xor cx, cx
    xor dx, dx
    int 21h
    pop bx
    jmp .done
.open:
    mov dx, numbuf
    int 21h
    jc .error
.opened:
    mov [bx + F_HANDLE], ax
.done:
    pop ds
    jmp next_op
.error:
    pop ds
    mov byte [cs:bx + F_MODE], 0
    cmp ax, 2
    je .not_found
    cmp ax, 3
    je .path
    mov al, E_BADFILE
    jmp rt_error
.not_found:
    mov al, E_NOFILE
    jmp rt_error
.path:
    mov al, E_PATH
    jmp rt_error

op_close:
    pop ax
    call file_slot
    call file_close
    jmp next_op

op_close_all:
    call files_close_all
    jmp next_op

files_close_all:
    push ax
    push bx
    mov al, 1
.next:
    xor ah, ah
    push ax
    call file_slot
    call file_close
    pop ax
    inc al
    cmp al, FILE_MAX
    jbe .next
    pop bx
    pop ax
    ret

; Closes the slot BX (flushing what was written)
file_close:
    cmp byte [cs:bx + F_MODE], 0
    je .done
    call file_flush
    push ax
    push bx
    mov bx, [cs:bx + F_HANDLE]
    mov ah, 3Eh
    int 21h
    pop bx
    pop ax
    mov byte [cs:bx + F_MODE], 0
.done:
    ret

; Writes out the buffer of an output slot BX
file_flush:
    cmp byte [cs:bx + F_MODE], 2
    jb .done
    mov cx, [cs:bx + F_POS]
    jcxz .done
    push ax
    push dx
    push ds
    push bx
    push cs
    pop ds
    lea dx, [bx + F_BUF]
    mov bx, [bx + F_HANDLE]
    mov ah, 40h
    int 21h
    pop bx
    pop ds
    jc .full
    cmp ax, cx
    jne .full
    mov word [cs:bx + F_POS], 0
    pop dx
    pop ax
.done:
    ret
.full:
    mov word [cs:bx + F_POS], 0
    mov al, E_DISKFULL
    jmp rt_error

; AL into the output slot BX
file_putc:
    push di
    mov di, [cs:bx + F_POS]
    mov [cs:bx + F_BUF + di], al
    inc di
    mov [cs:bx + F_POS], di
    inc byte [cs:bx + F_COL]
    cmp al, 10
    je .line
    cmp al, 13
    jne .col_done
.line:
    mov byte [cs:bx + F_COL], 0
.col_done:
    cmp di, FBUF_SIZE
    jb .done
    push cx
    call file_flush
    pop cx
.done:
    pop di
    ret

; The next byte of the input slot BX: AL, CF at the end
file_getc:
    push di
    mov di, [cs:bx + F_POS]
    cmp di, [cs:bx + F_LEN]
    jb .have
    call file_fill
    jc .end
    xor di, di
.have:
    mov al, [cs:bx + F_BUF + di]
    cmp al, 1Ah                     ; Ctrl-Z ends a text file
    je .end
    inc di
    mov [cs:bx + F_POS], di
    clc
    pop di
    ret
.end:
    stc
    pop di
    ret

; Reads the next piece of the file: CF if there is none
file_fill:
    cmp byte [cs:bx + F_EOF], 0
    jne .none
    push ax
    push cx
    push dx
    push ds
    push bx
    push cs
    pop ds
    lea dx, [bx + F_BUF]
    mov bx, [bx + F_HANDLE]
    mov cx, FBUF_SIZE
    mov ah, 3Fh
    int 21h
    pop bx
    pop ds
    jc .error
    mov word [cs:bx + F_POS], 0
    mov [cs:bx + F_LEN], ax
    or ax, ax
    jnz .some
    mov byte [cs:bx + F_EOF], 1
    pop dx
    pop cx
    pop ax
.none:
    stc
    ret
.some:
    pop dx
    pop cx
    pop ax
    clc
    ret
.error:
    pop dx
    pop cx
    pop ax
    mov al, E_BADFILE
    jmp rt_error

; The next byte without taking it: AL, CF at the end
file_peek:
    call file_getc
    jc .ret
    dec word [cs:bx + F_POS]
.ret:
    ret

; EOF(n)
op_eof:
    pop ax
    call file_slot
    cmp byte [cs:bx + F_MODE], 1
    jne .no
    call file_peek
    jc .yes
.no:
    mov ax, 0
    push ax
    jmp next_op
.yes:
    mov ax, -1
    push ax
    jmp next_op

; A field of INPUT # into numbuf (CX = its length)
file_field:
    push si
    push di
    push bx
    mov al, [cs:in_src]
    xor ah, ah
    call file_slot
    mov di, numbuf
.blank:
    call file_getc
    jnc .skip1
    jmp .past_end
.skip1:
    cmp al, ' '
    je .blank
    cmp al, 13
    je .blank
    cmp al, 10
    je .blank
    cmp al, 9
    je .blank
    cmp al, '"'
    jne .plain
.quoted:
    call file_getc
    jc .end
    cmp al, '"'
    je .after_quote
    call .store
    jmp .quoted
.after_quote:                       ; up to the comma or the line end
    call file_getc
    jc .end
    cmp al, ','
    je .end
    cmp al, 13
    je .end
    cmp al, 10
    je .end
    jmp .after_quote
.plain:
    call .store
    call file_getc
    jc .end
    cmp al, ','
    je .end
    cmp al, 13
    je .end
    cmp al, 10
    je .end
    cmp al, ' '                     ; a number also ends at a space
    jne .plain
    cmp byte [cs:in_numeric], 0
    je .plain
.end:
    cmp al, 13                      ; CR LF: both taken
    jne .trim
    call file_peek
    jc .trim
    cmp al, 10
    jne .trim
    call file_getc
.trim:
    cmp di, numbuf                  ; trailing spaces off
    je .terminate
    cmp byte [cs:di - 1], ' '
    jne .terminate
    dec di
    jmp .trim
.terminate:
    mov byte [cs:di], 0
    mov cx, di
    sub cx, numbuf
    pop bx
    pop di
    pop si
    ret
.past_end:
    mov al, E_EOF
    jmp rt_error
.store:
    cmp di, numbuf + NUMBUF_SIZE - 1
    jae .full
    mov [cs:di], al
    inc di
.full:
    ret

; LINE INPUT #n, a$
op_line_input_file:
    pop ax
    call file_slot
    cmp byte [cs:bx + F_MODE], 1
    jne .bad
    xor di, di
    call file_getc
    jc .past_end
.char:
    cmp al, 13
    je .cr
    cmp al, 10
    je .done
    cmp di, INBUF_SIZE - 1
    jae .skip
    mov [cs:inbuf + di], al
    inc di
.skip:
    call file_getc
    jnc .char
    jmp .done
.cr:
    call file_peek                  ; CR LF
    jc .done
    cmp al, 10
    jne .done
    call file_getc
.done:
    mov cx, di
    push si
    push ds
    push cs
    pop ds
    mov si, inbuf
    call text_to_temp
    pop ds
    pop si
    push di
    jmp next_op
.past_end:
    mov al, E_EOF
    jmp rt_error
.bad:
    mov al, E_FILEMODE
    jmp rt_error

; KILL name
op_kill:
    pop bx
    call string_to_numbuf
    push ds
    push cs
    pop ds
    mov dx, numbuf
    mov ah, 41h
    int 21h
    pop ds
    jc .error
    jmp next_op
.error:
    mov al, E_NOFILE
    jmp rt_error

; ======================================================================
; Graphics (SCREEN 1 and 13, both 320x200 at A000)
; ======================================================================

; Graphics statements need a graphics mode; ES = the screen
gfx_begin:
    cmp byte [cs:scr_mode], 0
    je .text
    push ax
    mov ax, 0A000h
    mov es, ax
    pop ax
    ret
.text:
    jmp err_func

gfx_end:
    mov es, [cs:seg_data]
    jmp next_op

; AX = a color from the program (-1: the default AL... in DL) -> AL
gfx_color:
    cmp ax, -1
    jne .given
    mov al, dl
.given:
    cmp byte [cs:scr_mode], 1
    jne .done
    and al, 3
.done:
    ret

; CX = x, DX = y, AL = color: the pixel, if it is on the screen
gfx_plot:
    cmp cx, 320
    jae .out
    cmp dx, 200
    jae .out
    push di
    push ax
    mov ax, dx
    xchg al, ah                     ; y * 256
    mov di, dx
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1                       ; + y * 64
    add di, ax
    add di, cx
    pop ax
    mov [es:di], al
    pop di
.out:
    ret

; CX = x, DX = y -> AL = the pixel (CF if off the screen)
gfx_get:
    cmp cx, 320
    jae .out
    cmp dx, 200
    jae .out
    push di
    mov ax, dx
    xchg al, ah
    mov di, dx
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    add di, ax
    add di, cx
    mov al, [es:di]
    pop di
    clc
    ret
.out:
    stc
    ret

; [STEP] coordinates: relative to the last point
gfx_step:
    add cx, [cs:gfx_x]
    add dx, [cs:gfx_y]
    ret

; PSET / PRESET flags (1 STEP, 2 PRESET): x, y, color
op_pset:
    lodsb
    mov bl, al
    pop ax
    pop dx
    pop cx
    call gfx_begin
    test bl, 1
    jz .absolute
    call gfx_step
.absolute:
    push dx
    mov dl, [cs:scr_fg]
    test bl, 2
    jz .fg
    xor dl, dl
.fg:
    call gfx_color
    pop dx
    call gfx_plot
    mov [cs:gfx_x], cx
    mov [cs:gfx_y], dx
    jmp gfx_end

; POINT(x, y)
op_point:
    pop dx
    pop cx
    call gfx_begin
    call gfx_get
    mov es, [cs:seg_data]
    jc .off
    xor ah, ah
    push ax
    jmp next_op
.off:
    mov ax, -1
    push ax
    jmp next_op

; LINE flags (1 STEP, 2 from the last point, 4 STEP, 8 B, 16 BF):
; x1, y1, x2, y2, color
op_line:
    lodsb
    mov [cs:line_flags], al
    call gfx_begin
    pop ax
    mov dl, [cs:scr_fg]
    call gfx_color
    mov [cs:gfx_c], al
    pop dx
    pop cx
    mov [cs:l_x2], cx
    mov [cs:l_y2], dx
    pop dx
    pop cx
    test byte [cs:line_flags], 2
    jz .first
    mov cx, [cs:gfx_x]
    mov dx, [cs:gfx_y]
    jmp .first_done
.first:
    test byte [cs:line_flags], 1
    jz .first_done
    call gfx_step
.first_done:
    push cx
    push dx
    mov cx, [cs:l_x2]
    mov dx, [cs:l_y2]
    test byte [cs:line_flags], 4
    jz .second
    pop bx                          ; STEP: from the first point
    pop ax
    push ax
    push bx
    add cx, ax
    add dx, bx
.second:
    mov [cs:l_x2], cx
    mov [cs:l_y2], dx
    mov [cs:gfx_x], cx
    mov [cs:gfx_y], dx
    pop dx
    pop cx
    test byte [cs:line_flags], 16
    jnz .fill
    test byte [cs:line_flags], 8
    jnz .box
    call gfx_line
    jmp gfx_end
.box:
    mov [cs:box_x1], cx
    mov [cs:box_y1], dx
    mov ax, [cs:l_x2]               ; top
    mov bx, dx
    call gfx_line_to
    mov cx, [cs:box_x1]             ; bottom
    mov dx, [cs:l_y2]
    mov ax, [cs:l_x2]
    mov bx, dx
    call gfx_line_to
    mov cx, [cs:box_x1]             ; left
    mov dx, [cs:box_y1]
    mov ax, cx
    mov bx, [cs:l_y2]
    call gfx_line_to
    mov cx, [cs:l_x2]               ; right
    mov dx, [cs:box_y1]
    mov ax, cx
    mov bx, [cs:l_y2]
    call gfx_line_to
    jmp gfx_end
.fill:
    call gfx_fill_box
    jmp gfx_end

; A line from (CX, DX) to (AX, BX)
gfx_line_to:
    push word [cs:l_x2]
    push word [cs:l_y2]
    mov [cs:l_x2], ax
    mov [cs:l_y2], bx
    call gfx_line
    pop word [cs:l_y2]
    pop word [cs:l_x2]
    ret

; A line from (CX, DX) to (l_x2, l_y2) in gfx_c (Bresenham)
gfx_line:
    push si
    push bp
    mov ax, [cs:l_x2]
    sub ax, cx
    mov si, 1                       ; SI = step in x
    jns .dx_pos
    neg ax
    neg si
.dx_pos:
    mov [cs:l_dx], ax
    mov ax, [cs:l_y2]
    sub ax, dx
    mov bp, 1                       ; BP = step in y
    jns .dy_pos
    neg ax
    neg bp
.dy_pos:
    neg ax
    mov [cs:l_dy], ax               ; -|dy|
    add ax, [cs:l_dx]
    mov bx, ax                      ; BX = err
.pixel:
    mov al, [cs:gfx_c]
    call gfx_plot
    cmp cx, [cs:l_x2]
    jne .go
    cmp dx, [cs:l_y2]
    je .done
.go:
    mov ax, bx
    shl ax, 1                       ; e2
    cmp ax, [cs:l_dy]
    jl .no_x
    add bx, [cs:l_dy]
    add cx, si
.no_x:
    cmp ax, [cs:l_dx]
    jg .pixel
    add bx, [cs:l_dx]
    add dx, bp
    jmp .pixel
.done:
    pop bp
    pop si
    ret

; A filled box (CX, DX)-(l_x2, l_y2) in gfx_c
gfx_fill_box:
    mov ax, [cs:l_x2]               ; x1 <= x2, y1 <= y2, inside
    cmp cx, ax
    jle .x_ok
    xchg cx, ax
.x_ok:
    mov bx, [cs:l_y2]
    cmp dx, bx
    jle .y_ok
    xchg dx, bx
.y_ok:
    call clip_x
    call clip_y
    cmp cx, ax
    jg .none
    cmp dx, bx
    jg .none
    sub ax, cx
    inc ax                          ; width
    push si
    mov si, ax
.row:
    push cx
    push dx
    mov ax, dx
    xchg al, ah
    mov di, dx
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1
    add di, ax
    add di, cx
    mov cx, si
    mov al, [cs:gfx_c]
    rep stosb
    pop dx
    pop cx
    inc dx
    cmp dx, bx
    jle .row
    pop si
.none:
    ret

; CX..AX within 0..319, DX..BX within 0..199
clip_x:
    or cx, cx
    jns .left_ok
    xor cx, cx
.left_ok:
    cmp ax, 319
    jle .right_ok
    mov ax, 319
.right_ok:
    ret
clip_y:
    or dx, dx
    jns .top_ok
    xor dx, dx
.top_ok:
    cmp bx, 199
    jle .bottom_ok
    mov bx, 199
.bottom_ok:
    ret

; ---------- CIRCLE ----------

; CIRCLE flags (1 STEP, 2 start, 4 end, 8 aspect): x, y, r, color,
; start, end, aspect
op_circle:
    lodsb
    mov [cs:circ_flags], al
    call gfx_begin
    mov es, [cs:seg_data]           ; (reals first)
    pop ax
    pop dx
    mov bx, circ_aspect
    call fstore
    pop ax
    pop dx
    mov bx, circ_end
    call fstore
    pop ax
    pop dx
    mov bx, circ_start
    call fstore
    pop ax
    push dx
    mov dl, [cs:scr_fg]
    call gfx_color
    pop dx
    mov [cs:gfx_c], al
    pop ax
    pop dx
    and dh, 7Fh                     ; |r|
    mov bx, circ_r
    call fstore
    pop dx
    pop cx
    test byte [cs:circ_flags], 1
    jz .absolute
    call gfx_step
.absolute:
    mov [cs:circ_x], cx
    mov [cs:circ_y], dx
    mov [cs:gfx_x], cx
    mov [cs:gfx_y], dx
    ; the radii: x and y, from the aspect (default 5/6 for 320x200)
    mov bx, c_aspect
    call fload
    test byte [cs:circ_flags], 8
    jz .aspect
    mov bx, circ_aspect
    call fload
    and dh, 7Fh
.aspect:
    mov bx, circ_aspect
    call fstore
    mov cx, [cs:c_one + 2]
    mov bx, [cs:c_one]
    call fcmp_keep
    cmp bl, 2
    je .tall
    mov cx, dx                      ; below 1: x = r, y = r * aspect
    mov bx, ax
    mov ax, [cs:circ_r]
    mov dx, [cs:circ_r + 2]
    call fmul
    call f2l_round
    mov [cs:circ_ry], ax
    mov bx, circ_r
    call fload
    call f2l_round
    mov [cs:circ_rx], ax
    jmp .radii
.tall:                              ; above: y = r, x = r / aspect
    mov cx, dx
    mov bx, ax
    mov ax, [cs:circ_r]
    mov dx, [cs:circ_r + 2]
    call fdiv
    call f2l_round
    mov [cs:circ_rx], ax
    mov bx, circ_r
    call fload
    call f2l_round
    mov [cs:circ_ry], ax
.radii:
    cmp word [cs:circ_rx], 1000     ; (nothing that large is visible)
    jbe .rx_ok
    mov word [cs:circ_rx], 1000
.rx_ok:
    cmp word [cs:circ_ry], 1000
    jbe .ry_ok
    mov word [cs:circ_ry], 1000
.ry_ok:
    ; an arc: its ends as "diamond angles"
    mov byte [cs:circ_arc], 0
    test byte [cs:circ_flags], 6
    jz .draw
    mov byte [cs:circ_arc], 1
    mov bx, circ_start
    call arc_end                    ; AX = its angle, CF if negative
    mov [cs:circ_a1], ax
    rcl byte [cs:circ_lines], 1
    test byte [cs:circ_flags], 4
    jnz .given_end
    mov ax, 16384                   ; no end: all the way round
    clc
    jmp .end_set
.given_end:
    mov bx, circ_end
    call arc_end
.end_set:
    mov [cs:circ_a2], ax
    rcl byte [cs:circ_lines], 1
.draw:
    mov ax, 0A000h
    mov es, ax
    call ellipse
    test byte [cs:circ_arc], 1
    jz .done
    test byte [cs:circ_lines], 2    ; negative start: a line to it
    jz .no_line1
    mov bx, circ_start
    call radius_line
.no_line1:
    test byte [cs:circ_lines], 1
    jz .done
    mov bx, circ_end
    call radius_line
.done:
    mov byte [cs:circ_lines], 0
    jmp gfx_end

; The angle (a real at CS:BX, radians) -> AX = its diamond angle; CF if it
; was negative. Also arc_cos/arc_sin = cos and sin * 10000.
arc_end:
    push bx
    call fload
    test dh, 80h
    pushf
    and dh, 7Fh
    mov bx, ftmp2
    call fstore
    call fcos
    mov bx, c_e4
    call fmul_c
    call f2l_round
    mov [cs:arc_cos], ax
    mov bx, ftmp2
    call fload
    call fsin
    mov bx, c_e4
    call fmul_c
    call f2l_round
    mov [cs:arc_sin], ax
    mov bx, [cs:arc_cos]
    call diamond
    popf
    jz .positive
    pop bx
    stc
    ret
.positive:
    pop bx
    clc
    ret

; A line from the center to the end of the arc at angle CS:BX
radius_line:
    call fload
    and dh, 7Fh
    push dx
    push ax
    call fcos
    mov cx, dx
    mov bx, ax
    mov ax, [cs:circ_rx]
    call i2f
    call fmul
    call f2l_round
    add ax, [cs:circ_x]
    mov [cs:l_x2], ax
    pop ax
    pop dx
    call fsin
    mov cx, dx
    mov bx, ax
    mov ax, [cs:circ_ry]
    call i2f
    call fmul
    call f2l_round
    neg ax
    add ax, [cs:circ_y]
    mov [cs:l_y2], ax
    mov cx, [cs:circ_x]
    mov dx, [cs:circ_y]
    jmp gfx_line

; BX = x, AX = y (y up) -> AX = the "diamond angle": 0 at +x, 4096 at +y,
; 8192 at -x, 12288 at -y, growing with the angle
diamond:
    push cx
    push dx
    mov cx, bx
    or cx, ax
    jz .done
    or ax, ax
    js .lower
    or bx, bx
    js .second
    mov cx, bx                      ; y / (x + y)
    add cx, ax
    xor dx, dx
    call .ratio
    jmp .done
.second:                            ; 1 + (-x) / (-x + y)
    neg bx
    mov cx, bx
    add cx, ax
    mov ax, bx
    call .ratio
    add ax, 4096
    jmp .done
.lower:
    neg ax                          ; AX = -y
    or bx, bx
    jns .fourth
    neg bx                          ; 2 + (-y) / (-x - y)
    mov cx, bx
    add cx, ax
    call .ratio
    add ax, 8192
    jmp .done
.fourth:                            ; 3 + x / (x - y)
    mov cx, bx
    add cx, ax
    mov ax, bx
    call .ratio
    add ax, 12288
.done:
    pop dx
    pop cx
    ret
.ratio:                             ; AX * 4096 / CX
    mov dx, 4096
    mul dx
    div cx
    ret

; Is the point (BX, AX) (from the center, y down) on the arc? CF = no
on_arc:
    test byte [cs:circ_arc], 1
    jz .yes
    push ax
    push bx
    neg ax
    call diamond
    mov bx, [cs:circ_a1]
    cmp bx, [cs:circ_a2]
    ja .wraps
    cmp ax, bx
    jb .no
    cmp ax, [cs:circ_a2]
    ja .no
    jmp .yes_pop
.wraps:
    cmp ax, bx
    jae .yes_pop
    cmp ax, [cs:circ_a2]
    jbe .yes_pop
.no:
    pop bx
    pop ax
    stc
    ret
.yes_pop:
    pop bx
    pop ax
.yes:
    clc
    ret

; The point (center + (BX, AX)), if on the arc
circ_point:
    call on_arc
    jc .no
    push cx
    push dx
    mov cx, [cs:circ_x]
    add cx, bx
    mov dx, [cs:circ_y]
    add dx, ax
    push ax
    mov al, [cs:gfx_c]
    call gfx_plot
    pop ax
    pop dx
    pop cx
.no:
    ret

; The four points (+-BX, +-AX)
circ_four:
    call circ_point
    neg bx
    call circ_point
    neg ax
    call circ_point
    neg bx
    call circ_point
    neg ax
    ret

; The ellipse with radii circ_rx, circ_ry around circ_x, circ_y: for each x
; its y, then for each y its x (no gaps)
ellipse:
    push si
    push di
    mov si, [cs:circ_rx]
    mov di, [cs:circ_ry]
    xor cx, cx                      ; x = 0 .. rx
.by_x:
    cmp cx, si
    ja .x_done
    or si, si
    jnz .x_some
    mov ax, di
    jmp .x_point
.x_some:                            ; y = ry * sqrt(rx^2 - x^2) / rx
    mov ax, si
    mul si
    mov [cs:sq_lo], ax
    mov [cs:sq_hi], dx
    mov ax, cx
    mul cx
    sub [cs:sq_lo], ax
    sbb [cs:sq_hi], dx
    call sq_scaled                  ; 16 * sqrt
    mul di
    push cx
    mov cx, si
    shl cx, 1
    shl cx, 1
    shl cx, 1
    add ax, cx
    adc dx, 0
    shl cx, 1
    div cx
    pop cx
.x_point:
    mov bx, cx
    call circ_four
    inc cx
    jmp .by_x
.x_done:
    xor cx, cx                      ; y = 0 .. ry
.by_y:
    cmp cx, di
    ja .y_done
    or di, di
    jnz .y_some
    mov bx, si
    jmp .y_point
.y_some:                            ; x = rx * sqrt(ry^2 - y^2) / ry
    mov ax, di
    mul di
    mov [cs:sq_lo], ax
    mov [cs:sq_hi], dx
    mov ax, cx
    mul cx
    sub [cs:sq_lo], ax
    sbb [cs:sq_hi], dx
    call sq_scaled
    mul si
    push cx
    mov cx, di
    shl cx, 1
    shl cx, 1
    shl cx, 1
    add ax, cx
    adc dx, 0
    shl cx, 1
    div cx
    pop cx
    mov bx, ax
.y_point:
    mov ax, cx
    call circ_four
    inc cx
    jmp .by_y
.y_done:
    pop di
    pop si
    ret

; AX = 16 * sqrt(sq_hi:sq_lo) (four more bits than the whole part)
sq_scaled:
    push cx
    mov ax, [cs:sq_lo]
    mov dx, [cs:sq_hi]
    mov cx, 8
.shift:
    shl ax, 1
    rcl dx, 1
    loop .shift
    pop cx
    jmp isqrt32

; DX:AX -> AX = its square root (whole part), Newton from above
isqrt32:
    push bx
    push cx
    mov bx, dx
    or bx, ax
    jz .done
    mov cx, 256
    or dx, dx
    jz .iterate
    mov cx, 0FFFFh
.iterate:
    push dx
    push ax
    div cx
    add ax, cx
    rcr ax, 1
    cmp ax, cx
    jae .found
    mov cx, ax
    pop ax
    pop dx
    jmp .iterate
.found:
    pop ax
    pop dx
    mov ax, cx
.done:
    pop cx
    pop bx
    ret

; ---------- PAINT ----------

; PAINT flags (1 STEP): x, y, paint color, border color. A scan-line
; fill; the pending spans are kept in the free memory above the arrays.
op_paint:
    lodsb
    mov bl, al
    call gfx_begin
    pop ax                          ; border
    pop cx                          ; paint
    push ax
    mov ax, cx
    mov dl, [cs:scr_fg]
    call gfx_color
    mov [cs:gfx_c], al
    pop ax
    mov dl, [cs:gfx_c]
    call gfx_color
    mov [cs:paint_border], al
    pop dx
    pop cx
    test bl, 1
    jz .absolute
    call gfx_step
.absolute:
    mov [cs:gfx_x], cx
    mov [cs:gfx_y], dx
    push si
    push bp
    push ds
    mov ax, [cs:arena_end]          ; room for the pending points
    sub ax, [cs:arena_top]
    cmp ax, 100h
    jb .no_room
    mov ds, [cs:arena_top]
    cmp ax, 1000h
    jb .small
    mov ax, 1000h
.small:
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    sub ax, 4
    mov [cs:paint_max], ax
    xor si, si                      ; SI = the top of the pending stack
    call paint_push
.next:
    or si, si
    jz .done
    sub si, 4
    mov cx, [si]
    mov dx, [si + 2]
    call paintable
    jc .next
    mov [cs:paint_x], cx            ; to the left
.left:
    dec cx
    call paintable
    jnc .left
    inc cx
    mov [cs:paint_l], cx
    mov cx, [cs:paint_x]
.right:
    inc cx
    call paintable
    jnc .right
    dec cx
    mov [cs:paint_r], cx
    ; fill the span
    mov cx, [cs:paint_l]
.fill:
    mov al, [cs:gfx_c]
    call gfx_plot
    inc cx
    cmp cx, [cs:paint_r]
    jle .fill
    ; the rows above and below: a seed at each run
    dec dx
    call paint_row
    add dx, 2
    call paint_row
    jmp .next
.no_room:
.done:
    pop ds
    pop bp
    pop si
    jmp gfx_end

; Seeds for the row DX between paint_l and paint_r
paint_row:
    push dx
    cmp dx, 200
    jae .done
    mov cx, [cs:paint_l]
    mov byte [cs:paint_in], 0
.pixel:
    cmp cx, [cs:paint_r]
    jg .done
    call paintable
    jc .wall
    cmp byte [cs:paint_in], 0
    jne .step
    mov byte [cs:paint_in], 1
    call paint_push
    jmp .step
.wall:
    mov byte [cs:paint_in], 0
.step:
    inc cx
    jmp .pixel
.done:
    pop dx
    ret

; (CX, DX) onto the pending stack (if there is room)
paint_push:
    cmp si, [cs:paint_max]
    jae .full
    mov [si], cx
    mov [si + 2], dx
    add si, 4
.full:
    ret

; CF = 0 if (CX, DX) is on the screen and neither border nor paint
paintable:
    call gfx_get
    jc .no
    cmp al, [cs:paint_border]
    je .no
    cmp al, [cs:gfx_c]
    je .no
    clc
    ret
.no:
    stc
    ret

; ---------- GET and PUT ----------
;
; The picture: width in bits (pixels * 2 in SCREEN 1, * 8 in SCREEN 13),
; height, then the rows (SCREEN 1: 4 pixels per byte, the first in the
; high bits, each row a whole number of bytes).

; The far address on the stack -> normalized in AX:DI (offset < 16)
far_normal:
    pop bx
    pop di
    pop ax
    push bx
    mov bx, di
    shr bx, 1
    shr bx, 1
    shr bx, 1
    shr bx, 1
    add ax, bx
    and di, 15
    ret

; GET (x1, y1)-(x2, y2), array
op_get:
    call far_normal
    mov [cs:img_seg], ax
    mov [cs:img_off], di
    pop bx                          ; y2
    pop ax                          ; x2
    pop dx                          ; y1
    pop cx                          ; x1
    call gfx_begin
    cmp cx, ax
    jle .x_ok
    xchg cx, ax
.x_ok:
    cmp dx, bx
    jle .y_ok
    xchg dx, bx
.y_ok:
    or cx, cx                       ; all of it on the screen
    jns .skip45
    jmp .bad
.skip45:
    or dx, dx
    jns .skip44
    jmp .bad
.skip44:
    cmp ax, 319
    jbe .skip43
    jmp .bad
.skip43:
    cmp bx, 199
    jbe .skip42
    jmp .bad
.skip42:
    push si
    push ds
    sub ax, cx
    inc ax
    mov [cs:img_w], ax
    sub bx, dx
    inc bx
    mov [cs:img_h], bx
    mov ds, [cs:img_seg]
    mov di, [cs:img_off]
    mov bx, ax                      ; the header
    shl bx, 1
    cmp byte [cs:scr_mode], 1
    je .bits
    shl bx, 1
    shl bx, 1
.bits:
    mov [di], bx
    mov bx, [cs:img_h]
    mov [di + 2], bx
    add di, 4
    mov si, cx                      ; SI = x1
.row:
    mov cx, si
    mov bx, [cs:img_w]
    cmp byte [cs:scr_mode], 1
    je .packed
.byte:
    call gfx_get
    mov [di], al
    inc di
    inc cx
    dec bx
    jnz .byte
    jmp .row_done
.packed:
    mov byte [cs:img_byte], 0
    mov byte [cs:img_bits], 0
.pixel:
    call gfx_get
    and al, 3
    shl byte [cs:img_byte], 1
    shl byte [cs:img_byte], 1
    or [cs:img_byte], al
    add byte [cs:img_bits], 2
    cmp byte [cs:img_bits], 8
    jb .more
    mov al, [cs:img_byte]
    mov [di], al
    inc di
    mov byte [cs:img_byte], 0
    mov byte [cs:img_bits], 0
.more:
    inc cx
    dec bx
    jnz .pixel
    cmp byte [cs:img_bits], 0       ; the last byte of the row
    je .row_done
    mov al, [cs:img_byte]
    mov cl, 8
    sub cl, [cs:img_bits]
    shl al, cl
    mov [di], al
    inc di
.row_done:
    inc dx
    dec word [cs:img_h]
    jnz .row
    pop ds
    pop si
    jmp gfx_end
.bad:
    jmp err_func

; PUT (x, y), array, action (0 PSET, 1 PRESET, 2 AND, 3 OR, 4 XOR)
op_put:
    lodsb
    mov [cs:put_action], al
    call far_normal
    mov [cs:img_seg], ax
    mov [cs:img_off], di
    pop dx
    pop cx
    call gfx_begin
    push si
    push ds
    push bp
    mov ds, [cs:img_seg]
    mov si, [cs:img_off]
    lodsw                           ; width in bits
    mov bx, ax
    shr bx, 1
    cmp byte [cs:scr_mode], 1
    je .width
    shr bx, 1
    shr bx, 1
.width:
    mov [cs:img_w], bx
    lodsw
    mov [cs:img_h], ax
    mov bp, cx                      ; BP = x
    or bx, bx
    jz .done
.row:
    cmp word [cs:img_h], 0
    je .done
    mov cx, bp
    mov bx, [cs:img_w]
    cmp byte [cs:scr_mode], 1
    je .packed
.byte:
    lodsb
    call put_pixel
    inc cx
    dec bx
    jnz .byte
    jmp .row_done
.packed:
    mov byte [cs:img_bits], 0
.pixel:
    cmp byte [cs:img_bits], 0
    jne .have
    lodsb
    mov [cs:img_byte], al
    mov byte [cs:img_bits], 8
.have:
    mov al, [cs:img_byte]
    rol al, 1
    rol al, 1
    mov [cs:img_byte], al
    and al, 3
    sub byte [cs:img_bits], 2
    call put_pixel
    inc cx
    dec bx
    jnz .pixel
.row_done:
    inc dx
    dec word [cs:img_h]
    jmp .row
.done:
    pop bp
    pop ds
    pop si
    jmp gfx_end

; AL = a pixel of the picture at (CX, DX), combined with the screen
put_pixel:
    cmp cx, 320
    jae .out
    cmp dx, 200
    jae .out
    push bx
    mov bl, al
    mov al, [cs:put_action]
    or al, al
    jz .pset
    cmp al, 1
    jne .not_preset
    not bl
    cmp byte [cs:scr_mode], 1
    jne .pset
    and bl, 3
    jmp .pset
.not_preset:
    push ax
    call gfx_get
    mov bh, al
    pop ax
    cmp al, 2
    jne .not_and
    and bl, bh
    jmp .pset
.not_and:
    cmp al, 3
    jne .xor
    or bl, bh
    jmp .pset
.xor:
    xor bl, bh
.pset:
    mov al, bl
    call gfx_plot
    pop bx
.out:
    ret

; ======================================================================
; Sound
; ======================================================================

; The speaker at AX hertz
speaker_on:
    push ax
    push bx
    push dx
    cmp ax, 37
    jb .off
    mov bx, ax
    mov dx, 12h                     ; 1193180 / f
    mov ax, 34DCh
    div bx
    call speaker_divisor
    pop dx
    pop bx
    pop ax
    ret
.off:
    call speaker_off
    pop dx
    pop bx
    pop ax
    ret

; The speaker with the PIT divisor AX
speaker_divisor:
    push ax
    mov al, 0B6h
    out 43h, al
    pop ax
    out 42h, al
    mov al, ah
    out 42h, al
    in al, 61h
    or al, 3
    out 61h, al
    ret

speaker_off:
    push ax
    in al, 61h
    and al, 0FCh
    out 61h, al
    pop ax
    ret

; Sound time is counted in 1/256 of a BIOS tick, so that short notes add
; up to the right length. snd_until = when the current sound ends.

; DX:AX = the time now
snd_now:
    push ds
    push bx
    xor bx, bx
    mov ds, bx
    mov ax, [46Ch]
    mov dx, [46Eh]
    pop bx
    pop ds
    mov dh, dl                      ; * 256
    mov dl, ah
    mov ah, al
    xor al, al
    ret

; A new sequence starts now, unless one is still going on
snd_start:
    call snd_now
    cmp dx, [cs:snd_until + 2]
    ja .now
    jb .keep
    cmp ax, [cs:snd_until]
    jbe .keep
.now:
    mov [cs:snd_until], ax
    mov [cs:snd_until + 2], dx
.keep:
    ret

; Waits DX:AX more units (after the last wait)
snd_wait:
    add [cs:snd_until], ax
    adc [cs:snd_until + 2], dx
.loop:
    call snd_now
    cmp dx, [cs:snd_until + 2]
    jb .loop
    ja .done
    cmp ax, [cs:snd_until]
    jb .loop
.done:
    ret

beep:
    push ax
    push dx
    call snd_start
    mov ax, 800
    call speaker_on
    mov ax, 1280                    ; 5 ticks
    xor dx, dx
    call snd_wait
    call speaker_off
    pop dx
    pop ax
    ret

; SOUND frequency, duration (in ticks)
op_sound:
    pop ax
    pop dx
    mov cx, 8
    call fscale                     ; * 256
    call f2l_round
    push dx
    push ax
    pop word [cs:snd_len]
    pop word [cs:snd_len + 2]
    pop ax
    pop dx
    call f2l_round
    or dx, dx
    jnz .bad
    cmp ax, 32767
    ja .bad
    push ax
    call snd_start
    pop ax
    call speaker_on
    mov ax, [cs:snd_len]
    mov dx, [cs:snd_len + 2]
    call snd_wait
    call speaker_off
    jmp next_op
.bad:
    jmp err_func

; PLAY "music" (the music macro language)
op_play:
    pop bx
    push si
    push ds
    mov cx, [es:bx + 2]
    mov si, [es:bx]
    mov ds, [cs:seg_str]
    call snd_start
.command:
    or cx, cx
    jnz .skip46
    jmp .done
.skip46:
    lodsb
    dec cx
    cmp al, 'a'
    jb .upper
    cmp al, 'z'
    ja .upper
    sub al, 20h
.upper:
    cmp al, 'A'
    jb .not_note
    cmp al, 'G'
    ja .not_note
    sub al, 'A'
    mov bl, al
    xor bh, bh
    mov al, [cs:note_steps + bx]    ; semitone in the octave
    mov ah, [cs:play_octave]
    mov bl, 12
    xchg al, ah
    mul bl
    add al, ah                      ; note number
    call play_accidental
    call play_note_length
    jmp .command
.not_note:
    cmp al, 'N'
    jne .not_n
    call play_number
    or ax, ax
    jz .n_rest
    dec ax
    cmp ax, 84
    jb .skip40
    jmp .bad
.skip40:
    push ax
    mov al, [cs:play_length]
    xor ah, ah
    mov [cs:note_len], ax
    call play_dots
    pop ax
    call play_tone
    jmp .command
.n_rest:
    mov al, [cs:play_length]
    xor ah, ah
    mov [cs:note_len], ax
    call play_dots
    call play_rest
    jmp .command
.not_n:
    cmp al, 'O'
    jne .not_o
    call play_number
    cmp ax, 6
    jbe .skip39
    jmp .bad
.skip39:
    mov [cs:play_octave], al
    jmp .command
.not_o:
    cmp al, '<'
    jne .not_down
    cmp byte [cs:play_octave], 0
    jne .skip38
    jmp .command
.skip38:
    dec byte [cs:play_octave]
    jmp .command
.not_down:
    cmp al, '>'
    jne .not_up
    cmp byte [cs:play_octave], 6
    jne .skip37
    jmp .command
.skip37:
    inc byte [cs:play_octave]
    jmp .command
.not_up:
    cmp al, 'L'
    jne .not_l
    call play_number
    or ax, ax
    jz .bad
    cmp ax, 64
    ja .bad
    mov [cs:play_length], al
    jmp .command
.not_l:
    cmp al, 'T'
    jne .not_t
    call play_number
    cmp ax, 32
    jb .bad
    cmp ax, 255
    ja .bad
    mov [cs:play_tempo], al
    jmp .command
.not_t:
    cmp al, 'P'
    jne .not_p
    call play_number
    or ax, ax
    jz .bad
    mov [cs:note_len], ax
    call play_dots
    call play_rest
    jmp .command
.not_p:
    cmp al, 'M'
    jne .not_m
    jcxz .bad
    lodsb
    dec cx
    and al, 0DFh
    mov ah, 7                       ; MN: 7/8 of the time sounds
    cmp al, 'N'
    je .style
    mov ah, 8                       ; ML: all of it
    cmp al, 'L'
    je .style
    mov ah, 6                       ; MS: 3/4
    cmp al, 'S'
    je .style
    cmp al, 'F'                     ; MF, MB: accepted
    jne .skip36
    jmp .command
.skip36:
    cmp al, 'B'
    jne .skip35
    jmp .command
.skip35:
    jmp .bad
.style:
    mov [cs:play_style], ah
    jmp .command
.not_m:
    cmp al, ' '                     ; spaces and ; are ignored
    jne .skip34
    jmp .command
.skip34:
    cmp al, ';'
    jne .skip33
    jmp .command
.skip33:
.bad:
    pop ds
    pop si
    call speaker_off
    jmp err_func
.done:
    pop ds
    pop si
    call speaker_off
    jmp next_op

note_steps  db 9, 11, 0, 2, 4, 5, 7     ; A B C D E F G

; # + -: AL = the note number, changed
play_accidental:
    jcxz .done
    mov ah, [si]
    cmp ah, '#'
    je .sharp
    cmp ah, '+'
    je .sharp
    cmp ah, '-'
    jne .done
    inc si
    dec cx
    or al, al
    jz .done
    dec al
    ret
.sharp:
    inc si
    dec cx
    inc al
.done:
    ret

; A note AL with an optional length and dots
play_note_length:
    push ax
    mov al, [cs:play_length]
    xor ah, ah
    mov [cs:note_len], ax
    jcxz .no_number
    mov al, [si]
    cmp al, '0'
    jb .no_number
    cmp al, '9'
    ja .no_number
    call play_number
    or ax, ax
    jz .no_number
    mov [cs:note_len], ax
.no_number:
    call play_dots
    pop ax
    xor ah, ah
    cmp ax, 84
    jae .ret
    jmp play_tone
.ret:
    ret

; Dots after a length: each one adds half again (note_mul / note_div)
play_dots:
    mov word [cs:note_mul], 1
    mov word [cs:note_div], 1
.dot:
    jcxz .done
    cmp byte [si], '.'
    jne .done
    inc si
    dec cx
    mov ax, [cs:note_mul]           ; * 3 / 2
    mov bx, ax
    shl ax, 1
    add ax, bx
    mov [cs:note_mul], ax
    shl word [cs:note_div], 1
    jmp .dot
.done:
    ret

; A number at DS:SI -> AX (0 if none)
play_number:
    xor ax, ax
.digit:
    jcxz .done
    mov bl, [si]
    sub bl, '0'
    cmp bl, 9
    ja .done
    inc si
    dec cx
    push dx
    mov dx, 10
    mul dx
    pop dx
    xor bh, bh
    add ax, bx
    jmp .digit
.done:
    ret

; DX:AX = the length of the note now set, in 1/256 ticks:
; 1118607 / (length * tempo) * mul / div
note_time:
    push bx
    push cx
    mov ax, [cs:note_len]
    mov bl, [cs:play_tempo]
    xor bh, bh
    mul bx
    mov bx, ax                      ; length * tempo (below 65536)
    mov dx, 11h                     ; 1118607 = 11:116Fh
    mov ax, 116Fh
    xor cx, cx
    cmp dx, bx
    jb .small
    push ax
    mov ax, dx
    xor dx, dx
    div bx
    mov cx, ax
    pop ax
.small:
    div bx
    mov dx, cx                      ; DX:AX = the time
    mov bx, [cs:note_mul]
    cmp bx, 1
    je .done
    push dx
    mul bx
    mov cx, ax
    mov ax, dx
    pop dx
    push ax
    mov ax, dx
    mul bx
    pop dx
    add dx, ax
    mov ax, cx
    mov cx, [cs:note_div]
.halve:
    cmp cx, 1
    jbe .done
    shr dx, 1
    rcr ax, 1
    shr cx, 1
    jmp .halve
.done:
    pop cx
    pop bx
    ret

; Plays the note number AX (0 = C of octave 0) for the length set
play_tone:
    push cx
    mov bl, 12
    div bl                          ; AL = octave, AH = note
    mov cl, al
    mov bl, ah
    xor bh, bh
    shl bx, 1
    mov ax, [cs:note_divisors + bx]
    shr ax, cl
    call speaker_divisor
    call note_time
    push dx
    push ax
    mov bl, [cs:play_style]         ; the part that sounds
    xor bh, bh
    push ax
    mov ax, dx
    mul bx
    mov cx, ax
    pop ax
    mul bx
    add dx, cx
    mov cx, 3
.eighths:
    shr dx, 1
    rcr ax, 1
    loop .eighths
    push dx
    push ax
    call snd_wait
    call speaker_off
    pop bx                          ; the rest of the time: silence
    pop cx
    pop ax
    pop dx
    sub ax, bx
    sbb dx, cx
    call snd_wait
    pop cx
    ret

play_rest:
    call speaker_off
    call note_time
    jmp snd_wait

note_divisors dw 36485, 34437, 32505, 30680, 28958, 27333
              dw 25799, 24351, 22984, 21694, 20477, 19327
; ---------- generated by gen.py: opcodes, keywords, tables ----------

OP_END                  equ 0
OP_STMT                 equ 1
OP_JMP                  equ 2
OP_JZ_I                 equ 3
OP_JZ_L                 equ 4
OP_JZ_S                 equ 5
OP_JNZ_I                equ 6
OP_JNZ_L                equ 7
OP_JNZ_S                equ 8
OP_GOSUB                equ 9
OP_RETURN               equ 10
OP_ON_GOTO              equ 11
OP_ON_GOSUB             equ 12
OP_PUSH_I               equ 13
OP_PUSH_L               equ 14
OP_PUSH_CSTR            equ 15
OP_POP1                 equ 16
OP_POP2                 equ 17
OP_SWAP_W               equ 18
OP_NOP                  equ 19
OP_BAD                  equ 20
OP_MAKE_BACK            equ 21
OP_LD_G_I               equ 22
OP_LD_G_L               equ 23
OP_LD_G_STR             equ 24
OP_LD_L_I               equ 25
OP_LD_L_L               equ 26
OP_LD_L_STR             equ 27
OP_LD_P_I               equ 28
OP_LD_P_L               equ 29
OP_LD_P_STR             equ 30
OP_LD_F_I               equ 31
OP_LD_F_L               equ 32
OP_ST_G_I               equ 33
OP_ST_G_L               equ 34
OP_ST_G_STR             equ 35
OP_ST_L_I               equ 36
OP_ST_L_L               equ 37
OP_ST_L_STR             equ 38
OP_ST_P_I               equ 39
OP_ST_P_L               equ 40
OP_ST_P_STR             equ 41
OP_ST_F_I               equ 42
OP_ST_F_L               equ 43
OP_ST_D_STR             equ 44
OP_ADDR_G               equ 45
OP_ADDR_L               equ 46
OP_LDP_ADDR             equ 47
OP_NEAR_ADDR            equ 48
OP_ADD_OFF              equ 49
OP_I2L                  equ 50
OP_I2S                  equ 51
OP_L2I                  equ 52
OP_L2S                  equ 53
OP_S2I                  equ 54
OP_S2L                  equ 55
OP_I2L_U2               equ 56
OP_I2S_U2               equ 57
OP_L2S_U2               equ 58
OP_ADD_I                equ 59
OP_ADD_L                equ 60
OP_ADD_S                equ 61
OP_SUB_I                equ 62
OP_SUB_L                equ 63
OP_SUB_S                equ 64
OP_MUL_I                equ 65
OP_MUL_L                equ 66
OP_MUL_S                equ 67
OP_MOD_I                equ 68
OP_MOD_L                equ 69
OP_MOD_S                equ 70
OP_IDIV_I               equ 71
OP_IDIV_L               equ 72
OP_IDIV_S               equ 73
OP_NEG_I                equ 74
OP_NEG_L                equ 75
OP_NEG_S                equ 76
OP_FORTEST_I            equ 77
OP_FORTEST_L            equ 78
OP_FORTEST_S            equ 79
OP_DIV_S                equ 80
OP_POW_S                equ 81
OP_CMP_I                equ 82
OP_CMP_L                equ 83
OP_CMP_S                equ 84
OP_CMP_STR              equ 85
OP_AND_I                equ 86
OP_AND_L                equ 87
OP_OR_I                 equ 88
OP_OR_L                 equ 89
OP_XOR_I                equ 90
OP_XOR_L                equ 91
OP_EQV_I                equ 92
OP_EQV_L                equ 93
OP_IMP_I                equ 94
OP_IMP_L                equ 95
OP_NOT_I                equ 96
OP_NOT_L                equ 97
OP_CAT                  equ 98
OP_CALL                 equ 99
OP_ENTER                equ 100
OP_LEAVE                equ 101
OP_LEAVE_I              equ 102
OP_LEAVE_L              equ 103
OP_LEAVE_STR            equ 104
OP_ARGS                 equ 105
OP_TEMPREF_I            equ 106
OP_TEMPREF_L            equ 107
OP_TEMPREF_STR          equ 108
OP_CONST_END1           equ 109
OP_CONST_END2           equ 110
OP_ON_ERROR             equ 111
OP_ERROR                equ 112
OP_RESUME               equ 113
OP_RESUME_NEXT          equ 114
OP_RESUME_LABEL         equ 115
OP_DIM_G                equ 116
OP_DIM_L                equ 117
OP_DIM_P                equ 118
OP_REDIM_G              equ 119
OP_REDIM_L              equ 120
OP_REDIM_P              equ 121
OP_AELEM_G              equ 122
OP_AELEM_L              equ 123
OP_AELEM_P              equ 124
OP_AFIRST_G             equ 125
OP_AFIRST_L             equ 126
OP_AFIRST_P             equ 127
OP_ERASE_G              equ 128
OP_ERASE_L              equ 129
OP_ERASE_P              equ 130
OP_LBOUND_G             equ 131
OP_LBOUND_L             equ 132
OP_LBOUND_P             equ 133
OP_UBOUND_G             equ 134
OP_UBOUND_L             equ 135
OP_UBOUND_P             equ 136
OP_OPTION_BASE          equ 137
OP_SWAP_2               equ 138
OP_SWAP_4               equ 139
OP_SWAP_STR             equ 140
OP_LEN                  equ 141
OP_ASC                  equ 142
OP_CHR                  equ 143
OP_LEFT                 equ 144
OP_RIGHT                equ 145
OP_MID                  equ 146
OP_SPACE                equ 147
OP_STRING               equ 148
OP_UCASE                equ 149
OP_LCASE                equ 150
OP_LTRIM                equ 151
OP_RTRIM                equ 152
OP_INSTR                equ 153
OP_STR_I                equ 154
OP_STR_L                equ 155
OP_STR_S                equ 156
OP_VAL                  equ 157
OP_HEX                  equ 158
OP_OCT                  equ 159
OP_ABS_I                equ 160
OP_ABS_L                equ 161
OP_ABS_S                equ 162
OP_SGN_I                equ 163
OP_SGN_L                equ 164
OP_SGN_S                equ 165
OP_INT_I                equ 166
OP_INT_L                equ 167
OP_INT_S                equ 168
OP_FIX_I                equ 169
OP_FIX_L                equ 170
OP_FIX_S                equ 171
OP_SIN                  equ 172
OP_COS                  equ 173
OP_TAN                  equ 174
OP_ATN                  equ 175
OP_SQR                  equ 176
OP_EXP                  equ 177
OP_LOG                  equ 178
OP_RND                  equ 179
OP_RANDOMIZE            equ 180
OP_RANDOMIZE_TIMER      equ 181
OP_TIMER                equ 182
OP_OUT_SCREEN           equ 183
OP_OUT_FILE             equ 184
OP_PRINT_I              equ 185
OP_PRINT_L              equ 186
OP_PRINT_S              equ 187
OP_PRINT_STR            equ 188
OP_PRINT_COMMA          equ 189
OP_PRINT_TAB            equ 190
OP_PRINT_SPC            equ 191
OP_PRINT_NL             equ 192
OP_WRITE_I              equ 193
OP_WRITE_L              equ 194
OP_WRITE_S              equ 195
OP_WRITE_STR            equ 196
OP_WRITE_COMMA          equ 197
OP_INPUT_BEGIN          equ 198
OP_INPUT_FILE           equ 199
OP_INPUT_I              equ 200
OP_INPUT_L              equ 201
OP_INPUT_S              equ 202
OP_INPUT_STR            equ 203
OP_INPUT_END            equ 204
OP_LINE_INPUT           equ 205
OP_LINE_INPUT_FILE      equ 206
OP_READ_I               equ 207
OP_READ_L               equ 208
OP_READ_S               equ 209
OP_READ_STR             equ 210
OP_RESTORE              equ 211
OP_INKEY                equ 212
OP_INPUT_KEYS           equ 213
OP_CSRLIN               equ 214
OP_POS                  equ 215
OP_DATE                 equ 216
OP_TIME                 equ 217
OP_FRE                  equ 218
OP_ERR                  equ 219
OP_ERL                  equ 220
OP_FREEFILE             equ 221
OP_CLS                  equ 222
OP_LOCATE               equ 223
OP_COLOR                equ 224
OP_SCREEN               equ 225
OP_WIDTH                equ 226
OP_VIEW_PRINT           equ 227
OP_PALETTE              equ 228
OP_PALETTE_RESET        equ 229
OP_PSET                 equ 230
OP_POINT                equ 231
OP_LINE                 equ 232
OP_CIRCLE               equ 233
OP_PAINT                equ 234
OP_GET                  equ 235
OP_PUT                  equ 236
OP_BEEP                 equ 237
OP_SOUND                equ 238
OP_PLAY                 equ 239
OP_SLEEP                equ 240
OP_DEF_SEG              equ 241
OP_DEF_SEG_DATA         equ 242
OP_PEEK                 equ 243
OP_POKE                 equ 244
OP_INP                  equ 245
OP_OUT                  equ 246
OP_OPEN                 equ 247
OP_CLOSE                equ 248
OP_CLOSE_ALL            equ 249
OP_EOF                  equ 250
OP_KILL                 equ 251

optable:
    dw op_end
    dw op_stmt
    dw op_jmp
    dw op_jz_i
    dw op_jz_l
    dw op_jz_s
    dw op_jnz_i
    dw op_jnz_l
    dw op_jnz_s
    dw op_gosub
    dw op_return
    dw op_on_goto
    dw op_on_gosub
    dw op_push_i
    dw op_push_l
    dw op_push_cstr
    dw op_pop1
    dw op_pop2
    dw op_swap_w
    dw op_nop
    dw op_bad
    dw op_make_back
    dw op_ld_g_i
    dw op_ld_g_l
    dw op_ld_g_str
    dw op_ld_l_i
    dw op_ld_l_l
    dw op_ld_l_str
    dw op_ld_p_i
    dw op_ld_p_l
    dw op_ld_p_str
    dw op_ld_f_i
    dw op_ld_f_l
    dw op_st_g_i
    dw op_st_g_l
    dw op_st_g_str
    dw op_st_l_i
    dw op_st_l_l
    dw op_st_l_str
    dw op_st_p_i
    dw op_st_p_l
    dw op_st_p_str
    dw op_st_f_i
    dw op_st_f_l
    dw op_st_d_str
    dw op_addr_g
    dw op_addr_l
    dw op_ldp_addr
    dw op_near_addr
    dw op_add_off
    dw op_i2l
    dw op_i2s
    dw op_l2i
    dw op_l2s
    dw op_s2i
    dw op_s2l
    dw op_i2l_u2
    dw op_i2s_u2
    dw op_l2s_u2
    dw op_add_i
    dw op_add_l
    dw op_add_s
    dw op_sub_i
    dw op_sub_l
    dw op_sub_s
    dw op_mul_i
    dw op_mul_l
    dw op_mul_s
    dw op_mod_i
    dw op_mod_l
    dw op_bad
    dw op_idiv_i
    dw op_idiv_l
    dw op_bad
    dw op_neg_i
    dw op_neg_l
    dw op_neg_s
    dw op_fortest_i
    dw op_fortest_l
    dw op_fortest_s
    dw op_div_s
    dw op_pow_s
    dw op_cmp_i
    dw op_cmp_l
    dw op_cmp_s
    dw op_cmp_str
    dw op_and_i
    dw op_and_l
    dw op_or_i
    dw op_or_l
    dw op_xor_i
    dw op_xor_l
    dw op_eqv_i
    dw op_eqv_l
    dw op_imp_i
    dw op_imp_l
    dw op_not_i
    dw op_not_l
    dw op_cat
    dw op_call
    dw op_enter
    dw op_leave
    dw op_leave_i
    dw op_leave_l
    dw op_leave_str
    dw op_args
    dw op_tempref_i
    dw op_tempref_l
    dw op_tempref_str
    dw op_const_end1
    dw op_const_end2
    dw op_on_error
    dw op_error
    dw op_resume
    dw op_resume_next
    dw op_resume_label
    dw op_dim_g
    dw op_dim_l
    dw op_dim_p
    dw op_redim_g
    dw op_redim_l
    dw op_redim_p
    dw op_aelem_g
    dw op_aelem_l
    dw op_aelem_p
    dw op_afirst_g
    dw op_afirst_l
    dw op_afirst_p
    dw op_erase_g
    dw op_erase_l
    dw op_erase_p
    dw op_lbound_g
    dw op_lbound_l
    dw op_lbound_p
    dw op_ubound_g
    dw op_ubound_l
    dw op_ubound_p
    dw op_option_base
    dw op_swap_2
    dw op_swap_4
    dw op_swap_str
    dw op_len
    dw op_asc
    dw op_chr
    dw op_left
    dw op_right
    dw op_mid
    dw op_space
    dw op_string
    dw op_ucase
    dw op_lcase
    dw op_ltrim
    dw op_rtrim
    dw op_instr
    dw op_str_i
    dw op_str_l
    dw op_str_s
    dw op_val
    dw op_hex
    dw op_oct
    dw op_abs_i
    dw op_abs_l
    dw op_abs_s
    dw op_sgn_i
    dw op_sgn_l
    dw op_sgn_s
    dw op_nop
    dw op_nop
    dw op_int_s
    dw op_nop
    dw op_nop
    dw op_fix_s
    dw op_sin
    dw op_cos
    dw op_tan
    dw op_atn
    dw op_sqr
    dw op_exp
    dw op_log
    dw op_rnd
    dw op_randomize
    dw op_randomize_timer
    dw op_timer
    dw op_out_screen
    dw op_out_file
    dw op_print_i
    dw op_print_l
    dw op_print_s
    dw op_print_str
    dw op_print_comma
    dw op_print_tab
    dw op_print_spc
    dw op_print_nl
    dw op_write_i
    dw op_write_l
    dw op_write_s
    dw op_write_str
    dw op_write_comma
    dw op_input_begin
    dw op_input_file
    dw op_input_i
    dw op_input_l
    dw op_input_s
    dw op_input_str
    dw op_input_end
    dw op_line_input
    dw op_line_input_file
    dw op_read_i
    dw op_read_l
    dw op_read_s
    dw op_read_str
    dw op_restore
    dw op_inkey
    dw op_input_keys
    dw op_csrlin
    dw op_pos
    dw op_date
    dw op_time
    dw op_fre
    dw op_err
    dw op_erl
    dw op_freefile
    dw op_cls
    dw op_locate
    dw op_color
    dw op_screen
    dw op_width
    dw op_view_print
    dw op_palette
    dw op_palette_reset
    dw op_pset
    dw op_point
    dw op_line
    dw op_circle
    dw op_paint
    dw op_get
    dw op_put
    dw op_beep
    dw op_sound
    dw op_play
    dw op_sleep
    dw op_def_seg
    dw op_def_seg_data
    dw op_peek
    dw op_poke
    dw op_inp
    dw op_out
    dw op_open
    dw op_close
    dw op_close_all
    dw op_eof
    dw op_kill

KW_AND               equ 1
KW_OR                equ 2
KW_XOR               equ 3
KW_EQV               equ 4
KW_IMP               equ 5
KW_NOT               equ 6
KW_MOD               equ 7
KW_DEFINT            equ 8
KW_DEFLNG            equ 9
KW_DEFSNG            equ 10
KW_DEFDBL            equ 11
KW_DEFSTR            equ 12
KW_ABS               equ 13
KW_APPEND            equ 14
KW_AS                equ 15
KW_ASC               equ 16
KW_ATN               equ 17
KW_BASE              equ 18
KW_BEEP              equ 19
KW_CALL              equ 20
KW_CASE              equ 21
KW_CDBL              equ 22
KW_CHR_S             equ 23
KW_CINT              equ 24
KW_CIRCLE            equ 25
KW_CLNG              equ 26
KW_CLOSE             equ 27
KW_CLS               equ 28
KW_COLOR             equ 29
KW_CONST             equ 30
KW_COS               equ 31
KW_CSNG              equ 32
KW_CSRLIN            equ 33
KW_DATA              equ 34
KW_DATE_S            equ 35
KW_DECLARE           equ 36
KW_DEF               equ 37
KW_DIM               equ 38
KW_DO                equ 39
KW_DOUBLE            equ 40
KW_ELSE              equ 41
KW_ELSEIF            equ 42
KW_END               equ 43
KW_EOF               equ 44
KW_ERASE             equ 45
KW_ERL               equ 46
KW_ERR               equ 47
KW_ERROR             equ 48
KW_EXIT              equ 49
KW_EXP               equ 50
KW_FIX               equ 51
KW_FOR               equ 52
KW_FRE               equ 53
KW_FREEFILE          equ 54
KW_FUNCTION          equ 55
KW_GET               equ 56
KW_GOSUB             equ 57
KW_GOTO              equ 58
KW_HEX_S             equ 59
KW_IF                equ 60
KW_INKEY_S           equ 61
KW_INP               equ 62
KW_INPUT             equ 63
KW_INPUT_S           equ 64
KW_INSTR             equ 65
KW_INT               equ 66
KW_INTEGER           equ 67
KW_IS                equ 68
KW_KILL              equ 69
KW_LBOUND            equ 70
KW_LCASE_S           equ 71
KW_LEFT_S            equ 72
KW_LEN               equ 73
KW_LET               equ 74
KW_LINE              equ 75
KW_LOCATE            equ 76
KW_LOG               equ 77
KW_LONG              equ 78
KW_LOOP              equ 79
KW_LTRIM_S           equ 80
KW_MID_S             equ 81
KW_NEXT              equ 82
KW_OCT_S             equ 83
KW_ON                equ 84
KW_OPEN              equ 85
KW_OPTION            equ 86
KW_OUT               equ 87
KW_OUTPUT            equ 88
KW_PAINT             equ 89
KW_PALETTE           equ 90
KW_PEEK              equ 91
KW_PLAY              equ 92
KW_POINT             equ 93
KW_POKE              equ 94
KW_POS               equ 95
KW_PRESET            equ 96
KW_PRINT             equ 97
KW_PSET              equ 98
KW_PUT               equ 99
KW_RANDOMIZE         equ 100
KW_READ              equ 101
KW_REDIM             equ 102
KW_REM               equ 103
KW_RESTORE           equ 104
KW_RESUME            equ 105
KW_RETURN            equ 106
KW_RIGHT_S           equ 107
KW_RND               equ 108
KW_RTRIM_S           equ 109
KW_SCREEN            equ 110
KW_SEG               equ 111
KW_SELECT            equ 112
KW_SGN               equ 113
KW_SHARED            equ 114
KW_SIN               equ 115
KW_SINGLE            equ 116
KW_SLEEP             equ 117
KW_SOUND             equ 118
KW_SPACE_S           equ 119
KW_SPC               equ 120
KW_SQR               equ 121
KW_STATIC            equ 122
KW_STEP              equ 123
KW_STOP              equ 124
KW_STR_S             equ 125
KW_STRING            equ 126
KW_STRING_S          equ 127
KW_SUB               equ 128
KW_SWAP              equ 129
KW_SYSTEM            equ 130
KW_TAB               equ 131
KW_TAN               equ 132
KW_THEN              equ 133
KW_TIME_S            equ 134
KW_TIMER             equ 135
KW_TO                equ 136
KW_TYPE              equ 137
KW_UBOUND            equ 138
KW_UCASE_S           equ 139
KW_UNTIL             equ 140
KW_VAL               equ 141
KW_VIEW              equ 142
KW_WEND              equ 143
KW_WHILE             equ 144
KW_WIDTH             equ 145
KW_WRITE             equ 146

; the keywords, numbered from 1: length, name
keywords:
    db 3, 'AND'
    db 2, 'OR'
    db 3, 'XOR'
    db 3, 'EQV'
    db 3, 'IMP'
    db 3, 'NOT'
    db 3, 'MOD'
    db 6, 'DEFINT'
    db 6, 'DEFLNG'
    db 6, 'DEFSNG'
    db 6, 'DEFDBL'
    db 6, 'DEFSTR'
    db 3, 'ABS'
    db 6, 'APPEND'
    db 2, 'AS'
    db 3, 'ASC'
    db 3, 'ATN'
    db 4, 'BASE'
    db 4, 'BEEP'
    db 4, 'CALL'
    db 4, 'CASE'
    db 4, 'CDBL'
    db 4, 'CHR$'
    db 4, 'CINT'
    db 6, 'CIRCLE'
    db 4, 'CLNG'
    db 5, 'CLOSE'
    db 3, 'CLS'
    db 5, 'COLOR'
    db 5, 'CONST'
    db 3, 'COS'
    db 4, 'CSNG'
    db 6, 'CSRLIN'
    db 4, 'DATA'
    db 5, 'DATE$'
    db 7, 'DECLARE'
    db 3, 'DEF'
    db 3, 'DIM'
    db 2, 'DO'
    db 6, 'DOUBLE'
    db 4, 'ELSE'
    db 6, 'ELSEIF'
    db 3, 'END'
    db 3, 'EOF'
    db 5, 'ERASE'
    db 3, 'ERL'
    db 3, 'ERR'
    db 5, 'ERROR'
    db 4, 'EXIT'
    db 3, 'EXP'
    db 3, 'FIX'
    db 3, 'FOR'
    db 3, 'FRE'
    db 8, 'FREEFILE'
    db 8, 'FUNCTION'
    db 3, 'GET'
    db 5, 'GOSUB'
    db 4, 'GOTO'
    db 4, 'HEX$'
    db 2, 'IF'
    db 6, 'INKEY$'
    db 3, 'INP'
    db 5, 'INPUT'
    db 6, 'INPUT$'
    db 5, 'INSTR'
    db 3, 'INT'
    db 7, 'INTEGER'
    db 2, 'IS'
    db 4, 'KILL'
    db 6, 'LBOUND'
    db 6, 'LCASE$'
    db 5, 'LEFT$'
    db 3, 'LEN'
    db 3, 'LET'
    db 4, 'LINE'
    db 6, 'LOCATE'
    db 3, 'LOG'
    db 4, 'LONG'
    db 4, 'LOOP'
    db 6, 'LTRIM$'
    db 4, 'MID$'
    db 4, 'NEXT'
    db 4, 'OCT$'
    db 2, 'ON'
    db 4, 'OPEN'
    db 6, 'OPTION'
    db 3, 'OUT'
    db 6, 'OUTPUT'
    db 5, 'PAINT'
    db 7, 'PALETTE'
    db 4, 'PEEK'
    db 4, 'PLAY'
    db 5, 'POINT'
    db 4, 'POKE'
    db 3, 'POS'
    db 6, 'PRESET'
    db 5, 'PRINT'
    db 4, 'PSET'
    db 3, 'PUT'
    db 9, 'RANDOMIZE'
    db 4, 'READ'
    db 5, 'REDIM'
    db 3, 'REM'
    db 7, 'RESTORE'
    db 6, 'RESUME'
    db 6, 'RETURN'
    db 6, 'RIGHT$'
    db 3, 'RND'
    db 6, 'RTRIM$'
    db 6, 'SCREEN'
    db 3, 'SEG'
    db 6, 'SELECT'
    db 3, 'SGN'
    db 6, 'SHARED'
    db 3, 'SIN'
    db 6, 'SINGLE'
    db 5, 'SLEEP'
    db 5, 'SOUND'
    db 6, 'SPACE$'
    db 3, 'SPC'
    db 3, 'SQR'
    db 6, 'STATIC'
    db 4, 'STEP'
    db 4, 'STOP'
    db 4, 'STR$'
    db 6, 'STRING'
    db 7, 'STRING$'
    db 3, 'SUB'
    db 4, 'SWAP'
    db 6, 'SYSTEM'
    db 3, 'TAB'
    db 3, 'TAN'
    db 4, 'THEN'
    db 5, 'TIME$'
    db 5, 'TIMER'
    db 2, 'TO'
    db 4, 'TYPE'
    db 6, 'UBOUND'
    db 6, 'UCASE$'
    db 5, 'UNTIL'
    db 3, 'VAL'
    db 4, 'VIEW'
    db 4, 'WEND'
    db 5, 'WHILE'
    db 5, 'WIDTH'
    db 5, 'WRITE'
    db 0

; statements by keyword
st_table:
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw st_deftype
    dw st_deftype
    dw st_deftype
    dw st_deftype
    dw st_deftype
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw st_beep
    dw st_call
    dw st_case
    dw 0
    dw 0
    dw 0
    dw st_circle
    dw 0
    dw st_close
    dw st_cls
    dw st_color
    dw st_const
    dw 0
    dw 0
    dw 0
    dw data_collect
    dw 0
    dw st_declare
    dw st_def
    dw st_dim
    dw st_do
    dw 0
    dw st_else
    dw st_elseif
    dw st_end
    dw 0
    dw st_erase
    dw 0
    dw 0
    dw st_error
    dw st_exit
    dw 0
    dw 0
    dw st_for
    dw 0
    dw 0
    dw st_sub
    dw st_get
    dw st_gosub
    dw st_goto
    dw 0
    dw st_if
    dw 0
    dw 0
    dw st_input
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw st_kill
    dw 0
    dw 0
    dw 0
    dw 0
    dw st_let
    dw st_line
    dw st_locate
    dw 0
    dw 0
    dw st_loop
    dw 0
    dw 0
    dw st_next
    dw 0
    dw st_on
    dw st_open
    dw st_option
    dw st_out
    dw 0
    dw st_paint
    dw st_palette
    dw 0
    dw st_play
    dw 0
    dw st_poke
    dw 0
    dw st_pset
    dw st_print
    dw st_pset
    dw st_put
    dw st_randomize
    dw st_read
    dw st_redim
    dw st_skip
    dw st_restore
    dw st_resume
    dw st_return
    dw 0
    dw 0
    dw 0
    dw st_screen
    dw 0
    dw st_select
    dw 0
    dw st_shared
    dw 0
    dw 0
    dw st_sleep
    dw st_sound
    dw 0
    dw 0
    dw 0
    dw st_dim
    dw 0
    dw st_stop
    dw 0
    dw 0
    dw 0
    dw st_sub
    dw st_swap
    dw st_system
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw 0
    dw st_type
    dw 0
    dw 0
    dw 0
    dw 0
    dw st_view
    dw st_wend
    dw st_while
    dw st_width
    dw st_write

; built-in functions: keyword, opcode, result type, arguments
fn_specs:
    db KW_ABS, OP_ABS_I, 0, 'N', 0
    db KW_SGN, OP_SGN_I, TY_INT, 'N', 0
    db KW_INT, OP_INT_I, 0, 'N', 0
    db KW_FIX, OP_FIX_I, 0, 'N', 0
    db KW_CINT, 0, TY_INT, 'I', 0
    db KW_CLNG, 0, TY_LNG, 'L', 0
    db KW_CSNG, 0, TY_SNG, 'F', 0
    db KW_CDBL, 0, TY_SNG, 'F', 0
    db KW_SIN, OP_SIN, TY_SNG, 'F', 0
    db KW_COS, OP_COS, TY_SNG, 'F', 0
    db KW_TAN, OP_TAN, TY_SNG, 'F', 0
    db KW_ATN, OP_ATN, TY_SNG, 'F', 0
    db KW_SQR, OP_SQR, TY_SNG, 'F', 0
    db KW_EXP, OP_EXP, TY_SNG, 'F', 0
    db KW_LOG, OP_LOG, TY_SNG, 'F', 0
    db KW_TIMER, OP_TIMER, TY_SNG, 0
    db KW_LEN, OP_LEN, TY_INT, 'S', 0
    db KW_ASC, OP_ASC, TY_INT, 'S', 0
    db KW_VAL, OP_VAL, TY_SNG, 'S', 0
    db KW_CHR_S, OP_CHR, TY_STR, 'I', 0
    db KW_STR_S, OP_STR_I, TY_STR, 'N', 0
    db KW_HEX_S, OP_HEX, TY_STR, 'L', 0
    db KW_OCT_S, OP_OCT, TY_STR, 'L', 0
    db KW_SPACE_S, OP_SPACE, TY_STR, 'I', 0
    db KW_STRING_S, OP_STRING, TY_STR, 'IX', 0
    db KW_LEFT_S, OP_LEFT, TY_STR, 'SI', 0
    db KW_RIGHT_S, OP_RIGHT, TY_STR, 'SI', 0
    db KW_MID_S, OP_MID, TY_STR, 'SI]I', 0
    db KW_LCASE_S, OP_LCASE, TY_STR, 'S', 0
    db KW_UCASE_S, OP_UCASE, TY_STR, 'S', 0
    db KW_LTRIM_S, OP_LTRIM, TY_STR, 'S', 0
    db KW_RTRIM_S, OP_RTRIM, TY_STR, 'S', 0
    db KW_INKEY_S, OP_INKEY, TY_STR, 0
    db KW_INPUT_S, OP_INPUT_KEYS, TY_STR, 'I', 0
    db KW_CSRLIN, OP_CSRLIN, TY_INT, 0
    db KW_POS, OP_POS, TY_INT, 'I', 0
    db KW_PEEK, OP_PEEK, TY_INT, 'L', 0
    db KW_INP, OP_INP, TY_INT, 'I', 0
    db KW_POINT, OP_POINT, TY_INT, 'II', 0
    db KW_ERR, OP_ERR, TY_INT, 0
    db KW_ERL, OP_ERL, TY_INT, 0
    db KW_FREEFILE, OP_FREEFILE, TY_INT, 0
    db KW_EOF, OP_EOF, TY_INT, 'I', 0
    db KW_DATE_S, OP_DATE, TY_STR, 0
    db KW_TIME_S, OP_TIME, TY_STR, 0
    db KW_FRE, OP_FRE, TY_SNG, 'A', 0
    db 0

; conversions: [from][to]
convert_ops:
    db 0, OP_I2L, OP_I2S, 0
    db OP_L2I, 0, OP_L2S, 0
    db OP_S2I, OP_S2L, 0, 0
    db 0, 0, 0, 0
; loads: [kind][type]
load_ops:
    db OP_LD_G_I, OP_LD_G_L, OP_LD_G_L, OP_LD_G_STR
    db OP_LD_L_I, OP_LD_L_L, OP_LD_L_L, OP_LD_L_STR
    db OP_LD_P_I, OP_LD_P_L, OP_LD_P_L, OP_LD_P_STR
    db OP_LD_F_I, OP_LD_F_L, OP_LD_F_L, OP_BAD
    db 0, 0, 0, 0
; stores: [kind][type]
store_ops:
    db OP_ST_G_I, OP_ST_G_L, OP_ST_G_L, OP_ST_G_STR
    db OP_ST_L_I, OP_ST_L_L, OP_ST_L_L, OP_ST_L_STR
    db OP_ST_P_I, OP_ST_P_L, OP_ST_P_L, OP_ST_P_STR
    db OP_ST_F_I, OP_ST_F_L, OP_ST_F_L, OP_BAD
    db OP_BAD, OP_BAD, OP_BAD, OP_ST_D_STR
; AND OR XOR EQV IMP: INT, LONG
logic_ops:
    db OP_AND_I, OP_AND_L, OP_OR_I, OP_OR_L
    db OP_XOR_I, OP_XOR_L, OP_EQV_I, OP_EQV_L
    db OP_IMP_I, OP_IMP_L
print_ops:
    db OP_PRINT_I, OP_PRINT_L, OP_PRINT_S, OP_PRINT_STR
input_ops:
    db OP_INPUT_I, OP_INPUT_L, OP_INPUT_S, OP_INPUT_STR
read_ops:
    db OP_READ_I, OP_READ_L, OP_READ_S, OP_READ_STR
write_ops:
    db OP_WRITE_I, OP_WRITE_L, OP_WRITE_S, OP_WRITE_STR
leave_ops:
    db OP_LEAVE_I, OP_LEAVE_L, OP_LEAVE_L, OP_LEAVE_STR
; DEFINT DEFLNG DEFSNG DEFDBL DEFSTR
deftype_of:
    db TY_INT, TY_LNG, TY_SNG, TY_SNG
    db TY_STR
type_suffix:
    db 0, '%', '&', '!'
    db '$'


; ---------- ERR, ERL, FREEFILE ----------

op_err:
    push word [cs:err_code]
    jmp next_op

op_erl:
    mov ax, [cs:err_ip]
    push ds
    push cs
    pop ds
    call line_of
    pop ds
    push ax
    jmp next_op

op_freefile:
    mov al, 1
.next:
    xor ah, ah
    push ax
    call file_slot
    pop ax
    cmp byte [cs:bx + F_MODE], 0
    je .found
    inc al
    cmp al, FILE_MAX
    jbe .next
    mov al, E_FILENUM
    jmp rt_error
.found:
    xor ah, ah
    push ax
    jmp next_op

; ======================================================================
; Constants
; ======================================================================

c_one           dw 0000h, 3F80h
c_two_over_pi   dw 0F983h, 3F22h
c_pio2_1        dw 0000h, 3FC9h
c_pio2_2        dw 0AA22h, 39FDh
c_pio2          dw 0FDBh, 3FC9h
c_pio6          dw 0A92h, 3F06h
c_sqrt3         dw 0B3D7h, 3FDDh
c_tan15         dw 30A3h, 3E89h
c_log2e         dw 0AA3Bh, 3FB8h
c_ln2_1         dw 8000h, 3F31h
c_ln2_2         dw 8083h, 0B95Eh
c_ln2           dw 7218h, 3F31h
c_sqrt2         dw 04F3h, 3FB5h
c_exp_max       dw 70A4h, 42B1h
c_exp_min       dw 0A8F6h, 0C2AEh
c_tick          dw 0F98Eh, 3D60h
c_e6            dw 2400h, 4974h
c_e7            dw 9680h, 4B18h
c_e4            dw 4000h, 461Ch
c_aspect        dw 5555h, 3F55h
c_p1            dw 0000h, 4120h         ; 10, 100, 10^4, 10^8, 10^16, 10^32
c_p2            dw 0000h, 42C8h
c_p4            dw 4000h, 461Ch
c_p8            dw 0BC20h, 4CBEh
c_p16           dw 1BCAh, 5A0Eh
c_p32           dw 0C5AEh, 749Dh

; polynomials: count, then the coefficients from the highest power
c_sin_coefs     dw 4                    ; -1/5040, 1/120, -1/6, 1
                dw 0D01h, 0B950h, 8889h, 3C08h, 0AAABh, 0BE2Ah, 0000h, 3F80h
c_cos_coefs     dw 5                    ; 1/40320, -1/720, 1/24, -1/2, 1
                dw 0D01h, 37D0h, 0B61h, 0BAB6h, 0AAABh, 3D2Ah, 0000h, 0BF00h
                dw 0000h, 3F80h
c_atn_coefs     dw 6                    ; -1/11, 1/9, -1/7, 1/5, -1/3, 1
                dw 0BA2Fh, 0BDBAh, 8E39h, 3DE3h, 4925h, 0BE12h, 0CCCDh, 3E4Ch
                dw 0AAABh, 0BEAAh, 0000h, 3F80h
c_exp_coefs     dw 8                    ; 1/5040 ... 1/2, 1, 1
                dw 0D01h, 3950h, 0B61h, 3AB6h, 8889h, 3C08h, 0AAABh, 3D2Ah
                dw 0AAABh, 3E2Ah, 0000h, 3F00h, 0000h, 3F80h, 0000h, 3F80h
c_log_coefs     dw 5                    ; 1/9, 1/7, 1/5, 1/3, 1
                dw 8E39h, 3DE3h, 4925h, 3E12h, 0CCCDh, 3E4Ch, 0AAABh, 3EAAh
                dw 0000h, 3F80h

; ======================================================================
; Messages
; ======================================================================

m_basic             db 'CBasic: ', 0
m_usage             db 'Usage: BASIC program[.BAS]', 0
m_crlf              db 13, 10, 0
m_ext_bas           db '.BAS', 0
m_cannot_open       db 'cannot open ', 0
m_read_error        db 'cannot read the program', 0
m_too_long          db 'the program is longer than 64 KB', 0
m_memory            db 'not enough memory', 0
m_line_end          db '): ', 0
m_in_line           db ' in line ', 0
m_redo              db 'Redo from start', 0
m_unprintable       db 'Unprintable error', 0

m_syntax            db 'Syntax error', 0
m_expected_end      db 'Expected: end of statement', 0
m_type_mismatch     db 'Type mismatch', 0
m_overflow          db 'Overflow', 0
m_dup_def           db 'Duplicate definition', 0
m_dup_label         db 'Duplicate label', 0
m_label_undefined   db 'Label not defined', 0
m_too_big           db 'Program too big', 0
m_too_deep          db 'Blocks nested too deeply', 0
m_too_many_names    db 'Too many names', 0
m_too_many_params   db 'Too many parameters', 0
m_too_many_strings  db 'Too many string constants', 0
m_too_much_data     db 'Too much DATA', 0
m_out_of_data       db 'Too many variables', 0
m_for_variable      db 'FOR needs a simple variable', 0
m_next_without_for  db 'NEXT without FOR', 0
m_no_field          db 'Element not defined', 0
m_no_sub            db 'Subprogram not defined', 0
m_shared_unknown    db 'SHARED of an unknown variable', 0
m_string_field      db 'Strings are not allowed in TYPE', 0
m_sub_in_sub        db 'SUB or FUNCTION inside another', 0
m_sub_open          db 'SUB or FUNCTION without END', 0
m_type_open         db 'TYPE without END TYPE', 0
m_unknown_type      db 'Unknown type', 0
m_wrong_dims        db 'Wrong number of dimensions', 0
m_bad_argument      db 'Argument-count mismatch', 0
m_bad_const         db 'Invalid constant', 0
m_if_open           db 'Block IF without END IF', 0
m_for_open          db 'FOR without NEXT', 0
m_do_open           db 'DO without LOOP', 0
m_while_open        db 'WHILE without WEND', 0
m_select_open       db 'SELECT without END SELECT', 0
m_if_without        db 'ELSE, ELSEIF or END IF without block IF', 0
m_loop_without      db 'LOOP without DO', 0
m_wend_without      db 'WEND without WHILE', 0
m_case_without      db 'CASE or END SELECT without SELECT', 0

ctl_open_msg    dw m_if_open, m_for_open, m_do_open, m_while_open, m_select_open
ctl_close_msg   dw m_if_without, m_next_without_for, m_loop_without
                dw m_wend_without, m_case_without

; runtime errors: number, text
error_texts:
    db E_NEXT, 'NEXT without FOR', 0
    db E_SYNTAX, 'Syntax error', 0
    db E_RETURN, 'RETURN without GOSUB', 0
    db E_DATA, 'Out of DATA', 0
    db E_FUNC, 'Illegal function call', 0
    db E_OVERFLOW, 'Overflow', 0
    db E_MEMORY, 'Out of memory', 0
    db E_LABEL, 'Label not defined', 0
    db E_SUBSCRIPT, 'Subscript out of range', 0
    db E_DUPDEF, 'Duplicate definition', 0
    db E_DIVZERO, 'Division by zero', 0
    db E_TYPE, 'Type mismatch', 0
    db E_STRSPACE, 'Out of string space', 0
    db E_STRLONG, 'String too long', 0
    db E_COMPLEX, 'String formula too complex', 0
    db E_NORESUME, 'No RESUME', 0
    db E_RESUME, 'RESUME without error', 0
    db E_STACK, 'Out of stack space', 0
    db E_BADFILE, 'Bad file name or number', 0
    db E_NOFILE, 'File not found', 0
    db E_FILEMODE, 'Bad file mode', 0
    db E_OPEN, 'File already open', 0
    db E_EXISTS, 'File already exists', 0
    db E_DISKFULL, 'Disk full', 0
    db E_EOF, 'Input past end of file', 0
    db E_FILENUM, 'Bad file name or number', 0
    db E_PATH, 'Path not found', 0
    db E_BREAK, 'Break', 0
    db 0

; ======================================================================
; Variables (not in the file; cleared at the start)
; ======================================================================

section .bss

bss_start:
; segments
seg_src         resw 1
seg_code        resw 1
seg_data        resw 1
seg_str         resw 1
seg_lines       resw 1
seg_sym         resw 1
arena_start     resw 1
arena_end       resw 1

src_name        resb 80
src_len         resw 1
err_count       resw 1
compile_sp      resw 1

; the lexer (lx_state .. lx_state_end is saved and restored as a whole)
lx_state:
lx_pos          resw 1
lx_line         resw 1
tok             resb 1
tok_type        resb 1
tok_op          resb 1
tok_kw          resb 1
tok_suffix      resb 1
tok_pad         resb 1
tok_lo          resw 1
tok_hi          resw 1
tok_len         resw 1
tok_text        resw 1
tok_start       resw 1
tok_name        resb 42
lx_state_end:
lx_saved        resb 64
lx_pos_tmp      resw 1
num_buf         resb 42

; names
key_buf         resb 84
key_len         resw 1
key_saved       resb 84
key_saved_len   resw 1
proc_saved      resb 84
proc_saved_len  resw 1
key_type        resb 1
find_scope      resb 1
sym_free        resw 1
field_key_buf   resb 84
field_key_len   resw 1
field_type_entry resw 1
dim_key         resb 84
dim_key_len     resw 1

; the compiler
pass            resb 1
scope           resb 1
in_sub          resb 1
main_ended      resb 1
deffn_mode      resb 1
sub_kind        resb 1
sub_type        resb 1
sub_count       resb 1
sub_strings     resb 1
dim_shared      resb 1
dim_redim       resb 1
dim_dims        resb 1
dim_type        resb 1
param_array     resb 1
call_parens     resb 1
call_arg        resb 1
arg_type        resb 1
arg_array       resb 1
arr_op_kind     resb 1
arr_type        resb 1
arr_dims        resb 1
option_base     resb 1
print_nl        resb 1
case_items      resb 1
fn_op           resb 1
fn_result       resb 1
fn_type         resb 1
r_kind          resb 1
r_type          resb 1
ex_left         resb 1
ex_pad          resb 1
deftype         resb 26
def_new         resb 1
ctl_depth       resb 1
cp              resw 1
data_top        resw 1
frame_size      resw 1
line_count      resw 1
str_const_top   resw 1
r_addr          resw 1
r_rec           resw 1
dim_rec         resw 1
arg_rec         resw 1
arr_addr        resw 1
arr_rec         resw 1
arr_size        resw 1
for_rec         resw 1
input_retry     resw 1
type_entry      resw 1
type_offset     resw 1
sub_entry       resw 1
sub_info        resw 1
sub_exit_chain  resw 1
enter_operand   resw 1
call_entry      resw 1
call_info       resw 1
on_count_at     resw 1
const_lo        resw 1
const_hi        resw 1
data_top_p1     resw 1
data_end        resw 1
ctl_stack       resb CTL_SIZE * CTL_MAX
exit_chains     resw CTL_MAX

; the machine
running         resb 1
in_eval         resb 1
in_handler      resb 1
out_file        resb 1
leave_kind      resb 1
rt_dims         resb 1
rt_type         resb 1
rt_base         resb 1
break_count     resb 1
in_src          resb 1
in_err          resb 1
in_fields       resb 1
in_numeric      resb 1
run_sp          resw 1
eval_sp         resw 1
stmt_ip         resw 1
stmt_sp         resw 1
module_ip       resw 1
module_sp       resw 1
err_code        resw 1
err_ip          resw 1
on_error        resw 1
enter_size      resw 1
enter_ret       resw 1
leave_lo        resw 1
leave_hi        resw 1
rt_esize        resw 1
rt_lo           resw 1
rt_hi           resw 1
temp_area       resw 1
temp_end        resw 1
temp_base       resw 1
temp_top        resw 1
ntemp_base      resw 1
ntemp_top       resw 1
ntemp_end       resw 1
frame_base      resw 1
frame_top       resw 1
sarr_top        resw 1
sarr_pinned     resw 1
arena_top       resw 1
arena_pinned    resw 1
heap_start      resw 1
str_top         resw 1
cat_left        resw 1
cat_right       resw 1
data_ptr        resw 1
def_seg         resw 1
in_pos          resw 1
inbuf_len       resw 1
inbuf           resb INBUF_SIZE
numbuf          resb NUMBUF_SIZE
fmt_digits      resb 12

; reals
fb_sign         resb 1
ft_sign         resb 1
f2l_mode        resb 1
fs_sign         resb 1
atn_sign        resb 1
atn_flags       resb 1
num_neg         resb 1
num_digits      resb 1
num_real        resb 1
radix_bits      resb 1
fmt_iter        resb 1
ft_exp          resw 1
ma_h            resw 1
ma_l            resw 1
w0              resw 1
w1              resw 1
fcount          resw 1
fcount2         resw 1
quadrant        resw 1
exp_n           resw 1
pow_n           resw 1
pow_k           resw 1
fmt_hi          resw 1
fmt_e10         resw 1
num_mant        resw 2
num_e10         resw 1
rnd_seed        resw 2
fx              resw 2
fy              resw 2
fk              resw 2
fx2             resw 2
ftmp            resw 2
ftmp2           resw 2

; the screen and graphics
scr_mode        resb 1
scr_cols        resb 1
scr_attr        resb 1
scr_fg          resb 1
cga_palette     resb 1
view_top        resb 1
view_bottom     resb 1
cur_row         resb 1
cur_col         resb 1
gfx_c           resb 1
line_flags      resb 1
circ_flags      resb 1
circ_arc        resb 1
circ_lines      resb 1
paint_border    resb 1
paint_in        resb 1
put_action      resb 1
img_bits        resb 1
img_byte        resb 1
gfx_pad         resb 1
gfx_x           resw 1
gfx_y           resw 1
l_x2            resw 1
l_y2            resw 1
l_dx            resw 1
l_dy            resw 1
box_x1          resw 1
box_y1          resw 1
circ_x          resw 1
circ_y          resw 1
circ_rx         resw 1
circ_ry         resw 1
circ_a1         resw 1
circ_a2         resw 1
circ_r          resw 2
circ_start      resw 2
circ_end        resw 2
circ_aspect     resw 2
arc_cos         resw 1
arc_sin         resw 1
sq_lo           resw 1
sq_hi           resw 1
paint_l         resw 1
paint_x         resw 1
paint_r         resw 1
paint_max       resw 1
img_seg         resw 1
img_off         resw 1
img_w           resw 1
img_h           resw 1

; sound
play_octave     resb 1
play_length     resb 1
play_tempo      resb 1
play_style      resb 1
snd_until       resw 2
snd_len         resw 2
note_len        resw 1
note_mul        resw 1
note_div        resw 1

; files
file_slots      resb F_SIZE * FILE_MAX

bss_end:
