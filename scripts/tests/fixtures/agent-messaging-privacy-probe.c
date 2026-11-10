#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 4) return 1;
    FILE *allowed = fopen(argv[1], "r");
    if (!allowed) return 2;
    fclose(allowed);
    FILE *outside = fopen(argv[2], "r");
    if (outside) { fclose(outside); return 3; }
    if (errno != EPERM && errno != EACCES) return 4;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(1);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) return 5;
    if (errno != EPERM && errno != EACCES) return 6;
    close(fd);
    fd = socket(AF_INET, SOCK_STREAM, 0);
    address.sin_port = htons((unsigned short)atoi(argv[3]));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) return 7;
    close(fd);
    puts("PASS: owned file/localhost port allowed; outside file and other port denied");
    return 0;
}
