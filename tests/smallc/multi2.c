/* multi2.c - the other half of multi.c */
int shared;
static int hidden = 2;

static int helper(void)
{
    return hidden * 100;
}

int twice(int x)
{
    return 2 * x;
}

int other_helper(void)
{
    return helper() + shared;
}
