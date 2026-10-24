/* struct.c - structures, unions and lists */
#include <stdio.h>
#include <stdlib.h>

struct point {
    int x, y;
};

struct rect {
    struct point a, b;
    char name[8];
};

union word {
    unsigned w;
    unsigned char b[2];
};

struct node {
    int value;
    struct node *next;
};

struct rect r1 = { { 1, 2 }, { 10, 20 }, "box" };
struct point pts[3] = { { 1, 1 }, { 2, 4 }, { 3, 9 } };

int area(struct rect *r)
{
    return (r->b.x - r->a.x) * (r->b.y - r->a.y);
}

struct node *push(struct node *list, int v)
{
    struct node *n;
    n = malloc(sizeof(struct node));
    n->value = v;
    n->next = list;
    return n;
}

int main(void)
{
    struct rect r2;
    struct point p, *pp;
    union word u;
    struct node *list, *n;
    int i, total;
    printf("%d %d %s %d\n", r1.a.y, r1.b.x, r1.name, area(&r1));
    r2 = r1;
    r2.a.x = 5;
    r2.name[0] = 'B';
    printf("%d %d %s %s\n", area(&r2), r1.a.x, r2.name, r1.name);
    printf("%d %d %d\n", sizeof(struct point), sizeof(struct rect), sizeof(u));
    u.w = 0x1234;
    printf("%x %x\n", u.b[0], u.b[1]);
    pp = pts;
    total = 0;
    for (i = 0; i < 3; i++, pp++)
        total += pp->x * pp->y;
    printf("%d %d\n", total, pts[2].y);
    p = pts[1];
    p.y++;
    printf("%d %d\n", p.y, pts[1].y);
    list = 0;
    for (i = 1; i <= 5; i++)
        list = push(list, i * i);
    for (n = list; n; n = n->next)
        printf("%d ", n->value);
    printf("\n");
    while (list) {
        n = list->next;
        free(list);
        list = n;
    }
    return 0;
}
