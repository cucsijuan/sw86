; asm.asm - the COS assembler (ASM.COM)
;
;   ASM source[.ASM] [output]
;
; Assembles a NASM-syntax 8086 program into a flat binary: a .COM file by
; default (the source name with .COM), or whatever the output name says
; (ASM COS.ASM COS.SYS). The dialect is the one of the pc86 asm86
; assembler and gives the same bytes: every 8086 instruction the machine
; runs, labels and .local labels, EQU, DB/DW/RESB/RESW, TIMES, ORG, $ and
; $$, the .text, .data and .bss sections, expressions with + - * / % // %% << >> & | ^ ~ ! and parentheses,
; BYTE/WORD/SHORT/NEAR/FAR, segment overrides and REP prefixes. It is
; written in that same dialect, so it assembles itself.
;
; How it works. The first pass reads the source a piece at a time and turns
; each line into tokens kept in memory (keywords and names are looked up
; once, here). Then passes over the tokens compute the address and size of
; every line until nothing changes, picking the shortest form of each jump,
; displacement and immediate, like NASM; the last pass writes the bytes.
;
; Memory, above the program's own 64 KB: the hash table of the names, the
; output (64 KB), then the tokens growing up and the names growing down
; from the top, each name on a paragraph of its own.
org 100h

    jmp start

T_EOL       equ 0               ; tokens in memory: the type byte, then
T_NUM       equ 1               ;   the value (dword)
T_STR       equ 2               ;   length (byte), the characters
T_PUNCT     equ 3               ;   the character (P_* for two)
T_DOLLAR    equ 4
T_DOLLAR2   equ 5
T_KW        equ 6               ;   keyword number (byte)
T_SYM       equ 7               ;   name (word: its entry)
T_ERR       equ 8               ;   message (ASCIIZ): a lexical error
T_LOCAL     equ 9               ; while lexing only: a .local name

P_SHL       equ 'L'             ; <<
P_SHR       equ 'R'             ; >>
P_SDIV      equ 'D'             ; //
P_SMOD      equ 'M'             ; %%

; A token of the current line, as the passes see it (8 bytes)
TK_TYPE     equ 0
TK_SUB      equ 1               ; punctuation, keyword number, string length
TK_LO       equ 2               ; number (low word), name entry, string address
TK_HI       equ 4               ; number (high word)
TK_CLASS    equ 2               ; keywords: class, a, b, flags
TK_A        equ 3
TK_B        equ 4
TK_FLAGS    equ 5
TK_SIZE     equ 8

; Keyword classes
C_REG8      equ 1               ; a = register number
C_REG16     equ 2
C_SREG      equ 3
C_REG32     equ 4
C_SIZE      equ 5               ; a = 1 byte, 2 word, 3 dword/qword/tword
C_JMOD      equ 6               ; a = 1 short, 2 near, 3 far
C_STRICT    equ 7
C_PTR       equ 8
C_DIR       equ 9               ; a = D_*
C_UNSUP     equ 10              ; 8086 instructions the machine lacks
C_LATER     equ 11              ; instructions of later CPUs
C_MNEM      equ 12              ; a = M_*, b = condition, /r or opcode

KF_KEYWORD  equ 1               ; cannot be a label; makes "name kw" a label
KF_STRING   equ 2               ; takes REP

D_DB        equ 1
D_DW        equ 2
D_RESB      equ 3
D_RESW      equ 4
D_EQU       equ 5
D_TIMES     equ 6
D_ORG       equ 7
D_BITS      equ 8
D_CPU       equ 9
D_REP       equ 10
D_REPNE     equ 11
D_OTHER     equ 12
D_SECTION   equ 13

M_ADD       equ 1               ; ADD..CMP in the order of the /r field
M_OR        equ 2
M_ADC       equ 3
M_SBB       equ 4
M_AND       equ 5
M_SUB       equ 6
M_XOR       equ 7
M_CMP       equ 8
M_MOV       equ 9
M_XCHG      equ 10
M_TEST      equ 11
M_LEA       equ 12
M_INC       equ 13
M_DEC       equ 14
M_NOT       equ 15
M_NEG       equ 16
M_MUL       equ 17
M_IMUL      equ 18
M_DIV       equ 19
M_IDIV      equ 20
M_ROL       equ 21
M_ROR       equ 22
M_RCL       equ 23
M_RCR       equ 24
M_SHL       equ 25
M_SHR       equ 26
M_SAR       equ 27
M_PUSH      equ 28
M_POP       equ 29
M_JMP       equ 30
M_CALL      equ 31
M_RET       equ 32
M_RETF      equ 33
M_IRET      equ 34
M_INT       equ 35
M_INT3      equ 36
M_LDS       equ 37
M_JCC       equ 38
M_LOOP      equ 39
M_LOOPE     equ 40
M_LOOPNE    equ 41
M_JCXZ      equ 42
M_IN        equ 43
M_OUT       equ 44
M_SIMPLE    equ 45

; A name (symbol or keyword): its own segment, the entry at offset 0
S_NEXT      equ 0               ; next entry with the same hash (segment)
S_KIND      equ 2               ; 0 symbol, 1 keyword
S_ID        equ 3               ; keyword: its number; symbol: SF_*
S_VLO       equ 4               ; value (dword)
S_VHI       equ 6
S_RELOC     equ 8               ; how many addresses it holds (signed)
S_PASS      equ 9               ; pass that defined it last, 0FFh none
S_LINE      equ 10              ; line that defined it
S_LEN       equ 12
S_NAME      equ 13
SF_DEFINED  equ 1               ; has a known value
SF_LABEL    equ 2

HASH_SIZE   equ 1024            ; buckets, in their own segment

; Statement kinds
K_EMPTY     equ 0
K_INSTR     equ 1
K_DB        equ 2
K_DW        equ 3
K_RESB      equ 4
K_RESW      equ 5
K_EQU       equ 6
K_ORG       equ 7
K_IGNORE    equ 8
K_ERROR     equ 9
K_SECTION   equ 10

; Sections: .text, then .data and .bss from the next multiple of 4; .bss
; takes addresses but no room in the output
SEC_TEXT    equ 0
SEC_DATA    equ 1
SEC_BSS     equ 2

; An operand (32 bytes)
O_TYPE      equ 0               ; OT_*
O_REG       equ 1
O_SIZE      equ 2               ; 0 not given, 1 byte, 2 word
O_IMMSZ     equ 3               ; size keyword given on an immediate
O_JMOD      equ 4               ; J_*
O_FAR       equ 5               ; immediate written as segment:offset
O_SEG       equ 6               ; segment override 0-3, 0FFh none
O_BASE      equ 7               ; 3 BX, 5 BP, 0FFh none
O_INDEX     equ 8               ; 6 SI, 7 DI, 0FFh none
O_IMM       equ 10              ; value: low, high, reloc, unknown
O_DISP      equ 16
O_FSEG      equ 22              ; the segment of segment:offset
O_SIZEOF    equ 32
V_LO        equ 0               ; inside a value
V_HI        equ 2
V_RELOC     equ 4
V_UNK       equ 5

OT_NONE     equ 0
OT_REG8     equ 1
OT_REG16    equ 2
OT_SREG     equ 3
OT_IMM      equ 4
OT_MEM      equ 5

J_DEFAULT   equ 0
J_SHORT     equ 1
J_NEAR      equ 2
J_FAR       equ 3

MAX_PASSES  equ 40
STICKY_PASS equ 12              ; from this pass on, long forms never shrink

INBUF_SIZE  equ 16384           ; source read a piece at a time
MAX_LINE    equ 4096
MAX_TOKENS  equ 400             ; per line
MAX_ERRORS  equ 100             ; shown

; ======================================================================
; Start
; ======================================================================

start:
    cld
    mov ax, cs                      ; the segments above the program
    add ax, 1000h
    mov [sym_seg], ax
    add ax, HASH_SIZE * 2 / 16
    mov [out_seg], ax
    add ax, 1000h
    mov [ir_seg], ax
    mov bx, [2]                     ; the top of our memory, from the PSP
    mov [name_top], bx
    sub bx, 400h                    ; room for the longest line
    mov [ir_limit], bx
    cmp ax, bx
    jb .memory
    mov si, m_memory
    jmp fatal
.memory:
    call get_args
    call init_names
    call lex_file
    call assemble
    cmp word [err_count], 0
    jne .failed
    call write_output
    mov si, out_name
    call puts
    mov si, m_colon
    call puts
    mov ax, [out_len]
    mov dx, [out_len + 2]
    call put_unsigned
    mov si, m_bytes
    call puts
    call flush_line
    mov ax, 4C00h
    int 21h
.failed:
    mov ax, [err_count]
    xor dx, dx
    call put_unsigned
    mov si, m_errors
    cmp word [err_count], 1
    jne .plural
    mov si, m_error
.plural:
    call puts
    call flush_line
    mov ax, 4C01h
    int 21h

; SI = message (ASCIIZ): prints "ASM: message" and ends with code 2
fatal:
    mov di, m_nothing
; SI = message, DI = a name after it: "ASM: message name", and ends
fatal_name:
    push si
    mov si, m_asm
    call puts
    pop si
    call puts
    mov si, di
    call puts
    call flush_line
    mov ax, 4C02h
    int 21h

; ======================================================================
; Output: a line is built in msgbuf and written at once
; ======================================================================

; DS:SI ASCIIZ
puts:
    push ax
    push di
    mov di, [msg_len]
.loop:
    lodsb
    or al, al
    jz .done
    cmp di, msgbuf_end - msgbuf - 3
    jae .loop
    mov [msgbuf + di], al
    inc di
    jmp .loop
.done:
    mov [msg_len], di
    pop di
    pop ax
    ret

putc:                               ; AL
    push di
    mov di, [msg_len]
    cmp di, msgbuf_end - msgbuf - 3
    jae .full
    mov [msgbuf + di], al
    inc di
    mov [msg_len], di
.full:
    pop di
    ret

; Writes the line and CR LF to standard output
flush_line:
    push ax
    push bx
    push cx
    push dx
    mov bx, [msg_len]
    mov word [msgbuf + bx], 0A0Dh
    lea cx, [bx + 2]
    mov dx, msgbuf
    mov bx, 1
    mov ah, 40h
    int 21h
    mov word [msg_len], 0
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; DX:AX unsigned, in decimal
put_unsigned:
    push ax
    push bx
    push cx
    push dx
    push si
    mov si, numbuf_end
    mov byte [si], 0
    mov bx, 10
.digit:
    mov cx, ax                      ; DX:AX / 10, one word at a time
    mov ax, dx
    xor dx, dx
    div bx
    xchg ax, cx
    div bx
    add dl, '0'
    dec si
    mov [si], dl
    mov dx, cx
    or cx, ax
    jnz .digit
    call puts
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; DX:AX signed, in decimal
put_signed:
    push ax
    push dx
    test dx, 8000h
    jz .positive
    push ax
    mov al, '-'
    call putc
    pop ax
    not dx
    neg ax
    sbb dx, -1
.positive:
    call put_unsigned
    pop dx
    pop ax
    ret

; ======================================================================
; Errors
; ======================================================================

; Starts an error message for the current line: CF = 1 when it must not be
; shown (not the last pass, quiet, or this line already has one).
err_begin:
    cmp byte [quiet], 0
    jne .hide
    mov byte [stmt_failed], 1
    cmp byte [final], 0
    je .hide
    push ax
    mov ax, [cur_line]
    cmp ax, [last_err_line]
    je .hide_pop
    mov [last_err_line], ax
    inc word [err_count]
    cmp word [err_count], MAX_ERRORS
    ja .hide_pop
    push si
    push dx
    mov si, src_name
    call puts
    mov al, '('
    call putc
    mov ax, [cur_line]
    xor dx, dx
    call put_unsigned
    mov si, m_line_end
    call puts
    pop dx
    pop si
    pop ax
    clc
    ret
.hide_pop:
    pop ax
.hide:
    stc
    ret

err_end:
    call flush_line
    ret

; SI = message: the whole error
error:
    call err_begin
    jc .done
    call puts
    call err_end
.done:
    ret

; SI = message, BX = token: "message: 'token'"
error_tok:
    call err_begin
    jc .done
    call puts
    call put_quoted
    call err_end
.done:
    ret

; ": 'token'" for the token at BX
put_quoted:
    push si
    mov si, m_quote_open
    call puts
    call put_token
    mov al, 27h
    call putc
    pop si
    ret

; The text of the token at BX
put_token:
    push ax
    push cx
    push dx
    push si
    mov al, [bx + TK_TYPE]
    cmp al, T_NUM
    jne .not_num
    mov ax, [bx + TK_LO]
    mov dx, [bx + TK_HI]
    call put_signed
    jmp .done
.not_num:
    cmp al, T_STR
    jne .not_str
    mov si, [bx + TK_LO]
    mov cl, [bx + TK_SUB]
    xor ch, ch
    jcxz .done
.str:
    lodsb
    call putc
    loop .str
    jmp .done
.not_str:
    cmp al, T_PUNCT
    jne .not_punct
    mov al, [bx + TK_SUB]
    mov si, m_shl
    cmp al, P_SHL
    je .two
    mov si, m_shr
    cmp al, P_SHR
    je .two
    mov si, m_sdiv
    cmp al, P_SDIV
    je .two
    mov si, m_smod
    cmp al, P_SMOD
    je .two
    call putc
    jmp .done
.two:
    call puts
    jmp .done
.not_punct:
    cmp al, T_DOLLAR
    jne .not_dollar
    mov al, '$'
    call putc
    jmp .done
.not_dollar:
    cmp al, T_DOLLAR2
    jne .not_dollar2
    mov si, m_dollar2
    call puts
    jmp .done
.not_dollar2:
    cmp al, T_KW
    jne .not_kw
    mov al, [bx + TK_SUB]
    call put_keyword
    jmp .done
.not_kw:
    cmp al, T_SYM
    jne .done
    mov ax, [bx + TK_LO]
    call put_symbol
.done:
    pop si
    pop dx
    pop cx
    pop ax
    ret

; The name of keyword AL
put_keyword:
    push ax
    push cx
    push si
    xor ah, ah
    mov si, ax
    shl si, 1
    mov si, [kw_ptr + si]
    lodsb
    mov cl, al
    xor ch, ch
.loop:
    lodsb
    call putc
    loop .loop
    pop si
    pop cx
    pop ax
    ret

; The name of the symbol whose entry is AX
put_symbol:
    push ax
    push cx
    push si
    push es
    mov es, ax
    mov cl, [es:S_LEN]
    xor ch, ch
    mov si, S_NAME
.loop:
    mov al, [es:si]
    inc si
    call putc
    loop .loop
    pop es
    pop si
    pop cx
    pop ax
    ret

; ======================================================================
; The command line
; ======================================================================

get_args:
    mov si, 81h
    mov di, src_name
    call get_word
    cmp byte [src_name], 0
    jne .have_source
    mov si, m_usage
    call puts
    call flush_line
    mov ax, 4C02h
    int 21h
.have_source:
    push si
    mov si, src_name                ; no extension: .ASM
    call find_dot
    jnc .source_ext
    mov si, m_ext_asm
    call append
.source_ext:
    pop si
    mov di, out_name
    call get_word
    cmp byte [out_name], 0
    jne .done
    mov si, src_name                ; the source name with .COM
    mov di, out_name
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    mov si, out_name
    call find_dot
    jc .no_dot
    mov byte [di], 0
.no_dot:
    mov si, m_ext_com
    mov di, out_name
    call append_to
.done:
    ret

; Copies the next word of the command tail at SI to DI (upper case, at
; most 64 characters, ASCIIZ). SI is left after it.
get_word:
    mov cx, 64
.skip:
    mov al, [si]
    cmp al, ' '
    je .next
    cmp al, 9
    jne .copy
.next:
    inc si
    jmp .skip
.copy:
    mov al, [si]
    cmp al, ' '
    jbe .end
    cmp al, 'a'
    jb .store
    cmp al, 'z'
    ja .store
    sub al, 20h
.store:
    jcxz .skip_char
    stosb
    dec cx
.skip_char:
    inc si
    jmp .copy
.end:
    mov byte [di], 0
    ret

; SI = ASCIIZ name: CF = 0 and DI = its '.' if it has an extension
find_dot:
    mov di, 0
.loop:
    lodsb
    or al, al
    jz .end
    cmp al, '\'
    je .dir
    cmp al, ':'
    je .dir
    cmp al, '.'
    jne .loop
    lea di, [si - 1]
    jmp .loop
.dir:                               ; a dot in a directory name does not count
    mov di, 0
    jmp .loop
.end:
    or di, di
    jz .none
    clc
    ret
.none:
    stc
    ret

; Appends the ASCIIZ string at SI to src_name
append:
    mov di, src_name
; Appends the ASCIIZ string at SI to the ASCIIZ string at DI
append_to:
    cmp byte [di], 0
    je .copy
    inc di
    jmp append_to
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    ret

; ======================================================================
; Names: symbols and keywords share one hash table
; ======================================================================

; Clears the table and enters every keyword
init_names:
    push es
    mov es, [sym_seg]
    xor di, di
    mov cx, HASH_SIZE
    xor ax, ax
    rep stosw
    pop es
    mov si, keywords
    xor bx, bx                      ; keyword number
.next:
    mov cl, [si]
    or cl, cl
    jz .done
    inc bx
    mov di, bx
    shl di, 1
    mov [kw_ptr + di], si
    xor ch, ch
    mov [namelen], cx
    push si
    inc si
    mov di, namebuf
    rep movsb
    push bx
    call find_name
    pop bx
    mov byte [es:di + S_KIND], 1
    mov [es:di + S_ID], bl
    push ds
    pop es
    pop si
    mov al, [si]
    xor ah, ah
    add si, ax
    add si, 5                       ; length, class, a, b, flags
    jmp .next
.done:
    ret

; Looks up namebuf (namelen characters), and enters it as a symbol if it
; is not there. Keywords match in any case, symbols exactly.
; Returns ES = the entry, DI = 0. Changes AX, BX, CX, DX, SI.
find_name:
    mov es, [sym_seg]
    mov si, namebuf
    mov cx, [namelen]
    xor ax, ax
.hash:
    mov dl, [si]
    cmp dl, 'A'
    jb .hash_add
    cmp dl, 'Z'
    ja .hash_add
    add dl, 20h
.hash_add:
    mov bx, ax                      ; h = h * 33 + c
    push cx
    mov cl, 5
    shl ax, cl
    pop cx
    add ax, bx
    xor dh, dh
    add ax, dx
    inc si
    loop .hash
    and ax, HASH_SIZE - 1
    shl ax, 1
    mov [hash_slot], ax
    mov bx, ax
    mov ax, [es:bx]
.entry:
    or ax, ax
    jz .new
    mov es, ax
    xor di, di
    mov al, [es:di + S_LEN]
    cmp al, [namelen]
    jne .other
    mov si, namebuf
    mov cx, [namelen]
    push di
    add di, S_NAME
    cmp byte [es:di - S_NAME + S_KIND], 0
    jne .keyword
    repe cmpsb
    pop di
    je .found
    jmp .other
.keyword:
    mov al, [si]
    cmp al, 'A'
    jb .kw_cmp
    cmp al, 'Z'
    ja .kw_cmp
    add al, 20h
.kw_cmp:
    cmp al, [es:di]
    jne .kw_differ
    inc si
    inc di
    loop .keyword
    pop di
.found:
    ret
.kw_differ:
    pop di
.other:
    mov ax, [es:S_NEXT]
    jmp .entry
.new:
    mov ax, [namelen]               ; paragraphs below the last name
    add ax, S_NAME + 15
    mov cl, 4
    shr ax, cl
    mov bx, [name_top]
    sub bx, ax
    mov ax, [ir_cur_seg]            ; above the tokens and a line
    add ax, 400h
    cmp bx, ax
    ja .room
    mov si, m_memory
    jmp fatal
