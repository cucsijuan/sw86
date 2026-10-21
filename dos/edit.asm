; edit.asm - the COS text editor (EDIT.COM)
;
;   EDIT file
;
; A full-screen editor for text files and programs: the file fills the
; screen, the cursor keys move through it and what is typed goes in at the
; cursor. F2 saves (the old file is kept as NAME.BAK), Esc leaves.
;
;   Arrows, Home, End, PgUp, PgDn    move; Ctrl+Home / Ctrl+End: the top /
;                                    the end of the file; Ctrl+arrows: words
;   Enter                            splits the line (keeps the indentation)
;   Backspace, Del                   delete (and join lines)
;   Tab                              spaces to the next column of 4
;   Ins                              insert / overwrite
;   Ctrl+Y                           cuts the line (cut lines pile up)
;   F9                               puts the cut lines back at the cursor
;   F1 help  F2 save  F3 find  F4 find again  F5 go to a line  Esc leave
;
; Lines are kept one by one in memory above the program (any size of file
; that fits, up to 16000 lines of 1000 characters); tabs in a file become
; spaces (every 8 columns); lines end in CR LF when it is saved.
org 100h

    jmp start

MAX_LEN     equ 1000            ; characters in a line
MAX_LINES   equ 16000           ; 4 bytes each in the line table
CLIP_MAX    equ 500             ; lines that can be cut at once
TEXT_ROWS   equ 23              ; rows 1-23 show the text
IOBUF_SIZE  equ 8192
ATTR_TEXT   equ 07h
ATTR_BAR    equ 70h

; Keys: scan codes from INT 16h (ASCII 0)
K_F1        equ 3Bh
K_F2        equ 3Ch
K_F3        equ 3Dh
K_F4        equ 3Eh
K_F5        equ 3Fh
K_F9        equ 43h
K_F10       equ 44h
K_HOME      equ 47h
K_UP        equ 48h
K_PGUP      equ 49h
K_LEFT      equ 4Bh
K_RIGHT     equ 4Dh
K_END       equ 4Fh
K_DOWN      equ 50h
K_PGDN      equ 51h
K_INS       equ 52h
K_DEL       equ 53h
K_CLEFT     equ 73h
K_CRIGHT    equ 74h
K_CEND      equ 75h
K_CHOME     equ 77h

; ======================================================================
; Start and the main loop
; ======================================================================

start:
    cld
    mov ax, cs                      ; the line table, then the lines
    add ax, 1000h
    mov [lt_seg], ax
    add ax, 1000h
    mov [heap_start], ax
    mov [heap_top], ax
    mov bx, [2]                     ; the top of our memory, from the PSP
    mov [heap_end], bx
    sub bx, 100h
    cmp ax, bx
    jb .memory
    mov si, m_memory
    jmp fatal
.memory:
    call get_name
    call load_file
    call video_init
.loop:
    call fix_view
    call draw
    call get_key
    mov word [msg_ptr], 0
    mov [key], ax
    cmp al, 19h                     ; Ctrl+Y: cut lines pile up
    je .cut
    mov byte [cutting], 0
.cut:
    call do_key
    jmp .loop

; SI = message: prints it and ends
fatal:
    call print
    mov si, m_crlf
    call print
    mov ax, 4C01h
    int 21h

; DS:SI ASCIIZ to standard output
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

; The name on the command line, upper case, into fname
get_name:
    mov si, 81h
.skip:
    lodsb
    cmp al, ' '
    je .skip
    cmp al, 9
    je .skip
    dec si
    mov di, fname
    mov cx, 64
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
    stosb
    loop .copy
.end:
    mov byte [di], 0
    cmp byte [fname], 0
    jne .done
    mov si, m_usage
    jmp fatal
.done:
    ret

; The key in AX: does what it says
do_key:
    or al, al
    jz .extended
    cmp al, 0E0h
    je .extended
    cmp al, 0Dh
    jne .not_enter
    jmp key_enter
.not_enter:
    cmp al, 08h
    jne .not_back
    jmp key_backspace
.not_back:
    cmp al, 09h
    jne .not_tab
    jmp key_tab
.not_tab:
    cmp al, 1Bh
    jne .not_esc
    jmp key_exit
.not_esc:
    cmp al, 19h
    jne .not_cut
    jmp key_cut
.not_cut:
    cmp al, ' '
    jb .done
    jmp key_char
.extended:
    mov al, ah
    mov si, key_table
.find:
    cmp byte [si], 0
    je .done
    cmp [si], al
    je .found
    add si, 3
    jmp .find
.found:
    jmp [si + 1]
.done:
    ret

key_table:
    db K_UP
    dw key_up
    db K_DOWN
    dw key_down
    db K_LEFT
    dw key_left
    db K_RIGHT
    dw key_right
    db K_HOME
    dw key_home
    db K_END
    dw key_end
    db K_PGUP
    dw key_pgup
    db K_PGDN
    dw key_pgdn
    db K_CHOME
    dw key_top
    db K_CEND
    dw key_bottom
    db K_CLEFT
    dw key_word_left
    db K_CRIGHT
    dw key_word_right
    db K_DEL
    dw key_delete
    db K_INS
    dw key_insert
    db K_F1
    dw key_help
    db K_F2
    dw key_save
    db K_F3
    dw key_find
    db K_F4
    dw key_find_next
    db K_F5
    dw key_goto
    db K_F9
    dw key_paste
    db K_F10
    dw key_exit
    db 0

; ======================================================================
; Moving
; ======================================================================

key_up:
    mov ax, [cy]
    or ax, ax
    jz .done
    dec ax
    call go_line
    call keep_column
