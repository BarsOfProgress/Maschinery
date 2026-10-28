#include "SafeArchive.h"
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
// Stable public libarchive 3 ABI. Apple's SDK ships the dylib stub but omits these headers.
// API declarations: https://github.com/libarchive/libarchive/tree/master/libarchive
struct archive; struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_open_fd(struct archive *, int, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);

int mm_extract_archive(const char *source, const char *destination, int64_t maximum_bytes, int (*cancelled)(void), char *error, size_t error_size) {
    int input = -1, root = -1, parent = -1, file = -1, success = 0;
    struct archive *reader = NULL;
    char *buffer = NULL;
    const char *reason = "Archive extraction failed";
    int64_t total = 0; size_t entries = 0;
    input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat info;
    if (input < 0 || fstat(input, &info) || !S_ISREG(info.st_mode)) { reason = "Archive is not a regular file"; goto done; }
    root = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) { reason = "Cannot open private archive workspace"; goto done; }
    reader = archive_read_new();
    if (!reader) goto done;
    archive_read_support_filter_all(reader); archive_read_support_format_all(reader);
    if (archive_read_open_fd(reader, input, 65536) != 0) { reason = archive_error_string(reader); goto done; }
    buffer = malloc(1024 * 1024); if (!buffer) goto done;
    struct archive_entry *entry; int status;
    while ((status = archive_read_next_header(reader, &entry)) == 0) {
        if (cancelled && cancelled()) { reason = "Cancelled"; goto done; }
        if (++entries > 2000000) { reason = "Archive has too many entries"; goto done; }
        const char *name = archive_entry_pathname(entry);
        if (!name || strlen(name) >= PATH_MAX || name[0] == '/') { reason = "Absolute or oversized archive path"; goto done; }
        if (archive_entry_symlink(entry) || archive_entry_hardlink(entry)) { reason = "Archive links are not permitted"; goto done; }
        mode_t type = archive_entry_filetype(entry);
        if (type != S_IFREG && type != S_IFDIR) { reason = "Archive devices/special files are not permitted"; goto done; }
        char path[PATH_MAX]; strlcpy(path, name, sizeof(path));
        char *save = NULL, *part = strtok_r(path, "/", &save);
        parent = dup(root); if (parent < 0) goto done;
        while (part) {
            if (!strcmp(part, "..")) { reason = "Parent traversal in archive"; goto done; }
            char *next = strtok_r(NULL, "/", &save);
            if (!strcmp(part, ".")) { part = next; continue; }
            if (next || type == S_IFDIR) {
                if (mkdirat(parent, part, 0755) && errno != EEXIST) { reason = "Cannot create archive directory"; goto done; }
                int directory = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (directory < 0) { reason = "Unsafe archive directory"; goto done; }
                close(parent); parent = directory;
            } else {
                file = openat(parent, part, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
                if (file < 0) { reason = "Duplicate or unsafe archive file"; goto done; }
                ssize_t count;
                while ((count = archive_read_data(reader, buffer, 1024 * 1024)) > 0) {
                    if (cancelled && cancelled()) { reason = "Cancelled"; goto done; }
                    if (count > maximum_bytes - total) { reason = "Archive exceeds available space budget"; goto done; }; total += count;
                    ssize_t offset = 0;
                    while (offset < count) { ssize_t written = write(file, buffer + offset, count - offset); if (written <= 0) { reason = "Cannot write archive file"; goto done; }; offset += written; }
                }
                if (count < 0) { reason = archive_error_string(reader); goto done; }
                close(file); file = -1;
            }
            part = next;
        }
        close(parent); parent = -1;
    }
    if (status != 1) { reason = archive_error_string(reader); goto done; }
    success = 1;
done:
    if (!success) snprintf(error, error_size, "%s", reason ? reason : "Unknown archive error");
    if (file >= 0) close(file);
    if (parent >= 0) close(parent);
    if (root >= 0) close(root);
    free(buffer);
    if (reader) archive_read_free(reader);
    if (input >= 0) close(input);
    return success;
}