.room:
    mov [name_top], bx
    lea ax, [bx - 400h]
    mov [ir_limit], ax
    mov es, [sym_seg]
    mov si, [hash_slot]
    mov ax, [es:si]
    mov [es:si], bx
    mov es, bx
    xor di, di
    mov [es:di + S_NEXT], ax
    xor ax, ax
    mov [es:di + S_KIND], ax        ; kind, flags
    mov [es:di + S_VLO], ax
    mov [es:di + S_VHI], ax
    mov word [es:di + S_RELOC], 0FF00h  ; reloc 0, never defined
    mov [es:di + S_LINE], ax
    mov cx, [namelen]
    mov [es:di + S_LEN], cl
    push di
    add di, S_NAME
    mov si, namebuf
    rep movsb
    pop di
    ret

; ======================================================================
; Pass 1: the source into tokens
; ======================================================================

lex_file:
    mov dx, src_name
    mov ax, 3D00h
    int 21h
    jnc .opened
    mov si, m_cannot_open
    mov di, src_name
    jmp fatal_name
.opened:
    mov [src_handle], ax
    mov ax, [ir_seg]
    mov [ir_cur_seg], ax
    mov word [ir_cur_off], 0
    mov word [buf_len], 0
    mov word [buf_pos], 0
    mov byte [src_eof], 0
    mov word [total_lines], 0
.line:
    mov si, [buf_pos]               ; find the end of the line
.scan:
    cmp si, [buf_len]
    jae .refill
    mov al, [inbuf + si]
    cmp al, 0Ah
    je .found
    cmp al, 1Ah                     ; Ctrl-Z ends a text file
    je .ctrl_z
    inc si
    jmp .scan
.refill:
    cmp byte [src_eof], 0
    jne .last
    mov cx, [buf_len]               ; move what is left to the front
    mov si, [buf_pos]
    sub cx, si
    push cx
    add si, inbuf
    mov di, inbuf
    rep movsb
    pop cx
    mov [buf_len], cx
    mov word [buf_pos], 0
    cmp cx, INBUF_SIZE
    jb .read
    mov si, m_long_line
    jmp fatal_at_line
.read:
    mov dx, inbuf
    add dx, cx
    neg cx
    add cx, INBUF_SIZE
    mov bx, [src_handle]
    mov ah, 3Fh
    int 21h
    jnc .read_ok
    mov si, m_read_error
    jmp fatal
.read_ok:
    or ax, ax
    jnz .got
    mov byte [src_eof], 1
.got:
    add [buf_len], ax
    jmp .line
.ctrl_z:
    mov [buf_len], si               ; the rest is not text
    mov byte [src_eof], 1
.last:
    mov si, [buf_len]
    cmp si, [buf_pos]
    je .end                         ; no last line without its LF
    mov di, si                      ; the line is [buf_pos, si)
    jmp .have_line
.found:
    lea di, [si + 1]                ; where the next line starts
.have_line:
    push di
    mov bx, si
    mov si, [buf_pos]
    add si, inbuf
    add bx, inbuf                   ; [si, bx) is the line
    cmp bx, si
    je .no_cr
    cmp byte [bx - 1], 0Dh
    jne .no_cr
    dec bx
.no_cr:
    mov ax, bx
    sub ax, si
    cmp ax, MAX_LINE
    jbe .length_ok
    mov si, m_long_line
    jmp fatal_at_line
.length_ok:
    inc word [total_lines]
    jnz .count_ok
    mov si, m_many_lines
    jmp fatal
.count_ok:
    call lex_line
    pop di
    mov [buf_pos], di
    jmp .line
.end:
    mov bx, [src_handle]
    mov ah, 3Eh
    int 21h
    ret

; SI = message: "NAME.ASM(line): message", and ends
fatal_at_line:
    push si
    mov si, src_name
    call puts
    mov al, '('
    call putc
    mov ax, [total_lines]
    inc ax
    xor dx, dx
    call put_unsigned
    mov si, m_line_end
    call puts
    pop si
    call puts
    call flush_line
    mov ax, 4C02h
    int 21h

; Turns the line [SI, BX) into tokens in memory: first into raw[] here,
; then the label is found (it decides what .local names mean), then the
; tokens are written to ir_cur_seg:ir_cur_off.
lex_line:
    mov [line_end], bx
    mov di, raw
    mov byte [lex_err], 0
.token:
    cmp si, [line_end]
    jb .char
    jmp .line_done
.char:
    mov al, [si]
    cmp al, ';'
    jne .not_comment
    jmp .line_done
.not_comment:
    cmp al, ' '
    je .space
    cmp al, 9
    jb .not_space
    cmp al, 0Dh
    ja .not_space
.space:
    inc si
    jmp .token
.not_space:
    cmp di, raw + MAX_TOKENS * TK_SIZE
    jb .room
    mov si, m_many_tokens
    jmp lex_error
.room:
    mov word [di + TK_LO], 0
    mov word [di + TK_HI], 0
    mov [tok_start], si
    cmp al, '$'
    jne .not_dollar
    mov ah, [si + 1]
    lea bx, [si + 1]
    cmp bx, [line_end]
    jae .dollar
    cmp ah, '$'
    jne .dollar_hex
    mov byte [di + TK_TYPE], T_DOLLAR2
    add si, 2
    jmp .stored
.dollar_hex:
    cmp ah, '0'
    jb .dollar
    cmp ah, '9'
    ja .dollar
    inc si                          ; $1F: a hexadecimal number
    call number_span
    mov dx, 16
    call parse_digits
    jnc .number
    mov si, m_bad_hex
    jmp lex_error_text
.dollar:
    mov byte [di + TK_TYPE], T_DOLLAR
    inc si
    jmp .stored
.not_dollar:
    cmp al, '0'
    jb .not_digit
    cmp al, '9'
    ja .not_digit
    call number_span
    call parse_number
    jnc .number
    mov si, m_bad_number
    jmp lex_error_text
.number:
    mov byte [di + TK_TYPE], T_NUM
    mov ax, [num_lo]
    mov [di + TK_LO], ax
    mov ax, [num_hi]
    mov [di + TK_HI], ax
    mov si, [span_end]
    jmp .stored
.not_digit:
    call is_id_start
    jc .not_id
    jmp lex_name
.not_id:
    cmp al, 27h
    je .string
    cmp al, '"'
    jne .not_string
.string:
    mov ah, al
    inc si
    mov bx, si
.str_end:
    cmp bx, [line_end]
    jae .unterminated
    cmp [bx], ah
    je .str_found
    inc bx
    jmp .str_end
.unterminated:
    mov si, m_unterminated
    call lex_error_begin
    mov al, ah
    call lex_putc
    mov al, ')'
    call lex_putc
    jmp lex_error_end
.str_found:
    mov cx, bx
    sub cx, si
    cmp cx, 255
    jbe .str_ok
    mov si, m_long_string
    jmp lex_error
.str_ok:
    mov byte [di + TK_TYPE], T_STR
    mov [di + TK_SUB], cl
    mov [di + TK_LO], si
    lea si, [bx + 1]
    jmp .stored
.not_string:
    cmp al, '`'
    jne .punct
    mov si, m_backquote
    jmp lex_error
.punct:
    mov byte [di + TK_TYPE], T_PUNCT
    mov [di + TK_SUB], al
    lea bx, [si + 1]
    cmp bx, [line_end]
    jae .single
    mov ah, [si + 1]
    mov dl, P_SHL
    cmp ax, '<<'
    je .double
    mov dl, P_SHR
    cmp ax, '>>'
    je .double
    mov dl, P_SDIV
    cmp ax, '//'
    je .double
    mov dl, P_SMOD
    cmp ax, '%%'
    je .double
.single:
    push di
    mov di, punct_chars
    mov cx, punct_chars_end - punct_chars
    push es
    push ds
    pop es
    repne scasb
    pop es
    pop di
    je .punct_ok
    mov si, m_unexpected_char
    call lex_error_begin
    mov al, 27h
    call lex_putc
    mov bx, [tok_start]
    mov al, [bx]
    call lex_putc
    mov al, 27h
    call lex_putc
    jmp lex_error_end
.punct_ok:
    inc si
    jmp .stored
.double:
    mov [di + TK_SUB], dl
    add si, 2
.stored:
    add di, TK_SIZE
    jmp .token
.line_done:
    mov [raw_end], di
    jmp lex_finish

; An identifier at SI
lex_name:
    mov bx, si
.span:
    inc bx
    cmp bx, [line_end]
    jae .end
    mov al, [bx]
    call is_id_char
    jnc .span
.end:
    mov cx, bx
    sub cx, si
    cmp cx, 255
    jbe .length_ok
    mov si, m_long_name
    jmp lex_error
.length_ok:
    push bx
    cmp byte [si], '.'              ; .name: depends on the last label
    jne .global
    cmp cx, 1
    je .local
    cmp byte [si + 1], '.'          ; ..name is global
    je .global
.local:
    mov byte [di + TK_TYPE], T_LOCAL
    mov [di + TK_LO], si
    mov [di + TK_HI], cx
    jmp .next
.global:
    mov [namelen], cx
    push di
    mov di, namebuf
    rep movsb
    call find_name
    mov ax, es
    mov bl, [es:di + S_KIND]
    mov bh, [es:di + S_ID]
    push ds
    pop es
    pop di
    mov byte [di + TK_TYPE], T_SYM
    mov [di + TK_LO], ax
    or bl, bl
    jz .next
    mov byte [di + TK_TYPE], T_KW
    mov [di + TK_SUB], bh
.next:
    pop si
    add di, TK_SIZE
    jmp lex_line.token

; AL: CF = 0 if it can start a name
is_id_start:
    cmp al, '_'
    je .yes
    cmp al, '.'
    je .yes
    cmp al, '?'
    je .yes
    cmp al, '@'
    je .yes
    cmp al, 80h
    jae .yes
    push ax
    or al, 20h
    cmp al, 'a'
    jb .no_pop
    cmp al, 'z'
    ja .no_pop
    pop ax
.yes:
    clc
    ret
.no_pop:
    pop ax
    stc
    ret

; AL: CF = 0 if it can be inside a name
is_id_char:
    call is_id_start
    jnc .yes
    cmp al, '0'
    jb .other
    cmp al, '9'
    jbe .yes
.other:
    cmp al, '$'
    je .yes
    cmp al, '#'
    je .yes
    cmp al, '~'
    je .yes
    stc
    ret
.yes:
    clc
    ret

; The characters of a number at SI (letters, digits, _): span_end
number_span:
    mov bx, si
.loop:
    cmp bx, [line_end]
    jae .end
    mov al, [bx]
    cmp al, '_'
    je .next
    cmp al, '0'
    jb .end
    cmp al, '9'
    jbe .next
    or al, 20h
    cmp al, 'a'
    jb .end
    cmp al, 'z'
    ja .end
.next:
    inc bx
    jmp .loop
.end:
    mov [span_end], bx
    ret

; The number [SI, span_end) in NASM's forms (0x1F, 1Fh, $1F, 0b101, 101b,
; 17o, 17q, 0d10, 10d...) into num_lo/num_hi. CF = 1 if it is not valid.
parse_number:
    mov cx, [span_end]
    sub cx, si
    cmp cx, 2
    jbe .suffix
    cmp byte [si], '0'
    jne .suffix
    mov al, [si + 1]
    call base_letter
    jc .suffix
    push si
    push cx
    add si, 2
    sub cx, 2
    call digits_n
    pop cx
    pop si
    jnc .done
.suffix:
    cmp cx, 1
    jbe .decimal
    mov bx, si
    add bx, cx
    mov al, [bx - 1]
    call base_letter
    jc .decimal
    dec cx
    jmp digits_n
.decimal:
    mov dx, 10
    jmp digits_n
.done:
    ret

; AL = a base letter (x h b y o q d t, any case): DX = the base
base_letter:
    or al, 20h
    mov dx, 16
    cmp al, 'x'
    je .yes
    cmp al, 'h'
    je .yes
    mov dx, 2
    cmp al, 'b'
    je .yes
    cmp al, 'y'
    je .yes
    mov dx, 8
    cmp al, 'o'
    je .yes
    cmp al, 'q'
    je .yes
    mov dx, 10
    cmp al, 'd'
    je .yes
    cmp al, 't'
    je .yes
    stc
    ret
.yes:
    clc
    ret

; The digits [SI, span_end) in base DX
parse_digits:
    mov cx, [span_end]
    sub cx, si
; The digits [SI, SI + CX) in base DX into num_lo/num_hi (_ ignored).
; CF = 1 if a digit is not valid or there is none.
digits_n:
    push si
    mov word [num_lo], 0
    mov word [num_hi], 0
    mov bx, dx
    xor dx, dx                      ; DL = any digit
    jcxz .bad
.loop:
    lodsb
    cmp al, '_'
    je .next
    sub al, '0'
    cmp al, 9
    jbe .value
    or al, 20h                      ; letters: 'a' - '0' = 31h
    sub al, 31h - 10
    cmp al, 10
    jb .bad
.value:
    xor ah, ah
    cmp ax, bx
    jae .bad
    push cx
    push ax
    mov ax, [num_hi]
    mul bx
    mov cx, ax
    mov ax, [num_lo]
    mul bx
    add dx, cx
    pop cx
    add ax, cx
    adc dx, 0
    mov [num_lo], ax
    mov [num_hi], dx
    pop cx
    mov dl, 1
.next:
    loop .loop
    or dl, dl
    jz .bad
    pop si
    clc
    ret
.bad:
    pop si
    stc
    ret

; ---------- lexical errors ----------

; SI = message: the line becomes just the error
lex_error:
    call lex_error_begin
    jmp lex_error_end

; SI = message: "message: text of the token" (tok_start to span_end)
lex_error_text:
    call lex_error_begin
    mov al, ':'
    call lex_putc
    mov al, ' '
    call lex_putc
    mov si, [tok_start]
.loop:
    cmp si, [span_end]
    jae lex_error_end
    lodsb
    call lex_putc
    jmp .loop

lex_error_begin:
    mov word [lex_msg_len], 0
.loop:
    lodsb
    or al, al
    jz .done
    call lex_putc
    jmp .loop
.done:
    ret

lex_putc:
    push bx
    mov bx, [lex_msg_len]
    cmp bx, 120
    jae .full
    mov [lex_msg + bx], al
    inc word [lex_msg_len]
.full:
    pop bx
    ret

; Writes the line as its error message
lex_error_end:
    mov bx, [lex_msg_len]
    mov byte [lex_msg + bx], 0
    call ir_begin
    mov al, T_ERR
    stosb
    mov si, lex_msg
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    mov al, T_EOL
    stosb
    jmp ir_end

; ---------- the line into memory ----------

; raw[] .. raw_end: finds the label, resolves .local names, writes it all
lex_finish:
    mov si, raw
    cmp si, [raw_end]
    je .resolve
    mov al, [si + TK_TYPE]
    cmp al, T_SYM
    je .candidate
    cmp al, T_LOCAL
    jne .resolve
.candidate:
    lea bx, [si + TK_SIZE]          ; label if ':' follows, nothing does,
    cmp bx, [raw_end]               ; or a keyword does
    je .label
    cmp byte [bx + TK_TYPE], T_PUNCT
    jne .kw_after
    cmp byte [bx + TK_SUB], ':'
    je .label
.kw_after:
    cmp byte [bx + TK_TYPE], T_KW
    jne .resolve
    mov al, [bx + TK_SUB]
    call kw_flags
    test al, KF_KEYWORD
    jz .resolve
.label:
    cmp byte [si + TK_TYPE], T_LOCAL
    jne .global_label
    call resolve_local              ; with the label before it
    jmp .resolve
.global_label:
    mov ax, [si + TK_LO]            ; ..name labels do not count
    push es
    push di
    mov es, ax
    xor di, di
    cmp byte [es:di + S_NAME], '.'
    pop di
    pop es
    je .resolve
    mov [last_global], ax
.resolve:
    cmp si, [raw_end]
    je .write
    cmp byte [si + TK_TYPE], T_LOCAL
    jne .resolved
    call after_section              ; SECTION .data: the name as it is
    jne .local
    push word [last_global]
    mov word [last_global], 0
    call resolve_local
    pop word [last_global]
    jmp .resolved
.local:
    call resolve_local
.resolved:
    add si, TK_SIZE
    jmp .resolve
.write:
    call ir_begin
    mov si, raw
.token:
    cmp si, [raw_end]
    je .end
    mov al, [si + TK_TYPE]
    stosb
    cmp al, T_NUM
    jne .not_num
    mov ax, [si + TK_LO]
    stosw
    mov ax, [si + TK_HI]
    stosw
    jmp .next
.not_num:
    cmp al, T_SYM
    jne .not_sym
    mov ax, [si + TK_LO]
    stosw
    jmp .next
.not_sym:
    cmp al, T_STR
    jne .not_str
    mov cl, [si + TK_SUB]
    mov al, cl
    stosb
    xor ch, ch
    push si
    mov si, [si + TK_LO]
    rep movsb
    pop si
    jmp .next
.not_str:
    cmp al, T_PUNCT
    je .sub
    cmp al, T_KW
    jne .next
.sub:
    mov al, [si + TK_SUB]
    stosb
.next:
    add si, TK_SIZE
    jmp .token
.end:
    mov al, T_EOL
    stosb
    jmp ir_end

; The T_LOCAL token at SI becomes the symbol last_global + its text
resolve_local:
    push si
    push di
    mov di, namebuf
    xor cx, cx
    mov ax, [last_global]
    or ax, ax
    jz .own
    push si
    push ds
    mov ds, ax
    xor si, si
    mov cl, [si + S_LEN]
    add si, S_NAME
    rep movsb
    pop ds
    pop si
.own:
    mov cx, [si + TK_HI]
    mov si, [si + TK_LO]
    mov ax, di
    sub ax, namebuf
    add ax, cx
    cmp ax, 255
    jbe .fits
    pop di
    pop si
    pop ax                          ; not back to lex_finish
    mov si, m_long_name
    jmp lex_error
.fits:
    mov [namelen], ax
    rep movsb
    call find_name
    mov ax, es
    push ds
    pop es
    pop di
    pop si
    mov byte [si + TK_TYPE], T_SYM
    mov [si + TK_LO], ax
    ret

; SI = a token of raw[]: ZF = 1 if the token before it is SECTION or SEGMENT
after_section:
    cmp si, raw
    je .no
    cmp byte [si - TK_SIZE + TK_TYPE], T_KW
    jne .ret
    push ax
    push bx
    mov al, [si - TK_SIZE + TK_SUB]
    xor ah, ah
    mov bx, ax
    shl bx, 1
    mov bx, [kw_ptr + bx]
    mov al, [bx]
    add bx, ax
    cmp word [bx + 1], C_DIR | (D_SECTION << 8)
    pop bx
    pop ax
.ret:
    ret
.no:
    cmp si, 0                       ; ZF = 0
    ret

; AL = keyword number: AL = its flags
kw_flags:
    push bx
    xor ah, ah
    mov bx, ax
    shl bx, 1
    mov bx, [kw_ptr + bx]
    mov al, [bx]
    add bx, ax
    mov al, [bx + 4]
    pop bx
    ret

; ES:DI = where the line goes; writes its sticky byte
ir_begin:
    mov es, [ir_cur_seg]
    mov di, [ir_cur_off]
    xor al, al
    stosb
    ret

; After the line: the pointer normalized, and memory checked
ir_end:
    mov ax, di
    mov cl, 4
    shr ax, cl
    mov bx, es
    add ax, bx
    and di, 0Fh
    mov [ir_cur_seg], ax
    mov [ir_cur_off], di
    push ds
    pop es
    cmp ax, [ir_limit]
    jb .ok
    mov si, m_memory
    jmp fatal