.done:
    ret

key_down:
    mov ax, [cy]
    inc ax
    cmp ax, [nlines]
    jae .done
    call go_line
    call keep_column
.done:
    ret

key_left:
    cmp word [cx_], 0
    je .previous
    dec word [cx_]
    jmp set_want
.previous:
    mov ax, [cy]
    or ax, ax
    jz .done
    dec ax
    call go_line
    jc .done
    mov ax, [cur_len]
    mov [cx_], ax
    jmp set_want
.done:
    ret

key_right:
    mov ax, [cx_]
    cmp ax, [cur_len]
    jae .next
    inc word [cx_]
    jmp set_want
.next:
    mov ax, [cy]
    inc ax
    cmp ax, [nlines]
    jae .done
    call go_line
    jc .done
    mov word [cx_], 0
    jmp set_want
.done:
    ret

key_home:
    mov word [cx_], 0
    jmp set_want

key_end:
    mov ax, [cur_len]
    mov [cx_], ax
    jmp set_want

key_pgup:
    mov ax, [cy]
    sub ax, TEXT_ROWS - 1
    jnc .line
    xor ax, ax
.line:
    mov bx, [top]
    sub bx, TEXT_ROWS - 1
    jnc .top
    xor bx, bx
.top:
    mov [top], bx
    call go_line
    jmp keep_column

key_pgdn:
    mov ax, [cy]
    add ax, TEXT_ROWS - 1
    cmp ax, [nlines]
    jb .line
    mov ax, [nlines]
    dec ax
.line:
    mov bx, [top]
    add bx, TEXT_ROWS - 1
    cmp bx, ax
    jbe .top
    mov bx, ax
.top:
    mov [top], bx
    call go_line
    jmp keep_column

key_top:
    xor ax, ax
    call go_line
    mov word [cx_], 0
    jmp set_want

key_bottom:
    mov ax, [nlines]
    dec ax
    call go_line
    mov ax, [cur_len]
    mov [cx_], ax
    jmp set_want

; Ctrl+Left: the start of the word before the cursor
key_word_left:
    mov bx, [cx_]
    or bx, bx
    jnz .back
    jmp key_left
.back:
    dec bx                          ; skip spaces, then the word
    jz .set
    cmp byte [cur + bx], ' '
    je .back
.word:
    cmp byte [cur + bx - 1], ' '
    je .set
    dec bx
    jnz .word
.set:
    mov [cx_], bx
    jmp set_want

; Ctrl+Right: the start of the next word
key_word_right:
    mov bx, [cx_]
    cmp bx, [cur_len]
    jb .word
    jmp key_right
.word:
    cmp bx, [cur_len]               ; skip the word, then spaces
    jae .set
    cmp byte [cur + bx], ' '
    je .spaces
    inc bx
    jmp .word
.spaces:
    cmp bx, [cur_len]
    jae .set
    cmp byte [cur + bx], ' '
    jne .set
    inc bx
    jmp .spaces
.set:
    mov [cx_], bx
    jmp set_want

; The column the cursor tries to keep when it goes up or down
set_want:
    mov ax, [cx_]
    mov [want], ax
    ret

keep_column:
    mov ax, [want]
    cmp ax, [cur_len]
    jbe .set
    mov ax, [cur_len]
.set:
    mov [cx_], ax
    ret

; AX = line: the cursor goes there (the line being edited is stored first).
; CF = 1 if it could not be stored (out of memory).
go_line:
    cmp ax, [cy]
    je .same
    push ax
    call commit
    pop ax
    jc .done
    mov [cy], ax
    call load_line
.same:
    clc
.done:
    ret

; The view follows the cursor
fix_view:
    mov ax, [cy]
    cmp ax, [top]
    jae .not_above
    mov [top], ax
.not_above:
    mov bx, [top]
    add bx, TEXT_ROWS
    cmp ax, bx
    jb .not_below
    sub ax, TEXT_ROWS - 1
    mov [top], ax
.not_below:
    mov ax, [cx_]
    cmp ax, [left]
    jae .not_left
    and ax, 0FFF0h                  ; a little of the text before it
    mov [left], ax
.not_left:
    mov bx, [left]
    add bx, 80
    cmp ax, bx
    jb .done
    sub ax, 64
    and ax, 0FFF0h
    mov [left], ax
.done:
    ret

; ======================================================================
; Editing
; ======================================================================

key_char:
    cmp byte [insert], 0
    je .overwrite
.insert:
    cmp word [cur_len], MAX_LEN
    jb .room
    jmp line_too_long
.room:
    push ax
    mov bx, [cx_]
    call open_gap
    pop ax
    mov [cur + bx], al
    jmp .moved
.overwrite:
    mov bx, [cx_]
    cmp bx, [cur_len]
    jae .insert
    mov [cur + bx], al
.moved:
    inc word [cx_]
    call set_want
    jmp changed

; Makes room for one character at BX in the current line
open_gap:
    push si
    push di
    push cx
    mov cx, [cur_len]
    sub cx, bx
    lea si, [cur - 1]
    add si, [cur_len]
    lea di, [si + 1]
    std
    rep movsb
    cld
    inc word [cur_len]
    pop cx
    pop di
    pop si
    ret

; Removes the character at BX from the current line
close_gap:
    push si
    push di
    push cx
    mov cx, [cur_len]
    sub cx, bx
    dec cx
    lea di, [cur + bx]
    lea si, [di + 1]
    rep movsb
    dec word [cur_len]
    pop cx
    pop di
    pop si
    ret

key_tab:
    mov ax, ' '
    call key_char
    cmp word [msg_ptr], 0           ; the line is full
    jne .done
    test word [cx_], 3
    jnz key_tab
