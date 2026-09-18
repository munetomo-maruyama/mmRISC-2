//---------------------------------------------------------------------------
// jtag_rbb.cpp : OpenOCD remote_bitbang server for Verilator (DPI-C)
//
// Protocol (OpenOCD doc/manual/jtag/drivers/remote_bitbang.txt):
//   '0'-'7' : write TCK/TMS/TDI = bit2/bit1/bit0
//   'R'     : read TDO, reply '0' or '1'
//   'r'-'u' : reset {TRST,SRST} (r:00 s:01 t:10 u:11, 1 = asserted)
//   'B'/'b' : blink on/off (ignored)
//   'Q'     : quit
//---------------------------------------------------------------------------
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

extern "C" {

static int listen_fd = -1;
static int client_fd = -1;

int rbb_init(int port)
{
    struct sockaddr_in addr;
    int one = 1;
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) { perror("socket"); return -1; }
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port        = htons(port);
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return -1; }
    if (listen(listen_fd, 1) < 0) { perror("listen"); return -1; }
    printf("[rbb] listening on port %d\n", port);
    fflush(stdout);
    client_fd = accept(listen_fd, NULL, NULL);
    if (client_fd < 0) { perror("accept"); return -1; }
    setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    printf("[rbb] OpenOCD connected\n");
    fflush(stdout);
    return 0;
}

// Process one command.
//   returns 0: no command / blink, 1: pins updated, 2: quit or disconnect
int rbb_tick(int *tck, int *tms, int *tdi, int *trst_n, int *srst_n, int tdo)
{
    char c;
    ssize_t n = read(client_fd, &c, 1);
    if (n == 0) return 2;
    if (n < 0) return (errno == EAGAIN || errno == EINTR) ? 0 : 2;
    switch (c) {
    case '0': case '1': case '2': case '3':
    case '4': case '5': case '6': case '7':
        *tck = (c - '0') >> 2 & 1;
        *tms = (c - '0') >> 1 & 1;
        *tdi = (c - '0') & 1;
        return 1;
    case 'R': {
        char r = tdo ? '1' : '0';
        if (write(client_fd, &r, 1) != 1) return 2;
        return 0;
    }
    case 'r': *trst_n = 1; *srst_n = 1; return 1;
    case 's': *trst_n = 1; *srst_n = 0; return 1;
    case 't': *trst_n = 0; *srst_n = 1; return 1;
    case 'u': *trst_n = 0; *srst_n = 0; return 1;
    case 'Q': return 2;
    default:  return 0;
    }
}

} // extern "C"
