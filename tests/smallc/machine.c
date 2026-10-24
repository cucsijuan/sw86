/* machine.c - #asm, interrupts and memory */
#include <stdio.h>
#include <dos.h>

#asm
section .text
;#def _triple
_triple:
    mov bx, sp
    mov ax, [bx+2]
    mov cx, ax
    add ax, ax
    add ax, cx
    ret
#endasm

int triple(int x);

int add3(int a)
{
#asm
    mov ax, [bp+4]
    add ax, 3
#endasm
}

int main(void)
{
    struct REGS r;
    unsigned seg;
    r.ax = 0x3000;
    intdos(&r, &r);
    printf("COS %d.%d\n", r.ax & 255, r.ax >> 8);
    printf("%d %d\n", triple(14), add3(4));
    seg = getds();
    pokeb(seg, (unsigned)&r, 'Q');
    printf("%c %d\n", r.ax & 255, peek(0, 0x410) != 0);
    return 0;
}
