#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    const char *path = getenv("QUICKTTY_CLAUDE_MOCK_MARKER");
    if (path) {
        int marker = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (marker >= 0) {
            const char line[] = "mock-empty-keychain\n";
            (void)write(marker, line, sizeof(line) - 1);
            (void)close(marker);
        }
    }
    return 44;
}