.ok:
    ret

; ======================================================================
; The passes
; ======================================================================

; Passes until addresses and sizes stop changing, then the last one, which
; writes the bytes and shows the errors.
assemble:
    mov word [org_val], 0
    mov word [org_set], 0
    mov byte [pass], 0
    mov byte [final], 0
.pass:
    call run_pass
    cmp byte [pass], 0
    je .again
    cmp byte [changed], 0
    je .stable
.again:
    inc byte [pass]
    cmp byte [pass], MAX_PASSES
    jb .pass
    mov byte [stable], 0
    jmp .last
.stable:
    mov byte [stable], 1
.last:
    inc byte [pass]
    mov byte [final], 1
    mov word [out_len], 0
    mov word [out_len + 2], 0
    mov es, [out_seg]
    xor di, di
    mov cx, 8000h
    xor ax, ax
    rep stosw
    push ds
    pop es
    call run_pass
    cmp word [err_count], 0
    jne .done
    mov si, m_circular
    cmp byte [stable], 0
    je .global_error
    mov si, m_unstable
    cmp byte [changed], 0
    jne .global_error
.done:
    ret
.global_error:
    push si
    mov si, src_name
    call puts
    mov si, m_colon
    call puts
    pop si
    call puts
    call flush_line
    inc word [err_count]
    ret

run_pass:
    mov ax, [org_val]               ; .text, .data, .bss
    xor dx, dx
    mov [sec_base], ax
    mov [sec_base + 2], dx
    add ax, [sec_size]
    adc dx, [sec_size + 2]
    call align4
    mov [sec_base + 4], ax
    mov [sec_base + 6], dx
    add ax, [sec_size + 4]
    adc dx, [sec_size + 6]
    call align4
    mov [sec_base + 8], ax
    mov [sec_base + 10], dx
    mov si, sec_base
    mov di, sec_addr
    mov cx, 6
    push ds
    pop es
    rep movsw
    mov byte [cur_sec], SEC_TEXT
    mov ax, [org_val]
    mov [addr_lo], ax
    mov word [addr_hi], 0
    mov byte [changed], 0
    mov byte [abort], 0
    mov word [cur_line], 0
    mov word [last_err_line], 0
    mov ax, [ir_seg]
    mov [rd_seg], ax
    mov word [rd_off], 0
.line:
    mov ax, [cur_line]
    cmp ax, [total_lines]
    jae .end
    inc word [cur_line]
    call decode_line
    call statement
    mov al, [sticky]
    cmp al, [sticky_old]
    je .sticky_same
    push es
    mov es, [st_seg]
    mov bx, [st_off]
    mov [es:bx], al
    pop es
.sticky_same:
    cmp byte [abort], 0
    je .line
.end:
    call sec_save                   ; the size of each section changed?
    xor bx, bx
.size:
    mov ax, [sec_addr + bx]
    mov dx, [sec_addr + bx + 2]
    sub ax, [sec_base + bx]
    sbb dx, [sec_base + bx + 2]
    cmp ax, [sec_size + bx]
    jne .size_changed
    cmp dx, [sec_size + bx + 2]
    je .size_same
.size_changed:
    mov [sec_size + bx], ax
    mov [sec_size + bx + 2], dx
    mov byte [changed], 1
.size_same:
    add bx, 4
    cmp bx, 12
    jb .size
    mov ax, [addr_lo]               ; the size of the program changed?
    mov dx, [addr_hi]
    cmp ax, [prev_end]
    jne .end_changed
    cmp dx, [prev_end + 2]
    je .end_same
.end_changed:
    mov byte [changed], 1
    mov [prev_end], ax
    mov [prev_end + 2], dx
.end_same:
    ret

; DX:AX up to a multiple of 4
align4:
    add ax, 3
    adc dx, 0
    and ax, 0FFFCh
    ret

; BX = 4 * the current section
sec_index:
    mov bl, [cur_sec]
    xor bh, bh
    shl bx, 1
    shl bx, 1
    ret

; The address reached in the current section is kept
sec_save:
    call sec_index
    mov ax, [addr_lo]
    mov [sec_addr + bx], ax
    mov ax, [addr_hi]
    mov [sec_addr + bx + 2], ax
    ret

; The next line of tokens from memory into tk[] (strings and the error
; message into strpool); tk_end = its T_EOL.
decode_line:
    push ds
    mov ax, [rd_seg]
    mov si, [rd_off]
    mov [st_seg], ax
    mov [st_off], si
    mov bx, ds
    mov es, bx
    mov ds, ax
    lodsb
    mov [es:sticky], al
    mov [es:sticky_old], al
    mov byte [es:line_err], 0
    mov di, tk
    mov bp, strpool
.token:
    lodsb
    mov [es:di + TK_TYPE], al
    cmp al, T_EOL
    jne .skip15
    jmp .done
.skip15:
    cmp al, T_NUM
    jne .not_num
    lodsw
    mov [es:di + TK_LO], ax
    lodsw
    mov [es:di + TK_HI], ax
    jmp .next
.not_num:
    cmp al, T_SYM
    jne .not_sym
    lodsw
    mov [es:di + TK_LO], ax
    jmp .next
.not_sym:
    cmp al, T_PUNCT
    jne .not_punct
    lodsb
    mov [es:di + TK_SUB], al
    jmp .next
.not_punct:
    cmp al, T_KW
    jne .not_kw
    lodsb
    mov [es:di + TK_SUB], al
    xor ah, ah
    mov bx, ax
    shl bx, 1
    mov bx, [es:kw_ptr + bx]
    mov al, [es:bx]
    add bx, ax
    mov ax, [es:bx + 1]             ; class, a
    mov [es:di + TK_CLASS], ax
    mov ax, [es:bx + 3]             ; b, flags
    mov [es:di + TK_B], ax
    jmp .next
.not_kw:
    cmp al, T_STR
    jne .not_str
    lodsb
    mov [es:di + TK_SUB], al
    mov [es:di + TK_LO], bp
    mov cl, al
    xor ch, ch
    xchg di, bp
    rep movsb
    xchg di, bp
    jmp .next
.not_str:
    cmp al, T_ERR
    jne .next
    mov byte [es:line_err], 1
    mov [es:err_text], bp
    xchg di, bp
.copy:
    lodsb
    stosb
    or al, al
    jnz .copy
    xchg di, bp
    jmp .token                      ; T_ERR takes no entry
.next:
    add di, TK_SIZE
    jmp .token
.done:
    mov [es:tk_end], di
    mov ax, si
    mov cl, 4
    shr ax, cl
    mov bx, ds
    add ax, bx
    and si, 0Fh
    pop ds
    mov [rd_seg], ax
    mov [rd_off], si
    ret

; ======================================================================
; A statement
; ======================================================================

statement:
    mov byte [stmt_failed], 0
    mov ax, [addr_lo]
    mov dx, [addr_hi]
    mov [line_start], ax
    mov [line_start + 2], dx
    mov [st_start], ax
    mov [st_start + 2], dx
    mov word [st_label], 0
    mov byte [st_kind], K_EMPTY
    mov word [st_times_beg], 0
    mov byte [st_rep], 0
    cmp byte [line_err], 0
    je .parse
    mov si, [err_text]              ; a lexical error
    call error
    mov byte [st_kind], K_ERROR
    ret
.parse:
    call parse_line
    mov bx, [st_label]
    or bx, bx
    jz .kind
    cmp byte [st_kind], K_EQU
    je .kind
    mov bx, [bx + TK_LO]
    mov ax, [addr_lo]
    mov dx, [addr_hi]
    mov cx, 1                       ; reloc 1, known
    mov byte [def_label], SF_LABEL
    call define_sym
.kind:
    mov al, [st_kind]
    cmp al, K_ORG
    jne .not_org
    jmp do_org
.not_org:
    cmp al, K_EQU
    jne .not_equ
    jmp do_equ
.not_equ:
    cmp al, K_SECTION
    jne .not_section
    call sec_save                   ; to the other section
    mov al, [st_section]
    mov [cur_sec], al
    call sec_index
    mov ax, [sec_addr + bx]
    mov [addr_lo], ax
    mov ax, [sec_addr + bx + 2]
    mov [addr_hi], ax
    jmp .done
.not_section:
    cmp al, K_INSTR
    jae .skip14
    jmp .done
.skip14:
    cmp al, K_RESW
    jbe .skip13
    jmp .done
.skip13:
    cmp byte [cur_sec], SEC_BSS
    jne .in_file
    cmp al, K_RESB
    jae .in_file
    mov si, m_bss_only
    call error
    jmp .done
.in_file:
    mov word [reps], 1              ; code and data, TIMES times
    mov word [reps + 2], 0
    mov si, [st_times_beg]
    or si, si
    jz .repeat
    mov di, [st_times_end]
    mov bx, m_times
    call eval_count
    mov [reps], ax
    mov [reps + 2], dx
.repeat:
    mov ax, [reps]
    or ax, [reps + 2]
    jnz .skip1
    jmp .done
.skip1:
    mov ax, [addr_lo]               ; the bytes go at this address
    mov [wpos], ax
    mov ax, [addr_hi]
    mov [wpos + 2], ax
    xor ax, ax
    xor dx, dx
    mov cl, [st_kind]
    cmp cl, K_INSTR
    jne .not_instr
    call encode
    jnc .encoded
    xor ax, ax
    xor dx, dx
    jmp .size
.encoded:
    mov si, enc
    mov cx, [enc_n]
    call out_bytes
    mov ax, [enc_n]
    xor dx, dx
    jmp .size
.not_instr:
    cmp cl, K_RESB
    jae .reserve
    call emit_data
    xor dx, dx
    jmp .size
.reserve:
    mov si, [st_args_beg]
    mov di, [st_args_end]
    mov bx, m_resb
    cmp byte [st_kind], K_RESB
    je .count
    mov bx, m_resw
.count:
    call eval_count
    cmp byte [st_kind], K_RESB
    je .zeros
    shl ax, 1
    rcl dx, 1
.zeros:
    call out_zero
.size:
    add [addr_lo], ax
    adc [addr_hi], dx
    cmp byte [stmt_failed], 0
    je .counted
    cmp byte [final], 0
    je .done
.counted:
    sub word [reps], 1
    sbb word [reps + 2], 0
    jmp .repeat
.done:
    cmp byte [final], 0             ; beyond 64 KB?
    je .fits
    cmp word [addr_hi], 0
    je .fits
    cmp word [addr_hi], 1
    jne .too_big
    cmp word [addr_lo], 0
    je .fits
.too_big:
    mov si, m_too_big
    call error
    mov byte [abort], 1
.fits:
    ret

do_org:
    mov si, [st_args_beg]
    mov di, [st_args_end]
    call eval_range
    jc .done
    or bl, bl
    jnz .not_number
    or bh, bh
    jz .number
.not_number:
    mov si, m_org_number
    jmp .error
.number:
    mov cx, [addr_lo]               ; code before it?
    cmp cx, [org_val]
    jne .late
    cmp word [addr_hi], 0
    je .first
.late:
    mov si, m_org_late
    jmp .error
.first:
    mov cx, [org_set]
    jcxz .once
    cmp cx, [cur_line]
    je .once
    mov si, m_org_once
    jmp .error
.once:
    or dx, dx
    jz .in_range
    mov si, m_org_range
    jmp .error
.in_range:
    cmp byte [cur_sec], SEC_TEXT
    je .in_text
    mov si, m_org_text
    jmp .error
.in_text:
    mov cx, [cur_line]
    mov [org_set], cx
    cmp ax, [org_val]
    je .same
    mov [org_val], ax
    mov byte [changed], 1
.same:
    mov [addr_lo], ax
    mov word [addr_hi], 0
    mov [sec_base], ax
    mov word [sec_base + 2], 0
.done:
    jmp statement.done
.error:
    call error
    jmp statement.done

do_equ:
    mov si, [st_args_beg]
    mov di, [st_args_end]
    call eval_range
    jnc .known
    mov bh, 1
.known:
    mov cx, bx
    mov bx, [st_label]
    mov bx, [bx + TK_LO]
    mov byte [def_label], 0
    call define_sym
    jmp statement.done

; BX = symbol entry, DX:AX = value, CL = reloc, CH = 1 if unknown,
; def_label = SF_LABEL or 0
define_sym:
    push es
    push di
    mov es, bx
    xor di, di
    mov si, ax
    mov al, [pass]
    cmp al, [es:di + S_PASS]
    mov ax, si
    jne .new_pass
    call err_begin
    jc .done
    mov al, 27h
    call putc
    mov ax, bx
    call put_symbol
    mov si, m_defined_on
    call puts
    mov ax, [es:di + S_LINE]
    xor dx, dx
    call put_unsigned
    call err_end
.done:
    pop di
    pop es
    ret
.new_pass:
    cmp ax, [es:di + S_VLO]
    jne .changed
    cmp dx, [es:di + S_VHI]
    jne .changed
    cmp cl, [es:di + S_RELOC]
    jne .changed
    test byte [es:di + S_ID], SF_DEFINED
    jz .changed
    or ch, ch
    jz .stored
.changed:
    mov byte [changed], 1
.stored:
    mov [es:di + S_VLO], ax
    mov [es:di + S_VHI], dx
    mov [es:di + S_RELOC], cl
    mov al, [def_label]
    or ch, ch
    jnz .unknown
    or al, SF_DEFINED
.unknown:
    mov [es:di + S_ID], al
    mov al, [pass]
    mov [es:di + S_PASS], al
    mov ax, [cur_line]
    mov [es:di + S_LINE], ax
    pop di
    pop es
    ret

; ---------- parsing the line ----------

; tk .. tk_end: the label, then the statement
parse_line:
    mov si, tk
    cmp si, [tk_end]
    je .empty
    cmp byte [si + TK_TYPE], T_SYM
    jne .statement
    lea bx, [si + TK_SIZE]
    cmp bx, [tk_end]
    je .label_alone
    cmp byte [bx + TK_TYPE], T_PUNCT
    jne .kw_after
    cmp byte [bx + TK_SUB], ':'
    jne .kw_after
    mov [st_label], si
    lea si, [bx + TK_SIZE]
    jmp .statement
.kw_after:
    cmp byte [bx + TK_TYPE], T_KW
    jne .unknown
    test byte [bx + TK_FLAGS], KF_KEYWORD
    jz .unknown
.label_alone:
    mov [st_label], si
    mov si, bx
.statement:
    jmp parse_stmt
.empty:
    ret
.unknown:
    mov bx, si
    jmp unknown_instruction

; BX = token: "unknown instruction: name"
unknown_instruction:
    mov si, m_unknown_instr
; SI = message, BX = token: "message" + the token, and the line is an error
stmt_error_tok:
    call err_begin
    jc .done
    call puts
    call put_token
    call err_end
.done:
    mov byte [st_kind], K_ERROR
    ret

; SI = message: the line is an error
stmt_error:
    call error
    mov byte [st_kind], K_ERROR
    ret

; The statement from SI to tk_end
parse_stmt:
    cmp si, [tk_end]
    jb .have
    mov byte [st_kind], K_EMPTY
    ret
.have:
    mov al, [si + TK_TYPE]
    cmp al, T_SYM
    jne .not_sym
    mov bx, si
    jmp unknown_instruction
.not_sym:
    cmp al, T_KW
    je .keyword
    mov si, m_expected_instr
    jmp stmt_error
.keyword:
    mov al, [si + TK_CLASS]
    cmp al, C_DIR
    je .directive
    cmp al, C_MNEM
    jne .not_mnem
    jmp .mnemonic
.not_mnem:
    mov bx, si
    cmp al, C_UNSUP
    jne .not_unsup
    mov si, m_unsupported
    jmp stmt_error_tok
.not_unsup:
    cmp al, C_LATER
    je .later
    jmp unknown_instruction
.later:
    call err_begin
    jc .later_done
    call put_token
    mov si, m_later_cpu
    call puts
    call err_end
.later_done:
    mov byte [st_kind], K_ERROR
    ret
.directive:
    mov al, [si + TK_A]
    cmp al, D_TIMES
    jne .not_times
    cmp word [st_times_beg], 0
    je .first_times
    mov si, m_times_twice
    jmp stmt_error
.first_times:
    push si
    add si, TK_SIZE
    mov di, [tk_end]
    call skip_expr
    pop si
    jc .no_count
    lea ax, [si + TK_SIZE]
    cmp bx, ax
    jne .count
.no_count:
    mov si, m_times_count
    jmp stmt_error
.count:
    mov [st_times_beg], ax
    mov [st_times_end], bx
    mov si, bx
    call parse_stmt
    mov al, [st_kind]
    cmp al, K_EQU
    je .times_bad
    cmp al, K_ORG
    je .times_bad
    cmp al, K_SECTION
    je .times_bad
    cmp al, K_IGNORE
    jne .times_ok
.times_bad:
    mov si, m_times_directive
    jmp stmt_error
.times_ok:
    ret
.not_times:
    cmp al, D_REP
    je .rep
    cmp al, D_REPNE
    jne .data
.rep:
    mov ah, 0F3h
    cmp al, D_REP
    je .rep_byte
    mov ah, 0F2h
.rep_byte:
    mov [st_rep], ah
    add si, TK_SIZE
    cmp si, [tk_end]
    jae .rep_bad
    cmp byte [si + TK_TYPE], T_KW
    jne .rep_bad
    cmp byte [si + TK_CLASS], C_MNEM
    jne .rep_bad
    jmp .mnemonic
.rep_bad:
    mov si, m_rep_alone
    jmp stmt_error
.data:
    lea bx, [si + TK_SIZE]
    mov [st_args_beg], bx
    mov bx, [tk_end]
    mov [st_args_end], bx
    mov ah, K_DB
    cmp al, D_DB
    je .kind
    mov ah, K_DW
    cmp al, D_DW
    je .kind
    mov ah, K_RESB
    cmp al, D_RESB
    je .kind
    mov ah, K_RESW
    cmp al, D_RESW
    je .kind
    mov ah, K_ORG
    cmp al, D_ORG
    je .kind
    cmp al, D_EQU
    jne .not_equ
    mov ah, K_EQU
    cmp word [st_label], 0
    jne .kind
    mov si, m_equ_name
    jmp stmt_error
.kind:
    mov [st_kind], ah
    ret
.not_equ:
    cmp al, D_BITS
    jne .not_bits
    mov si, m_bits
    mov cx, 16
    jmp .mode
.not_bits:
    cmp al, D_CPU
    jne .not_cpu
    mov si, m_cpu
    mov cx, 8086
.mode:
    mov bx, [tk_end]                ; exactly "bits 16" / "cpu 8086"
    sub bx, [st_args_beg]
    cmp bx, TK_SIZE
    jne .mode_bad
    mov bx, [st_args_beg]
    cmp byte [bx + TK_TYPE], T_NUM
    jne .mode_bad
    cmp word [bx + TK_HI], 0
    jne .mode_bad
    cmp [bx + TK_LO], cx
    jne .mode_bad
    mov byte [st_kind], K_IGNORE
    ret
.mode_bad:
    jmp stmt_error
.not_cpu:
    mov bx, si
    cmp al, D_OTHER
    jne .section
    call err_begin
    jc .other_done
    mov al, 27h
    call putc
    call put_token
    mov si, m_other_data
    call puts
    call err_end
.other_done:
    mov byte [st_kind], K_ERROR
    ret
.section:
    lea bx, [si + TK_SIZE]          ; its name: .text, .data or .bss
    cmp bx, [tk_end]
    jae .section_unnamed
    mov al, [bx + TK_TYPE]
    cmp al, T_KW
    je .section_other
    cmp al, T_SYM
    jne .section_unnamed
    call section_number
    jc .section_other
    lea cx, [bx + TK_SIZE]
    cmp cx, [tk_end]
    jne .section_attributes
    mov [st_section], al
    mov byte [st_kind], K_SECTION
    ret
