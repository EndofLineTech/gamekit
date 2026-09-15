/* Surface dyld errors without running Wine or creating a graphics device. */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s /absolute/path/to/library\n", argv[0]);
        return 2;
    }
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "FAIL dlopen: %s\n", dlerror());
        return 1;
    }
    printf("PASS dlopen: %s\n", argv[1]);
    dlclose(library);
    return 0;
}
