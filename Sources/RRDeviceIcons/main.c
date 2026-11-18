#include <ctype.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct idevice_private;
struct sbservices_client_private;
typedef struct idevice_private *Device;
typedef struct sbservices_client_private *Springboard;

static void *openLibrary(void) {
    const char *paths[] = {
        "/opt/homebrew/lib/libimobiledevice-1.0.dylib",
        "/usr/local/lib/libimobiledevice-1.0.dylib"
    };
    for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
        void *library = dlopen(paths[index], RTLD_NOW | RTLD_LOCAL);
        if (library != NULL) return library;
    }
    return NULL;
}

static int validBundle(const char *id) {
    size_t length = strlen(id);
    if (length == 0 || length > 255 || !isalnum((unsigned char)*id)) return 0;
    for (const unsigned char *p = (const unsigned char *)id; *p; p++) {
        if (!isalnum(*p) && *p != '.' && *p != '-') return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 3 || argc > 22) return 1;
    void *library = openLibrary();
    if (library == NULL) return 1;
    int (*openDevice)(Device *, const char *, int) = dlsym(library, "idevice_new_with_options");
    int (*freeDevice)(Device) = dlsym(library, "idevice_free");
    int (*openSpringboard)(Device, Springboard *, const char *) = dlsym(library, "sbservices_client_start_service");
    int (*freeSpringboard)(Springboard) = dlsym(library, "sbservices_client_free");
    int (*readIcon)(Springboard, const char *, char **, uint64_t *) = dlsym(library, "sbservices_get_icon_pngdata");
    if (!openDevice || !freeDevice || !openSpringboard || !freeSpringboard || !readIcon) return 1;

    Device device = NULL;
    const int lookupUSB = 1 << 1;
    if (openDevice(&device, argv[1], lookupUSB) != 0) return 1;
    Springboard client = NULL;
    if (openSpringboard(device, &client, "RRDeviceDesk") != 0) {
        freeDevice(device);
        return 1;
    }
    for (int index = 2; index < argc; index++) {
        const char *id = argv[index];
        if (!validBundle(id)) continue;
        char *png = NULL;
        uint64_t length = 0;
        if (readIcon(client, id, &png, &length) == 0 && png && length > 0 && length <= 512 * 1024) {
            printf("%s %zu\n", id, (size_t)length);
            if (fwrite(png, 1, (size_t)length, stdout) != length) {
                free(png);
                break;
            }
        }
        free(png);
    }
    freeSpringboard(client);
    freeDevice(device);
    dlclose(library);
    return ferror(stdout) ? 1 : 0;
}