.section_unnamed:
    mov si, m_section_name
    jmp stmt_error
.section_attributes:
    mov si, m_section_attr
    jmp stmt_error
.section_other:
    call err_begin
    jc .section_done
    mov si, m_section_other
    call puts
    mov al, 27h
    call putc
    call put_token
    mov al, 27h
    call putc
    call err_end
.section_done:
    mov byte [st_kind], K_ERROR
    ret
.mnemonic:
    mov [st_mnem], si
    mov byte [st_kind], K_INSTR
    add si, TK_SIZE
; The operands from SI to tk_end, separated by commas outside [] and ()
split_operands:
    mov byte [st_nops], 0
    mov di, [tk_end]
    cmp si, di
    jae .done
    xor dx, dx                      ; depth
    mov bx, si                      ; where the operand starts
.loop:
    cmp si, di
    je .split
    cmp byte [si + TK_TYPE], T_PUNCT
    jne .next
    mov al, [si + TK_SUB]
    cmp al, '['
    je .open
    cmp al, '('
    jne .not_open
.open:
    inc dx
    jmp .next
.not_open:
    cmp al, ']'
    je .close
    cmp al, ')'
    jne .not_close
.close:
    dec dx
    jmp .next
.not_close:
    cmp al, ','
    jne .next
    or dx, dx
    jz .split
.next:
    add si, TK_SIZE
    jmp .loop
.split:
    mov al, [st_nops]
    cmp al, 3
    jb .room
    mov si, m_many_operands
    jmp stmt_error
.room:
    cmp bx, si
    jne .operand
    mov si, m_missing_operand
    jmp stmt_error
.operand:
    xor ah, ah
    push di
    mov di, ax
    shl di, 1
    mov [st_op_beg + di], bx
    mov [st_op_end + di], si
    pop di
    inc byte [st_nops]
    cmp si, di
    je .done
    add si, TK_SIZE
    mov bx, si
    jmp .loop
.done:
    ret

; BX = a T_SYM token: AL = the section it names (CF if none)
section_number:
    push cx
    push si
    push di
    push es
    mov es, [bx + TK_LO]
    xor di, di
    mov si, section_names
    xor ax, ax
.next:
    mov cl, [si]
    or cl, cl
    jz .none
    xor ch, ch
    cmp cl, [es:di + S_LEN]
    jne .skip
    push si
    push di
    inc si
    add di, S_NAME
    repe cmpsb
    pop di
    pop si
    je .found
.skip:
    mov cl, [si]
    xor ch, ch
    add si, cx
    inc si
    inc ax
    jmp .next
.none:
    stc
    jmp .ret
.found:
    clc
.ret:
    pop es
    pop di
    pop si
    pop cx
    ret

section_names db 5, '.text', 5, '.data', 4, '.bss', 0

; ---------- output ----------

; CX bytes at SI, on the last pass, at address wpos (not for .bss)
out_bytes:
    cmp byte [final], 0
    je .done
    jcxz .done
.loop:
    mov al, [si]
    call out_byte
    inc si
    loop .loop
.done:
    ret

; DX:AX zero bytes, on the last pass (registers kept)
out_zero:
    cmp byte [final], 0
    je .done
    push ax
    push dx
.loop:
    mov bx, ax
    or bx, dx
    jz .end
    push ax
    xor al, al
    call out_byte
    pop ax
    sub ax, 1
    sbb dx, 0
    jmp .loop
.end:
    pop dx
    pop ax
.done:
    ret

; AL at address wpos of the output (64 KB from ORG), and wpos moves on
out_byte:
    push bx
    push dx
    push es
    cmp byte [cur_sec], SEC_BSS
    je .next
    mov bx, [wpos]
    mov dx, [wpos + 2]
    sub bx, [org_val]
    sbb dx, 0
    jnz .next                       ; past 64 KB: reported
    mov es, [out_seg]
    mov [es:bx], al
    add bx, 1                       ; the output is this long at least
    adc dx, 0
    cmp dx, [out_len + 2]
    jb .next
    ja .longer
    cmp bx, [out_len]
    jbe .next
.longer:
    mov [out_len], bx
    mov [out_len + 2], dx
.next:
    add word [wpos], 1
    adc word [wpos + 2], 0
    pop es
    pop dx
    pop bx
    ret

; db / dw: values and strings separated by commas. AX = the size.
emit_data:
    mov si, [st_args_beg]
    mov word [data_size], 0
    cmp si, [st_args_end]
    jb .item
    mov si, m_db_empty
    cmp byte [st_kind], K_DW
    jne .empty
    mov si, m_dw_empty
.empty:
    call error
    jmp .done
.item:
    mov di, si                      ; the item ends at a comma outside ()
    xor dx, dx
.find:
    cmp di, [st_args_end]
    jae .found
    cmp byte [di + TK_TYPE], T_PUNCT
    jne .find_next
    mov al, [di + TK_SUB]
    cmp al, '('
    jne .not_open
    inc dx
.not_open:
    cmp al, ')'
    jne .not_close
    dec dx
.not_close:
    cmp al, ','
    jne .find_next
    or dx, dx
    jz .found
.find_next:
    add di, TK_SIZE
    jmp .find
.found:
    cmp di, si
    jne .not_empty
    mov si, m_between_commas
    call error
    jmp .done
.not_empty:
    mov [item_end], di
    lea ax, [si + TK_SIZE]          ; a string alone, not a character?
    cmp ax, di
    jne .value
    cmp byte [si + TK_TYPE], T_STR
    jne .value
    mov cl, [si + TK_SUB]
    xor ch, ch
    cmp byte [st_kind], K_DW
    je .word_string
    cmp cx, 1
    je .value
    jmp .string
.word_string:
    cmp cx, 2
    je .value
.string:
    push cx
    mov si, [si + TK_LO]
    call out_bytes
    pop cx
    add [data_size], cx
    test cl, 1
    jz .next
    cmp byte [st_kind], K_DW
    jne .next
    mov ax, 1                       ; dw strings are padded to words
    xor dx, dx
    call out_zero
    inc word [data_size]
    jmp .next
.value:
    call eval_range
    jc .write
    push ax
    push dx
    push bx
    cmp byte [st_kind], K_DW
    je .check_word
    call check_byte
    jmp .checked
.check_word:
    call check_word
.checked:
    pop bx
    pop dx
    pop ax
.write:
    mov [data_bytes], ax
    mov si, data_bytes
    mov cx, 1
    cmp byte [st_kind], K_DW
    jne .one
    inc cx
.one:
    add [data_size], cx
    call out_bytes
.next:
    mov si, [item_end]
    cmp si, [st_args_end]
    jae .done
    add si, TK_SIZE
    cmp si, [st_args_end]
    jae .skip12
    jmp .item
.skip12:
    mov si, m_trailing_comma
    call error
.done:
    mov ax, [data_size]
    ret

; SI..DI = a count (TIMES, RESB, RESW), BX = its name: DX:AX = 0..10000h
eval_count:
    push bx
    call eval_range
    pop cx
    jc .zero
    or bh, bh
    jnz .zero
    or bl, bl
    jz .number
    mov bx, cx
    call err_begin
    jc .zero
    mov si, bx
    call puts
    mov si, m_count_address
    call puts
    call err_end
    jmp .zero
.number:
    test dx, 8000h
    jz .positive
    push ax
    push dx
    mov bx, cx
    call err_begin
    jc .neg_hidden
    mov si, bx
    call puts
    mov si, m_count_negative
    call puts
    pop dx
    pop ax
    call put_signed
    mov al, ')'
    call putc
    call err_end
    jmp .zero
.neg_hidden:
    pop dx
    pop ax
    jmp .zero
.positive:
    cmp dx, 1
    jb .ok
    ja .large
    or ax, ax
    jz .ok
.large:
    push ax
    push dx
    mov bx, cx
    call err_begin
    jc .neg_hidden
    mov si, bx
    call puts
    mov si, m_count_large
    call puts
    pop dx
    pop ax
    call put_signed
    mov al, ')'
    call putc
    call err_end
.zero:
    xor ax, ax
    xor dx, dx
.ok:
    ret

; ======================================================================
; Expressions: DX:AX = value, BL = how many addresses it holds (reloc),
; BH = 1 if it depends on a symbol not known yet
; ======================================================================

; SI..DI: the whole range must be one expression. CF = 1 on an error.
eval_range:
    mov [ex_pos], si
    mov [ex_end], di
    mov byte [ex_err], 0
    call ex_or
    cmp byte [ex_err], 0
    jne .error
    mov si, [ex_pos]
    cmp si, [ex_end]
    je .ok
    push ax
    push bx
    push dx
    mov bx, si
    mov si, m_unexpected_text
    call ex_fail
    pop dx
    pop bx
    pop ax
.error:
    stc
    ret
.ok:
    clc
    ret

; SI..DI: where an expression starting at SI ends, without errors.
; BX = that position; CF = 1 if it is not an expression.
skip_expr:
    mov byte [quiet], 1
    mov [ex_pos], si
    mov [ex_end], di
    mov byte [ex_err], 0
    call ex_or
    mov byte [quiet], 0
    mov bx, [ex_pos]
    cmp byte [ex_err], 0
    jne .bad
    clc
    ret
.bad:
    stc
    ret

; SI = message, BX = token or 0: the first error of the expression
ex_fail:
    cmp byte [ex_err], 0
    jne .done
    mov byte [ex_err], 1
    or bx, bx
    jz .plain
    cmp byte [bx + TK_TYPE], T_EOL
    je .plain
    jmp error_tok
.plain:
    jmp error
.done:
    ret

; AL = punctuation: CF = 0 and the position moves past it if it is next
ex_punct:
    push si
    mov si, [ex_pos]
    cmp si, [ex_end]
    jae .no
    cmp byte [si + TK_TYPE], T_PUNCT
    jne .no
    cmp [si + TK_SUB], al
    jne .no
    add word [ex_pos], TK_SIZE
    pop si
    clc
    ret
.no:
    pop si
    stc
    ret

ex_zero:
    xor ax, ax
    xor dx, dx
    xor bx, bx
    ret

ex_primary:
    mov si, [ex_pos]
    cmp si, [ex_end]
    jb .have
    mov si, m_missing_value
    xor bx, bx
    call ex_fail
    jmp ex_zero
.have:
    mov al, [si + TK_TYPE]
    cmp al, T_NUM
    jne .not_num
    add word [ex_pos], TK_SIZE
    mov ax, [si + TK_LO]
    mov dx, [si + TK_HI]
    xor bx, bx
    ret
.not_num:
    cmp al, T_SYM
    jne .not_sym
    add word [ex_pos], TK_SIZE
    mov bx, [si + TK_LO]
    push es
    mov es, bx
    test byte [es:S_ID], SF_DEFINED
    jz .undefined
    mov ax, [es:S_VLO]
    mov dx, [es:S_VHI]
    mov bl, [es:S_RELOC]
    xor bh, bh
    pop es
    ret
.undefined:
    pop es
    cmp byte [final], 0
    je .unknown
    cmp byte [quiet], 0
    jne .unknown
    call err_begin
    jc .hidden
    mov si, m_undefined
    call puts
    mov al, 27h
    call putc
    mov ax, bx
    call put_symbol
    mov al, 27h
    call putc
    call err_end
.hidden:
    mov byte [ex_err], 1
.unknown:
    call ex_zero
    mov bh, 1
    ret
.not_sym:
    cmp al, T_DOLLAR
    jne .not_dollar
    add word [ex_pos], TK_SIZE
    mov ax, [line_start]
    mov dx, [line_start + 2]
    mov bx, 1
    ret
.not_dollar:
    cmp al, T_DOLLAR2
    jne .not_dollar2
    add word [ex_pos], TK_SIZE
    call sec_index
    mov ax, [sec_base + bx]
    mov dx, [sec_base + bx + 2]
    mov bx, 1
    ret
.not_dollar2:
    cmp al, T_STR
    jne .not_str
    mov cl, [si + TK_SUB]
    or cl, cl
    jz .bad_char
    cmp cl, 4
    ja .bad_char
    add word [ex_pos], TK_SIZE
    xor ch, ch
    mov si, [si + TK_LO]
    mov word [char_val], 0
    mov word [char_val + 2], 0
    mov di, char_val
    push es
    push ds
    pop es
    rep movsb
    pop es
    mov ax, [char_val]
    mov dx, [char_val + 2]
    xor bx, bx
    ret
.bad_char:
    mov bx, si
    mov si, m_bad_char
    call ex_fail
    jmp ex_zero
.not_str:
    cmp al, T_PUNCT
    jne .not_punct
    cmp byte [si + TK_SUB], '('
    jne .expected
    add word [ex_pos], TK_SIZE
    call ex_or
    push ax
    mov al, ')'
    call ex_punct
    pop ax
    jnc .closed
    push ax
    push bx
    push dx
    mov bx, [ex_pos]
    mov si, m_missing_paren
    call ex_fail
    pop dx
    pop bx
    pop ax
.closed:
    ret
.not_punct:
    cmp al, T_KW
    jne .expected
    mov al, [si + TK_CLASS]
    mov bx, si
    mov si, m_register_here
    cmp al, C_SREG
    jbe .kw_error
    mov si, m_register_32
    cmp al, C_REG32
    je .kw_error
    mov si, m_expected_value
    jmp .kw_error
.expected:
    mov bx, si
    mov si, m_expected_value
.kw_error:
    call ex_fail
    jmp ex_zero

ex_unary:
    mov al, '-'
    call ex_punct
    jc .not_minus
    call ex_unary
    not dx
    neg ax
    sbb dx, -1
    neg bl
    ret
.not_minus:
    mov al, '+'
    call ex_punct
    jc .not_plus
    jmp ex_unary
.not_plus:
    mov al, '~'
    call ex_punct
    jc .not_not
    call ex_unary
    not ax
    not dx
    ret
.not_not:
    mov al, '!'
    call ex_punct
    jc .primary
    call ex_unary
    or ax, dx
    mov ax, 0
    mov dx, 0
    jnz .true
    inc ax
.true:
    ret
.primary:
    jmp ex_primary

; After the right operand: [b_*] = it, DX:AX BX = the left one
; BL = (a.reloc or b.reloc) ? 1 : 0, BH = a.unknown or b.unknown
combine:
    or bl, [b_rb]
    jz .no_reloc
    mov bl, 1
.no_reloc:
    or bh, [b_rb + 1]
    ret

; Saves the right operand (DX:AX BX) in b_*
save_b:
    mov [b_lo], ax
    mov [b_hi], dx
    mov [b_rb], bx
    ret

ex_mul:
    call ex_unary
.loop:
    mov si, [ex_pos]
    cmp si, [ex_end]
    jb .skip11
    jmp .done
.skip11:
    cmp byte [si + TK_TYPE], T_PUNCT
    je .skip10
    jmp .done
.skip10:
    mov cl, [si + TK_SUB]
    cmp cl, '*'
    je .op
    cmp cl, '/'
    je .op
    cmp cl, '%'
    je .op
    cmp cl, P_SDIV
    je .op
    cmp cl, P_SMOD
    jne .done
.op:
    add word [ex_pos], TK_SIZE
    push dx
    push ax
    push bx
    push cx
    call ex_unary
    call save_b
    pop cx
    pop bx
    pop ax
    pop dx
    call combine
    cmp cl, '*'
    jne .divide
    call mul32
    jmp .loop
.divide:
    mov si, [b_lo]
    or si, [b_hi]
    jnz .nonzero
    cmp byte [b_rb + 1], 0
    jne .zero
    push bx
    xor bx, bx
    mov si, m_div_zero
    call ex_fail
    pop bx
.zero:
    xor ax, ax
    xor dx, dx
    jmp .loop
.nonzero:
    cmp cl, '/'
    jne .not_udiv
    call udiv32
    jmp .loop
.not_udiv:
    cmp cl, '%'
    jne .signed
    call udiv32
    mov ax, [r_lo]
    mov dx, [r_hi]
    jmp .loop
.signed:
    call sdiv32
    cmp cl, P_SDIV
    jne .skip9
    jmp .loop
.skip9:
    mov ax, [r_lo]
    mov dx, [r_hi]
    jmp .loop
.done:
    ret

ex_add:
    call ex_mul
.loop:
    push ax
    mov al, '+'
    call ex_punct
    pop ax
    jc .not_plus
    push dx
    push ax
    push bx
    call ex_mul
    call save_b
    pop bx
    pop ax
    pop dx
    add ax, [b_lo]
    adc dx, [b_hi]
    add bl, [b_rb]
    or bh, [b_rb + 1]
    jmp .loop
.not_plus:
    push ax
    mov al, '-'
    call ex_punct
    pop ax
    jc .done
    push dx
    push ax
    push bx
    call ex_mul
    call save_b
    pop bx
    pop ax
    pop dx
    sub ax, [b_lo]
    sbb dx, [b_hi]
    sub bl, [b_rb]
    or bh, [b_rb + 1]
    jmp .loop
.done:
    ret

ex_shift:
    call ex_add
.loop:
    push ax
    mov al, P_SHL
    call ex_punct
    jnc .shift
    mov al, P_SHR
    call ex_punct
    jnc .shift
    pop ax
    ret
.shift:
    mov cl, al
    pop ax
    push cx
    push dx
    push ax
    push bx
    call ex_add
    call save_b
    pop bx
    pop ax
    pop dx
    pop cx
    call combine
    mov si, [b_lo]
    and si, 63
    cmp si, 32
    jb .count
    xor ax, ax
    xor dx, dx
    jmp .loop
.count:
    or si, si
    jz .loop
    cmp cl, P_SHL
    jne .right
.left:
    shl ax, 1
    rcl dx, 1
    dec si
    jnz .left
    jmp .loop
.right:
    shr dx, 1
    rcr ax, 1
    dec si
    jnz .right
    jmp .loop

ex_and:
    call ex_shift
.loop:
    push ax
    mov al, '&'
    call ex_punct
    pop ax
    jc .done
    push dx
    push ax
    push bx
    call ex_shift
    call save_b
    pop bx
    pop ax
    pop dx
    call combine
    and ax, [b_lo]
    and dx, [b_hi]
    jmp .loop
.done:
    ret

ex_xor:
    call ex_and
.loop:
    push ax
    mov al, '^'
    call ex_punct
    pop ax
    jc .done
    push dx
    push ax
    push bx
    call ex_and
    call save_b
    pop bx
    pop ax
    pop dx
    call combine
    xor ax, [b_lo]
    xor dx, [b_hi]
    jmp .loop
.done:
    ret

ex_or:
    call ex_xor
.loop:
    push ax
    mov al, '|'
    call ex_punct
    pop ax
    jc .done
    push dx
    push ax
    push bx
    call ex_xor
    call save_b
    pop bx
    pop ax
    pop dx
    call combine
    or ax, [b_lo]
    or dx, [b_hi]
    jmp .loop
.done:
    ret

; DX:AX * b (the low 32 bits)
mul32:
    push bx
    push cx
    mov cx, ax
    mov ax, dx
    mul word [b_lo]
    mov bx, ax
    mov ax, cx
    mul word [b_hi]
    add bx, ax
    mov ax, cx
    mul word [b_lo]
    add dx, bx
    pop cx
    pop bx
    ret

; DX:AX / b, unsigned: DX:AX = quotient, r_lo/r_hi = remainder
udiv32:
    push bx
    push cx
    push si
    push di
    xor si, si
    xor di, di
    mov cx, 32
