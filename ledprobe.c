// ledprobe.c — minimal, dependency-free serial probe for the SkyDimo CH340 controller.
// Opens the port at 115200 8N1 and streams a solid color to all LEDs for a few seconds
// using one of two candidate wire formats, so we can confirm which the firmware speaks.
//
//   cc -O2 -o ledprobe ledprobe.c
//   ./ledprobe /dev/cu.usbserial-130 raw      255 0 0 96   # candidate A: bare RGB stream
//   ./ledprobe /dev/cu.usbserial-130 adalight 0 255 0 96   # candidate B: Adalight 'Ada' header
//
// Safe + reversible: only sends color frames (the LEDs' normal data path). Nothing touches firmware.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <errno.h>

int main(int argc, char **argv) {
    if (argc != 7) {
        fprintf(stderr, "usage: %s <port> <raw|adalight> <r> <g> <b> <nLeds>\n", argv[0]);
        return 2;
    }
    const char *port = argv[1];
    const char *mode = argv[2];
    unsigned char r = (unsigned char)atoi(argv[3]);
    unsigned char g = (unsigned char)atoi(argv[4]);
    unsigned char b = (unsigned char)atoi(argv[5]);
    int n = atoi(argv[6]);
    if (n <= 0 || n > 4096) { fprintf(stderr, "bad nLeds\n"); return 2; }

    int fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) { fprintf(stderr, "open(%s): %s\n", port, strerror(errno)); return 1; }

    struct termios t;
    if (tcgetattr(fd, &t) != 0) { perror("tcgetattr"); return 1; }
    cfmakeraw(&t);
    cfsetispeed(&t, B115200);
    cfsetospeed(&t, B115200);
    t.c_cflag |= (CLOCAL | CREAD);   // ignore modem lines, enable receiver
    t.c_cflag &= ~CRTSCTS;           // no hardware flow control
    t.c_cflag &= ~PARENB;            // no parity
    t.c_cflag &= ~CSTOPB;            // 1 stop bit
    t.c_cflag = (t.c_cflag & ~CSIZE) | CS8;
    if (tcsetattr(fd, TCSANOW, &t) != 0) { perror("tcsetattr"); return 1; }
    fcntl(fd, F_SETFL, 0);           // blocking writes from here on

    // Build the frame.
    int hdr = 0;
    unsigned char header[6];
    if (strcmp(mode, "adalight") == 0) {
        int c = n - 1;               // Adalight encodes (count-1)
        header[0] = 'A'; header[1] = 'd'; header[2] = 'a';
        header[3] = (unsigned char)((c >> 8) & 0xFF);
        header[4] = (unsigned char)(c & 0xFF);
        header[5] = (unsigned char)(header[3] ^ header[4] ^ 0x55);
        hdr = 6;
    } else if (strcmp(mode, "raw") != 0) {
        fprintf(stderr, "mode must be raw or adalight\n"); return 2;
    }

    int body = n * 3;
    int len = hdr + body;
    unsigned char *frame = malloc(len);
    if (hdr) memcpy(frame, header, hdr);
    for (int i = 0; i < n; i++) {
        frame[hdr + i*3 + 0] = r;
        frame[hdr + i*3 + 1] = g;
        frame[hdr + i*3 + 2] = b;
    }

    fprintf(stderr, "mode=%s  n=%d  rgb=(%d,%d,%d)  framelen=%d  -> WATCH THE STRIP for ~3s\n",
            mode, n, r, g, b, len);

    // Stream ~3s so it lands even if the controller auto-resets on port open (Arduino-style).
    for (int rep = 0; rep < 90; rep++) {
        ssize_t w = write(fd, frame, len);
        if (w < 0) { perror("write"); break; }
        tcdrain(fd);
        usleep(33000); // ~30 fps
    }

    free(frame);
    close(fd);
    fprintf(stderr, "done.\n");
    return 0;
}