.done:
    ret

key_backspace:
    mov bx, [cx_]
    or bx, bx
    jz .join
    dec bx
    mov [cx_], bx
    call close_gap
    call set_want
    jmp changed
.join:
    mov ax, [cy]                    ; with the line above
    or ax, ax
    jz .done
    dec ax
    call line_entry
    mov ax, [es:bx + 2]
    push ds
    pop es
    add ax, [cur_len]
    cmp ax, MAX_LEN
    jbe .fits
    jmp line_too_long
.fits:
    call save_tail_all
    mov ax, [cy]
    call delete_entry
    mov byte [cur_dirty], 0
    dec word [cy]
    mov ax, [cy]
    call load_line
    mov ax, [cur_len]
    mov [cx_], ax
    call set_want
    call append_tail
    jmp changed
.done:
    ret

key_delete:
    mov bx, [cx_]
    cmp bx, [cur_len]
    jae .join
    call close_gap
    jmp changed
.join:
    mov ax, [cy]                    ; with the line below
    inc ax
    cmp ax, [nlines]
    jae .done
    push ax
    call line_entry
    mov cx, [es:bx + 2]
    mov si, [es:bx]
    push ds
    pop es
    pop ax
    mov dx, [cur_len]
    add dx, cx
    cmp dx, MAX_LEN
    jbe .fits
    jmp line_too_long
.fits:
    push ax
    push ds
    mov di, cur                     ; its text after ours
    add di, [cur_len]
    add [cur_len], cx
    mov ds, si
    mov si, 4
    rep movsb
    pop ds
    pop ax
    call delete_entry
    jmp changed
.done:
    ret

key_enter:
    mov ax, [nlines]
    cmp ax, MAX_LINES
    jb .room
    mov word [msg_ptr], m_many_lines
    ret
.room:
    mov bx, [cx_]                   ; the text after the cursor
    call save_tail
    xor bx, bx                      ; the indentation (not past the cursor)
.indent:
    cmp bx, [cx_]
    jae .indented
    cmp byte [cur + bx], ' '
    jne .indented
    inc bx
    jmp .indent
.indented:
    mov [indent], bx
    mov ax, [cx_]
    mov [cur_len], ax
    mov byte [cur_dirty], 1
    call commit
    jnc .stored
    mov ax, [cx_]                   ; out of memory: as it was
    mov [cur_len], ax
    call append_tail
    ret
.stored:
    mov ax, [cy]
    inc ax
    xor bx, bx
    xor cx, cx
    call insert_entry
    inc word [cy]
    mov ax, [cy]
    mov [cur_line], ax
    mov cx, [indent]                ; the new line: indentation + the tail
    mov [cur_len], cx
    mov [cx_], cx
    mov di, cur
    mov al, ' '
    push ds
    pop es
    rep stosb
    call append_tail
    call set_want
    jmp changed

; Ctrl+Y: the line goes to the cut lines
key_cut:
    cmp byte [cutting], 0
    jne .more
    mov word [clip_n], 0
    mov byte [cutting], 1
.more:
    cmp word [clip_n], CLIP_MAX
    jb .room
    mov word [msg_ptr], m_clip_full
    ret
.room:
    call commit
    jc .done
    mov ax, [cy]
    call line_entry
    mov ax, [es:bx]
    mov dx, [es:bx + 2]
    push ds
    pop es
    mov bx, [clip_n]
    shl bx, 1
    shl bx, 1
    mov [clip + bx], ax
    mov [clip + bx + 2], dx
    inc word [clip_n]
    mov ax, [cy]
    call delete_entry
    cmp word [nlines], 0
    jne .lines
    xor ax, ax                      ; never no lines at all
    xor bx, bx
    xor cx, cx
    call insert_entry
.lines:
    mov ax, [cy]
    cmp ax, [nlines]
    jb .load
    mov ax, [nlines]
    dec ax
    mov [cy], ax
.load:
    call load_line
    mov word [cx_], 0
    call set_want
    jmp mark_modified
.done:
    ret

; F9: copies of the cut lines go in before the cursor's line
key_paste:
    mov cx, [clip_n]
    jcxz .done
    add cx, [nlines]
    cmp cx, MAX_LINES
    jbe .room
    mov word [msg_ptr], m_many_lines
    ret
.room:
    call commit
    jc .done
    mov word [paste_k], 0
.line:
    mov bx, [paste_k]
    cmp bx, [clip_n]
    jae .end
    shl bx, 1
    shl bx, 1
    mov ax, [clip + bx]
    mov cx, [clip + bx + 2]
    push cx
    push ds                         ; its text into tmp
    push ds
    pop es
    mov di, tmp
    mov ds, ax
    mov si, 4
    rep movsb
    pop ds
    pop cx
    mov si, tmp
    call store_text
    jc .end
    mov bx, ax
    mov ax, [cy]
    call insert_entry
    inc word [cy]
    inc word [paste_k]
    jmp .line
.end:
    mov ax, [cy]
    call load_line
    mov word [cx_], 0
    call set_want
    jmp mark_modified
.done:
    ret

key_insert:
    xor byte [insert], 1
    jmp set_cursor_shape

line_too_long:
    mov word [msg_ptr], m_too_long
    ret

changed:
    mov byte [cur_dirty], 1
mark_modified:
    mov byte [modified], 1
    ret

; The text of the current line from BX to its end into tail / tail_len
save_tail:
    mov cx, [cur_len]
    sub cx, bx
    mov [tail_len], cx
    lea si, [cur + bx]
    mov di, tail
    push ds
    pop es
    rep movsb
    ret

