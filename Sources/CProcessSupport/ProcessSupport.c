#include "CProcessSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

int gk_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
             pid_t *pid, int *stdout_fd, int *stderr_fd)
{
    int out[2] = {-1, -1}, err[2] = {-1, -1}, result = 0;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int attributes_ready = 0, actions_ready = 0;
    *pid = 0; *stdout_fd = -1; *stderr_fd = -1;
    if (pipe(out) || pipe(err)) { result = errno; goto cleanup; }
    for (int i = 0; i < 2; ++i) {
        if (fcntl(out[i], F_SETFD, FD_CLOEXEC) || fcntl(err[i], F_SETFD, FD_CLOEXEC)) {
            result = errno; goto cleanup;
        }
    }
    if (fcntl(out[0], F_SETFL, O_NONBLOCK) || fcntl(err[0], F_SETFL, O_NONBLOCK)) {
        result = errno; goto cleanup;
    }
    if ((result = posix_spawnattr_init(&attributes))) goto cleanup;
    attributes_ready = 1;
    if ((result = posix_spawn_file_actions_init(&actions))) goto cleanup;
    actions_ready = 1;
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGHUP); sigaddset(&defaults, SIGQUIT); sigaddset(&defaults, SIGPIPE);
#define ACTION(call) do { if ((result = (call))) goto cleanup; } while (0)
    ACTION(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK |
                                    POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT));
    ACTION(posix_spawnattr_setpgroup(&attributes, 0));
    ACTION(posix_spawnattr_setsigmask(&attributes, &empty));
    ACTION(posix_spawnattr_setsigdefault(&attributes, &defaults));
    ACTION(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
    ACTION(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO));
    ACTION(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO));
    if (cwd) {
        if (__builtin_available(macOS 26.0, *)) {
            ACTION(posix_spawn_file_actions_addchdir(&actions, cwd));
        } else {
            ACTION(posix_spawn_file_actions_addchdir_np(&actions, cwd));
        }
    }
    ACTION(posix_spawn(pid, path, &actions, &attributes, argv, envp));
    *stdout_fd = out[0]; out[0] = -1;
    *stderr_fd = err[0]; err[0] = -1;
cleanup:
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    for (int i = 0; i < 2; ++i) {
        if (out[i] >= 0) close(out[i]);
        if (err[i] >= 0) close(err[i]);
    }
    return result;
#undef ACTION
}

int gk_wait_without_reaping(pid_t pid, int *exit_code, int *signal_number)
{
    siginfo_t info;
    while (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) != 0) {
        if (errno != EINTR) return errno;
    }
    *exit_code = info.si_code == CLD_EXITED ? info.si_status : -1;
    *signal_number = info.si_code == CLD_EXITED ? 0 : info.si_status;
    return 0;
}

int gk_reap(pid_t pid, int *exit_code, int *signal_number)
{
    int status;
    while (waitpid(pid, &status, 0) < 0) { if (errno != EINTR) return errno; }
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    *signal_number = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
    return 0;
}

int gk_identity(pid_t pid, GKProcessIdentity *identity)
{
    struct proc_bsdinfo info;
    memset(identity, 0, sizeof(*identity));
    errno = 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info))
        return errno ? errno : ESRCH;
    identity->pid = pid;
    identity->parent_pid = info.pbi_ppid;
    identity->uid = info.pbi_uid;
    identity->start_seconds = info.pbi_start_tvsec;
    identity->start_microseconds = info.pbi_start_tvusec;
    identity->zombie = info.pbi_status == SZOMB;
    errno = 0;
    if (!identity->zombie && proc_pidpath(pid, identity->path, sizeof(identity->path)) <= 0)
        return errno ? errno : ESRCH;
    return 0;
}

int gk_user_pids(pid_t *pids, int capacity_bytes)
{
    return proc_listpids(PROC_UID_ONLY, getuid(), pids, capacity_bytes);
}

int gk_arguments(pid_t pid, char **buffer, size_t *length)
{
    int argmax = 0, key[] = {CTL_KERN, KERN_ARGMAX};
    size_t size = sizeof(argmax);
    if (sysctl(key, 2, &argmax, &size, NULL, 0) != 0) return errno;
    if (argmax <= 0 || argmax > 2 * 1024 * 1024) return EOVERFLOW;
    char *bytes = malloc((size_t)argmax);
    if (!bytes) return ENOMEM;
    int query[] = {CTL_KERN, KERN_PROCARGS2, pid};
    size = (size_t)argmax;
    if (sysctl(query, 3, bytes, &size, NULL, 0) != 0) {
        int error = errno; free(bytes); return error;
    }
    *buffer = bytes; *length = size;
    return 0;
}

void gk_free(void *pointer) { free(pointer); }
