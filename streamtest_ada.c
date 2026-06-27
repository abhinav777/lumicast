// streamtest_ada.c — vendor's exact header: "Ada" + 0x00 + nLeds(16-bit big-endian).
// Blinks the WHOLE strip full-white <-> off in one open. If all 4 sides blink, protocol cracked.
//   cc -O2 -o streamtest_ada streamtest_ada.c && ./streamtest_ada /dev/cu.usbserial-130 96

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>

static int openport(const char *p) {
    int fd = open(p, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return -1;
    struct termios t; tcgetattr(fd, &t); cfmakeraw(&t);
    cfsetispeed(&t, B115200); cfsetospeed(&t, B115200);
    t.c_cflag |= (CLOCAL | CREAD); t.c_cflag &= ~CRTSCTS;
    t.c_cflag &= ~PARENB; t.c_cflag &= ~CSTOPB;
    t.c_cflag = (t.c_cflag & ~CSIZE) | CS8;
    tcsetattr(fd, TCSANOW, &t); fcntl(fd, F_SETFL, 0);
    return fd;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <port> <nLeds>\n", argv[0]); return 2; }
    int n = atoi(argv[2]);
    unsigned char hi = (n >> 8) & 0xFF, lo = n & 0xFF;    // count = nLeds (NOT nLeds-1)
    int len = 6 + n * 3;
    unsigned char *frame = malloc(len);
    frame[0] = 'A'; frame[1] = 'd'; frame[2] = 'a'; frame[3] = 0x00; frame[4] = hi; frame[5] = lo;
    fprintf(stderr, "header = Ada 00 %02x %02x  (count=%d)\n", hi, lo, n);

    int fd = openport(argv[1]);
    if (fd < 0) { perror("open"); return 1; }
    for (int cycle = 0; cycle < 6; cycle++) {
        unsigned char v = (cycle % 2 == 0) ? 255 : 0;     // FULL white, then off
        fprintf(stderr, "cycle %d -> %s\n", cycle, v ? "FULL WHITE" : "OFF");
        memset(frame + 6, v, n * 3);
        for (int rep = 0; rep < 30; rep++) { write(fd, frame, len); tcdrain(fd); usleep(33000); }
    }
    memset(frame + 6, 0, n * 3); write(fd, frame, len); tcdrain(fd);
    close(fd);
    fprintf(stderr, "done\n");
    return 0;
}
