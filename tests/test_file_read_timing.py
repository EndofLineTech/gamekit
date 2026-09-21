"""Verify diagnostic interposition preserves read data/results/errno."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from game_fixtures import GAMES, ROOT


class FileReadTimingTests(unittest.TestCase):
    def test_pipe_read_and_pread_are_preserved_and_contents_are_not_logged(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            helper = root / "trace.dylib"
            program = root / GAMES["primary"]["executable"]
            source = Path(__file__).resolve().parents[1] / "diagnostics/FileReadTiming.m"
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-dynamiclib", "-framework", "Foundation",
                            '-DGAMEKIT_READ_TIMING_DIRECTORY="' + str(root) + '"', str(source), "-o", str(helper)], check=True, capture_output=True)
            fixture = root / "fixture.c"
            fixture.write_text(r'''
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static int pair[2];
static void *send_byte(void *unused) { (void)unused; usleep(600000); write(pair[1], "X", 1); return 0; }
int main(int argc, char **argv) {
    if (argc != 2 || pipe(pair)) return 1;
    pthread_t thread; if (pthread_create(&thread, 0, send_byte, 0)) return 2;
    char byte = 0; errno = E2BIG;
    if (read(pair[0], &byte, 1) != 1 || byte != 'X' || errno != E2BIG) return 3;
    pthread_join(thread, 0); close(pair[0]); close(pair[1]);
    int fd = open(argv[1], O_RDONLY); if (fd < 0) return 4;
    char data[6] = {0}; errno = E2BIG;
    if (pread(fd, data, 5, 2) != 5 || strcmp(data, "ivate") || errno != E2BIG) return 5;
    close(fd);
    if (pread(-1, data, 1, 0) != -1 || errno != EBADF) return 6;
    usleep(1100000); return 0;
}
''')
            subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", str(fixture), "-o", str(program)], check=True, capture_output=True)
            secret = root / "private-data"
            secret.write_text("private-content-not-for-logs")
            env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(helper), WINEPREFIX=str(root),
                       GAMEKIT_SESSION_ID="59435B07-8324-4A5D-AD68-578E7AA813DB",
                       GAMEKIT_DIAGNOSTIC_PROFILE=str(ROOT / "tests/fixtures/games.json"))
            subprocess.run([str(program), str(secret)], env=env, check=True, capture_output=True, timeout=10)
            log = (root / "reads.jsonl").read_text()
            records = [json.loads(line) for line in log.splitlines()]
            self.assertTrue(any(r.get("event") == "slow-read" and r["returnedBytes"] == 1 for r in records))
            totals = [r for r in records if r.get("event") == "totals"]
            self.assertTrue(totals)
            self.assertGreaterEqual(totals[-1]["preadCalls"], 2)
            self.assertGreaterEqual(totals[-1]["preadBytes"], 5)
            self.assertGreater(totals[-1]["preadElapsedNS"], 0)
            self.assertTrue(any(r["preadIntervalMaxNS"] > 0 for r in totals))
            self.assertNotIn("private-content", log)
            self.assertNotIn(str(secret), log)


if __name__ == "__main__":
    unittest.main()
