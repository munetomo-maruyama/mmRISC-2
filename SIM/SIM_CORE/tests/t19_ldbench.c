// t19_ldbench.c : a benchmark made of loads, the way a compiler writes them
//
// t16_bench executes no load at all, so it says nothing about what a longer
// load to use distance would cost. This one is ordinary C built with -O2,
// in four parts that each lean on loads in a different way:
//
//   0  pointer chasing : a list walked node by node, every address comes
//                        out of the load before it (the worst case)
//   1  array sum       : independent loads, the next one does not wait
//   2  string scan     : byte loads, each one tested by a branch right away
//   3  insertion sort  : loads compared with each other and stored back
//
// The cycles of each part go to BENCH_SLOT (printed with +bench), the
// results are checked, and main returns 0 for a pass or the number of the
// part that got a wrong answer.

typedef unsigned long u64;

static inline u64 cycles(void)
{
    u64 c;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(c));
    return c;
}

#define BENCH_SLOT ((volatile u64 *)0x80002100UL)

//---------------------------------------------------------------------
// 0 : a list of 64 nodes, linked in a scattered order
//---------------------------------------------------------------------
struct node {
    struct node *next;
    long         value;
};

#define N_NODES 64
static struct node nodes[N_NODES];

static void build_list(void)
{
    // i -> (i * 37 + 11) mod 64 visits every node once (37 is odd)
    unsigned i = 0;
    for (int k = 0; k < N_NODES; k++) {
        unsigned j = (i * 37 + 11) % N_NODES;
        nodes[i].next  = (k == N_NODES - 1) ? 0 : &nodes[j];
        nodes[i].value = i;
        i = j;
    }
}

static long walk_list(int rounds)
{
    long sum = 0;
    for (int r = 0; r < rounds; r++)
        for (struct node *p = &nodes[0]; p; p = p->next)
            sum += p->value;
    return sum;
}

//---------------------------------------------------------------------
// 1 : an array of 256 words
//---------------------------------------------------------------------
#define N_ARRAY 256
static long array[N_ARRAY];

static long sum_array(int rounds)
{
    long sum = 0;
    for (int r = 0; r < rounds; r++)
        for (int i = 0; i < N_ARRAY; i++)
            sum += array[i];
    return sum;
}

//---------------------------------------------------------------------
// 2 : the length of a string and the count of one character in it
//---------------------------------------------------------------------
#define N_TEXT 400
static char text[N_TEXT + 1];

static long scan_text(int rounds)
{
    long total = 0;
    for (int r = 0; r < rounds; r++) {
        const char *s = text;
        long n = 0, e = 0;
        while (*s) {
            if (*s == 'e') e++;
            s++;
            n++;
        }
        total += n + 1000 * e;
    }
    return total;
}

//---------------------------------------------------------------------
// 3 : insertion sort of 96 numbers
//---------------------------------------------------------------------
#define N_SORT 96
static long keys[N_SORT];

static void fill_keys(void)
{
    unsigned x = 12345;
    for (int i = 0; i < N_SORT; i++) {
        x = x * 1103515245u + 12345u;
        keys[i] = (x >> 16) & 0x7FFF;
    }
}

static void sort_keys(void)
{
    for (int i = 1; i < N_SORT; i++) {
        long k = keys[i];
        int  j = i - 1;
        while (j >= 0 && keys[j] > k) {
            keys[j + 1] = keys[j];
            j--;
        }
        keys[j + 1] = k;
    }
}

//---------------------------------------------------------------------
int main(void)
{
    u64 t0, t1;
    long r;

    build_list();
    for (int i = 0; i < N_ARRAY; i++) array[i] = i * 3 + 1;
    for (int i = 0; i < N_TEXT; i++) text[i] = "the quick brown fox jumps over the lazy dog "[i % 44];
    text[N_TEXT] = 0;
    fill_keys();

    t0 = cycles();
    r = walk_list(20);
    t1 = cycles();
    BENCH_SLOT[0] = t1 - t0;
    if (r != 20L * (N_NODES * (N_NODES - 1) / 2)) return 1;

    t0 = cycles();
    r = sum_array(10);
    t1 = cycles();
    BENCH_SLOT[1] = t1 - t0;
    if (r != 10L * (3L * N_ARRAY * (N_ARRAY - 1) / 2 + N_ARRAY)) return 2;

    t0 = cycles();
    r = scan_text(4);
    t1 = cycles();
    BENCH_SLOT[2] = t1 - t0;
    // 400 characters, 9 full sentences of 44 and 4 more ("the "): 3 e each
    // sentence and one in the tail
    if (r != 4L * (400 + 1000 * (9 * 3 + 1))) return 3;

    t0 = cycles();
    sort_keys();
    t1 = cycles();
    BENCH_SLOT[3] = t1 - t0;
    for (int i = 1; i < N_SORT; i++)
        if (keys[i - 1] > keys[i]) return 4;

    return 0;
}
