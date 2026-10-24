/* arith.c - integers as the 8086 has them: 16 bits */
#include <stdio.h>

int sq(int x) { return x * x; }

int main(void)
{
    int a, b, i;
    unsigned u, v;
    char c;
    unsigned char uc;
    a = 7;
    b = -3;
    printf("%d %d %d %d %d\n", a + b, a - b, a * b, a / b, a % b);
    printf("%d %d %d\n", -7 / 2, -7 % 2, 7 / -2);
    u = 65535;
    v = 2;
    printf("%u %u %u %d\n", u + v, u / v, u % 10, u > v);
    a = -1;
    printf("%d %d %d\n", a < 1, (unsigned)a < 1, a >> 1);
    printf("%u %x %X %o\n", u >> 4, 48879, 0xbeef, 8);
    a = 32767;
    a = a + 1;
    printf("%d %d\n", a, sq(200));
    c = 200;
    uc = 200;
    printf("%d %d %d\n", c, uc, c == -56);
    a = 1;
    a <<= 4; a |= 3; a ^= 1; a &= 0x1E; a -= 2; a *= 3; a /= 2; a %= 7;
    printf("%d\n", a);
    i = 5;
    b = i++;
    c = ++i;
    printf("%d %d %d\n", b, c, i--);
    printf("%d %d %d %d\n", !i, ~i, -i, !!i);
    printf("%d %d\n", sizeof(int), sizeof(char *));
    b = (a = 3, a + 4);
    printf("%d %d\n", b, a > 2 ? 10 : 20);
    printf("%d %d %d\n", 1 && 0, 1 || 0, (0 || 5) && 6);
    u = 40000;
    printf("%d %u\n", u > 30000, u * 2);
    printf("%d %u %u %u %d\n", 40000 > 30000, 40000 / 3, 40000 >> 1, 50000u % 7, -1 < 1u);
    return 0;
}