.bit:
    shl ax, 1
    rcl dx, 1
    rcl si, 1
    rcl di, 1
    jc .subtract
    cmp di, [b_hi]
    jb .next
    ja .subtract
    cmp si, [b_lo]
    jb .next
.subtract:
    sub si, [b_lo]
    sbb di, [b_hi]
    or ax, 1
.next:
    loop .bit
    mov [r_lo], si
    mov [r_hi], di
    pop di
    pop si
    pop cx
    pop bx
    ret

; DX:AX / b, signed (rounded towards zero): quotient and remainder
sdiv32:
    push bx
    push word [b_lo]
    push word [b_hi]
    mov bl, dh                      ; the sign of the remainder
    mov bh, dh
    xor bh, [b_hi + 1]              ; the sign of the quotient
    test dh, 80h
    jz .a_positive
    not dx
    neg ax
    sbb dx, -1
.a_positive:
    test byte [b_hi + 1], 80h
    jz .b_positive
    not word [b_hi]
    neg word [b_lo]
    sbb word [b_hi], -1
.b_positive:
    call udiv32
    test bh, 80h
    jz .q_positive
    not dx
    neg ax
    sbb dx, -1
.q_positive:
    test bl, 80h
    jz .r_positive
    not word [r_hi]
    neg word [r_lo]
    sbb word [r_hi], -1
.r_positive:
    pop word [b_hi]
    pop word [b_lo]
    pop bx
    ret

; ======================================================================
; Operands
; ======================================================================

; SI..DI = an operand, BP = where it goes (op0, op1 or op2). CF = 1 on an
; error.
parse_operand:
    mov [opnd_end], di
    push di
    push ds
    pop es
    mov di, bp
    mov cx, O_SIZEOF / 2
    xor ax, ax
    rep stosw
    pop di
    mov word [bp + O_SEG], 0FFFFh   ; no segment, no base
    mov byte [bp + O_INDEX], 0FFh
.prefix:
    cmp si, di
    jb .prefix_have
    jmp .missing
.prefix_have:
    cmp byte [si + TK_TYPE], T_KW
    jne .prefix_done
    mov al, [si + TK_CLASS]
    mov ah, [si + TK_A]
    cmp al, C_SIZE
    jne .not_size
    cmp ah, 3
    jne .size
    mov si, m_byte_word
    jmp opnd_error
.size:
    mov [bp + O_SIZE], ah
    jmp .prefix_next
.not_size:
    cmp al, C_JMOD
    jne .not_jmod
    mov [bp + O_JMOD], ah
    jmp .prefix_next
.not_jmod:
    cmp al, C_STRICT
    jne .prefix_done
.prefix_next:
    add si, TK_SIZE
    jmp .prefix
.prefix_done:
    mov bx, si                      ; PTR anywhere?
.ptr:
    cmp bx, di
    jae .no_ptr
    cmp byte [bx + TK_TYPE], T_KW
    jne .ptr_next
    cmp byte [bx + TK_CLASS], C_PTR
    jne .ptr_next
    mov si, m_ptr
    jmp opnd_error
.ptr_next:
    add bx, TK_SIZE
    jmp .ptr
.no_ptr:
    cmp byte [si + TK_TYPE], T_PUNCT
    jne .not_mem
    cmp byte [si + TK_SUB], '['
    jne .not_mem
    cmp byte [di - TK_SIZE + TK_TYPE], T_PUNCT
    jne .no_bracket
    cmp byte [di - TK_SIZE + TK_SUB], ']'
    je .bracket
.no_bracket:
    mov si, m_bracket
    jmp opnd_error
.bracket:
    add si, TK_SIZE
    sub di, TK_SIZE
    jmp parse_mem
.not_mem:
    call is_register
    jc .not_reg
    mov ax, di
    sub ax, si
    cmp ax, TK_SIZE
    jne .reg_colon
    mov al, [si + TK_CLASS]         ; OT_REG8/REG16/SREG = C_REG8/REG16/SREG
    mov [bp + O_TYPE], al
    mov ah, [si + TK_A]
    mov [bp + O_REG], ah
    mov ah, 2
    cmp al, C_REG8
    jne .reg_size
    mov ah, 1
.reg_size:
    mov al, [bp + O_SIZE]
    mov [bp + O_SIZE], ah
    or al, al
    jnz .skip8
    jmp .ok
.skip8:
    cmp al, ah
    jne .skip7
    jmp .ok
.skip7:
    mov bx, si
    call err_begin
    jc .fail
    mov si, m_size_register
    call puts
    call put_token
    call err_end
.fail:
    stc
    ret
.reg_colon:
    cmp byte [si + TK_SIZE + TK_TYPE], T_PUNCT
    jne .not_reg
    cmp byte [si + TK_SIZE + TK_SUB], ':'
    jne .not_reg
    mov bx, si
    call err_begin
    jc .fail
    mov si, m_seg_inside
    call puts
    call put_token
    mov si, m_seg_inside_end
    call puts
    call err_end
    stc
    ret
.not_reg:
    mov byte [bp + O_TYPE], OT_IMM  ; an immediate
    mov al, [bp + O_SIZE]
    mov [bp + O_IMMSZ], al
    mov byte [bp + O_SIZE], 0
    mov bx, si                      ; segment:offset?
    xor dx, dx
.colon:
    cmp bx, di
    jae .value
    cmp byte [bx + TK_TYPE], T_PUNCT
    jne .colon_next
    mov al, [bx + TK_SUB]
    cmp al, '('
    jne .colon_not_open
    inc dx
.colon_not_open:
    cmp al, ')'
    jne .colon_not_close
    dec dx
.colon_not_close:
    cmp al, ':'
    jne .colon_next
    or dx, dx
    jz .far
.colon_next:
    add bx, TK_SIZE
    jmp .colon
.far:
    mov byte [bp + O_FAR], 1
    push bx
    mov di, bx
    call eval_range
    pop si
    jc .fail
    mov [bp + O_FSEG + V_LO], ax
    mov [bp + O_FSEG + V_HI], dx
    mov [bp + O_FSEG + V_RELOC], bx
    add si, TK_SIZE
    mov di, [opnd_end]
    cmp si, di
    jb .value
    mov si, m_far_offset
    jmp opnd_error
.value:
    call eval_range
    jnc .skip6
    jmp .fail
.skip6:
    mov [bp + O_IMM + V_LO], ax
    mov [bp + O_IMM + V_HI], dx
    mov [bp + O_IMM + V_RELOC], bx
.ok:
    clc
    ret
.missing:
    mov si, m_missing_operand
opnd_error:
    call error
    stc
    ret

; SI = token: CF = 0 if it is an 8-bit, 16-bit or segment register
is_register:
    cmp byte [si + TK_TYPE], T_KW
    jne .no
    cmp byte [si + TK_CLASS], C_SREG
    ja .no
    clc
    ret
.no:
    stc
    ret

; SI = token: CF = 0 if it can end a value (to tell binary +/- from unary)
ends_value:
    mov al, [si + TK_TYPE]
    cmp al, T_PUNCT
    je .punct
    cmp al, T_EOL
    je .no
    cmp al, T_DOLLAR2
    jbe .yes
    cmp al, T_SYM
    ja .no
.yes:
    clc
    ret
.punct:
    cmp byte [si + TK_SUB], ')'
    je .yes
.no:
    stc
    ret

; [SI..DI] inside the brackets
parse_mem:
    mov byte [bp + O_TYPE], OT_MEM
    mov ax, di
    sub ax, si
    cmp ax, 2 * TK_SIZE
    jb .terms
    cmp byte [si + TK_SIZE + TK_TYPE], T_PUNCT
    jne .terms
    cmp byte [si + TK_SIZE + TK_SUB], ':'
    jne .terms
    mov al, [si + TK_TYPE]
    cmp al, T_KW
    je .seg_kw
    cmp al, T_SYM
    jne .terms
    jmp .not_seg
.seg_kw:
    cmp byte [si + TK_CLASS], C_SREG
    jne .not_seg
    mov al, [si + TK_A]
    mov [bp + O_SEG], al
    add si, 2 * TK_SIZE
    jmp .terms
.not_seg:
    mov bx, si
    call err_begin
    jc .fail
    mov al, 27h
    call putc
    call put_token
    mov si, m_not_segment
    call puts
    call err_end
.fail:
    stc
    ret
.terms:
    cmp si, di
    jb .term
    mov si, m_empty_address
    jmp opnd_error
.term:
    cmp si, di
    jb .sign
    clc
    ret
.sign:
    xor cx, cx                      ; CL = 1 if subtracted
.signs:
    cmp si, di
    jae .term_start
    cmp byte [si + TK_TYPE], T_PUNCT
    jne .term_start
    mov al, [si + TK_SUB]
    cmp al, '+'
    je .plus
    cmp al, '-'
    jne .term_start
    xor cl, 1
.plus:
    add si, TK_SIZE
    jmp .signs
.term_start:
    mov [term_beg], si
    xor dx, dx                      ; depth
.scan:
    cmp si, di
    jae .term_end
    cmp byte [si + TK_TYPE], T_PUNCT
    jne .scan_next
    mov al, [si + TK_SUB]
    cmp al, '('
    jne .scan_not_open
    inc dx
.scan_not_open:
    cmp al, ')'
    jne .scan_not_close
    dec dx
.scan_not_close:
    or dx, dx
    jnz .scan_next
    cmp al, '+'
    je .scan_op
    cmp al, '-'
    jne .scan_next
.scan_op:
    cmp si, [term_beg]
    je .scan_next
    push si
    sub si, TK_SIZE
    call ends_value
    pop si
    jnc .term_end
.scan_next:
    add si, TK_SIZE
    jmp .scan
.term_end:
    mov bx, [term_beg]
    cmp bx, si
    jne .have_term
    mov si, m_missing_term
    jmp opnd_error
.have_term:
    mov ax, si
    sub ax, bx
    cmp ax, TK_SIZE
    jne .expression
    push si
    mov si, bx
    call is_register
    pop si
    jc .expression
    cmp byte [bx + TK_CLASS], C_REG16
    jne .bad_register
    mov al, [bx + TK_A]
    cmp al, 3
    je .register
    cmp al, 5
    jb .bad_register
.register:
    or cl, cl
    jz .added
    mov si, m_reg_subtract
    jmp opnd_error
.added:
    cmp al, 6
    jae .index
    cmp byte [bp + O_BASE], 0FFh
    jne .combination
    mov [bp + O_BASE], al
    jmp .term
.index:
    cmp byte [bp + O_INDEX], 0FFh
    jne .combination
    mov [bp + O_INDEX], al
    jmp .term
.combination:
    mov si, m_reg_combination
    jmp opnd_error
.bad_register:
    call err_begin
    jnc .skip5
    jmp .fail
.skip5:
    mov si, m_address_regs
    call puts
    call put_token
    mov al, ')'
    call putc
    call err_end
    stc
    ret
.expression:
    push si
    push di
    push cx
    mov di, si
    mov si, bx
    call eval_range
    pop cx
    pop di
    pop si
    jnc .skip4
    jmp .fail
.skip4:
    or cl, cl
    jz .positive
    not dx
    neg ax
    sbb dx, -1
    neg bl
.positive:
    add [bp + O_DISP + V_LO], ax
    adc [bp + O_DISP + V_HI], dx
    add [bp + O_DISP + V_RELOC], bl
    or [bp + O_DISP + V_UNK], bh
    jmp .term

; ======================================================================
; Encoding
; ======================================================================

; The instruction of the statement into enc / enc_n. CF = 1 on an error.
encode:
    mov word [enc_n], 0
    mov byte [enc_opnd], 0
.operand:
    mov al, [enc_opnd]
    cmp al, [st_nops]
    jae .operands_done
    xor ah, ah
    mov bx, ax
    shl bx, 1
    mov si, [st_op_beg + bx]
    mov di, [st_op_end + bx]
    mov cl, 5
    shl ax, cl
    add ax, op0
    mov bp, ax
    call parse_operand
    jnc .operand_ok
    ret
.operand_ok:
    inc byte [enc_opnd]
    jmp .operand
.operands_done:
    mov bx, [st_mnem]
    mov al, [bx + TK_A]
    mov [m_id], al
    mov al, [bx + TK_B]
    mov [m_cc], al
    mov al, [st_rep]
    or al, al
    jz .no_rep
    test byte [bx + TK_FLAGS], KF_STRING
    jnz .rep_ok
    mov si, m_rep_string
    jmp enc_error
.rep_ok:
    call eb
.no_rep:
    mov bp, op0                     ; FAR, SHORT and NEAR where they belong
    mov cl, [st_nops]
    xor ch, ch
    jcxz .dispatch
.check:
    mov al, [m_id]
    cmp byte [bp + O_JMOD], J_FAR
    je .far
    cmp byte [bp + O_FAR], 0
    je .not_far
.far:
    cmp al, M_JMP
    je .not_far
    cmp al, M_CALL
    je .not_far
    mov si, m_far_jmp
    jmp enc_error
.not_far:
    cmp byte [bp + O_TYPE], OT_IMM
    jne .check_next
    cmp byte [bp + O_JMOD], 0
    je .check_next
    cmp al, M_JMP
    je .check_next
    cmp al, M_CALL
    je .check_next
    cmp al, M_JCC
    jb .not_jump
    cmp al, M_JCXZ
    jbe .check_next
.not_jump:
    mov si, m_short_jumps
    jmp enc_error
.check_next:
    add bp, O_SIZEOF
    loop .check
.dispatch:
    mov bl, [m_id]
    xor bh, bh
    dec bx
    shl bx, 1
    jmp [handlers + bx]

handlers:
    dw do_alu, do_alu, do_alu, do_alu, do_alu, do_alu, do_alu, do_alu
    dw do_mov, do_xchg, do_test, do_lea, do_incdec, do_incdec
    dw do_group3, do_group3, do_group3, do_group3, do_group3, do_group3
    dw do_shift, do_shift, do_shift, do_shift, do_shift, do_shift, do_shift
    dw do_pushpop, do_pushpop, do_jmpcall, do_jmpcall, do_ret, do_ret
    dw do_iret, do_int, do_int3, do_lds, do_jcc
    dw do_loop, do_loop, do_loop, do_loop, do_inout, do_inout, do_simple

enc_ok:
    clc
    ret

; SI = message
enc_error:
    call error
    stc
    ret

; SI = message with % where the mnemonic goes
enc_error_fmt:
    call err_begin
    jc .done
.loop:
    lodsb
    or al, al
    jz .end
    cmp al, '%'
    jne .char
    push bx
    mov bx, [st_mnem]
    mov al, [bx + TK_SUB]
    pop bx
    call put_keyword
    jmp .loop
.char:
    call putc
    jmp .loop
.end:
    call err_end
.done:
    stc
    ret

enc_bad:
    mov si, m_bad_operands
    jmp enc_error_fmt

; AL = how many operands the instruction takes; returns only if it has them
need:
    cmp al, [st_nops]
    jne .wrong
    ret
.wrong:
    pop bx                          ; not back to the handler
    push ax
    call err_begin
    pop ax
    jc .done
    push ax
    mov bx, [st_mnem]
    call put_token
    mov si, m_takes
    call puts
    pop ax
    push ax
    add al, '0'
    call putc
    mov si, m_operand
    call puts
    pop ax
    cmp al, 1
    je .one
    mov al, 's'
    call putc
.one:
    call err_end
.done:
    stc
    ret

; AL: one more byte
eb:
    push bx
    mov bx, [enc_n]
    cmp bx, 16
    jae .full
    mov [enc + bx], al
    inc word [enc_n]
.full:
    pop bx
    ret

; AX: one more word
ew:
    call eb
    mov al, ah
    jmp eb

; SI = operand: its segment override prefix, if it has one
seg_prefix:
    cmp byte [si + O_TYPE], OT_MEM
    jne .done
    mov al, [si + O_SEG]
    cmp al, 0FFh
    je .done
    mov cl, 3
    shl al, cl
    add al, 26h
    call eb
.done:
    ret

; SI = operand (register or memory), AH = the reg field, AL = the sticky
; bit of its displacement (2 for the first operand, 4 for the second):
; the ModRM byte and the displacement
modrm:
    mov [mr_bit], al
    mov cl, 3
    shl ah, cl
    mov al, [si + O_TYPE]
    cmp al, OT_SREG
    ja .memory
    mov al, [si + O_REG]
    or al, ah
    or al, 0C0h
    jmp eb
.memory:
    mov al, [si + O_BASE]
    and al, [si + O_INDEX]
    cmp al, 0FFh
    jne .registers
    mov al, ah                      ; [address]
    or al, 6
    call eb
    mov ax, [si + O_DISP]
    jmp ew
.registers:
    mov al, [si + O_BASE]
    mov dl, [si + O_INDEX]
    cmp al, 3
    jne .not_bx
    mov dh, 7
    cmp dl, 0FFh
    je .rm
    sub dl, 6                       ; SI 0, DI 1
    mov dh, dl
    jmp .rm
.not_bx:
    cmp al, 5
    jne .no_base
    mov dh, 6
    cmp dl, 0FFh
    je .rm
    sub dl, 4                       ; SI 2, DI 3
    mov dh, dl
    jmp .rm
.no_base:
    sub dl, 2                       ; SI 4, DI 5
    mov dh, dl
.rm:
    or ah, dh                       ; reg and rm
    mov bx, [si + O_DISP]           ; 16-bit displacement
    mov dl, 2                       ; mod
    cmp byte [si + O_DISP + V_RELOC], 0
    jne .mod
    mov al, [sticky]
    test al, [mr_bit]
    jnz .mod
    mov dl, 1
    cmp byte [si + O_DISP + V_UNK], 0
    jne .mod
    or bx, bx
    jnz .not_zero
    cmp dh, 6
    je .not_zero
    mov dl, 0
    jmp .mod
.not_zero:
    cmp bx, -128
    jl .long
    cmp bx, 127
    jle .mod
.long:
    mov dl, 2
.mod:
    cmp dl, 2
    jne .emit
    cmp byte [pass], STICKY_PASS
    jb .emit
    mov al, [mr_bit]
    or [sticky], al
.emit:
    mov al, dl
    mov cl, 6
    shl al, cl
    or al, ah
    call eb
    mov ax, bx
    cmp dl, 1
    jne .not_byte
    jmp eb
.not_byte:
    cmp dl, 2
    jne .done
    jmp ew
.done:
    ret

; SI = operand: CF = 0 if it is an 8- or 16-bit register
is_reg:
    cmp byte [si + O_TYPE], OT_REG8
    je .yes
    cmp byte [si + O_TYPE], OT_REG16
    je .yes
    stc
    ret
.yes:
    clc
    ret

; SI = operand: CF = 0 if it is a register or memory
is_rm:
    call is_reg
    jnc .yes
    cmp byte [si + O_TYPE], OT_MEM
    je .yes
    stc
    ret
.yes:
    clc
    ret

; Both operands in memory? (then an error)
two_memory:
    cmp byte [op0 + O_TYPE], OT_MEM
    jne .no
    cmp byte [op1 + O_TYPE], OT_MEM
    jne .no
    pop ax                          ; not back to the handler
    mov si, m_two_memory
    jmp enc_error
.no:
    ret

; The size of an operation with two operands: AL = 1 or 2; returns only if
; it is known and they agree
op_size2:
    mov al, [op0 + O_SIZE]
    xor ah, ah
    cmp byte [op1 + O_TYPE], OT_IMM
    je .imm
    mov ah, [op1 + O_SIZE]
    jmp .compare
.imm:
    or al, al
    jnz .compare
    mov al, [op1 + O_IMMSZ]         ; mov [bx], word 5
.compare:
    or al, al
    jz .first_unknown
    or ah, ah
    jz .known
    cmp al, ah
    je .known
    pop ax
    mov si, m_size_mismatch
    jmp enc_error
