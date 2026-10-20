/* Synthetic negative checks for the offline, test-only provider sandbox.
 * No real credentials, private provider state, or network peer is accessed.
 */
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <spawn.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--bounded-child") == 0) return 0;
    if (argc != 3) return 10;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) return 11;
    char c;
    if (read(fd, &c, 1) != 1) return 12;
    close(fd);
    fd = open(argv[2], O_RDONLY);
    if (fd >= 0) { close(fd); return 13; }
    if (errno != EPERM && errno != EACCES) return 14;
    fd = open(argv[2], O_WRONLY);
    if (fd >= 0) { close(fd); return 15; }
    if (errno != EPERM && errno != EACCES) return 16;
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons(9);
        int connected = connect(fd, (struct sockaddr *)&address, sizeof(address));
        int error = errno;
        close(fd);
        if (connected == 0 || (error != EPERM && error != EACCES)) return 17;
    } else if (errno != EPERM && errno != EACCES) return 21;
    pid_t child = fork();
    if (!child) _exit(0);
    if (child > 0) { waitpid(child, 0, 0); return 18; }
    char *args[] = {"/usr/bin/true", 0};
    if (posix_spawn(&child, args[0], 0, 0, args, environ) == 0) {
        waitpid(child, 0, 0); return 19;
    }
    char *self_args[] = {argv[0], "--bounded-child", 0};
    if (posix_spawn(&child, self_args[0], 0, 0, self_args, environ) == 0) {
        waitpid(child, 0, 0); return 20;
    }
    return 0;
}
