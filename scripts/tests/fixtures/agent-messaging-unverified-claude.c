#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 1;
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
        execv(argv[1], argv + 1);
        _exit(3);
    }
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status)) return 4;
    return WEXITSTATUS(status);
}
