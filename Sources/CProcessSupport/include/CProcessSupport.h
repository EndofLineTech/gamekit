#ifndef GAMEKIT_PROCESS_SUPPORT_H
#define GAMEKIT_PROCESS_SUPPORT_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

int gk_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
             int discard_output, pid_t *pid, int *stdout_fd, int *stderr_fd);
int gk_wait_without_reaping(pid_t pid, int *exit_code, int *signal_number);
int gk_reap(pid_t pid, int *exit_code, int *signal_number);

typedef struct {
    pid_t pid;
    pid_t parent_pid;
    uid_t uid;
    uint64_t start_seconds;
    uint64_t start_microseconds;
    int zombie;
    char path[4096];
} GKProcessIdentity;

int gk_identity(pid_t pid, GKProcessIdentity *identity);
int gk_user_pids(pid_t *pids, int capacity_bytes);
int gk_arguments(pid_t pid, char **buffer, size_t *length);
void gk_free(void *pointer);
#endif