save_tail_all:
    xor bx, bx
    jmp save_tail

; Appends tail to the current line (it fits: checked before)
append_tail:
    mov cx, [tail_len]
    mov si, tail
    mov di, cur
    add di, [cur_len]
    add [cur_len], cx
    push ds
    pop es
    rep movsb
    ret

; ======================================================================
; Lines in memory
; ======================================================================

; AX = line: ES:BX = its entry in the line table (segment, length)
line_entry:
    mov bx, ax
    shl bx, 1
    shl bx, 1
    mov es, [lt_seg]
    ret

; AX = line: into cur / cur_len
load_line:
    mov [cur_line], ax
    call line_entry
    mov cx, [es:bx + 2]
    mov ax, [es:bx]
    mov [cur_len], cx
    push ds
    pop es
    mov di, cur
    push ds
    mov ds, ax
    mov si, 4
    rep movsb
    pop ds
    mov byte [cur_dirty], 0
    ret

; The current line back into memory if it changed. CF = 1: out of memory.
commit:
    cmp byte [cur_dirty], 0
    je .done
    mov ax, [cur_line]
    call line_entry
    mov cx, [cur_len]
    jcxz .empty
    mov ax, [es:bx]                 ; does it fit where it is?
    or ax, ax
    jz .new
    push es
    mov es, ax
    mov dx, [es:0]
    pop es
    shl dx, 1
    shl dx, 1
    shl dx, 1
    shl dx, 1
    sub dx, 4
    cmp cx, dx
    ja .new
    mov [es:bx + 2], cx
    mov es, ax
    mov di, 4
    mov si, cur
    rep movsb
    jmp .stored
.new:
    mov si, cur
    call store_text
    jc .failed
    mov cx, [cur_len]
    push ax
    mov ax, [cur_line]
    call line_entry
    pop ax
    mov [es:bx], ax
    mov [es:bx + 2], cx
    jmp .stored
.empty:
    mov word [es:bx], 0
    mov word [es:bx + 2], 0
.stored:
    push ds
    pop es
    mov byte [cur_dirty], 0
.done:
    clc
    ret
.failed:
    push ds
    pop es
    mov word [msg_ptr], m_out_of_memory
    stc
    ret

; SI = text, CX = its length: a copy in memory. AX = its segment (0 for
; an empty line). CF = 1: out of memory.
store_text:
    xor ax, ax
    jcxz .done
    push cx
    push si
    mov ax, cx
    add ax, 4 + 15
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    call alloc
    pop si
    pop cx
    jc .failed
    push es
    push cx
    mov es, ax
    mov [es:0], dx                  ; its size in paragraphs
    mov word [es:2], 0
    mov di, 4
    rep movsb
    pop cx
    pop es
.done:
    clc
.failed:
    ret

; AX = paragraphs: AX = segment, DX = the size. CF = 1: no room even after
; compacting.
alloc:
    mov dx, ax
    call .try
    jnc .done
    push dx
    call compact
    pop dx
    mov ax, dx
.try:
    mov ax, [heap_top]
    mov bx, ax
    add bx, dx
    jc .full
    cmp bx, [heap_end]
    ja .full
    mov [heap_top], bx
    clc
.done:
    ret
.full:
    stc
    ret

; Moves the lines in use down over the old copies left by editing. Every
; block starts with its size in paragraphs and a word that, here, says who
; uses it: a line (its number), a cut line (8000h + its number), or none.
compact:
    push ds
    pop es
    mov ax, [heap_start]            ; none
.clear:
    cmp ax, [heap_top]
    jae .lines
    mov es, ax
    mov word [es:2], 0FFFFh
    add ax, [es:0]
    jmp .clear
.lines:
    xor cx, cx
.line:
    cmp cx, [nlines]
    jae .clip
    mov ax, cx
    call line_entry
    mov ax, [es:bx]
    or ax, ax
    jz .line_next
    mov es, ax
    mov [es:2], cx
.line_next:
    inc cx
    jmp .line
.clip:
    xor cx, cx
.clip_line:
    cmp cx, [clip_n]
    jae .move
    mov bx, cx
    shl bx, 1
    shl bx, 1
    mov ax, [clip + bx]
    or ax, ax
    jz .clip_next
    mov es, ax
    mov ax, cx
    or ax, 8000h
    mov [es:2], ax
.clip_next:
    inc cx
    jmp .clip_line
.move:
    mov ax, [heap_start]            ; AX = this block, DX = where it goes
    mov dx, ax
.block:
    cmp ax, [heap_top]
    jae .end
    mov es, ax
    mov cx, [es:0]
    mov bx, [es:2]
    cmp bx, 0FFFFh
    je .next
    push ax
    push cx
    cmp ax, dx
    je .moved
    push ds
    push si
    mov ds, ax
    mov es, dx
    xor si, si
    xor di, di
    shl cx, 1
    shl cx, 1
    shl cx, 1
    rep movsw
    pop si
    pop ds
.moved:
    test bx, 8000h
    jnz .clip_ref
    mov ax, bx
    call line_entry
    mov [es:bx], dx
    jmp .ref_done
.clip_ref:
    and bx, 7FFFh
    shl bx, 1
    shl bx, 1
    mov [clip + bx], dx
.ref_done:
    pop cx
    pop ax
    add dx, cx
.next:
    add ax, cx
    jmp .block
.end:
    mov [heap_top], dx
    push ds
    pop es
    ret