.first_unknown:
    mov al, ah
    or al, al
    jnz .known
    pop ax
    mov si, m_size_unknown
    jmp enc_error
.known:
    mov [op_sz], al
    ret

; The size of a one-operand instruction (op0): returns only if it is known
need_size:
    cmp byte [op0 + O_SIZE], 0
    jne .known
    pop ax
    mov si, m_size_unknown
    jmp enc_error
.known:
    ret

; DX:AX BX = a value: CF = 1 (and an error) if it does not fit in a byte
check_byte:
    or bh, bh
    jnz .range_ok
    or dx, dx
    jz .positive
    cmp dx, 0FFFFh
    jne .out
    cmp ax, 0FF80h
    jae .range_ok
    jmp .out
.positive:
    cmp ax, 255
    jbe .range_ok
.out:
    call err_begin
    jc .fail
    mov si, m_value
    call puts
    call put_signed
    mov si, m_not_byte
    call puts
    call err_end
.fail:
    stc
    ret
.range_ok:
    or bl, bl
    jz .ok
    mov si, m_address_byte
    call error
    stc
    ret
.ok:
    clc
    ret

; DX:AX BX = a value: CF = 1 (and an error) if it does not fit in a word
check_word:
    or bh, bh
    jnz .ok
    or dx, dx
    jz .ok
    cmp dx, 0FFFFh
    jne .out
    cmp ax, 8000h
    jae .ok
.out:
    call err_begin
    jc .fail
    mov si, m_value
    call puts
    call put_signed
    mov si, m_not_word
    call puts
    call err_end
.fail:
    stc
    ret
.ok:
    clc
    ret

; DX:AX BX: CF = 0 if a word value can be a sign-extended byte
fits_simm8:
    or bl, bl
    jnz .no
    or bh, bh
    jnz .yes
    cmp ax, 7Fh
    jbe .yes
    cmp ax, 0FF80h
    jae .yes
.no:
    stc
    ret
.yes:
    clc
    ret

; The immediate of op1 into DX:AX BX
op1_imm:
    mov ax, [op1 + O_IMM + V_LO]
    mov dx, [op1 + O_IMM + V_HI]
    mov bx, [op1 + O_IMM + V_RELOC]
    ret

; The relative distance to op0's target from the end of an instruction
; that has CX more bytes: DX:AX = target - (address + enc_n + CX)
rel_target:
    mov ax, [op0 + O_IMM + V_LO]
    mov dx, [op0 + O_IMM + V_HI]
    add cx, [enc_n]
    sub ax, [addr_lo]
    sbb dx, [addr_hi]
    sub ax, cx
    sbb dx, 0
    ret

; DX:AX: CF = 0 if it is -128..127
fits_s8:
    cmp dx, 0
    je .positive
    cmp dx, 0FFFFh
    jne .no
    cmp ax, 0FF80h
    jae .yes
.no:
    stc
    ret
.positive:
    cmp ax, 7Fh
    ja .no
.yes:
    clc
    ret

; AL = opcode of a short jump to op0, SI = what it is, DI = the hint
encode_rel8:
    push ax
    mov cx, 2
    call rel_target
    mov [rel_lo], ax
    mov [rel_hi], dx
    pop ax
    call eb
    cmp byte [op0 + O_IMM + V_UNK], 0
    jne .emit
    mov ax, [rel_lo]
    mov dx, [rel_hi]
    call fits_s8
    jnc .emit
    call err_begin
    jc .emit
    call puts
    mov si, m_out_of_range
    call puts
    mov ax, [rel_lo]
    mov dx, [rel_hi]
    call put_signed
    mov si, m_limit
    call puts
    mov si, di
    call puts
    call err_end
.emit:
    mov al, [rel_lo]
    call eb
    jmp enc_ok

; ---------- the instructions ----------

do_simple:
    mov al, 0
    call need
    mov al, [m_cc]
    call eb
    jmp enc_ok

do_alu:
    mov al, 2
    call need
    mov al, [m_id]
    dec al
    mov cl, 3
    shl al, cl
    mov [alu_op], al                ; the /r field, shifted
    mov si, op0
    call is_rm
    jnc .rm
    jmp enc_bad
.rm:
    call two_memory
    cmp byte [op1 + O_TYPE], OT_SREG
    jne .not_sreg
    jmp enc_bad
.not_sreg:
    call op_size2
    cmp byte [op1 + O_TYPE], OT_IMM
    je .immediate
    jmp .registers
.immediate:
    call op1_imm
    cmp byte [op_sz], 1
    jne .word
    call check_byte
    jnc .byte_ok
    ret
.byte_ok:
    cmp byte [op1 + O_IMMSZ], 2
    jne .byte_size
    jmp enc_bad
.byte_size:
    mov [imm_val], ax
    cmp byte [op0 + O_TYPE], OT_REG8
    jne .byte_rm
    cmp byte [op0 + O_REG], 0
    jne .byte_rm
    mov al, [alu_op]                ; op al, imm8
    or al, 4
    call eb
    mov al, [imm_val]
    call eb
    jmp enc_ok
.byte_rm:
    mov si, op0
    call seg_prefix
    mov al, 80h
    call eb
    mov ah, [alu_op]
    call alu_modrm
    mov al, [imm_val]
    call eb
    jmp enc_ok
.word:
    call check_word
    jnc .word_ok
    ret
.word_ok:
    mov [imm_val], ax
    cmp byte [op1 + O_IMMSZ], 1
    jne .not_byte_size
    or bl, bl
    jnz .not_signed_byte
    or bh, bh
    jnz .not_byte_size
    call fits_simm8
    jnc .not_byte_size
.not_signed_byte:
    mov si, m_signed_byte
    jmp enc_error
.not_byte_size:
    test byte [sticky], 8
    jnz .long
    call fits_simm8
    jc .long
    mov si, op0                     ; op r/m16, simm8
    call seg_prefix
    mov al, 83h
    call eb
    mov ah, [alu_op]
    call alu_modrm
    mov al, [imm_val]
    call eb
    jmp enc_ok
.long:
    cmp byte [pass], STICKY_PASS
    jb .not_sticky
    or byte [sticky], 8
.not_sticky:
    cmp byte [op0 + O_TYPE], OT_REG16
    jne .word_rm
    cmp byte [op0 + O_REG], 0
    jne .word_rm
    mov al, [alu_op]                ; op ax, imm16
    or al, 5
    call eb
    mov ax, [imm_val]
    call ew
    jmp enc_ok
.word_rm:
    mov si, op0
    call seg_prefix
    mov al, 81h
    call eb
    mov ah, [alu_op]
    call alu_modrm
    mov ax, [imm_val]
    call ew
    jmp enc_ok
.registers:
    mov si, op1
    call is_reg
    jc .from_memory
    mov si, op0                     ; op r/m, reg
    call seg_prefix
    mov al, [alu_op]
    call or_word
    call eb
    mov ah, [op1 + O_REG]
    mov si, op0
    mov al, 2
    call modrm
    jmp enc_ok
.from_memory:
    cmp byte [op1 + O_TYPE], OT_MEM
    jne .bad
    mov si, op0
    call is_reg
    jc .bad
    mov si, op1                     ; op reg, r/m
    call seg_prefix
    mov al, [alu_op]
    or al, 2
    call or_word
    call eb
    mov ah, [op0 + O_REG]
    mov si, op1
    mov al, 4
    call modrm
    jmp enc_ok
.bad:
    jmp enc_bad

; AH = the reg field: ModRM for op0 (shifted /r in AH >> 3)
alu_modrm:
    mov cl, 3
    shr ah, cl
    mov si, op0
    mov al, 2
    jmp modrm

; AL |= 1 if the operation is on words
or_word:
    cmp byte [op_sz], 2
    jne .done
    or al, 1
.done:
    ret

do_mov:
    mov al, 2
    call need
    call two_memory
    cmp byte [op0 + O_TYPE], OT_SREG
    jne .not_to_sreg
    cmp byte [op0 + O_REG], 1
    jne .not_cs
    mov si, m_mov_cs
    jmp enc_error
.not_cs:
    cmp byte [op1 + O_TYPE], OT_IMM
    jne .not_imm_sreg
    call err_begin
    jc .fail
    mov si, m_mov_sreg_imm
    call puts
    mov bx, [op0 + O_REG]
    and bx, 3
    shl bx, 1
    mov si, [sreg_names + bx]
    call puts
    mov si, m_mov_sreg_imm_end
    call puts
    call err_end
.fail:
    stc
    ret
.not_imm_sreg:
    cmp byte [op1 + O_TYPE], OT_SREG
    jne .not_sreg_sreg
    mov si, m_mov_sreg_sreg
    jmp enc_error
.not_sreg_sreg:
    mov si, op1
    call byte_operand
    jnc .bad
    call seg_prefix
    mov al, 8Eh
    call eb
    mov ah, [op0 + O_REG]
    mov si, op1
    mov al, 4
    call modrm
    jmp enc_ok
.bad:
    jmp enc_bad
.not_to_sreg:
    cmp byte [op1 + O_TYPE], OT_SREG
    jne .not_from_sreg
    mov si, op0
    call byte_operand
    jnc .bad
    cmp byte [op0 + O_TYPE], OT_IMM
    je .bad
    call seg_prefix
    mov al, 8Ch
    call eb
    mov ah, [op1 + O_REG]
    mov si, op0
    mov al, 2
    call modrm
    jmp enc_ok
.not_from_sreg:
    mov si, op0
    call is_rm
    jc .bad
    call op_size2
    cmp byte [op1 + O_TYPE], OT_IMM
    jne .not_imm
    call op1_imm
    call check_size
    jnc .imm_ok
    ret
.imm_ok:
    mov [imm_val], ax
    mov si, op0
    call is_reg
    jc .imm_rm
    mov al, 0B0h                    ; mov reg, imm
    cmp byte [op_sz], 1
    je .imm_reg
    mov al, 0B8h
.imm_reg:
    add al, [op0 + O_REG]
    call eb
    jmp .imm
.imm_rm:
    call seg_prefix
    mov al, 0C6h
    call or_word
    call eb
    mov ah, 0
    mov si, op0
    mov al, 2
    call modrm
.imm:
    mov ax, [imm_val]
    cmp byte [op_sz], 1
    je .imm_byte
    call ew
    jmp enc_ok
.imm_byte:
    call eb
    jmp enc_ok
.not_imm:
    mov si, op0                     ; mov al/ax, [address]
    call is_reg
    jc .not_load
    cmp byte [op0 + O_REG], 0
    jne .not_load
    mov si, op1
    call direct
    jc .not_load
    call seg_prefix
    mov al, 0A0h
    call or_word
    call eb
    mov ax, [op1 + O_DISP]
    call ew
    jmp enc_ok
.not_load:
    mov si, op1                     ; mov [address], al/ax
    call is_reg
    jc .not_store
    cmp byte [op1 + O_REG], 0
    jne .not_store
    mov si, op0
    call direct
    jc .not_store
    call seg_prefix
    mov al, 0A2h
    call or_word
    call eb
    mov ax, [op0 + O_DISP]
    call ew
    jmp enc_ok
.not_store:
    mov si, op1
    call is_reg
    jc .not_reg_src
    mov si, op0                     ; mov r/m, reg
    call seg_prefix
    mov al, 88h
    call or_word
    call eb
    mov ah, [op1 + O_REG]
    mov si, op0
    mov al, 2
    call modrm
    jmp enc_ok
.not_reg_src:
    cmp byte [op1 + O_TYPE], OT_MEM
    jne .bad2
    mov si, op0
    call is_reg
    jc .bad2
    mov si, op1                     ; mov reg, r/m
    call seg_prefix
    mov al, 8Ah
    call or_word
    call eb
    mov ah, [op0 + O_REG]
    mov si, op1
    mov al, 4
    call modrm
    jmp enc_ok
.bad2:
    jmp enc_bad

; SI = operand: CF = 0 if it is an 8-bit register or byte memory
byte_operand:
    cmp byte [si + O_TYPE], OT_REG8
    je .yes
    cmp byte [si + O_TYPE], OT_MEM
    jne .no
    cmp byte [si + O_SIZE], 1
    je .yes
.no:
    stc
    ret
.yes:
    clc
    ret

; SI = operand: CF = 0 if it is memory with a plain [address]
direct:
    cmp byte [si + O_TYPE], OT_MEM
    jne .no
    cmp byte [si + O_BASE], 0FFh
    jne .no
    cmp byte [si + O_INDEX], 0FFh
    jne .no
    clc
    ret
.no:
    stc
    ret

; DX:AX BX checked against op_sz (byte or word)
check_size:
    cmp byte [op_sz], 1
    jne .word
    jmp check_byte
.word:
    jmp check_word

do_xchg:
    mov al, 2
    call need
    mov si, op0
    call is_rm
    jnc .skip3
    jmp .bad
.skip3:
    mov si, op1
    call is_rm
    jc .bad
    call two_memory
    call op_size2
    cmp byte [op_sz], 2
    jne .general
    cmp byte [op0 + O_TYPE], OT_REG16
    jne .general
    cmp byte [op1 + O_TYPE], OT_REG16
    jne .general
    mov al, [op1 + O_REG]
    cmp byte [op0 + O_REG], 0
    je .short
    mov al, [op0 + O_REG]
    cmp byte [op1 + O_REG], 0
    jne .general
.short:
    add al, 90h
    call eb
    jmp enc_ok
.general:
    mov si, op0
    call is_reg
    jc .memory_first
    mov si, op1
    call seg_prefix
    mov al, 86h
    call or_word
    call eb
    mov ah, [op0 + O_REG]
    mov si, op1
    mov al, 4
    call modrm
    jmp enc_ok
.memory_first:
    mov si, op0
    call seg_prefix
    mov al, 86h
    call or_word
    call eb
    mov ah, [op1 + O_REG]
    mov si, op0
    mov al, 2
    call modrm
    jmp enc_ok
.bad:
    jmp enc_bad

do_test:
    mov al, 2
    call need
    mov si, op0
    call is_rm
    jnc .skip2
    jmp .bad
.skip2:
    call two_memory
    call op_size2
    cmp byte [op1 + O_TYPE], OT_IMM
    jne .not_imm
    call op1_imm
    call check_size
    jnc .imm_ok
    ret
.imm_ok:
    mov [imm_val], ax
    mov si, op0
    call is_reg
    jc .imm_rm
    cmp byte [op0 + O_REG], 0
    jne .imm_rm
    mov al, 0A8h
    call or_word
    call eb
    jmp .imm
.imm_rm:
    mov si, op0
    call seg_prefix
    mov al, 0F6h
    call or_word
    call eb
    mov ah, 0
    mov si, op0
    mov al, 2
    call modrm
.imm:
    mov ax, [imm_val]
    cmp byte [op_sz], 1
    je .imm_byte
    call ew
    jmp enc_ok
.imm_byte:
    call eb
    jmp enc_ok
.not_imm:
    mov si, op1
    call is_rm
    jc .bad
    cmp byte [op1 + O_TYPE], OT_MEM
    jne .reg_src
    call seg_prefix
    mov al, 84h
    call or_word
    call eb
    mov ah, [op0 + O_REG]
    mov si, op1
    mov al, 4
    call modrm
    jmp enc_ok
.reg_src:
    mov si, op0
    call seg_prefix
    mov al, 84h
    call or_word
    call eb
    mov ah, [op1 + O_REG]
    mov si, op0
    mov al, 2
    call modrm
    jmp enc_ok
.bad:
    jmp enc_bad

do_lds:
    mov al, 2
    call need
    cmp byte [op0 + O_TYPE], OT_REG16
    jne .bad
    cmp byte [op1 + O_TYPE], OT_MEM
    jne .bad
    cmp byte [op1 + O_SIZE], 0
    je .ok
    mov si, m_lds_size
    jmp enc_error_fmt
.bad:
    mov si, m_lds
    jmp enc_error_fmt
.ok:
    mov si, op1
    call seg_prefix
    mov al, [m_cc]
    call eb
    mov ah, [op0 + O_REG]
    mov si, op1
    mov al, 4
    call modrm
    jmp enc_ok

do_lea:
    mov al, 2
    call need
    cmp byte [op0 + O_TYPE], OT_REG16
    jne .bad
    cmp byte [op1 + O_TYPE], OT_MEM
    je .ok
.bad:
    mov si, m_lea
    jmp enc_error
.ok:
    mov si, op1
    call seg_prefix
    mov al, 8Dh
    call eb
    mov ah, [op0 + O_REG]
    mov si, op1
    mov al, 4
    call modrm
    jmp enc_ok

do_incdec:
    mov al, 1
    call need
    cmp byte [op0 + O_TYPE], OT_REG16
    jne .rm
    mov al, 40h
    cmp byte [m_cc], 0
    je .short
    mov al, 48h
.short:
    add al, [op0 + O_REG]
    call eb
    jmp enc_ok
.rm:
    mov si, op0
    call is_rm
    jnc .size
    jmp enc_bad
.size:
    call need_size
    mov al, 0FEh
    jmp group_rm

; AL = opcode for bytes (+1 for words): op0 with /r = m_cc
group_rm:
    cmp byte [op0 + O_SIZE], 2
    jne .byte
    or al, 1
.byte:
    push ax
    mov si, op0
    call seg_prefix
    pop ax
    call eb
    mov ah, [m_cc]
    mov si, op0
    mov al, 2
    call modrm
    jmp enc_ok

do_group3:
    cmp byte [m_id], M_IMUL
    jne .one
    cmp byte [st_nops], 1
    jbe .one
    mov si, m_imul
    jmp enc_error
.one:
    mov al, 1
    call need
    mov si, op0
    call is_rm
    jnc .size
    jmp enc_bad
.size:
    call need_size
    mov al, 0F6h
    jmp group_rm

do_shift:
    mov al, 2
    call need
    mov si, op0
    call is_rm
    jnc .size
    jmp enc_bad
.size:
    call need_size
    mov al, 0D2h
    cmp byte [op1 + O_TYPE], OT_REG8
    jne .not_cl
    cmp byte [op1 + O_REG], 1
    je .opcode
.not_cl:
    mov al, 0D0h
    cmp byte [op1 + O_TYPE], OT_IMM
    jne .bad
    cmp byte [op1 + O_IMM + V_UNK], 0
    jne .unknown
    cmp byte [op1 + O_IMM + V_RELOC], 0
    jne .bad
    cmp word [op1 + O_IMM + V_HI], 0
    jne .bad
    cmp word [op1 + O_IMM + V_LO], 1
    je .opcode
    jmp .bad
.unknown:
    cmp byte [final], 0
    je .opcode
.bad:
    mov si, m_shift_count
    jmp enc_error
.opcode:
    jmp group_rm

do_pushpop:
    mov al, 1
    call need
    mov al, [op0 + O_TYPE]
    cmp al, OT_REG16
    jne .not_reg
    mov al, 50h
    cmp byte [m_id], M_POP
    jne .push_reg
    mov al, 58h
.push_reg:
    add al, [op0 + O_REG]
    call eb
    jmp enc_ok
.not_reg:
    cmp al, OT_SREG
    jne .not_sreg
    mov al, [op0 + O_REG]
    mov cl, 3
    shl al, cl
    or al, 6
    cmp byte [m_id], M_POP
    jne .push_sreg
    cmp byte [op0 + O_REG], 1
    jne .pop_sreg
    mov si, m_pop_cs
    jmp enc_error
.pop_sreg:
    inc al
.push_sreg:
    call eb
    jmp enc_ok
.not_sreg:
    mov si, op0
    call byte_operand
    jc .not_byte
    mov si, m_stack_words
    jmp enc_error
.not_byte:
    cmp byte [op0 + O_TYPE], OT_IMM
    jne .not_imm
    mov si, m_push_imm
    jmp enc_error
