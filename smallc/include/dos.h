/* dos.h - the machine: interrupts, ports, memory, programs */
#ifndef _DOS_H
#define _DOS_H

struct REGS {
    unsigned ax, bx, cx, dx, si, di, cflag;
};

extern unsigned _psp;           /* the segment of the program's PSP */

int int86(int n, struct REGS *in, struct REGS *out);
int intdos(struct REGS *in, struct REGS *out);
int inp(int port);
int outp(int port, int value);
unsigned inpw(int port);
unsigned outpw(int port, unsigned value);
int peekb(unsigned seg, unsigned off);
unsigned peek(unsigned seg, unsigned off);
void pokeb(unsigned seg, unsigned off, int value);
void poke(unsigned seg, unsigned off, unsigned value);
unsigned getds(void);
int spawn(char *path, char *args);
void disable(void);
void enable(void);

#endif
