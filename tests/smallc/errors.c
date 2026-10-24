/* errors.c - mistakes, each reported on its line */
int f(int a)
{
    return a + y;
}

int g(void)
{
    int x;
    x = ;
    *x = 1;
    return 2;
}

struct s { int a; } v;

int h(void)
{
    return v.b;
}

void k(void)
{
    long z;
    break;
    return 1;
}

int main(void)
{
    int a[3];
    a = 0;
    undefined_function();
    goto nowhere;
}