; AX = where, BX = segment, CX = length: a new line in the table
insert_entry:
    push ax
    push bx
    push cx
    push ds
    mov cx, [nlines]
    sub cx, ax
    shl cx, 1                       ; words to move up
    mov si, [nlines]
    shl si, 1
    shl si, 1
    dec si
    dec si
    lea di, [si + 4]
    mov ds, [lt_seg]
    mov es, [cs:lt_seg]
    std
    rep movsw
    cld
    pop ds
    pop cx
    pop bx
    pop ax
    inc word [nlines]
    push bx
    call line_entry
    pop ax
    mov [es:bx], ax
    mov [es:bx + 2], cx
    push ds
    pop es
    ret

; AX = line: it leaves the table
delete_entry:
    push ds
    mov cx, [nlines]
    sub cx, ax
    dec cx
    shl cx, 1
    mov di, ax
    shl di, 1
    shl di, 1
    lea si, [di + 4]
    mov es, [lt_seg]
    mov ds, [lt_seg]
    rep movsw
    pop ds
    push ds
    pop es
    dec word [nlines]
    ret

; ======================================================================
; Files
; ======================================================================

load_file:
    mov word [nlines], 0
    mov word [cur_len], 0
    mov dx, fname
    mov ax, 3D00h
    int 21h
    jnc .opened
    cmp ax, 2                       ; not found: a new file
    jne .cannot
    mov word [msg_ptr], m_new_file
    jmp .last
.cannot:
    mov si, m_cannot_open
    call print
    mov si, fname
    jmp fatal
.opened:
    mov [handle], ax
    mov byte [has_file], 1
.read:
    mov bx, [handle]
    mov cx, IOBUF_SIZE
    mov dx, iobuf
    mov ah, 3Fh
    int 21h
    jnc .got
    mov si, m_read_error
    jmp fatal
.got:
    mov cx, ax
    jcxz .end
    mov si, iobuf
.char:
    lodsb
    cmp al, 0Dh
    je .next
    cmp al, 0Ah
    jne .not_lf
    call .line
    jmp .next
.not_lf:
    cmp al, 1Ah                     ; Ctrl-Z: the end of a text file
    je .end
    cmp al, 9
    jne .store
.tab:
    mov al, ' '                     ; tabs: spaces to the next column of 8
    call .put
    test word [cur_len], 7
    jnz .tab
    jmp .next
.store:
    call .put
.next:
    loop .char
    jmp .read
.end:
    mov bx, [handle]
    mov ah, 3Eh
    int 21h
    cmp word [cur_len], 0
    jne .last
    cmp word [nlines], 0
    jne .loaded
.last:
    call .line
.loaded:
    xor ax, ax                      ; the cursor on the first line
    mov [cy], ax
    call load_line
    ret
.put:                               ; AL into the line being read
    cmp word [cur_len], MAX_LEN
    jb .room
    push ax
    call .line                      ; too long: it goes on in another one
    pop ax
    mov word [msg_ptr], m_split
.room:
    mov bx, [cur_len]
    mov [cur + bx], al
    inc word [cur_len]
    ret
.line:                              ; the line read becomes the last line
    push si
    push cx
    mov ax, [nlines]
    cmp ax, MAX_LINES
    jb .line_room
    mov si, m_too_large
    jmp fatal
.line_room:
    mov si, cur
    mov cx, [cur_len]
    call store_text
    jnc .line_stored
    mov si, m_too_large
    jmp fatal
.line_stored:
    mov bx, ax
    mov ax, [nlines]
    call insert_entry
    mov word [cur_len], 0
    pop cx
    pop si
    ret

; F2: writes NAME.$$$, then NAME becomes NAME.BAK and NAME.$$$ becomes NAME
key_save:
    call save_file
    ret

save_file:
    mov si, m_ext_tmp
    mov di, tmpname
    call make_name
    mov si, m_ext_bak
    mov di, bakname
    call make_name
    mov dx, tmpname
    xor cx, cx
    mov ah, 3Ch
    int 21h
    jnc .created
    jmp .cannot
.created:
    mov [handle], ax
    mov word [io_len], 0
    cmp word [nlines], 1            ; one empty line: an empty file
    jne .lines
    xor ax, ax
    call text_of
    jcxz .written
.lines:
    xor ax, ax
.line:
    cmp ax, [nlines]
    jae .written
    push ax
    call text_of
    jcxz .crlf
    push ds
    mov ds, bx
.copy:
    lodsb
    call put_out
    jc .out_error
    loop .copy
    pop ds
.crlf:
    mov al, 0Dh
    call put_out
    jc .failed
    mov al, 0Ah
    call put_out
    jc .failed
    pop ax
    inc ax
    jmp .line
.out_error:
    pop ds
.failed:
    pop ax
    jmp .write_error
.written:
    call flush_out
    jc .write_error
    mov bx, [handle]
    mov ah, 3Eh
    int 21h
    jc .write_error
    cmp byte [has_file], 0
    je .rename
    mov dx, bakname                 ; the old file is kept as NAME.BAK
    mov ah, 41h
    int 21h
    mov dx, fname
    mov di, bakname
    push ds
    pop es
    mov ah, 56h
    int 21h
.rename:
    mov dx, tmpname
    mov di, fname
    push ds
    pop es
    mov ah, 56h
    int 21h
    jc .cannot
    mov byte [has_file], 1
    mov byte [modified], 0
    mov word [msg_ptr], m_saved
    clc
    ret
.write_error:
    mov bx, [handle]
    mov ah, 3Eh
    int 21h
    mov dx, tmpname
    mov ah, 41h
    int 21h
.cannot:
    mov word [msg_ptr], m_cannot_save
    stc
    ret