.not_imm:
    cmp byte [op0 + O_SIZE], 0
    jne .sized
    mov si, m_push_size
    jmp enc_error_fmt
.sized:
    mov si, op0
    call seg_prefix
    mov al, 0FFh
    mov ah, 6
    cmp byte [m_id], M_POP
    jne .push_rm
    mov al, 8Fh
    mov ah, 0
.push_rm:
    push ax
    call eb
    pop ax
    mov si, op0
    mov al, 2
    call modrm
    jmp enc_ok

do_jmpcall:
    mov al, 1
    call need
    cmp byte [op0 + O_FAR], 0
    je .not_far_imm
    mov al, [op0 + O_JMOD]
    cmp al, J_SHORT
    je .bad
    cmp al, J_NEAR
    je .bad
    cmp al, J_FAR
    jne .far_imm
    mov si, m_already_far
    jmp enc_error_fmt
.far_imm:
    mov ax, [op0 + O_FSEG + V_LO]
    mov dx, [op0 + O_FSEG + V_HI]
    mov bx, [op0 + O_FSEG + V_RELOC]
    call check_word
    jc .fail
    mov ax, [op0 + O_IMM + V_LO]
    mov dx, [op0 + O_IMM + V_HI]
    mov bx, [op0 + O_IMM + V_RELOC]
    call check_word
    jc .fail
    mov al, 0EAh
    cmp byte [m_id], M_CALL
    jne .far_opcode
    mov al, 9Ah
.far_opcode:
    call eb
    mov ax, [op0 + O_IMM + V_LO]
    call ew
    mov ax, [op0 + O_FSEG + V_LO]
    call ew
    jmp enc_ok
.fail:
    ret
.bad:
    jmp enc_bad
.not_far_imm:
    cmp byte [op0 + O_JMOD], J_FAR
    jne .not_far
    cmp byte [op0 + O_TYPE], OT_IMM
    jne .far_mem
    mov si, m_far_needs
    jmp enc_error_fmt
.far_mem:
    cmp byte [op0 + O_TYPE], OT_MEM
    jne .bad
    cmp byte [op0 + O_SIZE], 1
    je .bad
    mov ah, 5
    cmp byte [m_id], M_CALL
    je .skip1
    jmp .indirect
.skip1:
    mov ah, 3
    jmp .indirect
.not_far:
    cmp byte [op0 + O_TYPE], OT_IMM
    jne .not_imm
    cmp byte [m_id], M_CALL
    jne .jmp
    cmp byte [op0 + O_JMOD], J_SHORT
    jne .call
    mov si, m_call_short
    jmp enc_error
.call:
    mov al, 0E8h
    call eb
    mov cx, 2
    call rel_target
    call ew
    jmp enc_ok
.jmp:
    mov al, [op0 + O_JMOD]
    cmp al, J_SHORT
    je .short
    cmp al, J_NEAR
    je .near
    test byte [sticky], 1
    jnz .near
    cmp byte [op0 + O_IMM + V_UNK], 0
    jne .short
    mov cx, 2
    call rel_target
    call fits_s8
    jc .near
.short:
    mov al, 0EBh
    mov si, m_short_jump
    mov di, m_short_hint
    jmp encode_rel8
.near:
    cmp byte [op0 + O_JMOD], J_DEFAULT
    jne .near_emit
    cmp byte [pass], STICKY_PASS
    jb .near_emit
    or byte [sticky], 1
.near_emit:
    mov al, 0E9h
    call eb
    mov cx, 2
    call rel_target
    call ew
    jmp enc_ok
.not_imm:
    mov al, [op0 + O_TYPE]
    cmp al, OT_REG8
    je .bad2
    cmp al, OT_SREG
    je .bad2
    mov si, op0
    call byte_operand
    jnc .bad2
    cmp byte [op0 + O_JMOD], J_SHORT
    je .bad2
    mov ah, 4
    cmp byte [m_id], M_CALL
    jne .indirect
    mov ah, 2
.indirect:
    push ax
    mov si, op0
    call seg_prefix
    mov al, 0FFh
    call eb
    pop ax
    mov si, op0
    mov al, 2
    call modrm
    jmp enc_ok
.bad2:
    jmp enc_bad

do_jcc:
    mov al, 1
    call need
    cmp byte [op0 + O_TYPE], OT_IMM
    je .imm
    mov si, m_jcc_label
    jmp enc_error
.imm:
    cmp byte [op0 + O_JMOD], J_NEAR
    jne .short
    ; NEAR: the short jump when the target is close, else the opposite
    ; condition over a near JMP (the 8086 has only short ones)
    test byte [sticky], 1
    jnz .long
    cmp byte [op0 + O_IMM + V_UNK], 0
    jne .short
    mov cx, 2
    call rel_target
    call fits_s8
    jc .long
.short:
    mov al, [m_cc]
    add al, 70h
    mov si, m_cond_jump
    mov di, m_cond_hint
    jmp encode_rel8
.long:
    cmp byte [pass], STICKY_PASS
    jb .long_emit
    or byte [sticky], 1
.long_emit:
    mov al, [m_cc]
    xor al, 1
    add al, 70h
    call eb
    mov al, 3
    call eb
    mov al, 0E9h
    call eb
    mov cx, 2
    call rel_target
    call ew
    jmp enc_ok

do_loop:
    mov al, 1
    call need
    cmp byte [op0 + O_TYPE], OT_IMM
    jne .bad
    cmp byte [op0 + O_JMOD], J_NEAR
    je .bad
    mov al, [m_id]
    sub al, M_LOOP                  ; LOOP E2, LOOPE E1, LOOPNE E0, JCXZ E3
    mov bl, al
    xor bh, bh
    mov al, [loop_opcodes + bx]
    mov si, m_loop_jump
    mov di, m_loop_hint
    jmp encode_rel8
.bad:
    jmp enc_bad

loop_opcodes db 0E2h, 0E1h, 0E0h, 0E3h

do_ret:
    cmp byte [st_nops], 0
    jne .operand
    call .opcode
    call eb
    jmp enc_ok
.operand:
    mov al, 1
    call need
    cmp byte [op0 + O_TYPE], OT_IMM
    jne .bad
    mov ax, [op0 + O_IMM + V_LO]
    mov dx, [op0 + O_IMM + V_HI]
    mov bx, [op0 + O_IMM + V_RELOC]
    call check_word
    jc .bad
    call .opcode
    dec al                          ; C2 / CA
    call eb
    mov ax, [op0 + O_IMM + V_LO]
    call ew
    jmp enc_ok
.bad:
    jmp enc_bad
.opcode:                            ; AL = C3 (RET) or CB (RETF)
    mov al, 0C3h
    cmp byte [m_id], M_RET
    je .near
    mov al, 0CBh
.near:
    ret

do_iret:
    mov al, 0
    call need
    mov al, 0CFh
    call eb
    jmp enc_ok

do_int3:
    mov al, 0
    call need
    mov al, 0CCh
    call eb
    jmp enc_ok

do_int:
    mov al, 1
    call need
    cmp byte [op0 + O_TYPE], OT_IMM
    jne .bad
    cmp byte [op0 + O_IMM + V_UNK], 0
    jne .ok
    cmp word [op0 + O_IMM + V_HI], 0
    jne .range
    cmp word [op0 + O_IMM + V_LO], 255
    jbe .ok
.range:
    mov si, m_int_range
    jmp enc_error
.ok:
    mov al, 0CDh
    call eb
    mov al, [op0 + O_IMM + V_LO]
    call eb
    jmp enc_ok
.bad:
    jmp enc_bad

do_inout:
    mov al, 2
    call need
    mov si, op0                     ; the accumulator and the port
    mov di, op1
    cmp byte [m_id], M_IN
    je .order
    xchg si, di
.order:
    call is_reg
    jc .not_acc
    cmp byte [si + O_REG], 0
    je .acc
.not_acc:
    mov si, m_inout_acc
    jmp enc_error_fmt
.acc:
    xor ah, ah                      ; AH = 1 for AX
    cmp byte [si + O_TYPE], OT_REG16
    jne .width
    inc ah
.width:
    cmp byte [di + O_TYPE], OT_REG16
    jne .not_dx
    cmp byte [di + O_REG], 2
    jne .not_dx
    mov al, 0ECh
    cmp byte [m_id], M_IN
    je .dx
    mov al, 0EEh
.dx:
    or al, ah
    call eb
    jmp enc_ok
.not_dx:
    cmp byte [di + O_TYPE], OT_IMM
    jne .bad_port
    cmp byte [di + O_IMM + V_UNK], 0
    jne .port_ok
    cmp word [di + O_IMM + V_HI], 0
    jne .port_range
    cmp word [di + O_IMM + V_LO], 255
    jbe .port_ok
.port_range:
    mov si, m_port_range
    jmp enc_error_fmt
.port_ok:
    mov al, 0E4h
    cmp byte [m_id], M_IN
    je .port
    mov al, 0E6h
.port:
    or al, ah
    call eb
    mov al, [di + O_IMM + V_LO]
    call eb
    jmp enc_ok
.bad_port:
    mov si, m_port
    jmp enc_error

; ======================================================================
; The output file
; ======================================================================

write_output:
    mov dx, out_name
    xor cx, cx
    mov ah, 3Ch
    int 21h
    jc .error
    mov bx, ax
    xor dx, dx
    mov cx, [out_len]
    cmp word [out_len + 2], 0
    je .write
    mov cx, 8000h                   ; 64 KB: two halves
    call .part
    mov dx, 8000h
.write:
    call .part
    mov ah, 3Eh
    int 21h
    jc .error
    ret
.part:                              ; CX bytes from out_seg:DX
    push cx
    push ds
    mov ds, [out_seg]
    mov ah, 40h
    int 21h
    pop ds
    pop cx
    jc .write_error
    cmp ax, cx
    jne .write_error
    ret
.write_error:
    pop ax
    mov ah, 3Eh
    int 21h
    mov dx, out_name                ; do not leave half a file
    mov ah, 41h
    int 21h
.error:
    mov si, m_cannot_write
    mov di, out_name
    jmp fatal_name

; ======================================================================
; Data
; ======================================================================

m_usage         db 'Usage: ASM source[.ASM] [output]', 0
m_asm           db 'ASM: ', 0
m_memory        db 'not enough memory', 0
m_cannot_open   db 'cannot open ', 0
m_nothing       db 0
m_cannot_write  db 'cannot write ', 0
m_read_error    db 'cannot read the source', 0
m_many_lines    db 'too many lines', 0
m_long_line     db 'line too long', 0
m_colon         db ': ', 0
m_line_end      db '): ', 0
m_bytes         db ' bytes', 0
m_errors        db ' errors', 0
m_error         db ' error', 0
m_quote_open    db ": '", 0
m_shl           db '<<', 0
m_shr           db '>>', 0
m_sdiv          db '//', 0
m_smod          db '%%', 0
m_dollar2       db '$$', 0
m_ext_asm       db '.ASM', 0
m_ext_com       db '.COM', 0

m_many_tokens   db 'too many tokens on the line', 0
m_bad_hex       db 'invalid hexadecimal number', 0
m_bad_number    db 'invalid number', 0
m_unterminated  db 'unterminated string (missing ', 0
m_long_string   db 'string too long (255 characters at most)', 0
m_backquote     db 'backquote strings are not supported; use single or double quotes', 0
m_unexpected_char db 'unexpected character: ', 0
m_long_name     db 'label name too long', 0

m_circular      db 'could not resolve addresses (circular references)', 0
m_unstable      db 'addresses did not stabilize; check expressions that depend on their own size', 0
m_too_big       db 'the program does not fit in a 64 KB segment', 0
m_org_number    db 'ORG needs a number', 0
m_org_late      db 'ORG must come before any code', 0
m_org_once      db 'only one ORG is allowed', 0
m_org_range     db 'ORG out of range', 0
m_defined_on    db "' is already defined on line ", 0
m_unknown_instr db 'unknown instruction: ', 0
m_expected_instr db 'expected an instruction or a label', 0
m_unsupported   db 'instruction not supported on this machine: ', 0
m_later_cpu     db ' does not exist on the 8086 (it is from a later CPU)', 0
m_times_twice   db 'repeated TIMES', 0
m_times_count   db 'TIMES needs a count', 0
m_times_directive db 'TIMES cannot be used with this directive', 0
m_rep_alone     db 'REP must be followed by a string instruction', 0
m_equ_name      db 'EQU needs a name in front: WIDTH equ 320', 0
m_bits          db 'this machine only has 16-bit mode (bits 16)', 0
m_cpu           db 'this machine is an 8086 (cpu 8086)', 0
m_other_data    db "' is not supported; use db/dw (bytes and words)", 0
m_section_name  db 'SECTION needs a name: .text, .data or .bss', 0
m_section_other db 'only the .text, .data and .bss sections are supported, not ', 0
m_section_attr  db 'section attributes (align=, start=, vstart=...) are not supported', 0
m_bss_only      db 'only RESB and RESW go in .bss (it takes no room in the file)', 0
m_org_text      db 'ORG goes in the .text section', 0
m_many_operands db 'too many operands', 0
m_missing_operand db 'missing operand', 0
m_db_empty      db 'db needs at least one value', 0
m_dw_empty      db 'dw needs at least one value', 0
m_between_commas db 'missing value between commas', 0
m_trailing_comma db 'trailing comma', 0
m_times         db 'TIMES', 0
m_resb          db 'RESB', 0
m_resw          db 'RESW', 0
m_count_address db ' needs a number, not an address (try $-$$)', 0
m_count_negative db ' cannot be negative (', 0
m_count_large   db ' too large (', 0

m_unexpected_text db 'unexpected text after expression', 0
m_missing_value db 'missing value in expression', 0
m_undefined     db 'undefined symbol: ', 0
m_bad_char      db 'invalid character constant', 0
m_missing_paren db "missing ')'", 0
m_register_here db 'a register cannot be used here', 0
m_register_32   db '32-bit register: the 8086 only has 8- and 16-bit registers', 0
m_expected_value db 'expected a value', 0
m_div_zero      db 'division by zero', 0

m_byte_word     db 'the 8086 only has BYTE and WORD operands', 0
m_ptr           db "PTR is MASM syntax; in NASM write e.g. 'word [bx]'", 0
m_bracket       db "missing ']' or unexpected text after ']'", 0
m_size_register db 'the size given does not match register ', 0
m_seg_inside    db 'the segment goes inside the brackets: [', 0
m_seg_inside_end db ':...]', 0
m_far_offset    db "missing offset after ':'", 0
m_not_segment   db "' is not a segment register", 0
m_empty_address db 'empty memory address', 0
m_missing_term  db 'missing term in address', 0
m_reg_subtract  db 'a register cannot be subtracted in an address', 0
m_reg_combination db 'invalid register combination on the 8086 (only BX/BP + SI/DI)', 0
m_address_regs  db 'the 8086 can only address memory through BX, BP, SI and DI (not ', 0

m_rep_string    db 'REP can only be used with string instructions (MOVSB, STOSB...)', 0
m_far_jmp       db 'FAR and segment:offset can only be used on JMP and CALL', 0
m_short_jumps   db 'SHORT/NEAR can only be used on jumps', 0
m_bad_operands  db 'invalid combination of operands for %', 0
m_takes         db ' takes ', 0
m_operand       db ' operand', 0
m_two_memory    db 'two memory operands are not allowed', 0
m_size_mismatch db 'operand sizes do not match', 0
m_size_unknown  db "operation size not specified: use 'byte [...]' or 'word [...]'", 0
m_value         db 'value ', 0
m_not_byte      db ' does not fit in a byte (-128..255)', 0
m_not_word      db ' does not fit in a word (-32768..65535)', 0
m_address_byte  db 'an address does not fit in a byte', 0
m_signed_byte   db 'value does not fit in a signed byte', 0
m_out_of_range  db ' out of range: target is ', 0
m_limit         db ' bytes away and the limit is -128..127', 0
m_short_jump    db 'short jump', 0
m_short_hint    db ' (remove SHORT to allow a near jump)', 0
m_cond_jump     db 'conditional jump', 0
m_cond_hint     db '. To go further, write NEAR (je near label)', 0
m_loop_jump     db 'loop jump', 0
m_loop_hint     db '. For longer loops use dec cx / jnz with a JMP', 0
m_mov_cs        db 'CS cannot be written with MOV; on the 8086 it changes with a far jump', 0
m_mov_sreg_imm  db 'the 8086 cannot load an immediate into a segment register; go through a register (mov ax, value / mov ', 0
m_mov_sreg_imm_end db ', ax)', 0
m_mov_sreg_sreg db 'cannot copy between segment registers; use an intermediate register', 0
m_lds           db '% takes a 16-bit register and a far pointer in memory: % si, [label]', 0
m_lds_size      db '% takes the address without a size: % si, [label]', 0
m_lea           db 'LEA takes a 16-bit register and an address: lea si, [label]', 0
m_imul          db "IMUL with more than one operand is 80186+; on the 8086 use 'imul source' (result in AX or DX:AX)", 0
m_shift_count   db 'the 8086 can only shift by 1 or by CL (e.g. mov cl, 4 / shl ax, cl)', 0
m_pop_cs        db 'POP CS does not exist; CS changes with a far jump', 0
m_stack_words   db 'the 8086 stack only holds 16-bit words', 0
m_push_imm      db 'PUSH with an immediate is 80186+; on the 8086: mov ax, value / push ax', 0
m_push_size     db 'operation size not specified: % word [...]', 0
m_already_far   db 'segment:offset is already far; write it without FAR: % 0000h:7C00h', 0
m_far_needs     db 'a far % needs segment:offset (% 0000h:7C00h) or a pointer in memory (% far [bx])', 0
m_call_short    db 'CALL has no SHORT form', 0
m_jcc_label     db 'conditional jumps only accept a label as target', 0
m_int_range     db 'interrupt number must be 0..255', 0
m_inout_acc     db '% only works with AL or AX', 0
m_port_range    db 'direct port numbers are 0..255; for higher ports use DX (mov dx, port / % ...)', 0
m_port          db 'port must be a number (0..255) or DX', 0

sreg_names      dw s_es, s_cs, s_ss, s_ds
s_es            db 'es', 0
s_cs            db 'cs', 0
s_ss            db 'ss', 0
s_ds            db 'ds', 0

punct_chars     db ',[]:()+-*/%|^&~!='
punct_chars_end:

; ---------- variables ----------

sym_seg         dw 0                ; segments: name hash, output, tokens
out_seg         dw 0
ir_seg          dw 0
ir_limit        dw 0                ; the tokens must stay below it
name_top        dw 0                ; the last name made, top of memory first
hash_slot       dw 0
namelen         dw 0
src_handle      dw 0
err_count       dw 0
last_err_line   dw 0
msg_len         dw 0

buf_len         dw 0                ; the source buffer
buf_pos         dw 0
src_eof         db 0
total_lines     dw 0
ir_cur_seg      dw 0                ; where pass 1 writes the next line
ir_cur_off      dw 0
line_end        dw 0
lex_err         db 0
tok_start       dw 0
span_end        dw 0
num_lo          dw 0
num_hi          dw 0
lex_msg_len     dw 0
raw_end         dw 0
last_global     dw 0                ; the last label without a dot

