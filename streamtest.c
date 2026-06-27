// streamtest.c — opens the port ONCE and blinks the strip white<->off several times,
// to test whether the controller re-latches frames within a single open (raw, no header).
//   cc -O2 -o streamtest streamtest.c && ./streamtest /dev/cu.usbserial-130 96
// If the strip blinks: continuous raw frames re-latch. If it stays stuck: a sync header is needed.

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
    int n = atoi(argv[2]); int len = n * 3;
    unsigned char *frame = malloc(len);
    int fd = openport(argv[1]);
    if (fd < 0) { perror("open"); return 1; }

    for (int cycle = 0; cycle < 6; cycle++) {
        unsigned char v = (cycle % 2 == 0) ? 60 : 0;   // dim white, then off
        fprintf(stderr, "cycle %d -> %s\n", cycle, v ? "WHITE" : "OFF");
        memset(frame, v, len);
        for (int rep = 0; rep < 30; rep++) {           // ~1s of frames at 33ms
            write(fd, frame, len); tcdrain(fd); usleep(33000);
        }
    }
    memset(frame, 0, len);
    write(fd, frame, len); tcdrain(fd);
    close(fd);
    fprintf(stderr, "done\n");
    return 0;
}