; AX = line: its text at BX:SI, CX characters (the line being edited from
; cur, so that it can be saved even when there is no memory to store it)
text_of:
    cmp ax, [cur_line]
    jne .stored
    cmp byte [cur_dirty], 0
    je .stored
    mov bx, ds
    mov es, bx
    mov si, cur
    mov cx, [cur_len]
    ret
.stored:
    call line_entry
    mov cx, [es:bx + 2]
    mov si, 4
    mov bx, [es:bx]
    push ds
    pop es
    ret

; AL into the output buffer (written when full). CF = 1 on an error.
put_out:
    push bx
    mov bx, [es:io_len]
    mov [es:iobuf + bx], al
    inc bx
    mov [es:io_len], bx
    cmp bx, IOBUF_SIZE
    pop bx
    jb .ok
    jmp flush_out
.ok:
    clc
    ret

flush_out:
    push ds
    push es
    pop ds
    push ax
    push bx
    push cx
    push dx
    mov cx, [io_len]
    mov word [io_len], 0
    jcxz .done
    mov bx, [handle]
    mov dx, iobuf
    mov ah, 40h
    int 21h
    jc .error
    cmp ax, cx
    jne .error
.done:
    clc
.end:
    pop dx
    pop cx
    pop bx
    pop ax
    pop ds
    ret
.error:
    stc
    jmp .end

; fname with the extension at SI (".BAK") into DI
make_name:
    push si
    mov si, fname
    mov bx, 0
.copy:
    lodsb
    cmp al, '.'
    jne .not_dot
    lea bx, [di]
.not_dot:
    stosb
    or al, al
    jnz .copy
    dec di
    or bx, bx
    jz .ext
    mov di, bx
.ext:
    pop si
.ext_copy:
    lodsb
    stosb
    or al, al
    jnz .ext_copy
    ret

; Esc / F10: leaves (asks first if there are changes)
key_exit:
    cmp byte [modified], 0
    je .leave
.ask:
    mov si, m_ask_save
    call ask_key
    cmp al, 1Bh
    je .stay
    or al, 20h
    cmp al, 'n'
    je .leave
    cmp al, 'y'
    jne .ask
    call save_file
    jc .stay
.leave:
    mov ax, 0600h                   ; a clean screen, as the editor found it
    mov bh, ATTR_TEXT
    xor cx, cx
    mov dx, 184Fh
    int 10h
    mov ah, 02h
    xor bh, bh
    xor dx, dx
    int 10h
    mov cx, [cursor_shape]
    mov ah, 01h
    int 10h
    mov ax, 4C00h
    int 21h
.stay:
    ret

; ======================================================================
; Finding
; ======================================================================

key_goto:
    mov si, m_ask_line
    mov di, answer
    mov byte [answer], 0
    call prompt
    jc .done
    mov si, answer
    xor ax, ax
.digit:
    mov bl, [si]
    sub bl, '0'
    cmp bl, 9
    ja .number
    mov cx, 10
    mul cx
    jc .last                        ; too large: the last line
    xor bh, bh
    add ax, bx
    jc .last
    inc si
    jmp .digit
.last:
    mov ax, 0FFFFh
.number:
    or ax, ax
    jz .done
    dec ax
    cmp ax, [nlines]
    jb .go
    mov ax, [nlines]
    dec ax
.go:
    call go_line
    mov word [cx_], 0
    call set_want
.done:
    ret

key_find:
    mov si, m_ask_find
    mov di, find_text
    call prompt
    jc key_find_next.done
key_find_next:
    cmp byte [find_text], 0
    je key_find
    call commit
    jc .done
    mov si, find_text               ; its length
    xor cx, cx
.length:
    lodsb
    or al, al
    jz .counted
    inc cx
    jmp .length
.counted:
    mov [find_len], cx
    mov ax, [cy]                    ; from just after the cursor
    mov [find_line], ax
    mov ax, [cx_]
    inc ax
    mov [find_col], ax
    mov ax, [nlines]
    inc ax
    mov [find_left], ax             ; every line once, and this one again
.line:
    call find_in_line
    jnc .found
    dec word [find_left]
    jz .not_found
    mov word [find_col], 0
    mov ax, [find_line]
    inc ax
    cmp ax, [nlines]
    jb .next
    xor ax, ax
.next:
    mov [find_line], ax
    jmp .line
.found:
    mov ax, [find_line]
    call go_line
    mov ax, [find_col]
    mov [cx_], ax
    call set_want
.done:
    ret
.not_found:
    mov word [msg_ptr], m_not_found
    ret

; find_text in line find_line from column find_col, any case: CF = 0 and
; find_col = where it is
find_in_line:
    mov ax, [find_line]
    call line_entry
    mov cx, [es:bx + 2]
    mov ax, [es:bx]
    mov es, ax
    mov bx, [find_col]
.try:
    mov dx, cx                      ; room for it from BX?
    sub dx, bx
    jb .no
    cmp dx, [find_len]
    jb .no
    xor si, si
.compare:
    cmp si, [find_len]
    jae .yes
    mov al, [find_text + si]
    call upper
    mov ah, al
    mov di, bx
    add di, si
    mov al, [es:di + 4]
    call upper
    cmp al, ah
    jne .next
    inc si
    jmp .compare
.next:
    inc bx
    jmp .try
.yes:
    mov [find_col], bx
    push ds
    pop es
    clc
    ret
.no:
    push ds
    pop es
    stc
    ret

upper:
    cmp al, 'a'
    jb .done
    cmp al, 'z'
    ja .done
    sub al, 20h
.done:
    ret

; ======================================================================
; The screen
; ======================================================================

video_init:
    mov ah, 0Fh                     ; the text memory: B000h on mono
    int 10h
    mov word [vseg], 0B800h
    cmp al, 7
    jne .color
    mov word [vseg], 0B000h
