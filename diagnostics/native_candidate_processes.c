/* Read-only inventory of non-zombie current-user processes in a candidate tree. */
#include "../Sources/CProcessSupport/include/CProcessSupport.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') return 2;
    const size_t length = strlen(argv[1]);
    if (!length || length >= 4096) return 2;
    pid_t *pids = calloc(65536, sizeof(pid_t));
    if (!pids) return 2;
    int bytes = gk_user_pids(pids, 65536 * sizeof(pid_t));
    if (bytes < 0 || bytes >= (int)(65536 * sizeof(pid_t))) { free(pids); return 2; }
    unsigned found = 0, unavailable = 0;
    for (int i = 0; i < bytes / (int)sizeof(pid_t); ++i) {
        GKProcessIdentity identity;
        int error = gk_identity(pids[i], &identity);
        if (error) { if (error != ESRCH && error != ENOENT) ++unavailable; continue; }
        if (identity.zombie) continue;
        if (strncasecmp(identity.path, argv[1], length) || identity.path[length] != '/') continue;
        printf("pid=%d path=%s\n", identity.pid, identity.path);
        ++found;
    }
    free(pids);
    printf("candidate_processes=%u\n", found);
    if (unavailable) { printf("unavailable_process_identities=%u\n", unavailable); return 2; }
    return found ? 1 : 0;
}