pass            db 0
final           db 0                ; the last pass: bytes and errors
stable          db 0
changed         db 0
abort           db 0
quiet           db 0                ; no errors (looking ahead)
stmt_failed     db 0
org_val         dw 0
org_set         dw 0                ; the line of the ORG
addr_lo         dw 0                ; the current address
addr_hi         dw 0
prev_end        dw 0, 0
cur_sec         db 0                ; SEC_TEXT, SEC_DATA, SEC_BSS
sec_base        dw 0, 0, 0, 0, 0, 0 ; where each section starts (dwords)
sec_addr        dw 0, 0, 0, 0, 0, 0 ; how far each has got in this pass
sec_size        dw 0, 0, 0, 0, 0, 0 ; their sizes in the last pass
wpos            dw 0, 0             ; where the next byte goes
out_len         dw 0, 0
cur_line        dw 0
rd_seg          dw 0                ; where the passes read the next line
rd_off          dw 0
st_seg          dw 0                ; the sticky byte of the line
st_off          dw 0
sticky          db 0                ; 1 long jump, 2/4 long displacement,
sticky_old      db 0                ; 8 long immediate
line_err        db 0
err_text        dw 0
tk_end          dw 0

line_start      dw 0, 0             ; $
st_start        dw 0, 0
st_label        dw 0                ; the statement: label token or 0
st_kind         db 0
st_section      db 0
st_times_beg    dw 0
st_times_end    dw 0
st_rep          db 0
st_mnem         dw 0
st_args_beg     dw 0
st_args_end     dw 0
st_nops         db 0
st_op_beg       dw 0, 0, 0
st_op_end       dw 0, 0, 0
def_label       db 0
reps            dw 0, 0
data_size       dw 0
item_end        dw 0
data_bytes      dw 0

ex_pos          dw 0                ; expressions
ex_end          dw 0
ex_err          db 0
char_val        dw 0, 0
b_lo            dw 0
b_hi            dw 0
b_rb            dw 0
r_lo            dw 0
r_hi            dw 0

opnd_end        dw 0                ; operands and encoding
term_beg        dw 0
enc_n           dw 0
enc_opnd        db 0
m_id            db 0
m_cc            db 0
mr_bit          db 0
op_sz           db 0
imm_val         dw 0
rel_lo          dw 0
rel_hi          dw 0
alu_op          db 0

src_name        times 80 db 0
out_name        times 80 db 0
numbuf          times 12 db 0
numbuf_end      db 0

; ---------- keywords ----------

; length, name, class, a, b, flags (see C_*, KF_*)
keywords:
    db 2, 'al', C_REG8, 0, 0, 0
    db 2, 'cl', C_REG8, 1, 0, 0
    db 2, 'dl', C_REG8, 2, 0, 0
    db 2, 'bl', C_REG8, 3, 0, 0
    db 2, 'ah', C_REG8, 4, 0, 0
    db 2, 'ch', C_REG8, 5, 0, 0
    db 2, 'dh', C_REG8, 6, 0, 0
    db 2, 'bh', C_REG8, 7, 0, 0
    db 2, 'ax', C_REG16, 0, 0, 0
    db 2, 'cx', C_REG16, 1, 0, 0
    db 2, 'dx', C_REG16, 2, 0, 0
    db 2, 'bx', C_REG16, 3, 0, 0
    db 2, 'sp', C_REG16, 4, 0, 0
    db 2, 'bp', C_REG16, 5, 0, 0
    db 2, 'si', C_REG16, 6, 0, 0
    db 2, 'di', C_REG16, 7, 0, 0
    db 2, 'es', C_SREG, 0, 0, 0
    db 2, 'cs', C_SREG, 1, 0, 0
    db 2, 'ss', C_SREG, 2, 0, 0
    db 2, 'ds', C_SREG, 3, 0, 0
    db 3, 'eax', C_REG32, 0, 0, 0
    db 3, 'ebx', C_REG32, 0, 0, 0
    db 3, 'ecx', C_REG32, 0, 0, 0
    db 3, 'edx', C_REG32, 0, 0, 0
    db 3, 'esi', C_REG32, 0, 0, 0
    db 3, 'edi', C_REG32, 0, 0, 0
    db 3, 'ebp', C_REG32, 0, 0, 0
    db 3, 'esp', C_REG32, 0, 0, 0
    db 2, 'fs', C_REG32, 0, 0, 0
    db 2, 'gs', C_REG32, 0, 0, 0
    db 4, 'byte', C_SIZE, 1, 0, 0
    db 4, 'word', C_SIZE, 2, 0, 0
    db 5, 'dword', C_SIZE, 3, 0, 0
    db 5, 'qword', C_SIZE, 3, 0, 0
    db 5, 'tword', C_SIZE, 3, 0, 0
    db 5, 'short', C_JMOD, J_SHORT, 0, 0
    db 4, 'near', C_JMOD, J_NEAR, 0, 0
    db 3, 'far', C_JMOD, J_FAR, 0, 0
    db 6, 'strict', C_STRICT, 0, 0, 0
    db 3, 'ptr', C_PTR, 0, 0, 0
    db 2, 'db', C_DIR, D_DB, 0, KF_KEYWORD
    db 2, 'dw', C_DIR, D_DW, 0, KF_KEYWORD
    db 4, 'resb', C_DIR, D_RESB, 0, KF_KEYWORD
    db 4, 'resw', C_DIR, D_RESW, 0, KF_KEYWORD
    db 3, 'equ', C_DIR, D_EQU, 0, KF_KEYWORD
    db 5, 'times', C_DIR, D_TIMES, 0, KF_KEYWORD
    db 3, 'org', C_DIR, D_ORG, 0, KF_KEYWORD
    db 4, 'bits', C_DIR, D_BITS, 0, KF_KEYWORD
    db 3, 'cpu', C_DIR, D_CPU, 0, KF_KEYWORD
    db 3, 'rep', C_DIR, D_REP, 0, KF_KEYWORD
    db 4, 'repe', C_DIR, D_REP, 0, KF_KEYWORD
    db 4, 'repz', C_DIR, D_REP, 0, KF_KEYWORD
    db 5, 'repne', C_DIR, D_REPNE, 0, KF_KEYWORD
    db 5, 'repnz', C_DIR, D_REPNE, 0, KF_KEYWORD
    db 2, 'dd', C_DIR, D_OTHER, 0, KF_KEYWORD
    db 2, 'dq', C_DIR, D_OTHER, 0, KF_KEYWORD
    db 2, 'dt', C_DIR, D_OTHER, 0, KF_KEYWORD
    db 4, 'resd', C_DIR, D_OTHER, 0, KF_KEYWORD
    db 4, 'resq', C_DIR, D_OTHER, 0, KF_KEYWORD
    db 7, 'section', C_DIR, D_SECTION, 0, KF_KEYWORD
    db 7, 'segment', C_DIR, D_SECTION, 0, KF_KEYWORD
    db 3, 'daa', C_UNSUP, 0, 0, KF_KEYWORD
    db 3, 'das', C_UNSUP, 0, 0, KF_KEYWORD
    db 3, 'aaa', C_UNSUP, 0, 0, KF_KEYWORD
    db 3, 'aas', C_UNSUP, 0, 0, KF_KEYWORD
    db 3, 'aam', C_UNSUP, 0, 0, KF_KEYWORD
    db 3, 'aad', C_UNSUP, 0, 0, KF_KEYWORD
    db 4, 'xlat', C_UNSUP, 0, 0, KF_KEYWORD
    db 5, 'xlatb', C_UNSUP, 0, 0, KF_KEYWORD
    db 4, 'lock', C_UNSUP, 0, 0, KF_KEYWORD
    db 4, 'wait', C_UNSUP, 0, 0, KF_KEYWORD
    db 5, 'fwait', C_UNSUP, 0, 0, KF_KEYWORD
    db 3, 'esc', C_UNSUP, 0, 0, KF_KEYWORD
    db 4, 'into', C_UNSUP, 0, 0, KF_KEYWORD
    db 4, 'salc', C_UNSUP, 0, 0, KF_KEYWORD
    db 5, 'pusha', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'popa', C_LATER, 0, 0, KF_KEYWORD
    db 6, 'pushaw', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'popaw', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'enter', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'leave', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'bound', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'ins', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'insb', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'insw', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'outs', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'outsb', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'outsw', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'movsx', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'movzx', C_LATER, 0, 0, KF_KEYWORD
    db 6, 'pushad', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'popad', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'cwde', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'cdq', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'lfs', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'lgs', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'lss', C_LATER, 0, 0, KF_KEYWORD
    db 2, 'bt', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'bts', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'btr', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'btc', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'bsf', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'bsr', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'shld', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'shrd', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'seto', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'setno', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'setb', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'setc', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'setnc', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'setae', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'setz', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'sete', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'setnz', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'setne', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'jecxz', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'movsd', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'stosd', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'lodsd', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'scasd', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'cmpsd', C_LATER, 0, 0, KF_KEYWORD
    db 6, 'pushfd', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'popfd', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'iretd', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'cmov', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'cmove', C_LATER, 0, 0, KF_KEYWORD
    db 6, 'cmovne', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'cmovz', C_LATER, 0, 0, KF_KEYWORD
    db 6, 'cmovnz', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'bswap', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'xadd', C_LATER, 0, 0, KF_KEYWORD
    db 7, 'cmpxchg', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'cpuid', C_LATER, 0, 0, KF_KEYWORD
    db 5, 'rdtsc', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'arpl', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'sldt', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'str', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'lgdt', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'lidt', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'smsw', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'lmsw', C_LATER, 0, 0, KF_KEYWORD
    db 4, 'clts', C_LATER, 0, 0, KF_KEYWORD
    db 7, 'syscall', C_LATER, 0, 0, KF_KEYWORD
    db 3, 'add', C_MNEM, M_ADD, 0, KF_KEYWORD
    db 2, 'or', C_MNEM, M_OR, 1, KF_KEYWORD
    db 3, 'adc', C_MNEM, M_ADC, 2, KF_KEYWORD
    db 3, 'sbb', C_MNEM, M_SBB, 3, KF_KEYWORD
    db 3, 'and', C_MNEM, M_AND, 4, KF_KEYWORD
    db 3, 'sub', C_MNEM, M_SUB, 5, KF_KEYWORD
    db 3, 'xor', C_MNEM, M_XOR, 6, KF_KEYWORD
    db 3, 'cmp', C_MNEM, M_CMP, 7, KF_KEYWORD
    db 3, 'mov', C_MNEM, M_MOV, 0, KF_KEYWORD
    db 4, 'xchg', C_MNEM, M_XCHG, 0, KF_KEYWORD
    db 4, 'test', C_MNEM, M_TEST, 0, KF_KEYWORD
    db 3, 'lea', C_MNEM, M_LEA, 0, KF_KEYWORD
    db 3, 'lds', C_MNEM, M_LDS, 0C5h, KF_KEYWORD
    db 3, 'les', C_MNEM, M_LDS, 0C4h, KF_KEYWORD
    db 3, 'inc', C_MNEM, M_INC, 0, KF_KEYWORD
    db 3, 'dec', C_MNEM, M_DEC, 1, KF_KEYWORD
    db 3, 'not', C_MNEM, M_NOT, 2, KF_KEYWORD
    db 3, 'neg', C_MNEM, M_NEG, 3, KF_KEYWORD
    db 3, 'mul', C_MNEM, M_MUL, 4, KF_KEYWORD
    db 4, 'imul', C_MNEM, M_IMUL, 5, KF_KEYWORD
    db 3, 'div', C_MNEM, M_DIV, 6, KF_KEYWORD
    db 4, 'idiv', C_MNEM, M_IDIV, 7, KF_KEYWORD
    db 3, 'rol', C_MNEM, M_ROL, 0, KF_KEYWORD
    db 3, 'ror', C_MNEM, M_ROR, 1, KF_KEYWORD
    db 3, 'rcl', C_MNEM, M_RCL, 2, KF_KEYWORD
    db 3, 'rcr', C_MNEM, M_RCR, 3, KF_KEYWORD
    db 3, 'shl', C_MNEM, M_SHL, 4, KF_KEYWORD
    db 3, 'sal', C_MNEM, M_SHL, 4, KF_KEYWORD
    db 3, 'shr', C_MNEM, M_SHR, 5, KF_KEYWORD
    db 3, 'sar', C_MNEM, M_SAR, 7, KF_KEYWORD
    db 4, 'push', C_MNEM, M_PUSH, 0, KF_KEYWORD
    db 3, 'pop', C_MNEM, M_POP, 0, KF_KEYWORD
    db 3, 'jmp', C_MNEM, M_JMP, 0, KF_KEYWORD
    db 4, 'call', C_MNEM, M_CALL, 0, KF_KEYWORD
    db 3, 'ret', C_MNEM, M_RET, 0, KF_KEYWORD
    db 4, 'retn', C_MNEM, M_RET, 0, KF_KEYWORD
    db 4, 'retf', C_MNEM, M_RETF, 0, KF_KEYWORD
    db 4, 'iret', C_MNEM, M_IRET, 0, KF_KEYWORD
    db 3, 'int', C_MNEM, M_INT, 0, KF_KEYWORD
    db 4, 'int3', C_MNEM, M_INT3, 0, KF_KEYWORD
    db 2, 'jo', C_MNEM, M_JCC, 0, KF_KEYWORD
    db 3, 'jno', C_MNEM, M_JCC, 1, KF_KEYWORD
    db 2, 'jb', C_MNEM, M_JCC, 2, KF_KEYWORD
    db 2, 'jc', C_MNEM, M_JCC, 2, KF_KEYWORD
    db 4, 'jnae', C_MNEM, M_JCC, 2, KF_KEYWORD
    db 3, 'jae', C_MNEM, M_JCC, 3, KF_KEYWORD
    db 3, 'jnb', C_MNEM, M_JCC, 3, KF_KEYWORD
    db 3, 'jnc', C_MNEM, M_JCC, 3, KF_KEYWORD
    db 2, 'je', C_MNEM, M_JCC, 4, KF_KEYWORD
    db 2, 'jz', C_MNEM, M_JCC, 4, KF_KEYWORD
    db 3, 'jne', C_MNEM, M_JCC, 5, KF_KEYWORD
    db 3, 'jnz', C_MNEM, M_JCC, 5, KF_KEYWORD
    db 3, 'jbe', C_MNEM, M_JCC, 6, KF_KEYWORD
    db 3, 'jna', C_MNEM, M_JCC, 6, KF_KEYWORD
    db 2, 'ja', C_MNEM, M_JCC, 7, KF_KEYWORD
    db 4, 'jnbe', C_MNEM, M_JCC, 7, KF_KEYWORD
    db 2, 'js', C_MNEM, M_JCC, 8, KF_KEYWORD
    db 3, 'jns', C_MNEM, M_JCC, 9, KF_KEYWORD
    db 2, 'jp', C_MNEM, M_JCC, 10, KF_KEYWORD
    db 3, 'jpe', C_MNEM, M_JCC, 10, KF_KEYWORD
    db 3, 'jnp', C_MNEM, M_JCC, 11, KF_KEYWORD
    db 3, 'jpo', C_MNEM, M_JCC, 11, KF_KEYWORD
    db 2, 'jl', C_MNEM, M_JCC, 12, KF_KEYWORD
    db 4, 'jnge', C_MNEM, M_JCC, 12, KF_KEYWORD
    db 3, 'jge', C_MNEM, M_JCC, 13, KF_KEYWORD
    db 3, 'jnl', C_MNEM, M_JCC, 13, KF_KEYWORD
    db 3, 'jle', C_MNEM, M_JCC, 14, KF_KEYWORD
    db 3, 'jng', C_MNEM, M_JCC, 14, KF_KEYWORD
    db 2, 'jg', C_MNEM, M_JCC, 15, KF_KEYWORD
    db 4, 'jnle', C_MNEM, M_JCC, 15, KF_KEYWORD
    db 4, 'loop', C_MNEM, M_LOOP, 0, KF_KEYWORD
    db 5, 'loope', C_MNEM, M_LOOPE, 0, KF_KEYWORD
    db 5, 'loopz', C_MNEM, M_LOOPE, 0, KF_KEYWORD
    db 6, 'loopne', C_MNEM, M_LOOPNE, 0, KF_KEYWORD
    db 6, 'loopnz', C_MNEM, M_LOOPNE, 0, KF_KEYWORD
    db 4, 'jcxz', C_MNEM, M_JCXZ, 0, KF_KEYWORD
    db 2, 'in', C_MNEM, M_IN, 0, KF_KEYWORD
    db 3, 'out', C_MNEM, M_OUT, 0, KF_KEYWORD
    db 5, 'movsb', C_MNEM, M_SIMPLE, 0A4h, KF_KEYWORD | KF_STRING
    db 5, 'movsw', C_MNEM, M_SIMPLE, 0A5h, KF_KEYWORD | KF_STRING
    db 5, 'cmpsb', C_MNEM, M_SIMPLE, 0A6h, KF_KEYWORD | KF_STRING
    db 5, 'cmpsw', C_MNEM, M_SIMPLE, 0A7h, KF_KEYWORD | KF_STRING
    db 5, 'stosb', C_MNEM, M_SIMPLE, 0AAh, KF_KEYWORD | KF_STRING
    db 5, 'stosw', C_MNEM, M_SIMPLE, 0ABh, KF_KEYWORD | KF_STRING
    db 5, 'lodsb', C_MNEM, M_SIMPLE, 0ACh, KF_KEYWORD | KF_STRING
    db 5, 'lodsw', C_MNEM, M_SIMPLE, 0ADh, KF_KEYWORD | KF_STRING
    db 5, 'scasb', C_MNEM, M_SIMPLE, 0AEh, KF_KEYWORD | KF_STRING
    db 5, 'scasw', C_MNEM, M_SIMPLE, 0AFh, KF_KEYWORD | KF_STRING
    db 3, 'nop', C_MNEM, M_SIMPLE, 90h, KF_KEYWORD
    db 3, 'hlt', C_MNEM, M_SIMPLE, 0F4h, KF_KEYWORD
    db 3, 'cbw', C_MNEM, M_SIMPLE, 98h, KF_KEYWORD
    db 3, 'cwd', C_MNEM, M_SIMPLE, 99h, KF_KEYWORD
    db 5, 'pushf', C_MNEM, M_SIMPLE, 9Ch, KF_KEYWORD
    db 4, 'popf', C_MNEM, M_SIMPLE, 9Dh, KF_KEYWORD
    db 4, 'sahf', C_MNEM, M_SIMPLE, 9Eh, KF_KEYWORD
    db 4, 'lahf', C_MNEM, M_SIMPLE, 9Fh, KF_KEYWORD
    db 3, 'clc', C_MNEM, M_SIMPLE, 0F8h, KF_KEYWORD
    db 3, 'stc', C_MNEM, M_SIMPLE, 0F9h, KF_KEYWORD
    db 3, 'cmc', C_MNEM, M_SIMPLE, 0F5h, KF_KEYWORD
    db 3, 'cli', C_MNEM, M_SIMPLE, 0FAh, KF_KEYWORD
    db 3, 'sti', C_MNEM, M_SIMPLE, 0FBh, KF_KEYWORD
    db 3, 'cld', C_MNEM, M_SIMPLE, 0FCh, KF_KEYWORD
    db 3, 'std', C_MNEM, M_SIMPLE, 0FDh, KF_KEYWORD
    db 0

; ---------- buffers, after the program (not in the file) ----------

bss:
inbuf       equ bss                         ; the source, a piece at a time
raw         equ inbuf + INBUF_SIZE          ; pass 1: the tokens of a line
tk          equ raw + MAX_TOKENS * TK_SIZE  ; the passes: the tokens of a line
strpool     equ tk + (MAX_TOKENS + 1) * TK_SIZE
namebuf     equ strpool + MAX_LINE + 256
msgbuf      equ namebuf + 260               ; the message being written
msgbuf_end  equ msgbuf + 256
lex_msg     equ msgbuf_end
kw_ptr      equ lex_msg + 128               ; keyword number -> its entry
enc         equ kw_ptr + 512                ; the instruction being encoded
op0         equ enc + 16                    ; its operands
op1         equ op0 + O_SIZEOF
op2         equ op1 + O_SIZEOF
bss_end     equ op2 + O_SIZEOF