.color:
    mov ah, 03h                     ; the cursor shape, to put it back
    xor bh, bh
    int 10h
    mov [cursor_shape], cx
    mov byte [insert], 1
    jmp set_cursor_shape

; A line for insert, a block for overwrite
set_cursor_shape:
    mov cx, [cursor_shape]
    cmp byte [insert], 0
    jne .set
    mov ch, 0
.set:
    mov ah, 01h
    int 10h
    ret

; Everything: the title, the text, the bottom line and the cursor
draw:
    call draw_title
    xor dx, dx                      ; DX = screen row - 1
.row:
    mov ax, [top]
    add ax, dx
    call draw_line
    inc dx
    cmp dx, TEXT_ROWS
    jb .row
    call draw_bottom
    mov dh, [cy]                    ; the cursor
    sub dh, [top]
    inc dh
    mov dl, [cx_]
    sub dl, [left]
    mov ah, 02h
    xor bh, bh
    int 10h
    ret

; AX = line, DX = row - 1
draw_line:
    push dx
    mov di, dx
    inc di
    mov bx, 160
    xchg ax, di
    mul bx
    xchg ax, di                     ; DI = the row in text memory
    xor cx, cx
    cmp ax, [nlines]
    jae .text
    cmp ax, [cur_line]
    jne .stored
    mov si, cur                     ; the line being edited
    mov cx, [cur_len]
    push ds
    jmp .skip
.stored:
    call line_entry
    mov cx, [es:bx + 2]
    mov ax, [es:bx]
    push ds
    mov ds, ax
    mov si, 4
.skip:
    mov ax, [cs:left]               ; from the first column shown
    cmp cx, ax
    jbe .none
    add si, ax
    sub cx, ax
    jmp .clip
.none:
    xor cx, cx
.clip:
    cmp cx, 80
    jbe .write
    mov cx, 80
.write:
    mov es, [cs:vseg]
    mov dx, 80
    sub dx, cx
    mov ah, ATTR_TEXT
    jcxz .pad
.char:
    lodsb
    stosw
    loop .char
.pad:
    mov cx, dx
    mov al, ' '
    rep stosw
    pop ds
    push ds
    pop es
    pop dx
    ret
.text:
    push ds                         ; past the end: an empty row
    jmp .write

; The title bar: the name, a * if changed, where the cursor is
draw_title:
    call bar_clear
    mov di, bar + 1
    mov si, m_title
    call bar_puts
    mov si, fname
    call bar_puts
    cmp byte [modified], 0
    je .position
    mov al, '*'
    stosb
.position:
    mov di, bar + 46
    mov si, m_line
    call bar_puts
    mov ax, [cy]
    inc ax
    call bar_number
    mov si, m_of
    call bar_puts
    mov ax, [nlines]
    call bar_number
    mov di, bar + 64
    mov si, m_col
    call bar_puts
    mov ax, [cx_]
    inc ax
    call bar_number
    mov di, bar + 74
    mov si, m_ins
    cmp byte [insert], 0
    jne .mode
    mov si, m_ovr
.mode:
    call bar_puts
    xor ax, ax
    jmp bar_show

; The bottom line: a message, or the keys
draw_bottom:
    call bar_clear
    mov di, bar + 1
    mov si, [msg_ptr]
    or si, si
    jnz .message
    mov si, m_keys
.message:
    call bar_puts
    mov ax, 24
    jmp bar_show

bar_clear:
    mov di, bar
    mov cx, 80
    mov al, ' '
    push ds
    pop es
    rep stosb
    ret

; SI ASCIIZ into the bar at DI
bar_puts:
    lodsb
    or al, al
    jz .done
    cmp di, bar + 80
    jae bar_puts
    stosb
    jmp bar_puts
.done:
    ret

; AX in decimal into the bar at DI
bar_number:
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
    ret

; The bar onto row AX, in inverse video
bar_show:
    mov bx, 160
    mul bx
    mov di, ax
    mov es, [vseg]
    mov si, bar
    mov cx, 80
    mov ah, ATTR_BAR
.char:
    lodsb
    stosw
    loop .char
    push ds
    pop es
    ret

; INT 16h: AX = the next key
get_key:
    xor ah, ah
    int 16h
    ret

; SI = question on the bottom line: AL = the key pressed
ask_key:
    mov [msg_ptr], si
    call draw
    mov dl, 0                       ; the cursor after the question
    mov si, [msg_ptr]
.length:
    lodsb
    inc dl
    or al, al
    jnz .length
    mov dh, 24
    mov ah, 02h
    xor bh, bh
    int 10h
    call get_key
    mov word [msg_ptr], 0
    ret

; SI = question, DI = answer (ASCIIZ, kept as the default): a line typed on
; the bottom line. CF = 1 if Esc.
prompt:
    mov [prompt_q], si
    mov [prompt_a], di
.show:
    call bar_clear
    mov di, bar + 1
    mov si, [prompt_q]
    call bar_puts
    mov [prompt_col], di
    mov si, [prompt_a]
    call bar_puts
    mov dx, di
    sub dx, bar
    mov ax, 24
    push dx
    call bar_show
    pop dx
    mov dh, 24
    mov ah, 02h
    xor bh, bh
    int 10h
    call get_key
    mov di, [prompt_a]
    mov bx, di                      ; BX = its end
.end:
    cmp byte [bx], 0
    je .ended
    inc bx
    jmp .end
.ended:
    cmp al, 0Dh
    je .enter
    cmp al, 1Bh
    je .escape
    cmp al, 08h
    jne .not_back
    cmp bx, di
    je .show
    mov byte [bx - 1], 0
    jmp .show
.not_back:
    cmp al, ' '
    jb .show
    mov cx, bx
    sub cx, di
    cmp cx, 40
    jae .show
    mov [bx], al
    mov byte [bx + 1], 0
    jmp .show
.enter:
    clc
    ret
.escape:
    stc
    ret

; F1: the keys
key_help:
    mov es, [vseg]
    xor di, di
    mov cx, 80 * 25
    mov ax, (ATTR_TEXT << 8) | ' '
    rep stosw
    push ds
    pop es
    mov si, help_text
    mov dx, 0102h                   ; row 1, column 2
.line:
    cmp byte [si], 0
    je .wait
    mov al, dh
    mov bl, 160
    mul bl
    mov di, ax
    mov al, dl
    xor ah, ah
    shl ax, 1
    add di, ax
    mov es, [vseg]
    mov ah, ATTR_TEXT
.char:
    lodsb
    or al, al
    jz .next
    stosw
    jmp .char
.next:
    push ds
    pop es
    inc dh
    jmp .line
.wait:
    mov dx, 1900h                   ; the cursor out of the way
    mov ah, 02h
    xor bh, bh
    int 10h
    call get_key
    ret

; ======================================================================
; Data
; ======================================================================

m_usage         db 'Usage: EDIT file', 0
m_memory        db 'EDIT: not enough memory', 0
m_cannot_open   db 'EDIT: cannot open ', 0
m_read_error    db 'EDIT: cannot read the file', 0
m_too_large     db 'EDIT: the file is too large', 0
m_crlf          db 13, 10, 0
m_title         db 'COS Edit  ', 0
m_line          db 'Line ', 0
m_of            db ' of ', 0
m_col           db 'Col ', 0
m_ins           db 'Insert', 0
m_ovr           db 'Over', 0
m_keys          db 'F1 Help  F2 Save  F3 Find  F4 Again  F5 Line  Ctrl+Y Cut  F9 Paste  Esc Exit', 0
m_new_file      db 'New file', 0
m_split         db 'Lines longer than 1000 characters were split', 0
m_too_long      db 'The line would be longer than 1000 characters', 0
m_many_lines    db 'Too many lines (16000 at most)', 0
m_clip_full     db 'Too many cut lines (500 at most)', 0
m_out_of_memory db 'Out of memory: save your work', 0
m_saved         db 'Saved', 0
m_cannot_save   db 'Cannot save the file (the diskette is full or protected?)', 0
m_not_found     db 'Not found', 0
m_ask_save      db 'Save the changes (Y/N)? ', 0
m_ask_line      db 'Go to line: ', 0
m_ask_find      db 'Find: ', 0
m_ext_tmp       db '.$$$', 0
m_ext_bak       db '.BAK', 0

help_text:
    db 'COS Edit', 0
    db ' ', 0
    db 'Arrows             move the cursor', 0
    db 'Home / End         the start / the end of the line', 0
    db 'PgUp / PgDn        a screen up / down', 0
    db 'Ctrl+Home / End    the top / the end of the file', 0
    db 'Ctrl+Left / Right  a word left / right', 0
    db ' ', 0
    db 'Enter              split the line (keeps the indentation)', 0
    db 'Backspace / Del    delete before / at the cursor (joins lines)', 0
    db 'Tab                spaces to the next column of 4', 0
    db 'Ins                insert or type over', 0
    db 'Ctrl+Y             cut the line (several in a row pile up)', 0
    db 'F9                 put the cut lines back before the cursor', 0
    db ' ', 0
    db 'F2                 save (the old file is kept as .BAK)', 0
    db 'F3 / F4            find a text (any case) / find it again', 0
    db 'F5                 go to a line by its number', 0
    db 'Esc or F10         leave', 0
    db ' ', 0
    db 'Press any key to go back to the text', 0
    db 0

; ---------- variables ----------

lt_seg          dw 0                ; the line table: segment, length
heap_start      dw 0                ; the lines: from here...
heap_top        dw 0                ; ...to here (the next free paragraph)
heap_end        dw 0
vseg            dw 0                ; text memory
cursor_shape    dw 0
handle          dw 0
has_file        db 0                ; the file exists on the diskette
nlines          dw 0
cy              dw 0                ; the cursor: line, column
cx_             dw 0
want            dw 0                ; the column kept going up and down
top             dw 0                ; the first line and column shown
left            dw 0
cur_line        dw 0                ; the line in cur
cur_len         dw 0
cur_dirty       db 0                ; cur differs from its stored copy
modified        db 0                ; the text differs from the file
insert          db 1
cutting         db 0                ; the last key was Ctrl+Y
clip_n          dw 0
paste_k         dw 0
indent          dw 0
tail_len        dw 0
key             dw 0
msg_ptr         dw 0
prompt_q        dw 0
prompt_a        dw 0
prompt_col      dw 0
io_len          dw 0
find_len        dw 0
find_line       dw 0
find_col        dw 0
find_left       dw 0
find_text       times 42 db 0
answer          times 42 db 0
fname           times 66 db 0
tmpname         times 70 db 0
bakname         times 70 db 0
bar             times 80 db 0

; ---------- buffers, after the program (not in the file) ----------

bss:
cur         equ bss                         ; the line being edited
tail        equ cur + MAX_LEN + 16          ; a piece of it
tmp         equ tail + MAX_LEN + 16
clip        equ tmp + MAX_LEN + 16          ; cut lines: segment, length
iobuf       equ clip + CLIP_MAX * 4
bss_end     equ iobuf + IOBUF_SIZE
